// =============================================================================
// CARTRIDGE - ROM and SRAM handling
// =============================================================================
// SNES cartridges come in two main board layouts, which determine how the
// ROM chip's linear address space maps onto the CPU's 24-bit bus:
//
// LoROM (Mode $20): ROM is addressed in 32KB chunks. Each CPU bank maps
//   32KB of ROM at $8000-$FFFF; consecutive banks are consecutive chunks.
//   ROM offset = (bank & $7F) * $8000 + (addr & $7FFF)
//   SRAM lives at banks $70-$7D, $0000-$7FFF.
//
// HiROM (Mode $21): ROM is addressed in full 64KB banks. Banks $C0-$FF
//   (and mirror $40-$7D) map the whole 64KB; banks $00-$3F/$80-$BF expose
//   only the upper half ($8000-$FFFF) since the lower half is system space.
//   ROM offset = (bank & $3F) * $10000 + addr
//   SRAM lives at banks $20-$3F (and $A0-$BF), $6000-$7FFF.
//
// The internal header (at ROM offset $7FC0 for LoROM, $FFC0 for HiROM)
// tells us which layout to use - but since we need the layout to find the
// header, detection scores both candidate locations on checksum validity,
// mapping byte, and reset vector sanity, then picks the better one.
//
// Many ROM dumps additionally carry a 512-byte "copier header" (from
// ancient floppy-based backup units) prepended to the data. It's detected
// by the file size being 512 bytes over a multiple of 32KB, and skipped.
// =============================================================================

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

        // Strip 512-byte copier header if present (file size = N*32KB + 512)
        const rom = if (rom_data.len % 0x8000 == 512) rom_data[512..] else rom_data;

        const cart_type = detectCartridgeType(rom);

        // SRAM size from header byte $xFD8: size = 1KB << value (0 = none).
        // Clamp to our 32KB buffer.
        const header_base: usize = if (cart_type == .LoROM) 0x7FC0 else 0xFFC0;
        var sram_size: usize = 0;
        if (rom.len > header_base + 0x18) {
            const sram_shift = rom[header_base + 0x18];
            if (sram_shift != 0 and sram_shift <= 5) {
                sram_size = @as(usize, 0x400) << @intCast(sram_shift);
            }
        }

        return Cartridge{
            .rom = rom,
            .sram = [_]u8{0} ** (32 * 1024),
            .cart_type = cart_type,
            .rom_size = rom.len,
            .sram_size = if (sram_size == 0) 0x2000 else sram_size,
        };
    }

    /// Score a candidate header location for plausibility. Higher = more
    /// likely to be the real header.
    fn scoreHeader(rom_data: []const u8, base: usize, expect_hirom: bool) u32 {
        if (rom_data.len < base + 0x40) return 0;
        var score: u32 = 0;

        // Checksum + complement must sum to $FFFF on a good dump
        const checksum = @as(u16, rom_data[base + 0x1C]) | (@as(u16, rom_data[base + 0x1D]) << 8);
        const complement = @as(u16, rom_data[base + 0x1E]) | (@as(u16, rom_data[base + 0x1F]) << 8);
        if (checksum +% complement == 0xFFFF) {
            score += 8;
        }

        // Mapping mode byte: $20/$30 = LoROM (bit 0 clear), $21/$31 = HiROM
        const map_mode = rom_data[base + 0x15];
        const mode_is_hirom = (map_mode & 0x01) != 0;
        if ((map_mode & 0xE0) == 0x20 and mode_is_hirom == expect_hirom) {
            score += 4;
        }

        // Reset vector (emulation mode, at header+$3C) must point into
        // ROM space $8000-$FFFF - a vector below $8000 can't be ROM code
        const reset = @as(u16, rom_data[base + 0x3C]) | (@as(u16, rom_data[base + 0x3D]) << 8);
        if (reset >= 0x8000) {
            score += 2;
        }

        return score;
    }

    fn detectCartridgeType(rom_data: []const u8) CartridgeType {
        const lorom_score = scoreHeader(rom_data, 0x7FC0, false);
        const hirom_score = scoreHeader(rom_data, 0xFFC0, true);

        if (hirom_score > lorom_score) {
            return .HiROM;
        }
        return .LoROM;
    }

    pub fn read(self: *const Cartridge, bank: u8, addr: u16) u8 {
        var rom_addr = self.mapAddress(bank, addr);
        // Mirror addresses beyond the ROM size. Real cartridges leave upper
        // address lines unconnected, so smaller ROMs repeat throughout the
        // mapped space; games do rely on reading mirrors.
        if (rom_addr >= self.rom.len) {
            rom_addr %= self.rom.len;
        }
        return self.rom[rom_addr];
    }

    pub fn readSram(self: *const Cartridge, bank: u8, addr: u16) u8 {
        const sram_addr = self.mapSramAddress(bank, addr);
        if (self.sram_size == 0) return 0;
        return self.sram[sram_addr % self.sram_size];
    }

    pub fn writeSram(self: *Cartridge, bank: u8, addr: u16, value: u8) void {
        if (self.sram_size == 0) return;
        const sram_addr = self.mapSramAddress(bank, addr);
        self.sram[sram_addr % self.sram_size] = value;
    }

    fn mapSramAddress(self: *const Cartridge, bank: u8, addr: u16) usize {
        return switch (self.cart_type) {
            // LoROM: SRAM at banks $70-$7D, up to 32KB per bank, banks
            // beyond the first mirror or extend (we treat linearly + mirror)
            .LoROM => (@as(usize, bank & 0x0F) << 15) | (addr & 0x7FFF),
            // HiROM: SRAM at banks $20-$3F, $6000-$7FFF (8KB windows,
            // consecutive banks = consecutive 8KB pages)
            .HiROM, .ExHiROM => (@as(usize, bank & 0x1F) << 13) | (addr & 0x1FFF),
        };
    }

    fn mapAddress(self: *const Cartridge, bank: u8, addr: u16) usize {
        return switch (self.cart_type) {
            .LoROM => mapLoROM(bank, addr),
            .HiROM => mapHiROM(bank, addr),
            .ExHiROM => mapHiROM(bank, addr), // Simplified
        };
    }

    fn mapLoROM(bank: u8, addr: u16) usize {
        // LoROM: ROM is mapped in 32KB chunks at $8000-$FFFF
        // Bank bits 0-6 select the 32KB chunk (up to 4MB)
        const rom_bank: usize = bank & 0x7F;
        const offset: usize = addr & 0x7FFF;
        return (rom_bank * 0x8000) + offset;
    }

    fn mapHiROM(bank: u8, addr: u16) usize {
        // HiROM: ROM is mapped in full 64KB banks (bank & $3F covers the
        // $C0-$FF native range and its $40-$7D mirror after the bus has
        // already stripped bit 7)
        const effective_bank = bank & 0x3F;
        return (@as(usize, effective_bank) << 16) | addr;
    }
};

test "cartridge detection" {
    // Minimal test - actual ROM detection would need real ROM data
}
