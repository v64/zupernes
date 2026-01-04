// Cartridge - ROM and SRAM handling

pub const CartridgeType = enum {
    LoROM,
    HiROM,
    ExHiROM,
};

pub const Cartridge = struct {
    rom: []const u8,
    sram: [32 * 1024]u8, // 32KB SRAM max for most games
    cart_type: CartridgeType,
    rom_size: usize,
    sram_size: usize,

    pub fn init(rom_data: []const u8) !Cartridge {
        if (rom_data.len < 0x8000) {
            return error.RomTooSmall;
        }

        // Detect cartridge type by checking header locations
        const cart_type = detectCartridgeType(rom_data);

        return Cartridge{
            .rom = rom_data,
            .sram = [_]u8{0} ** (32 * 1024),
            .cart_type = cart_type,
            .rom_size = rom_data.len,
            .sram_size = 0x2000, // Default 8KB
        };
    }

    fn detectCartridgeType(rom_data: []const u8) CartridgeType {
        // Check LoROM header at $7FC0 and HiROM header at $FFC0
        // Look for valid checksum complement

        const lorom_header: usize = 0x7FC0;
        const hirom_header: usize = 0xFFC0;

        var lorom_score: u32 = 0;
        var hirom_score: u32 = 0;

        // Check LoROM
        if (rom_data.len > lorom_header + 0x30) {
            const checksum = @as(u16, rom_data[lorom_header + 0x1C]) | (@as(u16, rom_data[lorom_header + 0x1D]) << 8);
            const complement = @as(u16, rom_data[lorom_header + 0x1E]) | (@as(u16, rom_data[lorom_header + 0x1F]) << 8);
            if (checksum +% complement == 0xFFFF) {
                lorom_score += 10;
            }
            // Check for valid mapping mode byte
            const map_mode = rom_data[lorom_header + 0x15];
            if (map_mode & 0x0F == 0x00 or map_mode & 0x0F == 0x01) {
                lorom_score += 5;
            }
        }

        // Check HiROM
        if (rom_data.len > hirom_header + 0x30) {
            const checksum = @as(u16, rom_data[hirom_header + 0x1C]) | (@as(u16, rom_data[hirom_header + 0x1D]) << 8);
            const complement = @as(u16, rom_data[hirom_header + 0x1E]) | (@as(u16, rom_data[hirom_header + 0x1F]) << 8);
            if (checksum +% complement == 0xFFFF) {
                hirom_score += 10;
            }
            const map_mode = rom_data[hirom_header + 0x15];
            if (map_mode & 0x0F == 0x01) {
                hirom_score += 5;
            }
        }

        if (hirom_score > lorom_score) {
            return .HiROM;
        }
        return .LoROM;
    }

    pub fn read(self: *const Cartridge, bank: u8, addr: u16) u8 {
        const rom_addr = self.mapAddress(bank, addr);
        if (rom_addr < self.rom.len) {
            return self.rom[rom_addr];
        }
        return 0;
    }

    pub fn readSram(self: *const Cartridge, bank: u8, addr: u16) u8 {
        _ = bank;
        const sram_addr = addr & 0x7FFF;
        if (sram_addr < self.sram.len) {
            return self.sram[sram_addr];
        }
        return 0;
    }

    pub fn writeSram(self: *Cartridge, bank: u8, addr: u16, value: u8) void {
        _ = bank;
        const sram_addr = addr & 0x7FFF;
        if (sram_addr < self.sram.len) {
            self.sram[sram_addr] = value;
        }
    }

    fn mapAddress(self: *const Cartridge, bank: u8, addr: u16) usize {
        return switch (self.cart_type) {
            .LoROM => self.mapLoROM(bank, addr),
            .HiROM => self.mapHiROM(bank, addr),
            .ExHiROM => self.mapHiROM(bank, addr), // Simplified
        };
    }

    fn mapLoROM(self: *const Cartridge, bank: u8, addr: u16) usize {
        _ = self;
        // LoROM: ROM is mapped in 32KB chunks at $8000-$FFFF
        // Bank bits 0-5 select the 32KB chunk
        const effective_bank = bank & 0x7F;
        const rom_bank: usize = effective_bank & 0x3F;
        const offset: usize = addr & 0x7FFF;
        return (rom_bank * 0x8000) + offset;
    }

    fn mapHiROM(self: *const Cartridge, bank: u8, addr: u16) usize {
        _ = self;
        // HiROM: ROM is mapped in full 64KB banks
        const effective_bank = bank & 0x3F;
        return (@as(usize, effective_bank) << 16) | addr;
    }
};

test "cartridge detection" {
    // Minimal test - actual ROM detection would need real ROM data
}
