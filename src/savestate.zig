// =============================================================================
// SAVESTATE - pointer-free machine state capture and restore
// =============================================================================
// A general emulator capability: snapshot the whole machine, restore it later,
// and continue execution identically. It is CAPTURE-ONLY in the same sense as
// the VRAM- and WRAM-write source traces: nothing here runs during ordinary
// emulation, no emulated behavior is altered by its existence, and taking a
// snapshot does not perturb the machine it snapshots.
//
// WHY A BYTE LAYOUT RATHER THAN A STRUCT DUMP
// -----------------------------------------------------------------------------
// `Emulator` is self-referential: `Bus.init(&ppu)` and `Cpu.init(&bus)` store
// interior pointers, and `Bus.cartridge.rom` is a slice into caller-owned ROM.
// A memcpy of the struct would capture those addresses and restoring it at a
// different address would corrupt the machine silently. So the format is an
// explicit little-endian byte layout of the POINTER-FREE state only, and
// `read` assigns field by field so every pointer in the destination survives
// untouched. This mirrors the existing `Apu.writeState`/`readState` contract,
// which this module reuses wholesale for the audio half.
//
// WHAT IS DELIBERATELY NOT CAPTURED
// -----------------------------------------------------------------------------
//   - `cpu.bus`, `bus.ppu`, `bus.flat_mem`  - interior pointers, re-established
//     by `Emulator.setup()` and preserved across `read`.
//   - `cartridge.rom` and the fields derived from it (cart_type, rom_size,
//     sram_size, has_dsp) - immutable; re-supplied by `loadRom`. Cartridge
//     SRAM *is* captured, because games mutate it.
//   - `dsp1.program` / `dsp1.data_rom` - immutable microcode, reloaded by
//     `loadRom`. The DSP's mutable registers and data RAM ARE captured.
//   - `ppu.vram_trace` / `bus.wram_trace` - capture-only debug buffers that no
//     emulated behavior reads. Restoring into a machine leaves whatever trace
//     configuration the caller set up, which is what a debugging caller wants.
//
// Everything else the machine can observe is captured, including the
// framebuffer and the exact intra-frame position (scanline/dot/master_accum),
// so a snapshot is valid mid-frame and not only on frame boundaries.
// =============================================================================

const std = @import("std");
const Cpu = @import("cpu/cpu.zig").Cpu;
const CpuFlags = @import("cpu/cpu.zig").Flags;
const Bus = @import("bus.zig").Bus;
const ppu_mod = @import("ppu/ppu.zig");
const Ppu = ppu_mod.Ppu;
const Dma = @import("dma.zig").Dma;
const Apu = @import("apu/apu.zig").Apu;

/// Bumped whenever the byte layout changes, so a stale snapshot is REJECTED
/// rather than silently misread - a savestate that quietly disagrees with the
/// machine would poison every recording built on it.
pub const magic = "ZNSAVE\x00\x01";

const fb_bytes = ppu_mod.SCREEN_WIDTH * ppu_mod.SCREEN_HEIGHT * 2;

pub const Error = error{ BadMagic, ShortBuffer };

// ---- little-endian scalar helpers -------------------------------------------

fn putU8(dst: []u8, at: *usize, value: u8) void {
    dst[at.*] = value;
    at.* += 1;
}
fn getU8(src: []const u8, at: *usize) u8 {
    const value = src[at.*];
    at.* += 1;
    return value;
}
fn putBool(dst: []u8, at: *usize, value: bool) void {
    putU8(dst, at, @intFromBool(value));
}
fn getBool(src: []const u8, at: *usize) bool {
    return getU8(src, at) != 0;
}
fn putU16(dst: []u8, at: *usize, value: u16) void {
    for (0..2) |i| dst[at.* + i] = @truncate(value >> @intCast(i * 8));
    at.* += 2;
}
fn getU16(src: []const u8, at: *usize) u16 {
    var value: u16 = 0;
    for (0..2) |i| value |= @as(u16, src[at.* + i]) << @intCast(i * 8);
    at.* += 2;
    return value;
}
fn putU32(dst: []u8, at: *usize, value: u32) void {
    for (0..4) |i| dst[at.* + i] = @truncate(value >> @intCast(i * 8));
    at.* += 4;
}
fn getU32(src: []const u8, at: *usize) u32 {
    var value: u32 = 0;
    for (0..4) |i| value |= @as(u32, src[at.* + i]) << @intCast(i * 8);
    at.* += 4;
    return value;
}
fn putU64(dst: []u8, at: *usize, value: u64) void {
    for (0..8) |i| dst[at.* + i] = @truncate(value >> @intCast(i * 8));
    at.* += 8;
}
fn getU64(src: []const u8, at: *usize) u64 {
    var value: u64 = 0;
    for (0..8) |i| value |= @as(u64, src[at.* + i]) << @intCast(i * 8);
    at.* += 8;
    return value;
}
fn putI16(dst: []u8, at: *usize, value: i16) void {
    putU16(dst, at, @bitCast(value));
}
fn getI16(src: []const u8, at: *usize) i16 {
    return @bitCast(getU16(src, at));
}

