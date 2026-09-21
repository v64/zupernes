// ZuperNES browser-theater WASM adapter
//
// This is the freestanding wasm32 "host" around the REAL emulator core
// (src/root.zig Emulator), published to the page as zupernes.wasm. It has
// NO imports: the browser (and `node test/theater/wasm-check.mjs`, which
// requires "a WASM instance ... from Node with no imports") instantiate it
// bare. Everything it does is memory-only; the ONLY host-dependent piece of
// the native code path - the DSP microcode dump lookup in the old
// Emulator.loadRom - was hoisted out to Emulator.loadRomFilesystemFree so
// native and WASM build the identical machine (see src/root.zig).
//
// CONTRACT (documented in test/theater/TASK.md, mirrored here):
//   All pointers are wasm32 byte offsets into the exported linear memory.
//   Status returns are 0 = success, nonzero = failure; the numeric error
//   codes are the enum below (also printed by the page on failure paths).
//
//   zn_alloc(len)        -> ptr    Owned upload/output memory (positive ptr,
//                                  0 on failure). Recycled by the caller
//                                  with zn_free(ptr, len).
//   zn_free(ptr, len)             Release a matching zn_alloc allocation.
//   zn_load_rom(ptr,len) -> st    Clone/own the ROM bytes, build a FRESH
//                                  machine, default FF SRAM. Atomic fail.
//   zn_run_frame(btns)   -> st    Set controller 1, run EXACTLY one frame.
//   zn_reset()           -> st    Cold boot of current ROM, SRAM preserved,
//                                  pending audio discarded.
//   zn_width/height()     = 256/224
//   zn_framebuffer_ptr() -> 256x224 LE RGB15 u16 (live: do not cache views)
//   zn_wram_ptr()        -> 128 KiB live WRAM (diagnostic surface)
//   zn_sram_ptr/_len()   -> cartridge SRAM bytes and size (before running)
//   zn_read_audio(ptr,max) -> n   Drain up to max stereo i16 pairs @32kHz.
//
// MOST IMPORTANT DESIGN RULES, from the TASK contract:
//  - Own the ROM bytes for the cartridge lifetime: zn_load_rom CLONES the
//    caller's upload, so the host may scribble/free its buffer immediately
//    (wasm-check.mjs verifies exactly that by filling 0xcc after load).
//  - The Emulator struct is large and self-referential; it lives at ONE
//    stable global slot. zn_reset rebuilds the CPU/PPU/DMA state in place,
//    exactly like a cold power cycle minus the ROM swap.
//  - Never cache TypedArray views across memory growth or machine
//    replacement: every zn_*_ptr()/read re-derives its slice from the
//    current Emulator fields, so a memory.growth (allocation) invalidates
//    nothing the host holds past the call that returned it.

const std = @import("std");
const zupernes = @import("zupernes");
const Emulator = zupernes.Emulator;

/// Documented numeric error codes (TASK.md: "Document numeric errors").
/// 1 = no ROM loaded (operation requires a cartridge),
/// 2 = the load itself failed (bad/short ROM - error.RomTooSmall etc.),
/// 3 = allocation failure,
/// 4 = bad arguments (null pointer / zero length where invalid, free-size
///     mismatch - see allocOwnership below).
pub const ZN_ERR_NO_ROM: i32 = 1;
pub const ZN_ERR_LOAD: i32 = 2;
pub const ZN_ERR_ALLOC: i32 = 3;
pub const ZN_ERR_ARGS: i32 = 4;
/// Unsupported-cartridge preflight codes (documented in the contract table).
pub const ZN_ERR_COPROCESSOR: i32 = 5;
pub const ZN_ERR_MAPPING: i32 = 6;
pub const ZN_ERR_REGION: i32 = 7;
pub const ZN_ERR_HEADER: i32 = 8;

const wasm_alloc = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &std.heap.WasmAllocator.vtable,
};

// ---------------------------------------------------------------------------
// Allocation registry. TASK.md's contract is plain: zn_alloc hands out
// OWNED memory, zn_free "releases a matching allocation" - nothing limits
// the host to one live allocation. The registry records every live
// (ptr,len) pair; zn_free verifies the pair is one of them (WasmAllocator's
// free is only safe on the exact pair that was allocated) and removes it.
// A pair that was never allocated (or already freed) is refused with ARGS
// instead of corrupting the freelist. The registry is a fixed table of
// MAX_ALLOCATIONS slots, reused as a free list, so the bookkeeping itself
// never allocates.
// ---------------------------------------------------------------------------
const MAX_ALLOCATIONS = 256;
var alloc_ptrs: [MAX_ALLOCATIONS]usize = @splat(0);
var alloc_lens: [MAX_ALLOCATIONS]usize = @splat(0);
var last_error: i32 = 0;

