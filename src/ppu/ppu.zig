// PPU (Picture Processing Unit) Emulation

const std = @import("std");
const dbg = @import("../debug.zig");

pub const SCREEN_WIDTH: usize = 256;
pub const SCREEN_HEIGHT: usize = 224; // Can be 224 or 239 depending on overscan
// =============================================================================
// NTSC TIMING
// =============================================================================
// Master clock: 21.477 MHz. One PPU dot = 4 master cycles, one scanline =
// 341 dots = 1364 master cycles, one frame = 262 scanlines.
// (Hardware subtleties not yet modeled: dots 323/327 are 6 master cycles
// each on most lines - the 341 dots really span 1364, not 341*4=1364...
// conveniently 341*4 IS 1364, the extra-long dots compensate for two
// missing ones; and non-interlace odd frames drop 4 cycles on line 240.)
// =============================================================================
pub const SCANLINES_PER_FRAME: usize = 262; // NTSC
pub const DOTS_PER_SCANLINE: usize = 341;
pub const MASTER_CYCLES_PER_DOT: u32 = 4;

// =============================================================================
// COMPTIME-GENERATED LOOKUP TABLES
// =============================================================================
// Zig evaluates these initializers entirely at compile time: the loops below
// run inside the compiler, and only the finished tables are embedded in the
// binary's read-only data section. This is the idiomatic Zig way to trade a
// little binary size for zero runtime table-building cost and no per-pixel
// arithmetic. (Contrast with the S-DSP's GAUSS/RATE_TABLE in apu/dsp.zig,
// which are hand-written literals because they mirror data physically baked
// into the chip - those must NOT be generated from a formula.)
// =============================================================================

/// Master brightness LUT: BRIGHTNESS_LUT[brightness][component] = scaled component.
///
/// INIDISP ($2100) bits 0-3 select a master brightness of 0 (black) to 15
/// (full). Hardware scales every color component linearly: out = in * b / 15.
/// Doing that per pixel costs three integer divisions - one of the slowest
/// ALU operations - on all 57,344 pixels of every frame. This 16x32-entry
/// table (1KB, permanently L1-resident) replaces them with three loads.
///
/// Row 0 is all zeros (screen black) and row 15 is the identity, so the
/// render loop needs no special-case branches for those either.
const BRIGHTNESS_LUT: [16][32]u16 = blk: {
    var table: [16][32]u16 = undefined;
    for (0..16) |b| {
        for (0..32) |c| {
            table[b][c] = @intCast((c * b) / 15);
        }
    }
    break :blk table;
};

/// Bitplane spread LUT: each bit of the input byte moves to every SECOND bit
/// of the output (bit n -> bit 2n), leaving a zero between each data bit.
///
/// Why: SNES tiles are stored PLANAR - a row of 8 pixels is split across
/// 2/4/8 separate "bitplane" bytes, where plane byte k holds bit k of all
/// 8 pixels. To get one pixel's color index you must gather one bit from
/// every plane. Done naively that's a shift+mask+shift+or PER PLANE PER
/// PIXEL (see getTilePixel's history in git).
///
/// With this table, two planes are combined in one step:
///     merged = PLANE_SPREAD[plane0] | PLANE_SPREAD[plane1] << 1
/// yields a u16 holding all eight 2-bit pixel values of the row at once
/// (pixel x lives at bits [2*(7-x) +: 2], because bitplane bit 7 is the
/// leftmost pixel). One shift+mask then extracts any pixel - and a future
/// line-buffer renderer can decode the whole row from `merged` with no
/// further VRAM reads, which is the groundwork this table really lays.
const PLANE_SPREAD: [256]u16 = blk: {
    // The compiler limits comptime loop iterations (default 1000) to catch
    // accidental infinite loops during compilation; 256 bytes x 8 bits
    // exceeds it, so raise the quota for this block.
    @setEvalBranchQuota(256 * 8 * 2);
    var table: [256]u16 = undefined;
    for (0..256) |byte| {
        var spread: u16 = 0;
        for (0..8) |bit| {
            if ((byte >> bit) & 1 != 0) {
                spread |= 1 << (bit * 2);
            }
        }
        table[byte] = spread;
    }
    break :blk table;
};