// ---- sizing ------------------------------------------------------------------

/// Exact snapshot size. Asserted against the cursor at the end of both
/// `write` and `read`, so a layout edit that forgets one side fails loudly.
pub const state_len: usize = blk: {
    var n: usize = magic.len;
    // CPU
    n += 2 * 5 + 3 + 2 + 1 + 1 + 1 + 4 + 1 + 4 + 8 + 8 + 3;
    // PPU arrays
    n += 64 * 1024 + 512 + 544 + fb_bytes;
    // PPU scalars
    n += 15 + 8 * 2 + 1 + 2 + 1 + 13 + 2 + 1 + 1 + 1 + 8 * 2 + 1 + 4 +
        2 + 2 + 2 + 1 + 2 + 2 + 2 + 8 + 4 + 1 + 4 + 4;
    // Bus arrays
    n += 128 * 1024 + 1 + 32 * 1024;
    // DMA
    n += 8 * (1 + 1 + 4 + 2 + 1 + 2 + 1 + 1) + 2;
    // Bus scalars
    n += 4 + 1 + 2 + 2 + 1 + 1 + 1 + 1 + 2 + 1 + 2 + 2 + 1 +
        2 + 2 + 1 + 2 + 2 + 1 + 4 + 4 + 1 + 1 + 1 + 4 + 4 + 4;
    // APU
    n += Apu.state_len;
    // DSP-1 mutable state: ram, pc, stack, sp, a, b, flaga, flagb,
    // eleven u16 registers, dp, idb.
    n += 256 * 2 + 2 + 16 * 2 + 1 + 2 + 2 + 1 + 1 + 2 * 11 + 1 + 2;
    // Emulator
    n += 2;
    break :blk n;
};

// ---- write -------------------------------------------------------------------