fn registryInsert(ptr: usize, len: usize) bool {
    for (&alloc_ptrs, &alloc_lens) |*slot, *slot_len| {
        if (slot.* == 0) {
            slot.* = ptr;
            slot_len.* = len;
            return true;
        }
    }
    return false; // table full: refuse rather than track a free we cannot verify
}
fn registryRemove(ptr: usize, len: usize) bool {
    for (&alloc_ptrs, &alloc_lens) |*slot, *slot_len| {
        if (slot.* == ptr) {
            if (slot_len.* != len) return false; // not a matching pair
            slot.* = 0;
            slot_len.* = 0;
            return true;
        }
    }
    return false; // not a live allocation
}

// ---------------------------------------------------------------------------
// Machine state. The Emulator is ~940 KB and self-referential, so it can
// NEVER live on the wasm stack (a 1 MB default stack with a 940 KB frame is
// an out-of-bounds trap before the first instruction runs). Instead the
// machine is allocated ONCE from the wasm heap at first successful load and
// NEVER moved: every interior pointer set up by Emulator.setup stays valid
// for the whole cartridge lifetime, which is exactly the "stable address"
// rule on Emulator.setup. zn_reset reloads the same ROM INTO that machine.
// ---------------------------------------------------------------------------

// The single machine; `rom_loaded` decides whether it holds a live
// cartridge.
var emulator: ?*Emulator = null;

// The owned ROM clone. The Cartridge borrows this slice (rom: []const u8
// with the copier header stripped), so it must outlive the machine. On
// zn_reset (same-ROM cold boot) hardware maps the SAME cartridge, so the
// bytes are reused; the battery SRAM inside the machine is explicitly
// preserved across the reload (see zn_reset).
var rom_bytes: ?[]u8 = null;

export fn zn_alloc(len: usize) usize {
    // Owned upload/output memory for the host, recorded in the registry so
    // a matching zn_free can be verified later (any order, many live at
    // once - the TASK.md contract, no single-slot LIFO invention).
    if (len == 0) return 0;
    const bytes = wasm_alloc.alloc(u8, len) catch {
        last_error = ZN_ERR_ALLOC;
        return 0;
    };
    const ptr = @intFromPtr(bytes.ptr);
    if (!registryInsert(ptr, bytes.len)) {
        // Registry full: free immediately and fail so the host never sees
        // an allocation it cannot release.
        wasm_alloc.free(bytes);
        last_error = ZN_ERR_ALLOC;
        return 0;
    }
    return ptr;
}

export fn zn_free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;
    if (!registryRemove(ptr, len)) {
        // Not a live (ptr,len) pair from zn_alloc: refuse rather than
        // corrupt the allocator freelist with an unverifiable pointer.
        last_error = ZN_ERR_ARGS;
        return;
    }
    const bytes: [*]u8 = @ptrFromInt(ptr);
    wasm_alloc.free(bytes[0..len]);
}

// ---------------------------------------------------------------------------
// Supported-cartridge preflight. One classifier, in the adapter next to
// the core it gates, so every host (page, Node checks) applies the SAME
// acceptance rules with no divergent JS copy. The rules mirror the core's
// own header interpretation (src/cartridge.zig detectCartridgeType +
// chip parsing); a dump the core can map but this browser build cannot
// support (coprocessor, ExHiROM-style mapping, PAL region) is refused
// with an actionable code BEFORE any machine state is touched, so the
// previous session stays intact. Bad checksums are explicitly NOT a
// rejection reason (TASK.md); copier headers are stripped by size rule
// in Cartridge.init already.
// ---------------------------------------------------------------------------
fn scoreHeaderAdapter(rom: []const u8, base: usize, expect_hirom: bool) u32 {
    // The core's header plausibility scoring (src/cartridge.zig
    // scoreHeader), restated locally so the preflight cannot drift from
    // what Cartridge.init will actually map. Same weights, same criteria.
    if (rom.len < base + 0x40) return 0;
    var score: u32 = 0;
    const checksum = @as(u16, rom[base + 0x1C]) | (@as(u16, rom[base + 0x1D]) << 8);
    const complement = @as(u16, rom[base + 0x1E]) | (@as(u16, rom[base + 0x1F]) << 8);
    if (checksum +% complement == 0xFFFF) score += 8;
    const map_mode = rom[base + 0x15];
    const mode_is_hirom = (map_mode & 0x01) != 0;
    if ((map_mode & 0xE0) == 0x20 and mode_is_hirom == expect_hirom) score += 4;
    const reset = @as(u16, rom[base + 0x3C]) | (@as(u16, rom[base + 0x3D]) << 8);
    if (reset >= 0x8000) score += 2;
    return score;
}