pub const Ppu = struct {
    // VRAM - 64KB
    vram: [64 * 1024]u8,

    // CGRAM - 512 bytes (256 colors, 15-bit each)
    cgram: [512]u8,

    // OAM - 544 bytes (128 sprites * 4 bytes + 32 bytes high table)
    oam: [544]u8,

    // Framebuffer - 15-bit BGR (native SNES format)
    framebuffer: [SCREEN_WIDTH * SCREEN_HEIGHT]u16,

    // PPU registers
    inidisp: u8, // $2100 - Screen display register
    obsel: u8, // $2101 - Object size and data area
    oamaddl: u8, // $2102 - OAM address low
    oamaddh: u8, // $2103 - OAM address high
    bgmode: u8, // $2105 - BG mode and character size
    mosaic: u8, // $2106 - Mosaic settings
    bg1sc: u8, // $2107 - BG1 tilemap address
    bg2sc: u8, // $2108 - BG2 tilemap address
    bg3sc: u8, // $2109 - BG3 tilemap address
    bg4sc: u8, // $210A - BG4 tilemap address
    bg12nba: u8, // $210B - BG1/2 character address
    bg34nba: u8, // $210C - BG3/4 character address
    vmain: u8, // $2115 - VRAM address increment mode
    vmaddl: u8, // $2116 - VRAM address low
    vmaddh: u8, // $2117 - VRAM address high

    // BG scroll registers
    bg1hofs: u16, // $210D - BG1 horizontal scroll
    bg1vofs: u16, // $210E - BG1 vertical scroll
    bg2hofs: u16, // $210F - BG2 horizontal scroll
    bg2vofs: u16, // $2110 - BG2 vertical scroll
    bg3hofs: u16, // $2111 - BG3 horizontal scroll
    bg3vofs: u16, // $2112 - BG3 vertical scroll
    bg4hofs: u16, // $2113 - BG4 horizontal scroll
    bg4vofs: u16, // $2114 - BG4 vertical scroll

    // Main/Sub screen designation
    tm: u8, // $212C - Main screen designation
    ts: u8, // $212D - Sub screen designation

    // ==========================================================================
    // WINDOW REGISTERS - Used to mask/clip layers in rectangular screen regions
    // ==========================================================================
    // The SNES has two windows (W1 and W2) that can be used to enable/disable
    // rendering of BG layers, sprites, and color math in rectangular regions.
    // Each window is defined by left and right X coordinates.
    // ==========================================================================
    w12sel: u8, // $2123 - Window 1/2 mask settings for BG1/BG2
    w34sel: u8, // $2124 - Window 1/2 mask settings for BG3/BG4
    wobjsel: u8, // $2125 - Window 1/2 mask settings for OBJ/Color
    wh0: u8, // $2126 - Window 1 left position
    wh1: u8, // $2127 - Window 1 right position
    wh2: u8, // $2128 - Window 2 left position
    wh3: u8, // $2129 - Window 2 right position
    wbglog: u8, // $212A - Window 1/2 mask logic for BG1-4
    wobjlog: u8, // $212B - Window 1/2 mask logic for OBJ/Color
    tmw: u8, // $212E - Window mask designation for main screen
    tsw: u8, // $212F - Window mask designation for sub screen

    // Color math registers
    cgwsel: u8, // $2130 - Color addition select
    cgadsub: u8, // $2131 - Color math designation
    coldata: u16, // Fixed color (combined from $2132 writes)

    // Latch for double-write scroll registers
    scroll_latch: u8,
    scroll_latch_set: bool,

    // =========================================================================
    // MODE 7 REGISTERS - Affine transformation state
    // =========================================================================
    // Mode 7 replaces the tile-grid BG1 with a single 1024x1024 pixel plane
    // (128x128 tiles of 8x8, 8bpp) that is sampled through a 2x2 affine
    // matrix - this is how the SNES does rotation and scaling (F-Zero,
    // Mario Kart, SMW boss rooms...).
    //
    // For each screen pixel (X,Y) the PPU computes a texture coordinate:
    //   [ u ]   [ A B ] [ X + hofs - cx ]   [ cx ]
    //   [ v ] = [ C D ] [ Y + vofs - cy ] + [ cy ]
    // where A-D are 8.8 signed fixed-point and cx/cy is the rotation center.
    //
    // All matrix/center registers are "write twice" (low byte then high
    // byte) through a shared latch (m7_latch), separate from the BG scroll
    // latch. M7HOFS/M7VOFS share addresses with BG1HOFS/BG1VOFS ($210D/E)
    // but latch independently and hold 13-bit signed values.
    // =========================================================================
    m7sel: u8, // $211A - Screen flip (bits 0-1) and screen-over mode (bits 6-7)
    m7a: i16, // $211B - Matrix A (8.8 fixed point, also MPY multiplicand)
    m7b: i16, // $211C - Matrix B (also MPY multiplier via last byte written)
    m7c: i16, // $211D - Matrix C
    m7d: i16, // $211E - Matrix D
    m7x: i16, // $211F - Center X (13-bit signed)
    m7y: i16, // $2120 - Center Y (13-bit signed)
    m7hofs: i16, // $210D - Mode 7 horizontal scroll (13-bit signed)
    m7vofs: i16, // $210E - Mode 7 vertical scroll (13-bit signed)
    m7_latch: u8, // Shared write-twice latch for all Mode 7 registers
    mpy_result: i32, // MPYL/M/H ($2134-$2136): m7a * (signed high byte of m7b)

    // Internal state
    vram_addr: u16,
    cgram_addr: u9,
    oam_addr: u10,
    cgram_latch: u8,
    vram_prefetch: u16,

    // Timing
    scanline: u16,
    dot: u16,
    frame_count: u64,

    // Master-cycle remainder carried between tick() calls (0-3). The PPU
    // advances in whole dots but the CPU hands us master cycles that are
    // rarely a multiple of 4.
    master_accum: u32,

    // Latch for VRAM reads
    vram_read_buffer: u8,

    pub fn init() Ppu {
        return Ppu{
            .vram = [_]u8{0} ** (64 * 1024),
            .cgram = [_]u8{0} ** 512,
            .oam = [_]u8{0} ** 544,
            .framebuffer = [_]u16{0} ** (SCREEN_WIDTH * SCREEN_HEIGHT),
            .inidisp = 0x80, // Screen off, brightness 0
            .obsel = 0,
            .oamaddl = 0,
            .oamaddh = 0,
            .bgmode = 0,
            .mosaic = 0,
            .bg1sc = 0,
            .bg2sc = 0,
            .bg3sc = 0,
            .bg4sc = 0,
            .bg12nba = 0,
            .bg34nba = 0,
            .vmain = 0,
            .vmaddl = 0,
            .vmaddh = 0,
            .bg1hofs = 0,
            .bg1vofs = 0,
            .bg2hofs = 0,
            .bg2vofs = 0,
            .bg3hofs = 0,
            .bg3vofs = 0,
            .bg4hofs = 0,
            .bg4vofs = 0,
            .tm = 0,
            .ts = 0,
            // Window registers
            .w12sel = 0,
            .w34sel = 0,
            .wobjsel = 0,
            .wh0 = 0,
            .wh1 = 0,
            .wh2 = 0,
            .wh3 = 0,
            .wbglog = 0,
            .wobjlog = 0,
            .tmw = 0,
            .tsw = 0,
            .cgwsel = 0,
            .cgadsub = 0,
            .coldata = 0,
            .scroll_latch = 0,
            .scroll_latch_set = false,
            .m7sel = 0,
            .m7a = 0,
            .m7b = 0,
            .m7c = 0,
            .m7d = 0,
            .m7x = 0,
            .m7y = 0,
            .m7hofs = 0,
            .m7vofs = 0,
            .m7_latch = 0,
            .mpy_result = 0,
            .vram_addr = 0,
            .cgram_addr = 0,
            .oam_addr = 0,
            .cgram_latch = 0,
            .vram_prefetch = 0,
            .scanline = 0,
            .dot = 0,
            .master_accum = 0,
            .frame_count = 0,
            .vram_read_buffer = 0,
        };
    }

    pub fn reset(self: *Ppu) void {
        self.inidisp = 0x80;
        self.scanline = 0;
        self.dot = 0;
        self.master_accum = 0;
        self.vram_addr = 0;
        self.cgram_addr = 0;
        self.oam_addr = 0;
        self.bg1hofs = 0;
        self.bg1vofs = 0;
        self.bg2hofs = 0;
        self.bg2vofs = 0;
        self.bg3hofs = 0;
        self.bg3vofs = 0;
        self.bg4hofs = 0;
        self.bg4vofs = 0;
        self.tm = 0;
        self.ts = 0;
        self.scroll_latch_set = false;
    }

    /// Advance PPU by given number of master clock cycles
    /// Advance the PPU by the given number of MASTER clock cycles.
    /// Internally the PPU state machine moves one dot (4 master cycles) at
    /// a time; leftover cycles accumulate for the next call so no time is
    /// lost between CPU instructions.
    pub fn tick(self: *Ppu, master_cycles: u32) void {
        self.master_accum += master_cycles;
        while (self.master_accum >= MASTER_CYCLES_PER_DOT) {
            self.master_accum -= MASTER_CYCLES_PER_DOT;
            self.dot += 1;

            if (self.dot >= DOTS_PER_SCANLINE) {
                self.dot = 0;
                self.scanline += 1;

                // Render the scanline if we're in visible area
                if (self.scanline < SCREEN_HEIGHT) {
                    self.renderScanline();
                }

                if (self.scanline >= SCANLINES_PER_FRAME) {
                    self.scanline = 0;
                    self.frame_count += 1;

                    // Draw frame counter overlay in debug builds
                    if (comptime dbg.show_frame_counter) {
                        self.drawFrameCounter();
                    }

                    // Debug: dump PPU state on frame 600 and 700
                    // Gated behind comptime so it compiles out in release builds
                    if (comptime dbg.enabled) {
                        if (self.frame_count == 1 or self.frame_count == 100 or self.frame_count == 200 or self.frame_count == 600 or self.frame_count == 700) {
                            std.debug.print("\n=== PPU STATE DUMP (frame {d}) ===\n", .{self.frame_count});
                            std.debug.print("BGMODE: ${x:0>2} (mode {})\n", .{ self.bgmode, @as(u3, @truncate(self.bgmode)) });
                            std.debug.print("TM (layer enable): ${x:0>2} (BG1={} BG2={} BG3={} BG4={} OBJ={})\n", .{
                                self.tm,
                                (self.tm & 0x01) != 0,
                                (self.tm & 0x02) != 0,
                                (self.tm & 0x04) != 0,
                                (self.tm & 0x08) != 0,
                                (self.tm & 0x10) != 0,
                            });
                            std.debug.print("BG12NBA: ${x:0>2}, BG34NBA: ${x:0>2}\n", .{ self.bg12nba, self.bg34nba });
                            std.debug.print("BG1SC: ${x:0>2}, BG2SC: ${x:0>2}, BG3SC: ${x:0>2}\n", .{ self.bg1sc, self.bg2sc, self.bg3sc });
                            std.debug.print("CGRAM[0] (backdrop): ${x:0>4}\n", .{self.getColor(0)});
                            std.debug.print("CGRAM[0-7]: ", .{});
                            for (0..8) |i| {
                                std.debug.print("${x:0>4} ", .{self.getColor(@intCast(i))});
                            }
                            std.debug.print("\n", .{});
                            std.debug.print("TMW (window mask): ${x:0>2}\n", .{self.tmw});
                            std.debug.print("W12SEL: ${x:0>2}, W34SEL: ${x:0>2}\n", .{ self.w12sel, self.w34sel });
                            std.debug.print("WH0-WH3: {}, {}, {}, {}\n", .{ self.wh0, self.wh1, self.wh2, self.wh3 });
                            // Dump BG3 tile 0 data (first 16 bytes of 2bpp tile)
                            const bg3_chr_base = @as(u32, self.bg34nba & 0x0F) << 13;
                            std.debug.print("BG3 chr base: ${x:0>5}, tile 0 data: ", .{bg3_chr_base});
                            for (0..16) |i| {
                                std.debug.print("{x:0>2} ", .{self.vram[(bg3_chr_base + i) & 0xFFFF]});
                            }
                            std.debug.print("\n", .{});

                            // Dump BG3 tilemap entries at a few positions
                            // BG3SC format: AAAAAASS where AAAAAA is base addr in 0x400 word units
                            const bg3_tilemap_base = @as(u32, self.bg3sc & 0xFC) << 9;
                            std.debug.print("BG3 tilemap base: ${x:0>5}\n", .{bg3_tilemap_base});
                            std.debug.print("BG3 tilemap row 0 tiles: ", .{});
                            for (0..16) |i| {
                                const offset = bg3_tilemap_base + i * 2;
                                const lo = self.vram[offset & 0xFFFF];
                                const hi = self.vram[(offset + 1) & 0xFFFF];
                                const entry: u16 = @as(u16, hi) << 8 | lo;
                                const tile_num = entry & 0x3FF;
                                std.debug.print("{x:0>2} ", .{@as(u8, @truncate(tile_num))});
                            }
                            std.debug.print("\n", .{});
                            // Dump row 6 (y=50 falls into this row)
                            std.debug.print("BG3 tilemap row 6 tiles: ", .{});
                            for (0..16) |i| {
                                const offset = bg3_tilemap_base + (6 * 32 + i) * 2;
                                const lo = self.vram[offset & 0xFFFF];
                                const hi = self.vram[(offset + 1) & 0xFFFF];
                                const entry: u16 = @as(u16, hi) << 8 | lo;
                                const tile_num = entry & 0x3FF;
                                std.debug.print("{x:0>2} ", .{@as(u8, @truncate(tile_num))});
                            }
                            std.debug.print("\n", .{});
                            // Dump BG3 scroll values
                            std.debug.print("BG3 scroll: hofs={} vofs={}\n", .{ self.bg3hofs, self.bg3vofs });
                            // Dump character data at different offsets to see what tile 0x55 looks like
                            const tile_55_addr = bg3_chr_base + 0x55 * 16; // 2bpp = 16 bytes per tile
                            std.debug.print("BG3 tile $55 addr: ${x:0>5}, data: ", .{tile_55_addr});
                            for (0..16) |i| {
                                std.debug.print("{x:0>2} ", .{self.vram[(tile_55_addr + i) & 0xFFFF]});
                            }
                            std.debug.print("\n", .{});
                            // Also check tile $fc (might be transparent/empty)
                            const tile_fc_addr = bg3_chr_base + 0xfc * 16;
                            std.debug.print("BG3 tile $fc addr: ${x:0>5}, data: ", .{tile_fc_addr});
                            for (0..16) |i| {
                                std.debug.print("{x:0>2} ", .{self.vram[(tile_fc_addr + i) & 0xFFFF]});
                            }
                            std.debug.print("\n", .{});
                            // Check tile $30 (where ASCII "0" would normally be)
                            const tile_30_addr = bg3_chr_base + 0x30 * 16; // 2bpp = 16 bytes
                            std.debug.print("BG3 tile $30 addr: ${x:0>5}, data: ", .{tile_30_addr});
                            for (0..16) |i| {
                                std.debug.print("{x:0>2} ", .{self.vram[(tile_30_addr + i) & 0xFFFF]});
                            }
                            std.debug.print("\n", .{});
                            // Check first 8 tiles to see pattern
                            std.debug.print("BG3 tiles 0-7 first byte: ", .{});
                            for (0..8) |t| {
                                const addr = bg3_chr_base + t * 16;
                                std.debug.print("t{d}=${x:0>2} ", .{ t, self.vram[addr & 0xFFFF] });
                            }
                            std.debug.print("\n", .{});

                            // Dump BG1 tilemap (where sky/clouds might be)
                            const bg1_tilemap_base = @as(u32, self.bg1sc & 0xFC) << 9;
                            const bg1_chr_base = @as(u32, self.bg12nba & 0x0F) << 13;
                            const bg1_size = self.bg1sc & 0x03;
                            std.debug.print("BG1 tilemap base: ${x:0>5}, chr base: ${x:0>5}, size bits: {d}\n", .{ bg1_tilemap_base, bg1_chr_base, bg1_size });
                            std.debug.print("BG1 scroll: hofs={} vofs={}\n", .{ self.bg1hofs, self.bg1vofs });
                            // With vofs=192, screen Y=0 reads tilemap Y=192, tile row 24
                            // Dump rows 24-27 which would be visible on screen
                            for (0..4) |row_idx| {
                                const row: u32 = 24 + @as(u32, @intCast(row_idx));
                                std.debug.print("BG1 tilemap row {d} (first 16 tiles): ", .{row});
                                for (0..16) |i| {
                                    const offset = bg1_tilemap_base + (row * 32 + i) * 2;
                                    const lo = self.vram[offset & 0xFFFF];
                                    const hi = self.vram[(offset + 1) & 0xFFFF];
                                    const entry: u16 = @as(u16, hi) << 8 | lo;
                                    const tile_num = entry & 0x3FF;
                                    std.debug.print("{x:0>3} ", .{tile_num});
                                }
                                std.debug.print("\n", .{});
                            }
                            // Show what tile $F8 looks like (4bpp = 32 bytes per tile)
                            const tile_f8_addr = bg1_chr_base + 0xF8 * 32;
                            std.debug.print("BG1 tile $F8 addr: ${x:0>5}, first 16 bytes: ", .{tile_f8_addr});
                            for (0..16) |i| {
                                std.debug.print("{x:0>2} ", .{self.vram[(tile_f8_addr + i) & 0xFFFF]});
                            }
                            std.debug.print("\n", .{});
                            // Also check tile 0 at BG1 chr base
                            std.debug.print("BG1 tile $00 addr: ${x:0>5}, first 16 bytes: ", .{bg1_chr_base});
                            for (0..16) |i| {
                                std.debug.print("{x:0>2} ", .{self.vram[(bg1_chr_base + i) & 0xFFFF]});
                            }
                            std.debug.print("\n", .{});
                            // Check which tiles in BG1 chr data are non-empty
                            // Sample tiles 0, 16, 32, 64, 128, 248 to see pattern
                            std.debug.print("BG1 chr data survey (first byte of each tile): ", .{});
                            const sample_tiles = [_]u32{ 0, 16, 32, 64, 128, 200, 248, 255 };
                            for (sample_tiles) |t| {
                                const addr = bg1_chr_base + t * 32; // 4bpp = 32 bytes per tile
                                const first_byte = self.vram[addr & 0xFFFF];
                                std.debug.print("t{d}=${x:0>2} ", .{ t, first_byte });
                            }
                            std.debug.print("\n", .{});
                            // Also check COLDATA for color math gradient
                            std.debug.print("COLDATA (fixed color): ${x:0>4}, CGADSUB: ${x:0>2}, CGWSEL: ${x:0>2}, TS: ${x:0>2}\n", .{ self.coldata, self.cgadsub, self.cgwsel, self.ts });

                            // Dump BG2 tilemap (where hills/ground might be)
                            const bg2_tilemap_base = @as(u32, self.bg2sc & 0xFC) << 9;
                            const bg2_chr_base = @as(u32, self.bg12nba >> 4) << 13;
                            std.debug.print("BG2 tilemap base: ${x:0>5}, chr base: ${x:0>5}\n", .{ bg2_tilemap_base, bg2_chr_base });
                            std.debug.print("BG2 scroll: hofs={} vofs={}\n", .{ self.bg2hofs, self.bg2vofs });
                            std.debug.print("BG2 tilemap row 0 (first 16 tiles): ", .{});
                            for (0..16) |i| {
                                const offset = bg2_tilemap_base + i * 2;
                                const lo = self.vram[offset & 0xFFFF];
                                const hi = self.vram[(offset + 1) & 0xFFFF];
                                const entry: u16 = @as(u16, hi) << 8 | lo;
                                const tile_num = entry & 0x3FF;
                                std.debug.print("{x:0>3} ", .{tile_num});
                            }
                            std.debug.print("\n", .{});

                            std.debug.print("=================================\n\n", .{});
                        }
                    }
                }
            }
        }
    }

    // ==========================================================================
    // SPRITE-TO-BACKGROUND PRIORITY
    // ==========================================================================
    // Determines whether a sprite pixel should appear in front of a BG pixel.
    // The SNES has complex per-mode priority ordering. This function implements
    // the correct layering for each mode.
    //
    // Mode 1 standard priority order (front to back):
    //   S3 → 1H → 2H → S2 → 1L → 2L → S1 → 3H → S0 → 3L
    //
    // Mode 1 with BG3 priority bit set (BGMODE bit 3 = 1):
    //   3H → S3 → 1H → 2H → S2 → 1L → 2L → S1 → S0 → 3L
    //   BG3 high priority tiles appear in front of EVERYTHING!
    //
    // Where:
    //   S0-S3 = Sprites with priority 0-3
    //   1H/1L = BG1 high/low priority (tile priority bit)
    //   2H/2L = BG2 high/low priority
    //   3H/3L = BG3 high/low priority
    // ==========================================================================
    fn spritePriorityWins(self: *Ppu, mode: u3, sprite_priority: u8, bg_layer: u8, bg_tile_priority: u8) bool {
        // If no BG pixel (backdrop only), sprite always wins
        if (bg_layer == 0) return true;

        switch (mode) {
            1 => {
                // Mode 1 has a special "BG3 priority" bit in BGMODE (bit 3).
                // When this bit is SET, BG3 high-priority tiles go to the FRONT
                // of the entire priority list - in front of even sprite priority 3!
                //
                // Standard Mode 1 priority (BGMODE bit 3 = 0):
                //   S3 → 1H → 2H → S2 → 1L → 2L → S1 → 3H → S0 → 3L
                //
                // Mode 1 with BG3 priority (BGMODE bit 3 = 1):
                //   3H → S3 → 1H → 2H → S2 → 1L → 2L → S1 → S0 → 3L
                //
                // This is used by SMW's title screen (BGMODE=$09) to make the
                // logo appear in front of Mario who is jumping behind it.
                const bg3_priority_bit = (self.bgmode & 0x08) != 0;

                // Special case: BG3 high priority with BG3 priority bit wins over ALL sprites
                if (bg3_priority_bit and bg_layer == 3 and bg_tile_priority == 1) {
                    return false; // Sprite does NOT win - BG3 high priority is in front
                }

                // Standard Mode 1 priority values (higher = more in front)
                const sprite_eff: u8 = switch (sprite_priority) {
                    3 => 10, // S3 - front
                    2 => 7, // S2
                    1 => 4, // S1
                    else => 2, // S0
                };

                // Note: 3H is lower in standard mode, but handled above when bg3_priority_bit is set
                const bg_eff: u8 = switch (bg_layer) {
                    1 => if (bg_tile_priority == 1) 9 else 6, // 1H=9, 1L=6
                    2 => if (bg_tile_priority == 1) 8 else 5, // 2H=8, 2L=5
                    3 => if (bg_tile_priority == 1) 3 else 1, // 3H=3, 3L=1
                    else => 0,
                };

                return sprite_eff > bg_eff;
            },
            0 => {
                // Mode 0 - simplified: treat similar to Mode 1 for now
                // TODO: Implement proper Mode 0 priority if needed
                const sprite_eff: u8 = switch (sprite_priority) {
                    3 => 10,
                    2 => 7,
                    1 => 4,
                    else => 2,
                };
                const bg_eff: u8 = if (bg_tile_priority == 1) 8 else 5;
                return sprite_eff > bg_eff;
            },
            else => {
                // Other modes - use simple comparison for now
                // Sprite priority 3 always wins, otherwise compare directly
                if (sprite_priority == 3) return true;
                if (bg_tile_priority == 1) return false; // High priority BG wins
                return sprite_priority >= 1; // Low priority BG loses to sprite 1+
            },
        }
    }

    fn renderScanline(self: *Ppu) void {
        const y = self.scanline;
        const start = y * SCREEN_WIDTH;

        // Check if display is enabled
        if ((self.inidisp & 0x80) != 0) {
            // Force blank - fill with black
            for (0..SCREEN_WIDTH) |x| {
                self.framebuffer[start + x] = 0;
            }
            return;
        }

        // Get background color from CGRAM[0]
        const backdrop = self.getColor(0);

        // Select the master-brightness row once per scanline (INIDISP can't
        // change mid-line in our scanline-granularity model; when mid-line
        // register changes land - see NEXTSTEPS.md - this moves into the
        // change-replay logic). &-of-array-row so the pixel loop indexes
        // through a pointer instead of recomputing the row address.
        const bright: *const [32]u16 = &BRIGHTNESS_LUT[self.inidisp & 0x0F];

        // Trace window state during spotlight animation (after frame 240 when display begins)
        // Log every frame at center scanline (112) to see window evolution
        if (comptime dbg.trace_windows) {
            if (self.frame_count >= 240 and self.frame_count <= 700 and y == 112) {
                std.debug.print("[WIN] frame={d} WH0={d} WH1={d} W12SEL=${x:0>2} W34SEL=${x:0>2} WOBJSEL=${x:0>2} CGWSEL=${x:0>2}\n", .{
                    self.frame_count, self.wh0, self.wh1, self.w12sel, self.w34sel, self.wobjsel, self.cgwsel,
                });
            }
        }

        // Get background mode
        const mode: u3 = @truncate(self.bgmode);

        // Render sprites for this scanline
        var sprite_buffer: [SCREEN_WIDTH]?SpritePixel = undefined;
        self.renderSprites(y, &sprite_buffer);

        // ======================================================================
        // BG LINE-BUFFER PASS
        // ======================================================================
        // Render every BG layer enabled on the main screen (TM) OR the
        // subscreen (TS) into its line buffer once. The per-pixel compositing
        // loop below then only reads buffered pixels - the expensive tilemap
        // walk and bitplane decode happen once per 8-pixel tile run instead
        // of once per pixel per screen. Layers disabled on both screens keep
        // undefined buffers; the TM/TS guards below never read them.
        // Mode 7 is absent here: its affine transform gives every pixel an
        // independent VRAM address, so buffering rows buys nothing - it
        // stays per-pixel via renderMode7Pixel().
        // ======================================================================
        var bg_lines: [4]BgLine = undefined;
        {
            const enabled = self.tm | self.ts;
            switch (mode) {
                0 => {
                    // Mode 0: 4 layers, all 2bpp
                    for (1..5) |bg| {
                        if ((enabled & (@as(u8, 1) << @intCast(bg - 1))) != 0) {
                            self.renderBgLine(@intCast(bg), y, 2, &bg_lines[bg - 1]);
                        }
                    }
                },
                1 => {
                    // Mode 1: BG1/BG2 4bpp, BG3 2bpp
                    if ((enabled & 0x01) != 0) self.renderBgLine(1, y, 4, &bg_lines[0]);
                    if ((enabled & 0x02) != 0) self.renderBgLine(2, y, 4, &bg_lines[1]);
                    if ((enabled & 0x04) != 0) self.renderBgLine(3, y, 2, &bg_lines[2]);
                },
                2, 3, 4, 5, 6 => {
                    // Modes 2-6: BG1/BG2 with mode-specific depths (see the
                    // compositing switch below for the per-mode table)
                    const bg1_bpp: u8 = if (mode == 3 or mode == 4) 8 else 4;
                    const bg2_bpp: u8 = switch (mode) {
                        2, 3 => 4,
                        else => 2,
                    };
                    if ((enabled & 0x01) != 0) self.renderBgLine(1, y, bg1_bpp, &bg_lines[0]);
                    if (mode != 6 and (enabled & 0x02) != 0) self.renderBgLine(2, y, bg2_bpp, &bg_lines[1]);
                },
                7 => {}, // per-pixel affine path below
            }
        }

        // Render each pixel
        for (0..SCREEN_WIDTH) |x| {
            var color: u16 = backdrop;
            var bg_priority: u8 = 0;
            var bg_layer: u8 = 0; // Track which BG layer produced this pixel (0 = backdrop)

            // Render BG layers (back to front based on priority)
            switch (mode) {
                0 => {
                    // Mode 0: 4 BG layers, 2bpp each (4 colors per BG)
                    // Apply window masking per layer
                    const x8: u8 = @intCast(x);
                    if ((self.tm & 0x08) != 0 and !self.isWindowMasked(3, x8)) {
                        if (bg_lines[3].pixel(x)) |c| {
                            color = c.color;
                            bg_priority = c.priority;
                            bg_layer = 4;
                        }
                    }
                    if ((self.tm & 0x04) != 0 and !self.isWindowMasked(2, x8)) {
                        if (bg_lines[2].pixel(x)) |c| {
                            if (c.priority >= bg_priority) {
                                color = c.color;
                                bg_priority = c.priority;
                                bg_layer = 3;
                            }
                        }
                    }
                    if ((self.tm & 0x02) != 0 and !self.isWindowMasked(1, x8)) {
                        if (bg_lines[1].pixel(x)) |c| {
                            if (c.priority >= bg_priority) {
                                color = c.color;
                                bg_priority = c.priority;
                                bg_layer = 2;
                            }
                        }
                    }
                    if ((self.tm & 0x01) != 0 and !self.isWindowMasked(0, x8)) {
                        if (bg_lines[0].pixel(x)) |c| {
                            if (c.priority >= bg_priority) {
                                color = c.color;
                                bg_priority = c.priority;
                                bg_layer = 1;
                            }
                        }
                    }
                },
                1 => {
                    // Mode 1: BG1/BG2 4bpp (16 colors), BG3 2bpp (4 colors)
                    // Render back to front: BG3 (lowest), BG2, BG1 (highest)
                    // Each layer only overwrites if it has a non-transparent pixel
                    // Apply window masking per layer
                    const x8: u8 = @intCast(x);
                    if ((self.tm & 0x04) != 0 and !self.isWindowMasked(2, x8)) {
                        if (bg_lines[2].pixel(x)) |c| {
                            color = c.color;
                            bg_priority = c.priority;
                            bg_layer = 3;
                        }
                    }
                    if ((self.tm & 0x02) != 0 and !self.isWindowMasked(1, x8)) {
                        if (bg_lines[1].pixel(x)) |c| {
                            if (c.priority >= bg_priority) {
                                color = c.color;
                                bg_priority = c.priority;
                                bg_layer = 2;
                            }
                        }
                    }
                    if ((self.tm & 0x01) != 0 and !self.isWindowMasked(0, x8)) {
                        if (bg_lines[0].pixel(x)) |c| {
                            if (c.priority >= bg_priority) {
                                color = c.color;
                                bg_priority = c.priority;
                                bg_layer = 1;
                            }
                        }
                    }
                },
                2, 3, 4, 5, 6 => {
                    // Modes 2-6: two BG layers with mode-specific depths.
                    //   Mode 2: BG1 4bpp, BG2 4bpp (+ offset-per-tile, TODO)
                    //   Mode 3: BG1 8bpp, BG2 4bpp
                    //   Mode 4: BG1 8bpp, BG2 2bpp (+ offset-per-tile, TODO)
                    //   Mode 5: BG1 4bpp, BG2 2bpp (hires - drawn lo-res here)
                    //   Mode 6: BG1 4bpp only   (hires + offset-per-tile)
                    // Render back-to-front: BG2 first, then BG1 on top when
                    // its pixel is opaque and priority allows.
                    const x8: u8 = @intCast(x);
                    if (mode != 6 and (self.tm & 0x02) != 0 and !self.isWindowMasked(1, x8)) {
                        if (bg_lines[1].pixel(x)) |c| {
                            color = c.color;
                            bg_priority = c.priority;
                            bg_layer = 2;
                        }
                    }
                    if ((self.tm & 0x01) != 0 and !self.isWindowMasked(0, x8)) {
                        if (bg_lines[0].pixel(x)) |c| {
                            if (c.priority >= bg_priority or bg_layer == 0) {
                                color = c.color;
                                bg_priority = c.priority;
                                bg_layer = 1;
                            }
                        }
                    }
                },
                7 => {
                    // Mode 7 - affine-transformed 8bpp plane on BG1.
                    // (EXTBG/$2133 bit 6 would add a BG2 view of the same
                    // plane with per-pixel priority - not yet implemented.)
                    if ((self.tm & 0x01) != 0 and !self.isWindowMasked(0, @intCast(x))) {
                        if (self.renderMode7Pixel(@intCast(x), y)) |c| {
                            color = c.color;
                            bg_priority = c.priority;
                            bg_layer = 1;
                        }
                    }
                },
            }

            // Combine with sprites based on priority
            // The SNES has complex per-mode priority ordering between sprites and BGs.
            // Each mode has a specific layering order that determines which elements
            // appear in front of others.
            //
            // Track final layer for color math:
            //   0 = backdrop, 1-4 = BG1-BG4, 5 = OBJ (sprite)
            var final_layer: u8 = bg_layer;

            if (sprite_buffer[x]) |sprite| {
                const sprite_wins = self.spritePriorityWins(mode, sprite.priority, bg_layer, bg_priority);

                // Debug: trace sprite priority decisions at frame 700
                if (comptime dbg.enabled) {
                    // Log sprite pixels that overlap with BG at frame 700
                    if (self.frame_count == 700 and bg_layer != 0) {
                        std.debug.print("[PRIO] x={d} y={d} s_pri={d} bg_l={d} bg_p={d} wins={}\n", .{
                            x, y, sprite.priority, bg_layer, bg_priority, sprite_wins,
                        });
                    }
                }

                if (sprite_wins) {
                    color = sprite.color;
                    final_layer = 5; // OBJ won
                }
            }

            // ==========================================================================
            // COLOR MATH - Full SNES color blending implementation
            // ==========================================================================
            // The SNES PPU has sophisticated color math capabilities controlled by:
            //
            // CGWSEL ($2130) - Color Addition Select:
            //   Bits 7-6 (MM): Force main screen BLACK region
            //     00 = Never (nowhere)
            //     01 = Outside color window
            //     10 = Inside color window
            //     11 = Always (everywhere)
            //   Bits 5-4 (SS): Force subscreen TRANSPARENT region (disables math)
            //     00 = Never (color math always applies)
            //     01 = Outside color window (math only inside window)
            //     10 = Inside color window (math only outside window)
            //     11 = Always (color math never applies)
            //   Bit 1: Add subscreen (0 = use fixed color, 1 = use subscreen)
            //   Bit 0: Direct color mode (for modes 3, 4, 7)
            //
            // CGADSUB ($2131) - Color Math Designation:
            //   Bits 0-3: BG1-BG4 participate in color math
            //   Bit 4: OBJ (sprites) participates
            //   Bit 5: Backdrop participates
            //   Bit 6: Half color math (divide result by 2)
            //   Bit 7: Subtract mode (0 = add, 1 = subtract)
            //
            // COLDATA ($2132) - Fixed color for blending (built from R/G/B writes)
            // ==========================================================================
            const x8: u8 = @intCast(x);
            const color_window_active = self.isColorWindowActive(x8);

            // Step 1: Force main screen BLACK based on CGWSEL bits 7-6
            // This happens BEFORE color math and creates spotlight/iris effects
            const force_black_mode: u2 = @truncate(self.cgwsel >> 6);
            var force_black = false;
            switch (force_black_mode) {
                0b00 => {}, // Never force black
                0b01 => force_black = !color_window_active, // Black OUTSIDE window
                0b10 => force_black = color_window_active, // Black INSIDE window
                0b11 => force_black = true, // Always black
            }

            if (force_black) {
                color = 0; // Main screen becomes black
            }

            // Step 2: Determine if color math should be applied
            // CGWSEL bits 5-4 control where subscreen becomes transparent
            // When subscreen is transparent, color math effectively doesn't apply
            const math_disable_mode: u2 = @truncate(self.cgwsel >> 4);
            var disable_math = false;
            switch (math_disable_mode) {
                0b00 => {}, // Never disable (math always applies)
                0b01 => disable_math = !color_window_active, // Disable OUTSIDE window
                0b10 => disable_math = color_window_active, // Disable INSIDE window
                0b11 => disable_math = true, // Always disable
            }

            // Step 3: Check if the source layer participates in color math
            // CGADSUB bits 0-5 control which layers can have math applied
            const layer_participates = switch (final_layer) {
                0 => (self.cgadsub & 0x20) != 0, // Backdrop (bit 5)
                1 => (self.cgadsub & 0x01) != 0, // BG1 (bit 0)
                2 => (self.cgadsub & 0x02) != 0, // BG2 (bit 1)
                3 => (self.cgadsub & 0x04) != 0, // BG3 (bit 2)
                4 => (self.cgadsub & 0x08) != 0, // BG4 (bit 3)
                5 => (self.cgadsub & 0x10) != 0, // OBJ (bit 4)
                else => false,
            };

            // Step 4: Apply color math if not disabled and layer participates
            if (!disable_math and layer_participates) {
                // Get the color to blend with (fixed color or subscreen)
                // CGWSEL bit 1: 0 = use fixed color (COLDATA), 1 = use subscreen
                //
                // Subscreen is a second rendered image using layers from TS register
                // instead of TM. It's commonly used for transparency effects like
                // water reflections, shadows, and the SMW title screen sky.
                const use_subscreen = (self.cgwsel & 0x02) != 0;

                // Hardware rule: with "add subscreen" selected, if the
                // subscreen has NO opaque pixel at this position (all layers
                // transparent), the FIXED COLOR is used instead - and the
                // half-math divide is suppressed. Games rely on this for
                // solid color fills: SMB1 (All-Stars) draws its sky as
                // backdrop + COLDATA blue with an empty subscreen.
                var blend_color: u16 = undefined;
                var subscreen_transparent = false;
                if (use_subscreen) {
                    if (self.renderSubscreenPixel(&bg_lines, @intCast(x), y, mode)) |sub| {
                        blend_color = sub;
                    } else {
                        blend_color = self.coldata;
                        subscreen_transparent = true;
                    }
                } else {
                    // Use fixed color from COLDATA register
                    blend_color = self.coldata;
                }

                // Extract RGB components (5 bits each)
                // SNES color format: 0bbbbbgg gggrrrrr (15-bit BGR)
                var r: i16 = @intCast(color & 0x1F);
                var g: i16 = @intCast((color >> 5) & 0x1F);
                var b: i16 = @intCast((color >> 10) & 0x1F);

                const br: i16 = @intCast(blend_color & 0x1F);
                const bg: i16 = @intCast((blend_color >> 5) & 0x1F);
                const bb: i16 = @intCast((blend_color >> 10) & 0x1F);

                // Add or subtract based on CGADSUB bit 7
                const subtract = (self.cgadsub & 0x80) != 0;
                if (subtract) {
                    r -= br;
                    g -= bg;
                    b -= bb;
                } else {
                    r += br;
                    g += bg;
                    b += bb;
                }

                // Half color math (CGADSUB bit 6) - divide result by 2.
                // Used for 50% transparency effects. NOT applied when the
                // subscreen fell back to fixed color (hardware behavior),
                // nor when the main pixel was forced black by the window.
                const half_math = (self.cgadsub & 0x40) != 0 and !subscreen_transparent and !force_black;
                if (half_math) {
                    r = @divTrunc(r, 2);
                    g = @divTrunc(g, 2);
                    b = @divTrunc(b, 2);
                }

                // Clamp to valid range (0-31)
                r = @max(0, @min(31, r));
                g = @max(0, @min(31, g));
                b = @max(0, @min(31, b));

                // Recombine into 15-bit color
                color = @as(u16, @intCast(r)) | (@as(u16, @intCast(g)) << 5) | (@as(u16, @intCast(b)) << 10);
            }

            // Apply master brightness from INIDISP bits 0-3.
            // Brightness 0 = black, 15 = full; hardware scales each 5-bit
            // component as component * brightness / 15. The comptime
            // BRIGHTNESS_LUT (row selected once per scanline above) replaces
            // the three per-pixel integer divisions with three table loads,
            // branch-free: row 0 is all zeros and row 15 is the identity, so
            // the old special cases fall out of the same lookup.
            // SNES color format: 0bbbbbgg gggrrrrr (15-bit BGR)
            self.framebuffer[start + x] = bright[color & 0x1F] |
                (bright[(color >> 5) & 0x1F] << 5) |
                (bright[(color >> 10) & 0x1F] << 10);
        }
    }

    const BgPixelResult = struct {
        color: u16,
        priority: u8,
    };

    /// Sign-extend a 13-bit value (Mode 7 scroll/center registers).
    fn sign13(value: u16) i16 {
        const v = value & 0x1FFF;
        if ((v & 0x1000) != 0) {
            return @bitCast(v | 0xE000);
        }
        return @bitCast(v);
    }

    /// Update the PPU multiplication result (MPYL/M/H).
    /// The PPU1 chip contains a 16x8 signed multiplier that is "free" for
    /// games to use - it computes continuously from M7A x M7B without
    /// consuming CPU time (unlike the CPU's own multiply at $4202/$4203).
    fn updateMpy(self: *Ppu, multiplier: i8) void {
        self.mpy_result = @as(i32, self.m7a) * @as(i32, multiplier);
    }

    /// Render one Mode 7 pixel.
    ///
    /// The Mode 7 plane is stored interleaved in VRAM: the LOW byte of each
    /// word is the 128x128 tilemap (one byte per tile, no flip/palette
    /// bits), the HIGH byte is 8bpp tile pixel data. Word address for the
    /// tilemap entry of tile (tx,ty) is ty*128+tx; word address of pixel
    /// (px,py) inside tile T is T*64 + py*8 + px.
    ///
    /// Per-pixel transform (from fullsnes/bsnes, all i32 math):
    ///   ox = CLIP(m7hofs - m7x), oy = CLIP(m7vofs - m7y)
    ///   u = ((m7a*ox & ~63) + (m7b*oy & ~63) + (m7b*sy & ~63) + (m7x<<8) + m7a*sx) >> 8
    ///   v = ((m7c*ox & ~63) + (m7d*oy & ~63) + (m7d*sy & ~63) + (m7y<<8) + m7c*sx) >> 8
    /// where CLIP clamps the 13-bit difference to +/-1024 (a hardware
    /// quirk: the middle terms only keep 10 fractional-truncated bits),
    /// and sx/sy are the (optionally flipped) screen coordinates.
    fn renderMode7Pixel(self: *Ppu, x: u16, y: u16) ?BgPixelResult {
        // M7SEL bits 0-1: horizontal/vertical screen flip
        const sx: i32 = if ((self.m7sel & 0x01) != 0) 255 - @as(i32, x) else @as(i32, x);
        const sy: i32 = if ((self.m7sel & 0x02) != 0) 255 - @as(i32, y) else @as(i32, y);

        const ox = mode7Clip(@as(i32, self.m7hofs) - @as(i32, self.m7x));
        const oy = mode7Clip(@as(i32, self.m7vofs) - @as(i32, self.m7y));

        const a = @as(i32, self.m7a);
        const b = @as(i32, self.m7b);
        const c = @as(i32, self.m7c);
        const d = @as(i32, self.m7d);

        // 8.8 fixed-point texture coordinates. The &~63 truncation on the
        // precomputed terms matches hardware rounding behavior.
        const u_fp = ((a * ox) & ~@as(i32, 63)) +
            ((b * oy) & ~@as(i32, 63)) +
            ((b * sy) & ~@as(i32, 63)) +
            (@as(i32, self.m7x) << 8) +
            (a * sx);
        const v_fp = ((c * ox) & ~@as(i32, 63)) +
            ((d * oy) & ~@as(i32, 63)) +
            ((d * sy) & ~@as(i32, 63)) +
            (@as(i32, self.m7y) << 8) +
            (c * sx);

        var u = u_fp >> 8;
        var v = v_fp >> 8;

        // The plane is 1024x1024 pixels. M7SEL bits 6-7 decide what happens
        // outside it ("screen over"):
        //   0/1: wrap around
        //   2:   transparent
        //   3:   repeat tile 0 (only the pixel coords wrap within a tile)
        const out_of_bounds = (u & ~@as(i32, 1023)) != 0 or (v & ~@as(i32, 1023)) != 0;
        const screen_over = self.m7sel >> 6;
        if (out_of_bounds and screen_over == 2) return null;
        u &= 1023;
        v &= 1023;

        var tile: u16 = 0; // Screen-over mode 3: out-of-bounds uses tile 0
        if (!out_of_bounds or screen_over != 3) {
            const tx: u32 = @intCast(u >> 3);
            const ty: u32 = @intCast(v >> 3);
            // Tilemap entry: LOW byte of word (ty*128+tx)
            tile = self.vram[(ty * 128 + tx) * 2];
        }

        // Pixel: HIGH byte of word (tile*64 + py*8 + px)
        const px: u32 = @intCast(u & 7);
        const py: u32 = @intCast(v & 7);
        const color_index = self.vram[(@as(u32, tile) * 64 + py * 8 + px) * 2 + 1];

        if (color_index == 0) return null; // Color 0 = transparent

        return BgPixelResult{
            .color = self.getColor(color_index),
            .priority = 0, // Mode 7 BG1 has a single priority level
        };
    }

    /// Mode 7 hardware clamp: the scroll-minus-center difference is a
    /// 13-bit value clipped to the range -1024..+1023 before entering the
    /// matrix multiply.
    fn mode7Clip(value: i32) i32 {
        if ((value & 0x2000) != 0) {
            return value | ~@as(i32, 1023);
        }
        return value & 1023;
    }

    /// Render a single BG pixel
    // ==========================================================================
    // LINE-BUFFER BACKGROUND RENDERING
    // ==========================================================================
    // The PPU renders each enabled BG layer into a per-scanline line buffer,
    // tile run by tile run, instead of resolving every screen pixel
    // independently. The motivation is that 8 consecutive pixels share one
    // tilemap entry and one CHR row: fetching and decoding them once per run
    // does 1/8th the work of the per-pixel approach (which re-read the
    // tilemap entry and re-extracted bitplanes for every single pixel).
    //
    // This structure is also what the hardware conceptually does during
    // H-blank prefetch, and it is the natural home for upcoming accuracy
    // features: offset-per-tile (modes 2/4/6) replaces a run's scroll values
    // per column, and per-mode priority reordering happens at composite time
    // over the finished buffers.
    //
    // renderBgPixel() below is KEPT as the reference implementation: a unit
    // test cross-checks renderBgLine() against it over randomized VRAM and
    // register state, so the fast path can never silently diverge from the
    // readable one.
    // ==========================================================================

    /// One BG layer's pixels for the current scanline.
    const BgLine = struct {
        /// Sentinel in `prio` marking a transparent pixel (real priorities
        /// are only 0/1, so 0xFF can never collide).
        const transparent: u8 = 0xFF;

        color: [SCREEN_WIDTH]u16, // resolved 15-bit CGRAM colors
        prio: [SCREEN_WIDTH]u8, // tile priority bit, or `transparent`

        /// View one buffered pixel in the same shape renderBgPixel returns,
        /// so the compositing code reads buffers and the reference
        /// implementation interchangeably.
        inline fn pixel(line: *const BgLine, x: usize) ?BgPixelResult {
            if (line.prio[x] == transparent) return null;
            return .{ .color = line.color[x], .priority = line.prio[x] };
        }
    };

    /// Decode one 8-pixel row of a planar tile into color indices.
    /// Each bitplane pair collapses to a u16 via the comptime PLANE_SPREAD
    /// table (all eight 2-bit slices at once); this routine is the
    /// decode-per-row payoff that table was built for. `base_addr` is the
    /// tile's BYTE address in VRAM, `py` the row within the tile (0-7).
    fn decodeTileRow(self: *const Ppu, base_addr: u32, py: u8, bpp: u8) [8]u8 {
        const row = @as(u32, py) * 2;
        const m01 = PLANE_SPREAD[self.vram[@as(usize, base_addr + row) & 0xFFFF]] |
            (PLANE_SPREAD[self.vram[@as(usize, base_addr + row + 1) & 0xFFFF]] << 1);
        var m23: u16 = 0;
        var m45: u16 = 0;
        var m67: u16 = 0;
        if (bpp >= 4) {
            m23 = PLANE_SPREAD[self.vram[@as(usize, base_addr + 16 + row) & 0xFFFF]] |
                (PLANE_SPREAD[self.vram[@as(usize, base_addr + 16 + row + 1) & 0xFFFF]] << 1);
        }
        if (bpp >= 8) {
            m45 = PLANE_SPREAD[self.vram[@as(usize, base_addr + 32 + row) & 0xFFFF]] |
                (PLANE_SPREAD[self.vram[@as(usize, base_addr + 32 + row + 1) & 0xFFFF]] << 1);
            m67 = PLANE_SPREAD[self.vram[@as(usize, base_addr + 48 + row) & 0xFFFF]] |
                (PLANE_SPREAD[self.vram[@as(usize, base_addr + 48 + row + 1) & 0xFFFF]] << 1);
        }

        var out: [8]u8 = undefined;
        inline for (0..8) |i| {
            // Pixel 0 is the LEFTMOST pixel and lives in bit 7 of each plane
            // byte, i.e. slice 7 of the spread word - hence (7 - i).
            const shift: u4 = @intCast((7 - i) * 2);
            var p: u8 = @truncate((m01 >> shift) & 3);
            p |= @as(u8, @truncate((m23 >> shift) & 3)) << 2;
            p |= @as(u8, @truncate((m45 >> shift) & 3)) << 4;
            p |= @as(u8, @truncate((m67 >> shift) & 3)) << 6;
            out[i] = p;
        }
        return out;
    }

    /// Render one full scanline of a BG layer into `line`.
    ///
    /// All layer configuration (scroll, tilemap base, tile size, CHR base)
    /// is hoisted out of the pixel loop - it cannot change mid-line in our
    /// scanline-granularity model (mid-line register writes are future
    /// accuracy work; see NEXTSTEPS.md). The scanline is then walked in runs
    /// of up to 8 pixels that share a single 8x8 tile row, so the tilemap
    /// entry fetch and bitplane decode happen once per run.
    ///
    /// The address math below intentionally mirrors renderBgPixel() line for
    /// line - see the register-format documentation there for the full
    /// derivation of the tilemap and character base calculations.
    fn renderBgLine(self: *Ppu, bg: u8, y: u16, bpp: u8, line: *BgLine) void {
        // Start fully transparent; only opaque pixels are written below.
        @memset(&line.prio, BgLine.transparent);

        // ---- Per-layer configuration (constant across the line) ----
        const hofs: u16 = switch (bg) {
            1 => self.bg1hofs,
            2 => self.bg2hofs,
            3 => self.bg3hofs,
            4 => self.bg4hofs,
            else => 0,
        };
        const vofs: u16 = switch (bg) {
            1 => self.bg1vofs,
            2 => self.bg2vofs,
            3 => self.bg3vofs,
            4 => self.bg4vofs,
            else => 0,
        };
        const sc_reg: u8 = switch (bg) {
            1 => self.bg1sc,
            2 => self.bg2sc,
            3 => self.bg3sc,
            4 => self.bg4sc,
            else => 0,
        };
        // BGMODE bits 4-7: 16x16 tile enable per layer
        const tile_size_bit: u3 = switch (bg) {
            1 => 4,
            2 => 5,
            3 => 6,
            4 => 7,
            else => 4,
        };
        const large_tiles = ((self.bgmode >> tile_size_bit) & 1) != 0;
        const tile_size: u16 = if (large_tiles) 16 else 8;
        // BG12NBA/BG34NBA nibbles select the CHR base in 8KB steps
        const chr_base: u32 = switch (bg) {
            1 => @as(u32, self.bg12nba & 0x0F) << 13,
            2 => @as(u32, self.bg12nba >> 4) << 13,
            3 => @as(u32, self.bg34nba & 0x0F) << 13,
            4 => @as(u32, self.bg34nba >> 4) << 13,
            else => 0,
        };
        const bytes_per_row: u32 = switch (bpp) {
            2 => 2,
            4 => 4,
            8 => 8,
            else => 2,
        };
        const palette_shift: u16 = switch (bpp) {
            2 => 4, // 2bpp palettes are 4 colors apart
            4 => 16, // 4bpp palettes are 16 colors apart
            else => 0, // 8bpp uses the full 256-color palette
        };
        const map_width_32 = (sc_reg & 0x01) != 0;
        const map_height_32 = (sc_reg & 0x02) != 0;
        const map_base: u32 = @as(u32, sc_reg & 0xFC) << 9;

        // Vertical position is constant for the whole line
        const sy = (y +% vofs) & 0x3FF;
        const tile_y = sy / tile_size;
        const quadrant_y: u16 = (tile_y / 32) & 1;
        const local_tile_y: u32 = tile_y & 31;

        var x: u16 = 0;
        while (x < SCREEN_WIDTH) {
            const sx = (x +% hofs) & 0x3FF;
            // Run length: pixels remaining in this 8-aligned CHR row. Runs
            // never straddle a tile (8-blocks nest in 16px tiles) nor the
            // 1024-pixel map wrap (1024 is 8-aligned), so everything fetched
            // below is valid for the whole run.
            const run: u16 = @min(8 - (sx & 7), SCREEN_WIDTH - x);

            // ---- Tilemap entry fetch (once per run) ----
            const tile_x = sx / tile_size;
            const quadrant_x: u16 = (tile_x / 32) & 1;
            var tilemap_addr = map_base;
            if (map_width_32 and quadrant_x != 0) {
                tilemap_addr +%= 0x800;
            }
            if (map_height_32 and quadrant_y != 0) {
                tilemap_addr +%= if (map_width_32) 0x1000 else 0x800;
            }
            const tilemap_offset: u32 = tilemap_addr + (local_tile_y * 32 + (tile_x & 31)) * 2;
            const tile_lo = self.vram[@as(usize, tilemap_offset) & 0xFFFF];
            const tile_hi = self.vram[@as(usize, tilemap_offset + 1) & 0xFFFF];
            const tilemap_entry: u16 = @as(u16, tile_hi) << 8 | tile_lo;

            const tile_num: u16 = tilemap_entry & 0x3FF;
            const palette: u8 = @truncate((tilemap_entry >> 10) & 0x07);
            const tile_priority: u8 = @intCast((tilemap_entry >> 13) & 1);
            const h_flip = ((tilemap_entry >> 14) & 1) != 0;
            const v_flip = ((tilemap_entry >> 15) & 1) != 0;

            if (comptime dbg.trace_bg_render) {
                if (bg == 3 and self.frame_count == 600 and y < 5 and x < 24) {
                    std.debug.print("[BG3] x={d:3} y={d:3} tile({d},{d}) entry=${x:0>4} tile={x:0>3}\n", .{ x, y, tile_x, tile_y, tilemap_entry, tile_num });
                }
            }

            // ---- Locate the 8x8 CHR row (once per run) ----
            var py = sy % tile_size;
            if (v_flip) py = tile_size - 1 - py;

            // Horizontal flip mirrors the pixel order within the tile; the
            // run's pixels all land in one 8-pixel half either way, so the
            // sub-tile choice is constant and only the walk direction flips.
            const px_first = sx % tile_size;
            const px0: u16 = if (h_flip) tile_size - 1 - px_first else px_first;

            var actual_tile = tile_num;
            if (large_tiles) {
                // 16x16 tiles are four adjacent 8x8 tiles: +1 to the right,
                // +16 below (the CHR layout is a 16-tile-wide grid)
                actual_tile += @intCast(px0 / 8);
                actual_tile += @intCast((py / 8) * 16);
                py = py % 8;
            }

            const tile_data_addr: u32 = chr_base + @as(u32, actual_tile) * 8 * bytes_per_row;

            if (comptime dbg.trace_bg_render) {
                if (bg == 3 and self.frame_count == 600 and x <= 16 and x + run > 16 and y == 50) {
                    std.debug.print("  actual_tile=${x:0>3} chr_base=${x:0>5} tile_data_addr=${x:0>5}\n", .{ actual_tile, chr_base, tile_data_addr });
                }
            }

            const row = self.decodeTileRow(tile_data_addr, @intCast(py), bpp);
            const palette_base: u16 = @as(u16, palette) * palette_shift;

            // ---- Emit the run ----
            // Walk the decoded row forward or backward depending on h_flip.
            var px: u16 = px0 & 7;
            for (0..run) |i| {
                const color_index = row[px];
                if (color_index != 0) { // color 0 is transparent
                    line.color[x + i] = self.getColor(@intCast(palette_base + color_index));
                    line.prio[x + i] = tile_priority;
                }
                if (h_flip) px -%= 1 else px +%= 1;
            }
            x += run;
        }
    }

    /// Reference (per-pixel) BG renderer. No longer used for actual frame
    /// output - renderBgLine() above is the production path - but kept
    /// permanently: the "renderBgLine matches renderBgPixel" test verifies
    /// the two agree on every pixel over randomized state, and this version
    /// is the more readable specification of the address math (see the
    /// register-format documentation blocks inside).
    fn renderBgPixel(self: *Ppu, bg: u8, x: u16, y: u16, bpp: u8) ?BgPixelResult {
        // Get scroll offsets for this BG
        const hofs: u16 = switch (bg) {
            1 => self.bg1hofs,
            2 => self.bg2hofs,
            3 => self.bg3hofs,
            4 => self.bg4hofs,
            else => 0,
        };
        const vofs: u16 = switch (bg) {
            1 => self.bg1vofs,
            2 => self.bg2vofs,
            3 => self.bg3vofs,
            4 => self.bg4vofs,
            else => 0,
        };

        // Get tilemap address for this BG
        const sc_reg: u8 = switch (bg) {
            1 => self.bg1sc,
            2 => self.bg2sc,
            3 => self.bg3sc,
            4 => self.bg4sc,
            else => 0,
        };

        // Check tile size (8x8 or 16x16)
        const tile_size_bit: u3 = switch (bg) {
            1 => 4,
            2 => 5,
            3 => 6,
            4 => 7,
            else => 4,
        };
        const large_tiles = ((self.bgmode >> tile_size_bit) & 1) != 0;
        const tile_size: u16 = if (large_tiles) 16 else 8;

        // Calculate scrolled position
        const sx = (x +% hofs) & 0x3FF; // 10-bit wrap for 1024 pixel tilemap
        const sy = (y +% vofs) & 0x3FF;

        // Get tile coordinates
        const tile_x = sx / tile_size;
        const tile_y = sy / tile_size;

        // Calculate which tilemap quadrant we're in (for > 32x32 tilemaps)
        const map_width_32 = (sc_reg & 0x01) != 0;
        const map_height_32 = (sc_reg & 0x02) != 0;

        var quadrant_x: u16 = 0;
        var quadrant_y: u16 = 0;

        if (large_tiles) {
            quadrant_x = (tile_x / 32) & 1;
            quadrant_y = (tile_y / 32) & 1;
        } else {
            quadrant_x = (tile_x / 32) & 1;
            quadrant_y = (tile_y / 32) & 1;
        }

        // =============================================================================
        // TILEMAP BASE ADDRESS CALCULATION
        // =============================================================================
        // Reference: https://snes.nesdev.org/wiki/Registers
        // Reference: fullsnes.txt "$2107-$210A - BGxSC"
        //
        // $2107-$210A - BGxSC - BG1-4 Tilemap Address and Size (W)
        // Register format: AAAAAASS where:
        //   - AAAAAA (bits 7:2) = tilemap base address in 0x400 WORD units (1KB words = 2KB bytes)
        //   - SS (bits 1:0) = tilemap size (0=32x32, 1=64x32, 2=32x64, 3=64x64 tiles)
        //
        // The PPU uses word addresses internally, but our vram[] array is byte-indexed.
        // Conversion: byte_addr = word_addr * 2
        //
        // Formula: base_addr = ((sc_reg & 0xFC) >> 2) * 0x400 words * 2 bytes
        //        = (sc_reg & 0xFC) * 0x100 * 2 = (sc_reg & 0xFC) << 9
        //
        // Example: If BG1SC = 0x70:
        //   - bits 7:2 = 0x1C = 28
        //   - tilemap base = 28 * 0x400 * 2 = 0xE000 bytes
        //   - With formula: (0x70 & 0xFC) << 9 = 0x70 << 9 = 0xE000 bytes ✓
        // =============================================================================
        var tilemap_addr: u32 = @as(u32, sc_reg & 0xFC) << 9;

        // Add quadrant offset (each 32x32 quadrant is 32*32*2 = 2KB = 0x800 bytes)
        if (map_width_32 and quadrant_x != 0) {
            tilemap_addr +%= 0x800;
        }
        if (map_height_32 and quadrant_y != 0) {
            tilemap_addr +%= if (map_width_32) 0x1000 else 0x800;
        }

        // Calculate tile position within current quadrant
        const local_tile_x = tile_x & 31;
        const local_tile_y = tile_y & 31;

        // Read tilemap entry (2 bytes per tile)
        const tilemap_offset: u32 = tilemap_addr + @as(u32, local_tile_y * 32 + local_tile_x) * 2;
        const tile_lo = self.vram[@as(usize, tilemap_offset) & 0xFFFF];
        const tile_hi = self.vram[@as(usize, tilemap_offset + 1) & 0xFFFF];
        const tilemap_entry: u16 = @as(u16, tile_hi) << 8 | tile_lo;

        // Parse tilemap entry
        const tile_num: u16 = tilemap_entry & 0x3FF;


        // Debug: trace BG3 tile reading on frame 600
        // Trace first few positions to verify tile reading
        if (comptime dbg.trace_bg_render) {
            if (bg == 3 and self.frame_count == 600 and y < 5 and x < 24 and (x % 8 == 0)) {
                std.debug.print("[BG3] x={d:3} y={d:3} tile({d},{d}) entry=${x:0>4} tile={x:0>3}\n", .{ x, y, tile_x, tile_y, tilemap_entry, tile_num });
            }
        }
        const palette: u8 = @truncate((tilemap_entry >> 10) & 0x07);
        const tile_priority = (tilemap_entry >> 13) & 1;
        const h_flip = ((tilemap_entry >> 14) & 1) != 0;
        const v_flip = ((tilemap_entry >> 15) & 1) != 0;

        // Get pixel position within tile
        var px = sx % tile_size;
        var py = sy % tile_size;

        // Handle flipping
        if (h_flip) px = tile_size - 1 - px;
        if (v_flip) py = tile_size - 1 - py;

        // For 16x16 tiles, figure out which 8x8 sub-tile
        var actual_tile = tile_num;
        if (large_tiles) {
            actual_tile += (px / 8);
            actual_tile += (py / 8) * 16;
            px = px % 8;
            py = py % 8;
        }

        // =============================================================================
        // CHARACTER (TILE GRAPHICS) BASE ADDRESS CALCULATION
        // =============================================================================
        // Reference: https://snes.nesdev.org/wiki/Registers
        // Reference: fullsnes.txt "$210B/$210C - BG12NBA/BG34NBA"
        //
        // $210B - BG12NBA - BG1/BG2 Character Data Address (W)
        // $210C - BG34NBA - BG3/BG4 Character Data Address (W)
        //
        // Register format: BBBBAAAA where:
        //   - AAAA (bits 3:0) = BG1/BG3 character base address
        //   - BBBB (bits 7:4) = BG2/BG4 character base address
        //
        // Address calculation (from fullsnes):
        //   - Each increment = 0x1000 WORDS = 0x2000 BYTES (4K-word / 8KB steps)
        //   - Character base (bytes) = value * 0x2000 = value << 13
        //   - Value range 0-F maps to VRAM 0x0000-0xE000 (word addr) = 0x0000-0x1C000 (byte addr)
        //
        // Example: If BG12NBA = 0x21:
        //   - BG1 chr base = (0x21 & 0x0F) << 13 = 1 << 13 = 0x2000 bytes
        //   - BG2 chr base = (0x21 >> 4) << 13 = 2 << 13 = 0x4000 bytes
        // =============================================================================
        const chr_base: u32 = switch (bg) {
            1 => @as(u32, self.bg12nba & 0x0F) << 13,
            2 => @as(u32, self.bg12nba >> 4) << 13,
            3 => @as(u32, self.bg34nba & 0x0F) << 13,
            4 => @as(u32, self.bg34nba >> 4) << 13,
            else => 0,
        };

        // Calculate bytes per tile row based on bpp
        const bytes_per_row: u32 = switch (bpp) {
            2 => 2,
            4 => 4,
            8 => 8,
            else => 2,
        };

        // Calculate tile data address
        // Each 8x8 tile uses (8 * bytes_per_row) bytes
        const tile_data_addr: u32 = chr_base + @as(u32, actual_tile) * 8 * bytes_per_row;

        // Debug: trace the actual tile address being used
        if (comptime dbg.trace_bg_render) {
            if (bg == 3 and self.frame_count == 600 and x == 16 and y == 50) {
                std.debug.print("  actual_tile=${x:0>3} chr_base=${x:0>5} tile_data_addr=${x:0>5}\n", .{ actual_tile, chr_base, tile_data_addr });
                std.debug.print("  First 4 bytes at tile_data_addr: {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{
                    self.vram[@as(usize, tile_data_addr) & 0xFFFF],
                    self.vram[@as(usize, tile_data_addr + 1) & 0xFFFF],
                    self.vram[@as(usize, tile_data_addr + 2) & 0xFFFF],
                    self.vram[@as(usize, tile_data_addr + 3) & 0xFFFF],
                });
            }
        }

        // Read pixel data from tile
        const pixel_color = self.getTilePixel(tile_data_addr, @intCast(px), @intCast(py), bpp);

        // Color 0 is transparent
        if (pixel_color == 0) return null;

        // Calculate palette offset based on bpp and BG
        const palette_offset: u16 = switch (bpp) {
            2 => @as(u16, palette) * 4,
            4 => @as(u16, palette) * 16,
            8 => 0, // 8bpp uses full 256-color palette
            else => 0,
        };

        // Get actual color from CGRAM
        const color = self.getColor(@intCast(palette_offset + pixel_color));

        return .{
            .color = color,
            .priority = @intCast(tile_priority),
        };
    }

    /// ==========================================================================
    /// SUBSCREEN RENDERING
    /// ==========================================================================
    /// Renders a single pixel from the subscreen for color math blending.
    /// The subscreen uses the TS register ($212D) instead of TM ($212C) to
    /// determine which layers are enabled. This is used for transparency effects.
    ///
    /// Unlike the main screen which composites layers back-to-front with priority,
    /// the subscreen result is simply blended with the main screen via color math.
    /// ==========================================================================
    /// Render the subscreen pixel at (x, y), or null if every enabled
    /// subscreen layer is transparent there. The distinction matters:
    /// a fully-transparent subscreen makes "add subscreen" color math
    /// fall back to the fixed color instead of adding the backdrop.
    /// Reads the same per-scanline BG line buffers the main screen uses -
    /// the subscreen shows the SAME rendered layers, just selected by TS
    /// instead of TM, so one buffer pass serves both screens.
    fn renderSubscreenPixel(self: *Ppu, bg_lines: *const [4]BgLine, x: u16, y: u16, mode: u3) ?u16 {
        var color: ?u16 = null;

        // Note: Subscreen doesn't use window masking for layer enable
        // (though the color window affects where color math applies)

        switch (mode) {
            0 => {
                // Mode 0: 4 BG layers, 2bpp each
                if ((self.ts & 0x08) != 0) {
                    if (bg_lines[3].pixel(x)) |c| {
                        color = c.color;
                    }
                }
                if ((self.ts & 0x04) != 0) {
                    if (bg_lines[2].pixel(x)) |c| {
                        color = c.color;
                    }
                }
                if ((self.ts & 0x02) != 0) {
                    if (bg_lines[1].pixel(x)) |c| {
                        color = c.color;
                    }
                }
                if ((self.ts & 0x01) != 0) {
                    if (bg_lines[0].pixel(x)) |c| {
                        color = c.color;
                    }
                }
            },
            1 => {
                // Mode 1: BG1/BG2 4bpp, BG3 2bpp
                if ((self.ts & 0x04) != 0) {
                    if (bg_lines[2].pixel(x)) |c| {
                        color = c.color;
                    }
                }
                if ((self.ts & 0x02) != 0) {
                    if (bg_lines[1].pixel(x)) |c| {
                        color = c.color;
                    }
                }
                if ((self.ts & 0x01) != 0) {
                    if (bg_lines[0].pixel(x)) |c| {
                        color = c.color;
                    }
                }
            },
            2, 3, 4, 5, 6 => {
                // Modes 2-6 subscreen: mode 6 has no BG2 (depths are baked
                // into the buffers by the line-buffer pass)
                if (mode != 6 and (self.ts & 0x02) != 0) {
                    if (bg_lines[1].pixel(x)) |c| {
                        color = c.color;
                    }
                }
                if ((self.ts & 0x01) != 0) {
                    if (bg_lines[0].pixel(x)) |c| {
                        color = c.color;
                    }
                }
            },
            7 => {
                // Mode 7 on the subscreen - per-pixel affine, not buffered
                if ((self.ts & 0x01) != 0) {
                    if (self.renderMode7Pixel(x, y)) |c| {
                        color = c.color;
                    }
                }
            },
        }

        // Note: Subscreen sprites (OBJ) would be handled here if TS bit 4 is set
        // For now we don't render subscreen sprites, as it's less common

        return color;
    }

    /// Get a pixel value from tile data
    /// base_addr is a BYTE address into VRAM
    ///
    /// SNES uses planar format - bitplanes come in pairs, and a tile stores
    /// each row's pair bytes adjacently:
    ///   2bpp: bp0, bp1 for each row (16 bytes per tile)
    ///   4bpp: all rows of bp0/bp1, then all rows of bp2/bp3 (32 bytes)
    ///   8bpp: bp0/1, bp2/3, bp4/5, bp6/7 sections of 16 bytes each (64 bytes)
    ///
    /// Each plane PAIR is merged via the comptime PLANE_SPREAD table into a
    /// u16 holding all eight 2-bit pixel slices of the row, then the wanted
    /// pixel's slice is extracted with a single shift+mask. Pixel px=0 is the
    /// LEFTMOST pixel, which lives in bit 7 of each plane byte - hence the
    /// (7 - px) in the shift amount.
    fn getTilePixel(self: *Ppu, base_addr: u32, px: u8, py: u8, bpp: u8) u8 {
        const shift: u4 = @intCast((7 - px) * 2);
        const row = @as(u32, py) * 2;

        // Bitplanes 0-1
        const bp0 = self.vram[@as(usize, base_addr + row) & 0xFFFF];
        const bp1 = self.vram[@as(usize, base_addr + row + 1) & 0xFFFF];
        const merged01 = PLANE_SPREAD[bp0] | (PLANE_SPREAD[bp1] << 1);
        var pixel: u8 = @truncate((merged01 >> shift) & 3);

        if (bpp >= 4) {
            // Bitplanes 2-3 (next 16-byte section of the tile)
            const bp2 = self.vram[@as(usize, base_addr + 16 + row) & 0xFFFF];
            const bp3 = self.vram[@as(usize, base_addr + 16 + row + 1) & 0xFFFF];
            const merged23 = PLANE_SPREAD[bp2] | (PLANE_SPREAD[bp3] << 1);
            pixel |= @as(u8, @truncate((merged23 >> shift) & 3)) << 2;
        }

        if (bpp >= 8) {
            // Bitplanes 4-5
            const bp4 = self.vram[@as(usize, base_addr + 32 + row) & 0xFFFF];
            const bp5 = self.vram[@as(usize, base_addr + 32 + row + 1) & 0xFFFF];
            const merged45 = PLANE_SPREAD[bp4] | (PLANE_SPREAD[bp5] << 1);
            pixel |= @as(u8, @truncate((merged45 >> shift) & 3)) << 4;

            // Bitplanes 6-7
            const bp6 = self.vram[@as(usize, base_addr + 48 + row) & 0xFFFF];
            const bp7 = self.vram[@as(usize, base_addr + 48 + row + 1) & 0xFFFF];
            const merged67 = PLANE_SPREAD[bp6] | (PLANE_SPREAD[bp7] << 1);
            pixel |= @as(u8, @truncate((merged67 >> shift) & 3)) << 6;
        }

        return pixel;
    }

    /// Get a 15-bit color from CGRAM
    fn getColor(self: *Ppu, index: u8) u16 {
        const addr = @as(u16, index) * 2;
        const lo = self.cgram[addr];
        const hi = self.cgram[addr + 1];
        return @as(u16, hi & 0x7F) << 8 | lo;
    }

    // ==========================================================================
    // WINDOW MASKING
    // ==========================================================================
    // The SNES has two windows that can mask (hide) portions of BG layers and
    // sprites. Each window defines a horizontal range (left to right position).
    // For each layer, you can enable either window, invert either window's effect,
    // and combine the two windows using OR/AND/XOR/XNOR logic.
    //
    // Registers:
    //   W12SEL ($2123): Window enable/invert for BG1/BG2
    //   W34SEL ($2124): Window enable/invert for BG3/BG4
    //   WOBJSEL ($2125): Window enable/invert for OBJ/Color
    //   WH0-WH3 ($2126-$2129): Window 1/2 left/right positions
    //   WBGLOG ($212A): Window logic for BG1-4
    //   WOBJLOG ($212B): Window logic for OBJ/Color
    //   TMW ($212E): Enable window masking per layer on main screen
    //   TSW ($212F): Enable window masking per layer on sub screen
    //
    // Returns true if the pixel at position x should be MASKED (hidden) for
    // the given layer. Layer: 0=BG1, 1=BG2, 2=BG3, 3=BG4, 4=OBJ
    // ==========================================================================
    fn isWindowMasked(self: *Ppu, layer: u3, x: u8) bool {
        // Check if window masking is enabled for this layer on main screen
        const tmw_bit = @as(u8, 1) << layer;
        if ((self.tmw & tmw_bit) == 0) return false;

        // Get window settings for this layer
        const w_sel: u8 = switch (layer) {
            0 => self.w12sel & 0x0F, // BG1
            1 => self.w12sel >> 4, // BG2
            2 => self.w34sel & 0x0F, // BG3
            3 => self.w34sel >> 4, // BG4
            4 => self.wobjsel & 0x0F, // OBJ
            else => 0,
        };

        // Get window logic for this layer
        const w_log: u2 = switch (layer) {
            0 => @truncate(self.wbglog & 0x03), // BG1
            1 => @truncate((self.wbglog >> 2) & 0x03), // BG2
            2 => @truncate((self.wbglog >> 4) & 0x03), // BG3
            3 => @truncate(self.wbglog >> 6), // BG4
            4 => @truncate(self.wobjlog & 0x03), // OBJ
            else => 0,
        };

        // Window 1 settings: bits 0=enable, 1=invert
        const w1_enable = (w_sel & 0x02) != 0;
        const w1_invert = (w_sel & 0x01) != 0;

        // Window 2 settings: bits 2=enable, 3=invert
        const w2_enable = (w_sel & 0x08) != 0;
        const w2_invert = (w_sel & 0x04) != 0;

        // Calculate window 1 state (true if inside window)
        var w1_inside: bool = false;
        if (w1_enable) {
            // Window is "inside" when left <= x <= right
            // When left > right, window covers nothing
            w1_inside = (x >= self.wh0 and x <= self.wh1);
            if (w1_invert) w1_inside = !w1_inside;
        }

        // Calculate window 2 state
        var w2_inside: bool = false;
        if (w2_enable) {
            w2_inside = (x >= self.wh2 and x <= self.wh3);
            if (w2_invert) w2_inside = !w2_inside;
        }

        // Combine windows based on logic
        // If only one window enabled, use that window's result
        // If neither enabled, no masking (return false)
        var masked: bool = false;
        if (w1_enable and w2_enable) {
            masked = switch (w_log) {
                0 => w1_inside or w2_inside, // OR
                1 => w1_inside and w2_inside, // AND
                2 => w1_inside != w2_inside, // XOR
                3 => w1_inside == w2_inside, // XNOR
            };
        } else if (w1_enable) {
            masked = w1_inside;
        } else if (w2_enable) {
            masked = w2_inside;
        }

        return masked;
    }

    // ==========================================================================
    // COLOR WINDOW
    // ==========================================================================
    // The color window is used for color math effects like "force main screen
    // black" which creates spotlight/iris effects. It uses the same window
    // positions (WH0-WH3) as BG/OBJ windows but has separate enable/invert
    // settings in WOBJSEL bits 4-7 and logic in WOBJLOG bits 2-3.
    //
    // Returns true if the color window is "active" at position x.
    // This is used by CGWSEL bits 6-7 to determine where to force black.
    // ==========================================================================
    fn isColorWindowActive(self: *Ppu, x: u8) bool {
        // Color window settings are in WOBJSEL bits 4-7
        // Bit 4: Window 1 invert for color
        // Bit 5: Window 1 enable for color
        // Bit 6: Window 2 invert for color
        // Bit 7: Window 2 enable for color
        const w1_enable = (self.wobjsel & 0x20) != 0;
        const w1_invert = (self.wobjsel & 0x10) != 0;
        const w2_enable = (self.wobjsel & 0x80) != 0;
        const w2_invert = (self.wobjsel & 0x40) != 0;

        // Color window logic is in WOBJLOG bits 2-3
        const w_log: u2 = @truncate((self.wobjlog >> 2) & 0x03);

        // Calculate window 1 state
        var w1_inside: bool = false;
        if (w1_enable) {
            w1_inside = (x >= self.wh0 and x <= self.wh1);
            if (w1_invert) w1_inside = !w1_inside;
        }

        // Calculate window 2 state
        var w2_inside: bool = false;
        if (w2_enable) {
            w2_inside = (x >= self.wh2 and x <= self.wh3);
            if (w2_invert) w2_inside = !w2_inside;
        }

        // Combine windows based on logic
        var active: bool = false;
        if (w1_enable and w2_enable) {
            active = switch (w_log) {
                0 => w1_inside or w2_inside, // OR
                1 => w1_inside and w2_inside, // AND
                2 => w1_inside != w2_inside, // XOR
                3 => w1_inside == w2_inside, // XNOR
            };
        } else if (w1_enable) {
            active = w1_inside;
        } else if (w2_enable) {
            active = w2_inside;
        }

        return active;
    }

    const SpritePixel = struct {
        color: u16,
        priority: u8,
        palette: u8,
    };

    /// Get sprite sizes based on OBSEL register
    fn getSpriteSizes(self: *Ppu) struct { small: [2]u8, large: [2]u8 } {
        // OBSEL bits 5-7 select size combination
        const size_sel: u3 = @truncate(self.obsel >> 5);
        return switch (size_sel) {
            0 => .{ .small = .{ 8, 8 }, .large = .{ 16, 16 } },
            1 => .{ .small = .{ 8, 8 }, .large = .{ 32, 32 } },
            2 => .{ .small = .{ 8, 8 }, .large = .{ 64, 64 } },
            3 => .{ .small = .{ 16, 16 }, .large = .{ 32, 32 } },
            4 => .{ .small = .{ 16, 16 }, .large = .{ 64, 64 } },
            5 => .{ .small = .{ 32, 32 }, .large = .{ 64, 64 } },
            6 => .{ .small = .{ 16, 32 }, .large = .{ 32, 64 } },
            7 => .{ .small = .{ 16, 32 }, .large = .{ 32, 32 } },
        };
    }

    /// Render sprites for a scanline into a buffer
    fn renderSprites(self: *Ppu, y: u16, sprite_buffer: *[SCREEN_WIDTH]?SpritePixel) void {
        // Clear sprite buffer
        for (sprite_buffer) |*p| {
            p.* = null;
        }

        if ((self.tm & 0x10) == 0) return; // OBJ not enabled on main screen

        const sizes = self.getSpriteSizes();

        // =============================================================================
        // SPRITE CHARACTER BASE ADDRESS CALCULATION
        // =============================================================================
        // Reference: https://snes.nesdev.org/wiki/Registers
        // Reference: fullsnes.txt "$2101 - OBSEL"
        //
        // $2101 - OBSEL - OBJ Size and Character Data Address (W)
        // Register format: SSSNNBBB where:
        //   - BBB (bits 0-2): OBJ name base address
        //   - NN (bits 3-4): OBJ name select (gap between first/second character tables)
        //   - SSS (bits 5-7): OBJ size select
        //
        // Address calculation (from fullsnes):
        //   - First Table:  NameBase * 8K words = BBB << 14 bytes
        //   - Second Table: NameBase * 8K + (NameSelect + 1) * 4K words
        //                 = BBB << 14 + (NN + 1) << 13 bytes
        //
        // The "+1" is critical! Even with NN=0, the second table is offset by 4K words
        // (8KB / 256 tiles) from the first table. This allows sprites to select between
        // two 256-tile banks using the name_select bit in OAM attributes.
        //
        // Example: If OBSEL = 0x62 (bits: 011 00 010):
        //   - BBB = 2, NN = 0, SSS = 3 (16x16/32x32)
        //   - obj_base = 2 << 14 = 0x8000 bytes
        //   - obj_name_gap = (0 + 1) << 13 = 0x2000 bytes = 256 tiles
        //   - First table: tiles 0-255 at 0x8000
        //   - Second table: tiles 0-255 at 0xA000 (selected via name_select bit)
        // =============================================================================
        const obj_base: u32 = @as(u32, self.obsel & 0x07) << 14;
        // Gap between first and second character tables: (NN + 1) * 4K words = (NN + 1) * 8KB
        const obj_name_gap: u32 = (@as(u32, ((self.obsel >> 3) & 0x03)) + 1) << 13;

        // Process sprites in reverse order (sprite 0 has highest priority)
        var sprite_count: u8 = 0;
        var i: i16 = 127;
        while (i >= 0) : (i -= 1) {
            const sprite_idx: u8 = @intCast(i);

            // Read OAM entry (4 bytes per sprite in low table)
            const oam_offset = @as(usize, sprite_idx) * 4;
            const x_lo = self.oam[oam_offset];
            const y_pos = self.oam[oam_offset + 1];
            const tile = self.oam[oam_offset + 2];
            const attr = self.oam[oam_offset + 3];

            // Read high table (2 bits per sprite: x bit 8, size bit)
            const high_byte = self.oam[512 + @as(usize, sprite_idx >> 2)];
            const shift_amt: u3 = @truncate((sprite_idx & 3) * 2);
            const high_bits = (high_byte >> shift_amt) & 0x03;
            const x_hi = (high_bits & 1) != 0;
            const large = (high_bits & 2) != 0;

            // Calculate X position (signed 9-bit)
            var x: i16 = @as(i16, x_lo);
            if (x_hi) x = x - 256;

            // Calculate Y position (wrapped at 256)
            const sprite_y = y_pos;

            // Get sprite size
            const size = if (large) sizes.large else sizes.small;
            const width: i16 = size[0];
            const height: i16 = size[1];

            // Check if sprite is on this scanline
            const py_raw = (@as(i16, @intCast(y)) -% @as(i16, sprite_y)) & 0xFF;
            if (py_raw >= height) continue;

            // Parse attributes
            const palette: u8 = ((attr >> 1) & 0x07) + 8; // Sprites use palettes 8-15
            const priority: u8 = (attr >> 4) & 0x03;
            const h_flip = (attr & 0x40) != 0;
            const v_flip = (attr & 0x80) != 0;
            const name_select = (attr & 0x01) != 0;

            // Calculate tile Y offset (with vertical flip)
            var py: i16 = py_raw;
            if (v_flip) py = height - 1 - py;

            // Get base tile number
            // If name_select is set (OAM attribute bit 0), use the second character table.
            // The gap between tables is determined by OBSEL bits 3-4 (NN) as (NN+1)*4K words.
            // Each tile is 32 bytes (4bpp 8x8), so byte offset / 32 = tile offset.
            var base_tile: u16 = tile;
            if (name_select) {
                // Add the gap in tiles: obj_name_gap bytes / 32 bytes per tile
                base_tile +%= @truncate(obj_name_gap >> 5);
            }

            // Calculate which 8x8 tile row we're in
            const tile_row: u16 = @intCast(@divFloor(py, 8));

            // Render pixels for this sprite
            var px: i16 = 0;
            while (px < width) : (px += 1) {
                const screen_x = x + px;
                if (screen_x < 0 or screen_x >= SCREEN_WIDTH) continue;

                const sx: usize = @intCast(screen_x);

                // Skip if already drawn by higher priority sprite
                if (sprite_buffer[sx] != null) continue;

                // Calculate pixel position within sprite (with horizontal flip)
                var pixel_x = px;
                if (h_flip) pixel_x = width - 1 - pixel_x;

                // Calculate which 8x8 tile column
                const tile_col: u16 = @intCast(@divFloor(pixel_x, 8));

                // Calculate tile number (16 tiles per row in VRAM layout)
                const tile_num = base_tile +% tile_col +% (tile_row * 16);

                // Calculate pixel position within 8x8 tile
                const tile_px: u8 = @intCast(@mod(pixel_x, 8));
                const tile_py: u8 = @intCast(@mod(py, 8));

                // Read tile data (sprites are always 4bpp)
                // Each 4bpp 8x8 tile is 32 bytes
                const tile_addr: u32 = obj_base +% (@as(u32, tile_num) * 32);
                const pixel_color = self.getTilePixel(tile_addr, tile_px, tile_py, 4);

                if (pixel_color == 0) continue; // Transparent

                // Get color from sprite palette (128 + palette*16 + color)
                const color = self.getColor(128 + @as(u8, palette - 8) * 16 + pixel_color);

                sprite_buffer[sx] = .{
                    .color = color,
                    .priority = priority,
                    .palette = palette,
                };

                sprite_count += 1;
                if (sprite_count >= 32 * 8) break; // Max 32 sprites, 34 8-pixel chunks per line
            }
        }
    }

    // ==========================================================================
    // DEBUG FRAME COUNTER OVERLAY
    // ==========================================================================
    // Draws the current frame number in the lower-right corner of the screen.
    // Uses a simple 5x7 pixel bitmap font for digits 0-9.
    // White text (0x7FFF) on black background (0x0000) for easy readability.
    // Only compiled in debug builds (gated by dbg.show_frame_counter).
    // ==========================================================================

    /// 5x7 pixel bitmap font for digits 0-9
    /// Each digit is stored as 7 bytes, one per row, with bits 4-0 representing pixels
    const digit_font = [10][7]u8{
        // 0
        .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        // 1
        .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        // 2
        .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        // 3
        .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 },
        // 4
        .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        // 5
        .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
        // 6
        .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        // 7
        .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        // 8
        .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        // 9
        .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
    };

    /// Draw the frame counter overlay in the lower-right corner
    /// Called at end of each frame when dbg.show_frame_counter is enabled
    fn drawFrameCounter(self: *Ppu) void {
        const white: u16 = 0x7FFF; // 15-bit BGR white
        const black: u16 = 0x0000;

        // Convert frame count to digits
        var digits: [10]u8 = undefined;
        var digit_count: usize = 0;
        var n = self.frame_count;

        // Handle 0 specially
        if (n == 0) {
            digits[0] = 0;
            digit_count = 1;
        } else {
            // Extract digits in reverse order
            while (n > 0 and digit_count < 10) {
                digits[digit_count] = @intCast(n % 10);
                n /= 10;
                digit_count += 1;
            }
        }

        // Each digit is 5 pixels wide + 1 pixel spacing, font is 7 pixels tall
        const char_width: usize = 6; // 5 pixel char + 1 pixel spacing
        const char_height: usize = 7;
        const padding: usize = 2; // Padding around text

        // Calculate total width of text area (including black background padding)
        const text_width = digit_count * char_width + padding * 2;
        const text_height = char_height + padding * 2;

        // Position in lower-right corner
        const start_x = SCREEN_WIDTH - text_width;
        const start_y = SCREEN_HEIGHT - text_height;

        // Draw black background
        for (0..text_height) |dy| {
            const y = start_y + dy;
            if (y >= SCREEN_HEIGHT) continue;
            for (0..text_width) |dx| {
                const x = start_x + dx;
                if (x >= SCREEN_WIDTH) continue;
                self.framebuffer[y * SCREEN_WIDTH + x] = black;
            }
        }

        // Draw digits (in reverse order since we extracted them backwards)
        var i: usize = 0;
        while (i < digit_count) : (i += 1) {
            const digit = digits[digit_count - 1 - i];
            const digit_x = start_x + padding + i * char_width;
            const digit_y = start_y + padding;

            // Draw each row of the digit
            for (0..7) |row| {
                const row_bits = digit_font[digit][row];
                for (0..5) |col| {
                    const bit: u3 = @intCast(4 - col);
                    if ((row_bits >> bit) & 1 != 0) {
                        const x = digit_x + col;
                        const y = digit_y + row;
                        if (x < SCREEN_WIDTH and y < SCREEN_HEIGHT) {
                            self.framebuffer[y * SCREEN_WIDTH + x] = white;
                        }
                    }
                }
            }
        }
    }

    pub fn getFramebuffer(self: *Ppu) []const u16 {
        return &self.framebuffer;
    }

    pub fn readRegister(self: *Ppu, addr: u16) u8 {
        return switch (addr) {
            // PPU multiplier result: m7a (16-bit signed) * m7b high byte
            // (8-bit signed), 24-bit signed result
            0x2134 => @truncate(@as(u32, @bitCast(self.mpy_result))), // MPYL
            0x2135 => @truncate(@as(u32, @bitCast(self.mpy_result)) >> 8), // MPYM
            0x2136 => @truncate(@as(u32, @bitCast(self.mpy_result)) >> 16), // MPYH
            0x2137 => 0, // SLHV - Software latch
            0x2138 => self.readOam(),
            0x2139 => self.readVramLow(),
            0x213A => self.readVramHigh(),
            0x213B => self.readCgram(),
            0x213C => 0, // OPHCT - Horizontal scanline counter
            0x213D => 0, // OPVCT - Vertical scanline counter
            0x213E => 0x01, // STAT77 - PPU1 status
            0x213F => 0x03, // STAT78 - PPU2 status (NTSC, not interlaced)
            else => 0,
        };
    }

    pub fn writeRegister(self: *Ppu, addr: u16, value: u8) void {
        switch (addr) {
            0x2100 => self.inidisp = value,
            0x2101 => self.obsel = value,
            0x2102 => {
                self.oamaddl = value;
                self.oam_addr = (@as(u10, self.oamaddh & 1) << 8) | value;
            },
            0x2103 => {
                self.oamaddh = value;
                self.oam_addr = (@as(u10, value & 1) << 8) | self.oamaddl;
            },
            0x2104 => self.writeOam(value),
            0x2105 => self.bgmode = value,
            0x2106 => self.mosaic = value,
            0x2107 => self.bg1sc = value,
            0x2108 => self.bg2sc = value,
            0x2109 => self.bg3sc = value,
            0x210A => self.bg4sc = value,
            0x210B => self.bg12nba = value,
            0x210C => self.bg34nba = value,
            // BG scroll registers (double-write, first write is low 8 bits, second is high 5 bits)
            // $210D/$210E also feed the Mode 7 scroll registers through the
            // separate Mode 7 latch (13-bit signed values).
            0x210D => {
                self.bg1hofs = (@as(u16, value) << 8) | (self.bg1hofs >> 8);
                self.bg1hofs = (self.bg1hofs & 0xFF00) | self.scroll_latch;
                self.scroll_latch = value;
                self.m7hofs = sign13((@as(u16, value) << 8) | self.m7_latch);
                self.m7_latch = value;
            },
            0x210E => {
                self.bg1vofs = (@as(u16, value) << 8) | (self.bg1vofs >> 8);
                self.bg1vofs = (self.bg1vofs & 0xFF00) | self.scroll_latch;
                self.scroll_latch = value;
                self.m7vofs = sign13((@as(u16, value) << 8) | self.m7_latch);
                self.m7_latch = value;
            },
            0x210F => {
                self.bg2hofs = (@as(u16, value) << 8) | (self.bg2hofs >> 8);
                self.bg2hofs = (self.bg2hofs & 0xFF00) | self.scroll_latch;
                self.scroll_latch = value;
            },
            0x2110 => {
                self.bg2vofs = (@as(u16, value) << 8) | (self.bg2vofs >> 8);
                self.bg2vofs = (self.bg2vofs & 0xFF00) | self.scroll_latch;
                self.scroll_latch = value;
            },
            0x2111 => {
                self.bg3hofs = (@as(u16, value) << 8) | (self.bg3hofs >> 8);
                self.bg3hofs = (self.bg3hofs & 0xFF00) | self.scroll_latch;
                self.scroll_latch = value;
            },
            0x2112 => {
                self.bg3vofs = (@as(u16, value) << 8) | (self.bg3vofs >> 8);
                self.bg3vofs = (self.bg3vofs & 0xFF00) | self.scroll_latch;
                self.scroll_latch = value;
            },
            0x2113 => {
                self.bg4hofs = (@as(u16, value) << 8) | (self.bg4hofs >> 8);
                self.bg4hofs = (self.bg4hofs & 0xFF00) | self.scroll_latch;
                self.scroll_latch = value;
            },
            0x2114 => {
                self.bg4vofs = (@as(u16, value) << 8) | (self.bg4vofs >> 8);
                self.bg4vofs = (self.bg4vofs & 0xFF00) | self.scroll_latch;
                self.scroll_latch = value;
            },
            0x2115 => self.vmain = value,
            0x2116 => {
                self.vmaddl = value;
                self.vram_addr = (@as(u16, self.vmaddh) << 8) | value;
                self.prefetchVram();
            },
            0x2117 => {
                self.vmaddh = value;
                self.vram_addr = (@as(u16, value) << 8) | self.vmaddl;
                self.prefetchVram();
            },
            0x2118 => self.writeVramLow(value),
            0x2119 => self.writeVramHigh(value),
            // Mode 7 registers - all write-twice through m7_latch except M7SEL
            0x211A => self.m7sel = value,
            0x211B => {
                // M7A - full 16-bit signed 8.8 fixed point
                self.m7a = @bitCast((@as(u16, value) << 8) | self.m7_latch);
                self.m7_latch = value;
                // Writing M7A latches the multiplicand for the PPU multiplier
                self.updateMpy(@as(i8, @bitCast(@as(u8, @truncate(@as(u16, @bitCast(self.m7b)) >> 8)))));
            },
            0x211C => {
                self.m7b = @bitCast((@as(u16, value) << 8) | self.m7_latch);
                self.m7_latch = value;
                // The PPU multiplier computes m7a * (signed 8-bit) every time
                // the M7B high byte is written; games read the 24-bit result
                // from MPYL/M/H as a free hardware multiply during Mode 7
                self.updateMpy(@as(i8, @bitCast(value)));
            },
            0x211D => {
                self.m7c = @bitCast((@as(u16, value) << 8) | self.m7_latch);
                self.m7_latch = value;
            },
            0x211E => {
                self.m7d = @bitCast((@as(u16, value) << 8) | self.m7_latch);
                self.m7_latch = value;
            },
            0x211F => {
                self.m7x = sign13((@as(u16, value) << 8) | self.m7_latch);
                self.m7_latch = value;
            },
            0x2120 => {
                self.m7y = sign13((@as(u16, value) << 8) | self.m7_latch);
                self.m7_latch = value;
            },
            0x2121 => {
                self.cgram_addr = @as(u9, value) << 1;
            },
            0x2122 => self.writeCgram(value),
            // Window mask settings
            0x2123 => self.w12sel = value,
            0x2124 => {
                if (comptime dbg.trace_windows) {
                    // Log ALL writes to W34SEL during spotlight frames
                    if (self.frame_count >= 500 and self.frame_count <= 650) {
                        std.debug.print("[W34SEL] = ${x:0>2} at frame {d}\n", .{ value, self.frame_count });
                    }
                }
                self.w34sel = value;
            },
            0x2125 => self.wobjsel = value,
            // Window positions
            0x2126 => self.wh0 = value,
            0x2127 => self.wh1 = value,
            0x2128 => self.wh2 = value,
            0x2129 => self.wh3 = value,
            // Window logic
            0x212A => self.wbglog = value,
            0x212B => self.wobjlog = value,
            // Main/sub screen designation
            0x212C => self.tm = value,
            0x212D => self.ts = value,
            // Window area main/sub screen disable
            0x212E => self.tmw = value,
            0x212F => self.tsw = value,
            // Color math
            0x2130 => self.cgwsel = value,
            0x2131 => self.cgadsub = value,
            0x2132 => {
                // Fixed color data
                const intensity: u16 = @as(u16, value & 0x1F);
                if ((value & 0x20) != 0) self.coldata = (self.coldata & 0x7FE0) | intensity; // Red
                if ((value & 0x40) != 0) self.coldata = (self.coldata & 0x7C1F) | (intensity << 5); // Green
                if ((value & 0x80) != 0) self.coldata = (self.coldata & 0x03FF) | (intensity << 10); // Blue
            },
            else => {},
        }
    }

    fn prefetchVram(self: *Ppu) void {
        const addr: usize = self.getVramAddr();
        self.vram_prefetch = @as(u16, self.vram[addr * 2 + 1]) << 8 | self.vram[addr * 2];
    }

    fn getVramAddr(self: *Ppu) u16 {
        // Apply address remapping based on VMAIN.
        // VRAM is 32K words; the address register is 16 bits but the top bit
        // is ignored (addresses $8000-$FFFF mirror $0000-$7FFF). Masking here
        // also keeps the byte-index math (addr * 2) from overflowing.
        const addr = self.vram_addr & 0x7FFF;
        return switch ((self.vmain >> 2) & 3) {
            0 => addr,
            1 => (addr & 0xFF00) | ((addr & 0x00E0) >> 5) | ((addr & 0x001F) << 3),
            2 => (addr & 0xFE00) | ((addr & 0x01C0) >> 6) | ((addr & 0x003F) << 3),
            3 => (addr & 0xFC00) | ((addr & 0x0380) >> 7) | ((addr & 0x007F) << 3),
            else => addr,
        };
    }

    fn getVramIncrement(self: *Ppu) u16 {
        return switch (self.vmain & 3) {
            0 => 1,
            1 => 32,
            2, 3 => 128,
            else => 1,
        };
    }

    fn readVramLow(self: *Ppu) u8 {
        const result: u8 = @truncate(self.vram_prefetch);
        if ((self.vmain & 0x80) == 0) {
            self.prefetchVram();
            self.vram_addr +%= self.getVramIncrement();
        }
        return result;
    }

    fn readVramHigh(self: *Ppu) u8 {
        const result: u8 = @truncate(self.vram_prefetch >> 8);
        if ((self.vmain & 0x80) != 0) {
            self.prefetchVram();
            self.vram_addr +%= self.getVramIncrement();
        }
        return result;
    }

    fn writeVramLow(self: *Ppu, value: u8) void {
        const addr = self.getVramAddr();
        self.vram[addr * 2] = value;
        if ((self.vmain & 0x80) == 0) {
            self.vram_addr +%= self.getVramIncrement();
        }
    }

    fn writeVramHigh(self: *Ppu, value: u8) void {
        const addr = self.getVramAddr();
        self.vram[addr * 2 + 1] = value;
        if ((self.vmain & 0x80) != 0) {
            self.vram_addr +%= self.getVramIncrement();
        }
    }

    fn readOam(self: *Ppu) u8 {
        const addr = self.oam_addr;
        const result = if (addr < 512)
            self.oam[addr]
        else
            self.oam[512 + (addr & 0x1F)];
        self.oam_addr = (self.oam_addr + 1) & 0x3FF;
        return result;
    }

    fn writeOam(self: *Ppu, value: u8) void {
        const addr = self.oam_addr;
        if (addr < 512) {
            self.oam[addr] = value;
        } else {
            self.oam[512 + (addr & 0x1F)] = value;
        }
        self.oam_addr = (self.oam_addr + 1) & 0x3FF;
    }

    fn readCgram(self: *Ppu) u8 {
        const result = self.cgram[self.cgram_addr];
        self.cgram_addr +%= 1; // Wrapping add, mask implicit since u9
        return result;
    }

    fn writeCgram(self: *Ppu, value: u8) void {
        if ((self.cgram_addr & 1) == 0) {
            self.cgram_latch = value;
        } else {
            self.cgram[self.cgram_addr - 1] = self.cgram_latch;
            self.cgram[self.cgram_addr] = value & 0x7F; // Only 15 bits used
        }
        self.cgram_addr +%= 1; // Wrapping add, mask implicit since u9
    }
};