pub fn write(
    cpu: *const Cpu,
    ppu: *const Ppu,
    bus: *const Bus,
    last_scanline: u16,
    dst: []u8,
) Error!usize {
    if (dst.len < state_len) return Error.ShortBuffer;
    var at: usize = 0;
    @memcpy(dst[at..][0..magic.len], magic);
    at += magic.len;

    // ---- CPU ----
    putU16(dst, &at, cpu.a);
    putU16(dst, &at, cpu.x);
    putU16(dst, &at, cpu.y);
    putU16(dst, &at, cpu.sp);
    putU16(dst, &at, cpu.pc);
    putU8(dst, &at, cpu.dbr);
    putU8(dst, &at, cpu.ea_bank);
    putU8(dst, &at, cpu.pbr);
    putU16(dst, &at, cpu.dp);
    putU8(dst, &at, cpu.p.toByte());
    putBool(dst, &at, cpu.emulation_mode);
    putU8(dst, &at, cpu.cycles);
    putU32(dst, &at, cpu.mem_masters);
    putU8(dst, &at, cpu.mem_accesses);
    putU32(dst, &at, cpu.internal_flushed);
    putU64(dst, &at, cpu.total_cycles);
    putU64(dst, &at, cpu.instruction_count);
    putBool(dst, &at, cpu.nmi_pending);
    putBool(dst, &at, cpu.irq_pending);
    putBool(dst, &at, cpu.waiting);

    // ---- PPU memories ----
    @memcpy(dst[at..][0 .. 64 * 1024], &ppu.vram);
    at += 64 * 1024;
    @memcpy(dst[at..][0..512], &ppu.cgram);
    at += 512;
    @memcpy(dst[at..][0..544], &ppu.oam);
    at += 544;
    for (ppu.framebuffer) |px| putU16(dst, &at, px);

    // ---- PPU registers ----
    for ([_]u8{
        ppu.inidisp, ppu.obsel,   ppu.oamaddl, ppu.oamaddh, ppu.bgmode,
        ppu.mosaic,  ppu.bg1sc,   ppu.bg2sc,   ppu.bg3sc,   ppu.bg4sc,
        ppu.bg12nba, ppu.bg34nba, ppu.vmain,   ppu.vmaddl,  ppu.vmaddh,
    }) |v| putU8(dst, &at, v);
    for ([_]u16{
        ppu.bg1hofs, ppu.bg1vofs, ppu.bg2hofs, ppu.bg2vofs,
        ppu.bg3hofs, ppu.bg3vofs, ppu.bg4hofs, ppu.bg4vofs,
    }) |v| putU16(dst, &at, v);
    putU8(dst, &at, ppu.tm);
    putBool(dst, &at, ppu.tm_force != null);
    putU8(dst, &at, ppu.tm_force orelse 0);
    putU8(dst, &at, ppu.ts);
    for ([_]u8{
        ppu.w12sel, ppu.w34sel,  ppu.wobjsel, ppu.wh0, ppu.wh1,
        ppu.wh2,    ppu.wh3,     ppu.wbglog,  ppu.wobjlog,
        ppu.tmw,    ppu.tsw,     ppu.cgwsel,  ppu.cgadsub,
    }) |v| putU8(dst, &at, v);
    putU16(dst, &at, ppu.coldata);
    putU8(dst, &at, ppu.scroll_latch);
    putBool(dst, &at, ppu.scroll_latch_set);
    putU8(dst, &at, ppu.m7sel);
    for ([_]i16{
        ppu.m7a, ppu.m7b, ppu.m7c,     ppu.m7d,
        ppu.m7x, ppu.m7y, ppu.m7hofs,  ppu.m7vofs,
    }) |v| putI16(dst, &at, v);
    putU8(dst, &at, ppu.m7_latch);
    putU32(dst, &at, @bitCast(ppu.mpy_result));
    putU16(dst, &at, ppu.vram_addr);
    putU16(dst, &at, ppu.cgram_addr);
    putU16(dst, &at, ppu.oam_addr);
    putU8(dst, &at, ppu.cgram_latch);
    putU16(dst, &at, ppu.vram_prefetch);
    putU16(dst, &at, ppu.scanline);
    putU16(dst, &at, ppu.dot);
    putU64(dst, &at, ppu.frame_count);
    putU32(dst, &at, ppu.master_accum);
    putU8(dst, &at, ppu.vram_read_buffer);
    putU32(dst, &at, ppu.writer_pc);
    putU32(dst, &at, ppu.dma_src);

    // ---- Bus memories ----
    @memcpy(dst[at..][0 .. 128 * 1024], &bus.wram);
    at += 128 * 1024;
    putBool(dst, &at, bus.cartridge != null);
    if (bus.cartridge) |cart| {
        @memcpy(dst[at..][0 .. 32 * 1024], &cart.sram);
    } else {
        @memset(dst[at..][0 .. 32 * 1024], 0);
    }
    at += 32 * 1024;

    // ---- DMA ----
    for (bus.dma.channels) |ch| {
        putU8(dst, &at, @bitCast(ch.control));
        putU8(dst, &at, ch.b_addr);
        putU32(dst, &at, ch.a_addr);
        putU16(dst, &at, ch.byte_count);
        putU8(dst, &at, ch.indirect_bank);
        putU16(dst, &at, ch.hdma_addr);
        putU8(dst, &at, ch.line_counter);
        putBool(dst, &at, ch.hdma_do_transfer);
    }
    putU8(dst, &at, bus.dma.hdma_enable);
    putU8(dst, &at, bus.dma.hdma_terminated);

    // ---- Bus registers ----
    putU32(dst, &at, bus.wram_addr);
    putU8(dst, &at, bus.nmitimen);
    putU16(dst, &at, bus.htime);
    putU16(dst, &at, bus.vtime);
    putU8(dst, &at, bus.mdmaen);
    putU8(dst, &at, bus.hdmaen);
    putU8(dst, &at, bus.wrmpya);
    putU8(dst, &at, bus.wrmpyb);
    putU16(dst, &at, bus.wrdiv);
    putU8(dst, &at, bus.wrdivb);
    putU16(dst, &at, bus.rddiv);
    putU16(dst, &at, bus.rdmpy);
    putU8(dst, &at, bus.memsel);
    putU16(dst, &at, bus.joypad1);
    putU16(dst, &at, bus.joypad2);
    putBool(dst, &at, bus.joypad2_connected);
    putU16(dst, &at, bus.joy1_latch);
    putU16(dst, &at, bus.joy2_latch);
    putBool(dst, &at, bus.joypad_strobe);
    putU32(dst, &at, bus.joy1_shift);
    putU32(dst, &at, bus.joy2_shift);
    putBool(dst, &at, bus.nmi_flag);
    putBool(dst, &at, bus.irq_flag);
    putBool(dst, &at, bus.dsp1_present);
    putU32(dst, &at, bus.writer_pc);
    putU32(dst, &at, bus.dsp_accum);
    putU32(dst, &at, bus.dma_masters);

    // ---- APU (existing pointer-free contract) ----
    at += bus.apu.writeState(dst[at..]);

    // ---- DSP-1 mutable state (microcode excluded) ----
    for (bus.dsp1.ram) |w| putU16(dst, &at, w);
    putU16(dst, &at, bus.dsp1.pc);
    for (bus.dsp1.stack) |w| putU16(dst, &at, w);
    putU8(dst, &at, bus.dsp1.sp);
    putU16(dst, &at, bus.dsp1.a);
    putU16(dst, &at, bus.dsp1.b);
    putU8(dst, &at, packDspFlags(bus.dsp1.flaga));
    putU8(dst, &at, packDspFlags(bus.dsp1.flagb));
    for ([_]u16{
        bus.dsp1.tr, bus.dsp1.trb, bus.dsp1.rp, bus.dsp1.k, bus.dsp1.l,
        bus.dsp1.m,  bus.dsp1.n,   bus.dsp1.dr, bus.dsp1.sr, bus.dsp1.so,
        bus.dsp1.si,
    }) |v| putU16(dst, &at, v);
    putU8(dst, &at, bus.dsp1.dp);
    putU16(dst, &at, bus.dsp1.idb);

    // ---- Emulator ----
    putU16(dst, &at, last_scanline);

    std.debug.assert(at == state_len);
    return at;
}

