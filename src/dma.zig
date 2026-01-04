// DMA Controller - Direct Memory Access for SNES
// Handles both General Purpose DMA (GPDMA) and Horizontal DMA (HDMA)

const std = @import("std");
const dbg = @import("debug.zig");

pub const Dma = struct {
    channels: [8]DmaChannel,

    // Active HDMA channels (set by $420C)
    hdma_enable: u8,

    // HDMA terminated flag per channel
    hdma_terminated: u8,

    pub const DmaChannel = struct {
        // $43x0 - DMAPx: DMA Control
        control: DmaControl,

        // $43x1 - BBADx: B-bus address (PPU register)
        b_addr: u8,

        // $43x2-$43x4 - A1Tx: A-bus address (source/dest)
        a_addr: u24,

        // $43x5-$43x6 - DASx: Byte counter (DMA) / Indirect address (HDMA)
        byte_count: u16,

        // $43x7 - DASBx: HDMA indirect bank
        indirect_bank: u8,

        // $43x8-$43x9 - A2Ax: HDMA table address
        hdma_addr: u16,

        // $43xA - NTRLx: HDMA line counter
        line_counter: u8,

        // Internal: whether HDMA uses indirect addressing
        hdma_do_transfer: bool,

        pub fn init() DmaChannel {
            return .{
                .control = .{},
                .b_addr = 0,
                .a_addr = 0,
                .byte_count = 0,
                .indirect_bank = 0,
                .hdma_addr = 0,
                .line_counter = 0,
                .hdma_do_transfer = false,
            };
        }
    };

    pub const DmaControl = packed struct(u8) {
        // =============================================================================
        // DMAPx ($43x0) - DMA/HDMA Parameters
        // =============================================================================
        // Bit layout: da-itppp
        //   ppp (bits 0-2): Transfer pattern select
        //   t   (bit 3):    A-bus address step (0=increment, 1=decrement)
        //   i   (bit 4):    Fixed transfer (DMA) - A-bus address doesn't change
        //   -   (bit 5):    Unused
        //   a   (bit 6):    HDMA addressing mode (0=absolute/table, 1=indirect)
        //   d   (bit 7):    Transfer direction (0=A→B / CPU→PPU, 1=B→A / PPU→CPU)
        //
        // Transfer patterns (ppp):
        //   0: 1 byte,  1 register  (p)
        //   1: 2 bytes, 2 registers (p, p+1)
        //   2: 2 bytes, 1 register  (p, p)
        //   3: 4 bytes, 2 registers (p, p, p+1, p+1)
        //   4: 4 bytes, 4 registers (p, p+1, p+2, p+3)
        //   5: 4 bytes, 2 registers (p, p+1, p, p+1) - same as mode 1 x2
        //   6: 2 bytes, 1 register  (p, p) - same as mode 2
        //   7: 4 bytes, 2 registers (p, p, p+1, p+1) - same as mode 3
        // =============================================================================
        transfer_mode: u3 = 0,

        // A-bus address step: 0=increment, 1=decrement
        a_addr_decrement: bool = false,

        // Fixed transfer mode (DMA only): 0=normal, 1=A-bus address fixed
        a_addr_fixed: bool = false,

        // Unused bit 5
        _unused: bool = false,

        // HDMA indirect mode (HDMA only): 0=absolute table, 1=indirect table
        indirect: bool = false,

        // Transfer direction: 0=A→B (CPU→PPU), 1=B→A (PPU→CPU)
        direction: bool = false,
    };

    pub fn init() Dma {
        var dma = Dma{
            .channels = undefined,
            .hdma_enable = 0,
            .hdma_terminated = 0,
        };
        for (&dma.channels) |*ch| {
            ch.* = DmaChannel.init();
        }
        return dma;
    }

    pub fn reset(self: *Dma) void {
        for (&self.channels) |*ch| {
            ch.* = DmaChannel.init();
        }
        self.hdma_enable = 0;
        self.hdma_terminated = 0;
    }

    /// Read DMA register
    pub fn readRegister(self: *Dma, addr: u16) u8 {
        if (addr < 0x4300 or addr > 0x437F) return 0;

        const channel_num = (addr >> 4) & 0x07;
        const reg = addr & 0x0F;
        const channel = &self.channels[channel_num];

        return switch (reg) {
            0x00 => @bitCast(channel.control),
            0x01 => channel.b_addr,
            0x02 => @truncate(channel.a_addr),
            0x03 => @truncate(channel.a_addr >> 8),
            0x04 => @truncate(channel.a_addr >> 16),
            0x05 => @truncate(channel.byte_count),
            0x06 => @truncate(channel.byte_count >> 8),
            0x07 => channel.indirect_bank,
            0x08 => @truncate(channel.hdma_addr),
            0x09 => @truncate(channel.hdma_addr >> 8),
            0x0A => channel.line_counter,
            else => 0,
        };
    }

    /// Write DMA register
    pub fn writeRegister(self: *Dma, addr: u16, value: u8) void {
        if (addr < 0x4300 or addr > 0x437F) return;

        const channel_num = (addr >> 4) & 0x07;
        const reg = addr & 0x0F;
        const channel = &self.channels[channel_num];

        switch (reg) {
            0x00 => channel.control = @bitCast(value),
            0x01 => channel.b_addr = value,
            0x02 => channel.a_addr = (channel.a_addr & 0xFFFF00) | value,
            0x03 => channel.a_addr = (channel.a_addr & 0xFF00FF) | (@as(u24, value) << 8),
            0x04 => channel.a_addr = (channel.a_addr & 0x00FFFF) | (@as(u24, value) << 16),
            0x05 => channel.byte_count = (channel.byte_count & 0xFF00) | value,
            0x06 => channel.byte_count = (channel.byte_count & 0x00FF) | (@as(u16, value) << 8),
            0x07 => channel.indirect_bank = value,
            0x08 => channel.hdma_addr = (channel.hdma_addr & 0xFF00) | value,
            0x09 => channel.hdma_addr = (channel.hdma_addr & 0x00FF) | (@as(u16, value) << 8),
            0x0A => channel.line_counter = value,
            else => {},
        }
    }

    /// Get transfer unit size for a given transfer mode
    fn getTransferSize(mode: u3) u8 {
        return switch (mode) {
            0 => 1, // 1 byte
            1 => 2, // 2 bytes
            2 => 2, // 2 bytes
            3 => 4, // 4 bytes
            4 => 4, // 4 bytes
            5 => 4, // 4 bytes
            6 => 2, // 2 bytes (same as mode 2)
            7 => 4, // 4 bytes (same as mode 3)
        };
    }

    /// Get B-bus address offset for each byte within transfer unit
    fn getBOffset(mode: u3, byte_index: u8) u8 {
        return switch (mode) {
            0 => 0, // p
            1 => byte_index & 1, // p, p+1
            2 => 0, // p, p
            3 => (byte_index >> 1) & 1, // p, p, p+1, p+1
            4 => byte_index & 3, // p, p+1, p+2, p+3
            5 => byte_index & 1, // p, p+1, p, p+1
            6 => 0, // p, p (same as mode 2)
            7 => (byte_index >> 1) & 1, // p, p, p+1, p+1 (same as mode 3)
        };
    }

    /// Execute DMA transfer - called when $420B is written
    /// Returns the number of cycles consumed
    pub fn runDma(self: *Dma, enable_mask: u8, bus: anytype) u32 {
        var total_cycles: u32 = 0;

        // Process channels in order 0-7
        for (0..8) |i| {
            const channel_bit = @as(u8, 1) << @intCast(i);
            if ((enable_mask & channel_bit) == 0) continue;

            const channel = &self.channels[i];
            const ctrl = channel.control;

            // Debug: trace DMA transfers to VRAM (registers $2118/$2119)
            if (comptime dbg.trace_dma) {
                if (channel.b_addr == 0x18 or channel.b_addr == 0x19) {
                    const vram_addr = bus.ppu.vram_addr;
                    const vmain = bus.ppu.vmain;
                    std.debug.print("[DMA] Ch{d} VRAM transfer: src=${x:0>6} dst=VRAM[${x:0>4}] size={d} mode={d} vmain=${x:0>2}\n", .{
                        i,
                        channel.a_addr,
                        vram_addr,
                        if (channel.byte_count == 0) @as(u32, 65536) else channel.byte_count,
                        ctrl.transfer_mode,
                        vmain,
                    });
                }
            }

            // Count bytes to transfer (0 = 65536)
            var remaining: u32 = if (channel.byte_count == 0) 65536 else channel.byte_count;
            const transfer_size = getTransferSize(ctrl.transfer_mode);

            // Base B-bus address (PPU register at $21xx)
            const b_base: u16 = 0x2100 | @as(u16, channel.b_addr);

            var byte_index: u8 = 0;

            while (remaining > 0) : (remaining -= 1) {
                const b_offset = getBOffset(ctrl.transfer_mode, byte_index);
                const b_addr = b_base + b_offset;

                if (!ctrl.direction) {
                    // A→B: Read from A-bus (CPU memory), write to B-bus (PPU)
                    const value = bus.readDma(channel.a_addr);
                    bus.writePpuDma(b_addr, value);
                } else {
                    // B→A: Read from B-bus (PPU), write to A-bus (CPU memory)
                    const value = bus.readPpuDma(b_addr);
                    bus.writeDma(channel.a_addr, value);
                }

                // Update A-bus address
                if (!ctrl.a_addr_decrement) {
                    channel.a_addr +%= 1;
                } else {
                    channel.a_addr -%= 1;
                }

                byte_index = (byte_index + 1) % transfer_size;
                total_cycles += 8; // 8 master cycles per byte
            }

            // Update byte count (wraps to 0)
            channel.byte_count = 0;
        }

        return total_cycles;
    }

    /// Initialize HDMA at start of frame (scanline 0)
    /// HDMA (H-Blank DMA) transfers data to PPU registers at the start of each scanline
    /// Used for effects like gradient backgrounds, window shaping (spotlight), IRQ timing, etc.
    pub fn initHdma(self: *Dma, bus: anytype) void {
        if (comptime dbg.trace_hdma) {
            if (self.hdma_enable != 0) {
                std.debug.print("[HDMA] Init frame - channels enabled: ${x:0>2}\n", .{self.hdma_enable});
            }
        }

        self.hdma_terminated = 0;

        for (0..8) |i| {
            const channel_bit = @as(u8, 1) << @intCast(i);
            if ((self.hdma_enable & channel_bit) == 0) continue;

            const channel = &self.channels[i];
            const bank: u8 = @truncate(channel.a_addr >> 16);

            // Load table address from A-bus address
            channel.hdma_addr = @truncate(channel.a_addr);

            // Read line counter from table
            channel.line_counter = bus.read(bank, channel.hdma_addr);
            channel.hdma_addr +%= 1;

            if (comptime dbg.trace_hdma) {
                std.debug.print("[HDMA] Ch{d} init: table=${x:0>2}:{x:0>4}, line_count=${x:0>2}, b_addr=${x:0>2}, mode={d}\n", .{
                    i,
                    bank,
                    @as(u16, @truncate(channel.a_addr)),
                    channel.line_counter,
                    channel.b_addr,
                    channel.control.transfer_mode,
                });
            }

            // Check for termination (line counter = 0)
            if (channel.line_counter == 0) {
                self.hdma_terminated |= channel_bit;
                continue;
            }

            channel.hdma_do_transfer = true;

            // Load indirect address if using indirect mode
            if (channel.control.indirect) {
                const lo = bus.read(bank, channel.hdma_addr);
                channel.hdma_addr +%= 1;
                const hi = bus.read(bank, channel.hdma_addr);
                channel.hdma_addr +%= 1;
                channel.byte_count = (@as(u16, hi) << 8) | lo;

                if (comptime dbg.trace_hdma) {
                    std.debug.print("[HDMA] Ch{d} indirect addr: ${x:0>2}:{x:0>4}\n", .{ i, channel.indirect_bank, channel.byte_count });
                }
            }
        }
    }

    /// Run HDMA at start of each scanline (H-blank)
    /// Called once per visible scanline (0-224) when hdma_enable is non-zero
    pub fn runHdma(self: *Dma, bus: anytype) void {
        for (0..8) |i| {
            const channel_bit = @as(u8, 1) << @intCast(i);
            if ((self.hdma_enable & channel_bit) == 0) continue;
            if ((self.hdma_terminated & channel_bit) != 0) continue;

            const channel = &self.channels[i];
            const ctrl = channel.control;
            const bank: u8 = @truncate(channel.a_addr >> 16);

            // Transfer data if flag is set
            if (channel.hdma_do_transfer) {
                const transfer_size = getTransferSize(ctrl.transfer_mode);
                const b_base: u16 = 0x2100 | @as(u16, channel.b_addr);

                // Debug: trace all HDMA transfers to window registers
                if (comptime dbg.trace_hdma) {
                    if (channel.b_addr == 0x26) {
                        std.debug.print("[HDMA] Ch{d} transfer to WH0/WH1, indirect={}, indirect_bank=${x:0>2}, byte_count=${x:0>4}, hdma_addr=${x:0>4}\n", .{ i, ctrl.indirect, channel.indirect_bank, channel.byte_count, channel.hdma_addr });
                    }
                }

                for (0..transfer_size) |byte_idx| {
                    const b_offset = getBOffset(ctrl.transfer_mode, @intCast(byte_idx));
                    const b_addr = b_base + b_offset;

                    var src_addr: u16 = undefined;
                    var src_bank: u8 = undefined;

                    if (ctrl.indirect) {
                        src_addr = channel.byte_count;
                        src_bank = channel.indirect_bank;
                        channel.byte_count +%= 1;
                    } else {
                        src_addr = channel.hdma_addr;
                        src_bank = bank;
                        channel.hdma_addr +%= 1;
                    }

                    if (!ctrl.direction) {
                        const value = bus.read(src_bank, src_addr);
                        bus.writePpuDma(b_addr, value);

                        // Trace window register writes (WH0-WH3: $2126-$2129) which are used for spotlight effect
                        if (comptime dbg.trace_hdma) {
                            if (b_addr >= 0x2126 and b_addr <= 0x2129) {
                                std.debug.print("[HDMA] Ch{d} write ${x:0>4}=${x:0>2} (WH{d}) from ${x:0>2}:{x:0>4}\n", .{ i, b_addr, value, b_addr - 0x2126, src_bank, src_addr });
                            }
                        }
                    } else {
                        const value = bus.readPpuDma(b_addr);
                        bus.write(src_bank, src_addr, value);
                    }
                }
            }

            // Decrement line counter
            // IMPORTANT: Preserve the repeat bit (bit 7) while decrementing!
            // The repeat bit determines if HDMA transfers every scanline in this block.
            // Without preserving it, HDMA only transfers once at the start of each block,
            // breaking effects like the SMW title screen spotlight which needs per-scanline updates.
            const repeat_bit = channel.line_counter & 0x80;
            const new_count = ((channel.line_counter & 0x7F) -% 1) & 0x7F;
            channel.line_counter = repeat_bit | new_count;

            // Check if we need to reload
            if ((channel.line_counter & 0x7F) == 0) {
                // Read next line counter
                channel.line_counter = bus.read(bank, channel.hdma_addr);
                channel.hdma_addr +%= 1;

                // Check for termination
                if (channel.line_counter == 0) {
                    self.hdma_terminated |= channel_bit;
                    continue;
                }

                channel.hdma_do_transfer = true;

                // Reload indirect address if needed
                if (ctrl.indirect) {
                    const lo = bus.read(bank, channel.hdma_addr);
                    channel.hdma_addr +%= 1;
                    const hi = bus.read(bank, channel.hdma_addr);
                    channel.hdma_addr +%= 1;
                    channel.byte_count = (@as(u16, hi) << 8) | lo;
                }
            } else {
                // Transfer on next line only if repeat flag (bit 7) is set
                channel.hdma_do_transfer = (channel.line_counter & 0x80) != 0;
            }
        }
    }
};

test "dma init" {
    const dma = Dma.init();
    for (dma.channels) |ch| {
        const ctrl: u8 = @bitCast(ch.control);
        try @import("std").testing.expectEqual(@as(u8, 0), ctrl);
    }
}

test "dma register access" {
    var dma = Dma.init();

    // Write control register for channel 0
    dma.writeRegister(0x4300, 0x01);
    try @import("std").testing.expectEqual(@as(u8, 0x01), dma.readRegister(0x4300));

    // Write B-bus address for channel 2
    dma.writeRegister(0x4321, 0x18); // VRAM data register
    try @import("std").testing.expectEqual(@as(u8, 0x18), dma.readRegister(0x4321));

    // Write A-bus address for channel 1
    dma.writeRegister(0x4312, 0x00); // Low
    dma.writeRegister(0x4313, 0x80); // High
    dma.writeRegister(0x4314, 0x7E); // Bank
    try @import("std").testing.expectEqual(@as(u24, 0x7E8000), dma.channels[1].a_addr);
}