test "ppu init" {
    const ppu = Ppu.init();
    _ = ppu;
}

test "brightness LUT matches hardware formula" {
    // The LUT must be exactly component * brightness / 15 for every entry,
    // with row 0 all-black and row 15 the identity (those two properties are
    // what lets the render loop drop its special-case branches).
    for (0..16) |b| {
        for (0..32) |c| {
            const expected: u16 = @intCast((c * b) / 15);
            try std.testing.expectEqual(expected, BRIGHTNESS_LUT[b][c]);
        }
    }
    try std.testing.expectEqual(@as(u16, 0), BRIGHTNESS_LUT[0][31]);
    try std.testing.expectEqual(@as(u16, 31), BRIGHTNESS_LUT[15][31]);
}

test "plane spread LUT interleaves bits" {
    // Every input bit n must land at output bit 2n and nowhere else.
    try std.testing.expectEqual(@as(u16, 0x0000), PLANE_SPREAD[0x00]);
    try std.testing.expectEqual(@as(u16, 0x5555), PLANE_SPREAD[0xFF]); // all 8 bits -> even positions
    try std.testing.expectEqual(@as(u16, 0x4000), PLANE_SPREAD[0x80]); // bit 7 -> bit 14
    try std.testing.expectEqual(@as(u16, 0x0001), PLANE_SPREAD[0x01]); // bit 0 -> bit 0
    // Spot-check a mixed pattern: 0b1010_0110 -> bits 7,5,2,1
    try std.testing.expectEqual(@as(u16, 0x4000 | 0x0400 | 0x0010 | 0x0004), PLANE_SPREAD[0xA6]);
}