fn validateCartridge(rom_all: []const u8) i32 {
    if (rom_all.len < 0x8000) return ZN_ERR_ARGS;
    // Apply the same copier-header normalization Cartridge.init uses, so a
    // headered dump validates against its real internal header.
    const rom = if (rom_all.len % 0x8000 == 512) rom_all[512..] else rom_all;
    if (rom.len < 0x8000) return ZN_ERR_ARGS;

    // Locate the internal header with the core's own scoring. A dump where
    // NEITHER candidate location scores anything (no checksum agreement,
    // no map byte, no plausible reset vector) is a malformed dump, not an
    // ordinary SNES cartridge.
    const lorom_score = scoreHeaderAdapter(rom, 0x7FC0, false);
    const hirom_score = scoreHeaderAdapter(rom, 0xFFC0, true);
    // A reset vector alone (score 2) is not evidence of an internal
    // header - a garbage dump passes it by chance. Require at least the
    // map-mode byte (4) or checksum agreement (8) at one location.
    if (lorom_score < 4 and hirom_score < 4) return ZN_ERR_HEADER;
    const base: usize = if (lorom_score >= hirom_score) 0x7FC0 else 0xFFC0;

    // Mapping mode ($xxD5): $20/$30 LoROM, $21/$31 HiROM - everything
    // else (ExHiROM $25/$35 and beyond) is outside the ordinary envelope.
    const map_mode = rom[base + 0x15];
    const recognized = (map_mode & 0xE0) == 0x20 and ((map_mode & 0x0F) == 0x00 or (map_mode & 0x0F) == 0x01);
    if (!recognized) return ZN_ERR_MAPPING;

    // Chip type ($xxD6): the core emulates plain ROM (0x00) and
    // ROM+RAM(+battery) boards (0x01/0x02). 0x03-0x05 announce DSP
    // coprocessors the browser cannot feed microcode; >= 0x0F are other
    // coprocessors the core does not implement at all.
    const chip = rom[base + 0x16];
    if ((chip >= 0x03 and chip <= 0x05) or chip >= 0x0F) return ZN_ERR_COPROCESSOR;

    // Destination code ($xxD9): 0 = Japan, 1 = US; both NTSC. 2+ is PAL,
    // whose timing this build does not emulate.
    const destination = rom[base + 0x19];
    if (destination >= 2) return ZN_ERR_REGION;

    return 0;
}

export fn zn_load_rom(ptr: usize, len: usize) i32 {
    if (ptr == 0 or len < 0x8000) {
        last_error = ZN_ERR_ARGS;
        return ZN_ERR_ARGS;
    }
    // CLONE first: the caller's upload is temporary (it may be clobbered or
    // freed as soon as this returns) and the cartridge must own its bytes.
    const source: [*]const u8 = @ptrFromInt(ptr);
    const rom_copy = wasm_alloc.alloc(u8, len) catch {
        last_error = ZN_ERR_ALLOC;
        return ZN_ERR_ALLOC;
    };
    @memcpy(rom_copy, source[0..len]);

    // Validate BEFORE touching the previous session: a load failure (e.g. a
    // 17-byte "ROM") must leave the previous game and its saves intact
    // (TASK.md: atomic failure). The preflight enforces the supported
    // NTSC ordinary-LoROM/HiROM envelope first (actionable codes), then
    // Cartridge.init re-checks structurally.
    {
        const prefault = validateCartridge(rom_copy);
        if (prefault != 0) {
            wasm_alloc.free(rom_copy);
            last_error = prefault;
            return prefault;
        }
    }
    _ = zupernes.Cartridge.init(rom_copy) catch {
        wasm_alloc.free(rom_copy);
        last_error = ZN_ERR_LOAD;
        return ZN_ERR_LOAD;
    };

    // Build the FRESH machine. The first successful load allocates the
    // ~940 KB Emulator slot from the wasm heap; later loads reuse the same
    // stable address (the old machine is simply overwritten in place).
    var machine: *Emulator = undefined;
    if (emulator) |m| {
        machine = m;
    } else {
        machine = wasm_alloc.create(Emulator) catch {
            wasm_alloc.free(rom_copy);
            last_error = ZN_ERR_ALLOC;
            return ZN_ERR_ALLOC;
        };
    }
    machine.* = Emulator.init();
    machine.setup();
    machine.loadRomFilesystemFree(rom_copy) catch {
        // ROM rejected: nothing committed, the previous session survives.
        wasm_alloc.free(rom_copy);
        last_error = ZN_ERR_LOAD;
        return ZN_ERR_LOAD;
    };
    // Commit: replace the old cartridge's owned bytes. No dangling core
    // pointers exist by construction - `machine` IS the live machine and
    // every interior pointer now points into the new cartridge.
    if (rom_bytes) |old| wasm_alloc.free(old);
    rom_bytes = rom_copy;
    emulator = machine;
    last_error = 0;
    return 0;
}

