// PPU (Picture Processing Unit) Emulation

pub const SCREEN_WIDTH: usize = 256;
pub const SCREEN_HEIGHT: usize = 224; // Can be 224 or 239 depending on overscan
pub const SCANLINES_PER_FRAME: usize = 262; // NTSC
pub const DOTS_PER_SCANLINE: usize = 340;

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
            .vram_addr = 0,
            .cgram_addr = 0,
            .oam_addr = 0,
            .cgram_latch = 0,
            .vram_prefetch = 0,
            .scanline = 0,
            .dot = 0,
            .frame_count = 0,
            .vram_read_buffer = 0,
        };
    }

    pub fn reset(self: *Ppu) void {
        self.inidisp = 0x80;
        self.scanline = 0;
        self.dot = 0;
        self.vram_addr = 0;
        self.cgram_addr = 0;
        self.oam_addr = 0;
    }

    /// Advance PPU by given number of master clock cycles
    pub fn tick(self: *Ppu, cycles: u32) void {
        var remaining = cycles;
        while (remaining > 0) {
            remaining -= 1;
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
                }
            }
        }
    }

    fn renderScanline(self: *Ppu) void {
        // Check if display is enabled
        if ((self.inidisp & 0x80) != 0) {
            // Force blank - fill with black
            const start = self.scanline * SCREEN_WIDTH;
            for (0..SCREEN_WIDTH) |x| {
                self.framebuffer[start + x] = 0;
            }
            return;
        }

        // Get background mode
        const mode = self.bgmode & 0x07;

        // For now, just render a test pattern based on mode
        const start = self.scanline * SCREEN_WIDTH;
        for (0..SCREEN_WIDTH) |x| {
            // Simple test pattern - will be replaced with actual rendering
            const color: u16 = switch (mode) {
                0 => self.renderMode0Pixel(x, self.scanline),
                1 => self.renderMode1Pixel(x, self.scanline),
                else => @as(u16, @truncate(x)) | (@as(u16, @truncate(self.scanline)) << 5),
            };
            self.framebuffer[start + x] = color;
        }
    }

    fn renderMode0Pixel(self: *Ppu, x: usize, y: u16) u16 {
        _ = self;
        _ = x;
        _ = y;
        // Mode 0: 4 BG layers, 4 colors each
        // TODO: Implement proper Mode 0 rendering
        return 0;
    }

    fn renderMode1Pixel(self: *Ppu, x: usize, y: u16) u16 {
        _ = self;
        _ = x;
        _ = y;
        // Mode 1: 2 BG layers with 16 colors, 1 with 4 colors
        // TODO: Implement proper Mode 1 rendering
        return 0;
    }

    pub fn getFramebuffer(self: *Ppu) []const u16 {
        return &self.framebuffer;
    }

    pub fn readRegister(self: *Ppu, addr: u16) u8 {
        return switch (addr) {
            0x2134 => 0, // MPYL - Multiplication result low
            0x2135 => 0, // MPYM - Multiplication result mid
            0x2136 => 0, // MPYH - Multiplication result high
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
            0x2121 => {
                self.cgram_addr = @as(u9, value) << 1;
            },
            0x2122 => self.writeCgram(value),
            else => {},
        }
    }

    fn prefetchVram(self: *Ppu) void {
        const addr = self.getVramAddr();
        self.vram_prefetch = @as(u16, self.vram[addr * 2 + 1]) << 8 | self.vram[addr * 2];
    }

    fn getVramAddr(self: *Ppu) u16 {
        // Apply address remapping based on VMAIN
        const addr = self.vram_addr;
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
        self.cgram_addr = (self.cgram_addr + 1) & 0x1FF;
        return result;
    }

    fn writeCgram(self: *Ppu, value: u8) void {
        if ((self.cgram_addr & 1) == 0) {
            self.cgram_latch = value;
        } else {
            self.cgram[self.cgram_addr - 1] = self.cgram_latch;
            self.cgram[self.cgram_addr] = value & 0x7F; // Only 15 bits used
        }
        self.cgram_addr = (self.cgram_addr + 1) & 0x1FF;
    }
};

test "ppu init" {
    const ppu = Ppu.init();
    _ = ppu;
}