test "renderBgLine matches renderBgPixel reference" {
    // Property test: the fast line-buffer renderer must agree with the
    // readable per-pixel reference on EVERY pixel, across randomized VRAM
    // contents and register configurations (scroll values, tilemap sizes,
    // 8x8/16x16 tiles, flips, all depths). This is what allows renderBgLine
    // to be optimized aggressively without fear of silent divergence.
    var ppu = Ppu.init();

    // Deterministic xorshift PRNG - tests must be reproducible, and comptime
    // Zig has no ambient randomness anyway.
    var rng: u32 = 0x2F6E2B1;
    const next = struct {
        fn next(state: *u32) u32 {
            state.* ^= state.* << 13;
            state.* ^= state.* >> 17;
            state.* ^= state.* << 5;
            return state.*;
        }
    }.next;

    for (&ppu.vram) |*b| b.* = @truncate(next(&rng));
    for (&ppu.cgram) |*b| b.* = @truncate(next(&rng));

    var line: Ppu.BgLine = undefined;
    var config: u32 = 0;
    while (config < 32) : (config += 1) {
        // Randomize the full layer configuration each round
        ppu.bgmode = @truncate(next(&rng)); // includes 16x16 tile bits
        ppu.bg1sc = @truncate(next(&rng));
        ppu.bg2sc = @truncate(next(&rng));
        ppu.bg3sc = @truncate(next(&rng));
        ppu.bg4sc = @truncate(next(&rng));
        ppu.bg12nba = @truncate(next(&rng));
        ppu.bg34nba = @truncate(next(&rng));
        ppu.bg1hofs = @truncate(next(&rng) & 0x3FF);
        ppu.bg1vofs = @truncate(next(&rng) & 0x3FF);
        ppu.bg2hofs = @truncate(next(&rng) & 0x3FF);
        ppu.bg2vofs = @truncate(next(&rng) & 0x3FF);
        ppu.bg3hofs = @truncate(next(&rng) & 0x3FF);
        ppu.bg3vofs = @truncate(next(&rng) & 0x3FF);
        ppu.bg4hofs = @truncate(next(&rng) & 0x3FF);
        ppu.bg4vofs = @truncate(next(&rng) & 0x3FF);

        const bpps = [3]u8{ 2, 4, 8 };
        const bpp = bpps[next(&rng) % 3];
        const bg: u8 = @intCast(1 + next(&rng) % 4);
        const y: u16 = @intCast(next(&rng) % SCREEN_HEIGHT);

        ppu.renderBgLine(bg, y, bpp, &line);
        for (0..SCREEN_WIDTH) |x| {
            const expected = ppu.renderBgPixel(bg, @intCast(x), y, bpp);
            const got = line.pixel(x);
            if (expected) |e| {
                try std.testing.expect(got != null);
                try std.testing.expectEqual(e.color, got.?.color);
                try std.testing.expectEqual(e.priority, got.?.priority);
            } else {
                try std.testing.expect(got == null);
            }
        }
    }
}