export fn zn_reset() i32 {
    if (emulator == null or rom_bytes == null) return ZN_ERR_NO_ROM;
    const machine = emulator.?;
    const cart = machine.bus.cartridge orelse return ZN_ERR_NO_ROM;
    // COLD boot: rebuild the whole machine over the SAME ROM bytes at the
    // same stable address, then RESTORE the battery SRAM - "a cold boot of
    // the same ROM retaining battery SRAM" (TASK.md). Everything else
    // (CPU, PPU, APU, DMA - and any DSP state) powers up fresh.
    var sram: [32 * 1024]u8 = undefined;
    const sram_size = cart.sram_size;
    @memcpy(sram[0..sram_size], cart.sram[0..sram_size]);
    machine.* = Emulator.init();
    machine.setup();
    machine.loadRomFilesystemFree(rom_bytes.?) catch {
        last_error = ZN_ERR_LOAD;
        return ZN_ERR_LOAD;
    };
    @memcpy(machine.bus.cartridge.?.sram[0..sram_size], sram[0..sram_size]);
    // Pending audio from the dead machine is already gone with it: the DSP
    // sample ring belongs to the discarded APU ("clear pending audio").
    return 0;
}

export fn zn_run_frame(buttons: u16) i32 {
    const machine = emulator orelse return ZN_ERR_NO_ROM;
    // Set controller 1 then run exactly one frame (TASK.md). setJoypad
    // masks to 0xFFF0 like the $4218/$4219 hardware layout.
    machine.setJoypad(0, buttons);
    machine.runFrame();
    return 0;
}

export fn zn_width() u32 {
    return 256;
}

export fn zn_height() u32 {
    return 224;
}

export fn zn_framebuffer_ptr() usize {
    const machine = emulator orelse return 0;
    return @intFromPtr(machine.getFramebuffer().ptr);
}

export fn zn_wram_ptr() usize {
    const machine = emulator orelse return 0;
    return @intFromPtr(&machine.bus.wram);
}

export fn zn_sram_ptr() usize {
    const machine = emulator orelse return 0;
    // `orelse` on a value optional would COPY the payload to the stack and
    // hand out a dangling pointer; capture a POINTER to the payload instead.
    const cart = &(machine.bus.cartridge orelse return 0);
    return @intFromPtr(&cart.sram);
}

export fn zn_sram_len() usize {
    const machine = emulator orelse return 0;
    const cart = &(machine.bus.cartridge orelse return 0);
    return cart.sram_size;
}

export fn zn_read_audio(ptr: usize, max_frames: usize) i32 {
    if (ptr == 0) return ZN_ERR_ARGS;
    if (emulator == null) return 0;
    if (max_frames == 0) return 0;
    const machine = emulator.?;
    // Drain up to max_frames stereo i16 pairs into the (zn_alloc'd) output
    // buffer, never exceeding its capacity: the slice length IS the capacity
    // readSamples will write.
    const dst: [][2]i16 = @as([*][2]i16, @ptrFromInt(ptr))[0..max_frames];
    var total: usize = 0;
    while (total < max_frames) {
        const n = machine.readAudioSamples(dst[total..]);
        if (n == 0) break;
        total += n;
    }
    return @intCast(total);
}

/// Adapter-level diagnostic for tests: the frame counter (0 with no ROM).
export fn zn_frame_count() u64 {
    const machine = emulator orelse return 0;
    return machine.ppu.frame_count;
}

/// Adapter-level diagnostic: the last recorded error code (0 = none).
export fn zn_last_error() i32 {
    return last_error;
}

// ---------------------------------------------------------------------------
// A freestanding wasm module is only a set of exported entry points; the
// compiler analyzes exactly what the ROOT file references. Without an
// explicit reference the export functions would not be semantically
// analyzed, and wasm-ld garbage-collects functions that were never code-
// generated - leaving a module that exports only `memory`. Referencing the
// set here through comptime forces the exports to exist in the object
// before linking, which is where the zn_* contract lives.
// ---------------------------------------------------------------------------
comptime {
    _ = &zn_alloc;
    _ = &zn_free;
    _ = &zn_load_rom;
    _ = &zn_run_frame;
    _ = &zn_reset;
    _ = &zn_width;
    _ = &zn_height;
    _ = &zn_framebuffer_ptr;
    _ = &zn_wram_ptr;
    _ = &zn_sram_ptr;
    _ = &zn_sram_len;
    _ = &zn_read_audio;
    _ = &zn_frame_count;
    _ = &zn_last_error;
}