// ---- read --------------------------------------------------------------------

/// Restore into a machine that has ALREADY had `setup()` and `loadRom()` run
/// on it with the same ROM. Only serialized fields are assigned, so every
/// interior pointer in the destination survives.
pub fn read(
    cpu: *Cpu,
    ppu: *Ppu,
    bus: *Bus,
    last_scanline: *u16,
    src: []const u8,
) Error!usize {
    if (src.len < state_len) return Error.ShortBuffer;
    if (!std.mem.eql(u8, src[0..magic.len], magic)) return Error.BadMagic;
    var at: usize = magic.len;

    // ---- CPU ----
    cpu.a = getU16(src, &at);
    cpu.x = getU16(src, &at);
    cpu.y = getU16(src, &at);
    cpu.sp = getU16(src, &at);
    cpu.pc = getU16(src, &at);
    cpu.dbr = getU8(src, &at);
    cpu.ea_bank = getU8(src, &at);
    cpu.pbr = getU8(src, &at);
    cpu.dp = getU16(src, &at);
    cpu.p = CpuFlags.fromByte(getU8(src, &at));
    cpu.emulation_mode = getBool(src, &at);
    cpu.cycles = getU8(src, &at);
    cpu.mem_masters = getU32(src, &at);
    cpu.mem_accesses = getU8(src, &at);
    cpu.internal_flushed = getU32(src, &at);
    cpu.total_cycles = getU64(src, &at);
    cpu.instruction_count = getU64(src, &at);
    cpu.nmi_pending = getBool(src, &at);
    cpu.irq_pending = getBool(src, &at);
    cpu.waiting = getBool(src, &at);

    // ---- PPU memories ----
    @memcpy(&ppu.vram, src[at..][0 .. 64 * 1024]);
    at += 64 * 1024;
    @memcpy(&ppu.cgram, src[at..][0..512]);
    at += 512;
    @memcpy(&ppu.oam, src[at..][0..544]);
    at += 544;
    for (&ppu.framebuffer) |*px| px.* = getU16(src, &at);

    // ---- PPU registers ----
    inline for (.{
        "inidisp", "obsel",   "oamaddl", "oamaddh", "bgmode",
        "mosaic",  "bg1sc",   "bg2sc",   "bg3sc",   "bg4sc",
        "bg12nba", "bg34nba", "vmain",   "vmaddl",  "vmaddh",
    }) |name| @field(ppu, name) = getU8(src, &at);
    inline for (.{
        "bg1hofs", "bg1vofs", "bg2hofs", "bg2vofs",
        "bg3hofs", "bg3vofs", "bg4hofs", "bg4vofs",
    }) |name| @field(ppu, name) = getU16(src, &at);
    ppu.tm = getU8(src, &at);
    const tm_force_present = getBool(src, &at);
    const tm_force_value = getU8(src, &at);
    ppu.tm_force = if (tm_force_present) tm_force_value else null;
    ppu.ts = getU8(src, &at);
    inline for (.{
        "w12sel", "w34sel", "wobjsel", "wh0", "wh1",
        "wh2",    "wh3",    "wbglog",  "wobjlog",
        "tmw",    "tsw",    "cgwsel",  "cgadsub",
    }) |name| @field(ppu, name) = getU8(src, &at);
    ppu.coldata = getU16(src, &at);
    ppu.scroll_latch = getU8(src, &at);
    ppu.scroll_latch_set = getBool(src, &at);
    ppu.m7sel = getU8(src, &at);
    inline for (.{
        "m7a", "m7b", "m7c",    "m7d",
        "m7x", "m7y", "m7hofs", "m7vofs",
    }) |name| @field(ppu, name) = getI16(src, &at);
    ppu.m7_latch = getU8(src, &at);
    ppu.mpy_result = @bitCast(getU32(src, &at));
    ppu.vram_addr = getU16(src, &at);
    ppu.cgram_addr = @truncate(getU16(src, &at));
    ppu.oam_addr = @truncate(getU16(src, &at));
    ppu.cgram_latch = getU8(src, &at);
    ppu.vram_prefetch = getU16(src, &at);
    ppu.scanline = getU16(src, &at);
    ppu.dot = getU16(src, &at);
    ppu.frame_count = getU64(src, &at);
    ppu.master_accum = getU32(src, &at);
    ppu.vram_read_buffer = getU8(src, &at);
    ppu.writer_pc = @truncate(getU32(src, &at));
    ppu.dma_src = @truncate(getU32(src, &at));

    // ---- Bus memories ----
    @memcpy(&bus.wram, src[at..][0 .. 128 * 1024]);
    at += 128 * 1024;
    const had_cart = getBool(src, &at);
    if (had_cart) {
        if (bus.cartridge) |*cart| @memcpy(&cart.sram, src[at..][0 .. 32 * 1024]);
    }
    at += 32 * 1024;

    // ---- DMA ----
    for (&bus.dma.channels) |*ch| {
        ch.control = @bitCast(getU8(src, &at));
        ch.b_addr = getU8(src, &at);
        ch.a_addr = @truncate(getU32(src, &at));
        ch.byte_count = getU16(src, &at);
        ch.indirect_bank = getU8(src, &at);
        ch.hdma_addr = getU16(src, &at);
        ch.line_counter = getU8(src, &at);
        ch.hdma_do_transfer = getBool(src, &at);
    }
    bus.dma.hdma_enable = getU8(src, &at);
    bus.dma.hdma_terminated = getU8(src, &at);

    // ---- Bus registers ----
    bus.wram_addr = @truncate(getU32(src, &at));
    bus.nmitimen = getU8(src, &at);
    bus.htime = getU16(src, &at);
    bus.vtime = getU16(src, &at);
    bus.mdmaen = getU8(src, &at);
    bus.hdmaen = getU8(src, &at);
    bus.wrmpya = getU8(src, &at);
    bus.wrmpyb = getU8(src, &at);
    bus.wrdiv = getU16(src, &at);
    bus.wrdivb = getU8(src, &at);
    bus.rddiv = getU16(src, &at);
    bus.rdmpy = getU16(src, &at);
    bus.memsel = getU8(src, &at);
    bus.joypad1 = getU16(src, &at);
    bus.joypad2 = getU16(src, &at);
    bus.joypad2_connected = getBool(src, &at);
    bus.joy1_latch = getU16(src, &at);
    bus.joy2_latch = getU16(src, &at);
    bus.joypad_strobe = getBool(src, &at);
    bus.joy1_shift = getU32(src, &at);
    bus.joy2_shift = getU32(src, &at);
    bus.nmi_flag = getBool(src, &at);
    bus.irq_flag = getBool(src, &at);
    bus.dsp1_present = getBool(src, &at);
    bus.writer_pc = @truncate(getU32(src, &at));
    bus.dsp_accum = getU32(src, &at);
    bus.dma_masters = getU32(src, &at);

    // ---- APU ----
    at += bus.apu.readState(src[at..]);

    // ---- DSP-1 mutable state ----
    for (&bus.dsp1.ram) |*w| w.* = getU16(src, &at);
    bus.dsp1.pc = getU16(src, &at);
    for (&bus.dsp1.stack) |*w| w.* = getU16(src, &at);
    bus.dsp1.sp = getU8(src, &at);
    bus.dsp1.a = getU16(src, &at);
    bus.dsp1.b = getU16(src, &at);
    bus.dsp1.flaga = unpackDspFlags(getU8(src, &at));
    bus.dsp1.flagb = unpackDspFlags(getU8(src, &at));
    inline for (.{
        "tr", "trb", "rp", "k",  "l",
        "m",  "n",   "dr", "sr", "so",
        "si",
    }) |name| @field(bus.dsp1, name) = getU16(src, &at);
    bus.dsp1.dp = getU8(src, &at);
    bus.dsp1.idb = getU16(src, &at);

    // ---- Emulator ----
    last_scanline.* = getU16(src, &at);

    std.debug.assert(at == state_len);
    return at;
}