test "getTilePixel decodes planar tiles via spread LUT" {
    // Build one 4bpp tile row by hand and verify every pixel decodes to the
    // same color index the planar format defines. Row 0 planes:
    //   bp0 = 0b10110100  bp1 = 0b01100010  bp2 = 0b00010110  bp3 = 0b10000001
    // Pixel x takes bit (7-x) from each plane; e.g. x=0 -> bp3..bp0 bits
    // 1,0,0,1 -> color 0b1001 = 9.
    var ppu = Ppu.init();
    ppu.vram[0] = 0b10110100; // bp0, row 0
    ppu.vram[1] = 0b01100010; // bp1, row 0
    ppu.vram[16] = 0b00010110; // bp2, row 0
    ppu.vram[17] = 0b10000001; // bp3, row 0

    const expected = [8]u8{ 9, 2, 3, 5, 0, 5, 6, 8 };
    for (0..8) |x| {
        const bit: u3 = @intCast(7 - x);
        // Cross-check the expectation against the definition itself
        const from_planes: u8 = ((ppu.vram[0] >> bit) & 1) |
            ((ppu.vram[1] >> bit) & 1) << 1 |
            ((ppu.vram[16] >> bit) & 1) << 2 |
            ((ppu.vram[17] >> bit) & 1) << 3;
        try std.testing.expectEqual(expected[x], from_planes);
        try std.testing.expectEqual(expected[x], ppu.getTilePixel(0, @intCast(x), 0, 4));
    }

    // 2bpp reads only the first plane pair
    try std.testing.expectEqual(@as(u8, 1), ppu.getTilePixel(0, 0, 0, 2));

    // 8bpp: planes 4-7 for row 0 live at +32/+33 and +48/+49
    ppu.vram[32] = 0b10000000; // bp4: pixel 0 gets bit 4
    ppu.vram[49] = 0b10000000; // bp7: pixel 0 gets bit 7
    try std.testing.expectEqual(@as(u8, 9 | 0x10 | 0x80), ppu.getTilePixel(0, 0, 0, 8));
}
