// =============================================================================
// APU - AUDIO PROCESSING UNIT INTERFACE
// =============================================================================
// This module provides the interface between the main 65816 CPU and the SPC700
// audio processor. The APU runs independently from the main CPU, but they
// communicate through 4 bidirectional I/O ports.
//
// HARDWARE OVERVIEW:
// -----------------------------------------------------------------------------
// The SNES APU consists of:
//   - S-SMP: Contains the SPC700 CPU (1.024 MHz, 8-bit)
//   - S-DSP: 8-channel digital signal processor (32 kHz, 16-bit audio)
//   - 64KB PSRAM: Shared between SPC700 and DSP
//   - IPL ROM: 64-byte boot ROM for initial program loading
//
// The APU operates completely asynchronously from the main CPU. Communication
// happens through memory-mapped I/O ports that have separate read/write buffers.
//
// PORT ARCHITECTURE:
// -----------------------------------------------------------------------------
// From the 65816 CPU's perspective (addresses $2140-$2143):
//   - Writing stores to the APU's input buffer
//   - Reading returns from the APU's output buffer
//
// From the SPC700's perspective (addresses $F4-$F7):
//   - Reading returns what the 65816 wrote
//   - Writing sets what the 65816 will read
//
// This bidirectional buffering allows both processors to communicate
// simultaneously without bus conflicts.
//
// TIMING:
// -----------------------------------------------------------------------------
// The SPC700 runs at 1.024 MHz while the main CPU runs at ~3.58 MHz (NTSC).
// For every main CPU master cycle, the SPC700 advances roughly 0.286 cycles.
// Proper emulation requires running the SPC700 in sync with the main CPU.
//
// REFERENCES:
// -----------------------------------------------------------------------------
// - https://wiki.superfamicom.org/spc700-reference
// - https://wiki.superfamicom.org/transferring-data-from-rom-to-the-snes-apu
// - https://www.copetti.org/writings/consoles/super-nintendo/
// =============================================================================

const std = @import("std");
const Spc700 = @import("spc700.zig").Spc700;
const dbg = @import("../debug.zig");

pub const Apu = struct {
    /// The SPC700 CPU core
    spc: Spc700,

    /// Cycle counter for synchronization with main CPU
    /// The SPC700 runs at 1.024 MHz, main CPU at ~3.58 MHz (NTSC)
    /// Ratio: 1.024 / 3.58 ≈ 0.286 SPC cycles per master cycle
    cycle_counter: i32,

    /// Master cycles per SPC700 cycle (fixed-point 16.16)
    /// 3.58 MHz / 1.024 MHz = 3.496 master cycles per SPC cycle
    /// In 16.16 fixed point: 3.496 * 65536 = 229,146
    cycles_per_spc: u32 = 229146,

    /// SPC700 cycles accumulated toward the next DSP sample (one stereo
    /// sample every 32 SPC cycles = 32kHz)
    dsp_timer: u32 = 0,

    pub fn init() Apu {
        return Apu{
            .spc = Spc700.init(),
            .cycle_counter = 0,
        };
    }

    // =========================================================================
    // PORT ACCESS (from main CPU via $2140-$2143)
    // =========================================================================

    /// Read from APU port (called by main CPU reading $2140-$2143)
    /// Returns what the SPC700 has written to its output port
    pub fn readPort(self: *Apu, port: u2) u8 {
        const value = self.spc.port_out[port];
        if (comptime dbg.trace_apu) {
            std.debug.print("[APU] CPU read port {d} = ${x:0>2}\n", .{ port, value });
        }
        return value;
    }

    /// Write to APU port (called by main CPU writing $2140-$2143)
    /// Stores value in the SPC700's input port buffer
    pub fn writePort(self: *Apu, port: u2, value: u8) void {
        self.spc.port_in[port] = value;
        if (comptime dbg.trace_apu) {
            std.debug.print("[APU] CPU write port {d} = ${x:0>2}\n", .{ port, value });
        }
    }

    // =========================================================================
    // SYNCHRONIZATION
    // =========================================================================
    // The APU must be kept in sync with the main CPU. We use a cycle counter
    // that accumulates master cycles, then executes SPC700 instructions when
    // enough cycles have accumulated.

    /// Run the APU for the specified number of master cycles
    /// This should be called after each main CPU instruction
    pub fn runCycles(self: *Apu, master_cycles: u32) void {
        // Add master cycles to counter (in 16.16 fixed point)
        self.cycle_counter += @intCast(master_cycles << 16);

        // Execute SPC700 instructions while we have cycles
        while (self.cycle_counter >= @as(i32, @intCast(self.cycles_per_spc))) {
            const spc_cycles = self.step();
            self.cycle_counter -= @intCast(spc_cycles * self.cycles_per_spc);

            // Clock the S-DSP: it produces one stereo sample every 32
            // SPC700 cycles (1.024 MHz / 32 = 32000 Hz)
            self.dsp_timer += spc_cycles;
            while (self.dsp_timer >= 32) {
                self.dsp_timer -= 32;
                self.spc.dsp.tick(&self.spc.ram);
            }
        }
    }

    /// Drain decoded audio (stereo i16 frames at 32kHz) for the frontend.
    /// Returns the number of frames written into dst.
    pub fn readSamples(self: *Apu, dst: [][2]i16) usize {
        return self.spc.dsp.readSamples(dst);
    }

    /// Execute one SPC700 instruction, returns cycles consumed
    fn step(self: *Apu) u8 {
        return self.spc.step();
    }

    // =========================================================================
    // RESET
    // =========================================================================

    /// Reset the APU to its initial state
    pub fn reset(self: *Apu) void {
        self.spc = Spc700.init();
        self.cycle_counter = 0;
    }
};

// =============================================================================
// TESTS
// =============================================================================

test "apu init" {
    const apu = Apu.init();

    // Ports start at 0 - IPL ROM will write $AA/$BB after RAM clear
    try std.testing.expectEqual(@as(u8, 0), apu.spc.port_out[0]);
    try std.testing.expectEqual(@as(u8, 0), apu.spc.port_out[1]);
}

test "apu port communication" {
    var apu = Apu.init();

    // Write from CPU to APU
    apu.writePort(0, 0x55);
    try std.testing.expectEqual(@as(u8, 0x55), apu.spc.port_in[0]);

    // Read from APU to CPU
    apu.spc.port_out[1] = 0x77;
    try std.testing.expectEqual(@as(u8, 0x77), apu.readPort(1));
}