// ---- DSP flag packing --------------------------------------------------------
// Upd7725's Flags is a plain (unpacked) struct, so it gets an explicit bit
// layout here rather than a @bitCast.

fn packDspFlags(f: anytype) u8 {
    return (@as(u8, @intFromBool(f.c)) << 0) |
        (@as(u8, @intFromBool(f.z)) << 1) |
        (@as(u8, @intFromBool(f.s0)) << 2) |
        (@as(u8, @intFromBool(f.s1)) << 3) |
        (@as(u8, @intFromBool(f.ov0)) << 4) |
        (@as(u8, @intFromBool(f.ov1)) << 5);
}

fn unpackDspFlags(byte: u8) @TypeOf(@as(Bus, undefined).dsp1.flaga) {
    return .{
        .c = (byte & 0x01) != 0,
        .z = (byte & 0x02) != 0,
        .s0 = (byte & 0x04) != 0,
        .s1 = (byte & 0x08) != 0,
        .ov0 = (byte & 0x10) != 0,
        .ov1 = (byte & 0x20) != 0,
    };
}

test "state_len matches what write actually emits" {
    const buf = try std.testing.allocator.alloc(u8, state_len);
    defer std.testing.allocator.free(buf);
    var ppu = Ppu.init();
    var bus = Bus.init(&ppu);
    var cpu = Cpu.init(&bus);
    try std.testing.expectEqual(state_len, try write(&cpu, &ppu, &bus, 0, buf));
}

test "read rejects a foreign buffer instead of misreading it" {
    const buf = try std.testing.allocator.alloc(u8, state_len);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);
    var ppu = Ppu.init();
    var bus = Bus.init(&ppu);
    var cpu = Cpu.init(&bus);
    var last: u16 = 0;
    try std.testing.expectError(Error.BadMagic, read(&cpu, &ppu, &bus, &last, buf));
}

test "read preserves interior pointers and round-trips scalars" {
    const buf = try std.testing.allocator.alloc(u8, state_len);
    defer std.testing.allocator.free(buf);
    var ppu = Ppu.init();
    var bus = Bus.init(&ppu);
    var cpu = Cpu.init(&bus);
    cpu.a = 0x1234;
    cpu.pbr = 0x7E;
    ppu.frame_count = 99;
    bus.wram[0x1234] = 0xAB;
    _ = try write(&cpu, &ppu, &bus, 7, buf);

    cpu.a = 0;
    cpu.pbr = 0;
    ppu.frame_count = 0;
    bus.wram[0x1234] = 0;
    var last: u16 = 0;
    _ = try read(&cpu, &ppu, &bus, &last, buf);

    try std.testing.expectEqual(@as(u16, 0x1234), cpu.a);
    try std.testing.expectEqual(@as(u8, 0x7E), cpu.pbr);
    try std.testing.expectEqual(@as(u64, 99), ppu.frame_count);
    try std.testing.expectEqual(@as(u8, 0xAB), bus.wram[0x1234]);
    try std.testing.expectEqual(@as(u16, 7), last);
    // The pointers restore() must never touch.
    try std.testing.expectEqual(&bus, cpu.bus);
    try std.testing.expectEqual(&ppu, bus.ppu);
}
