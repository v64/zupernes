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
    pub const FrameClock = struct {
        /// Actual master clocks billed to the APU during one presented field.
        master_cycles: u32,
        /// Offset of the first CPU->APU port write in that field, if NMI/CPU
        /// service ran.  A null phase means the APU free-ran unserviced.
        command_phase_cycles: ?u32,
    };

    const FrameClockCapture = struct {
        start_master_cycles: u64,
        first_port_write_cycles: ?u64 = null,
    };

    /// Capture-only master-clock cursor.  This is deliberately outside the
    /// portable APU state: a restored anchor owns the hardware's *future*
    /// state, while a capture client uses the cursor only to measure the
    /// elapsed CPU/PPU clock between two frame boundaries.
    master_cycles: u64 = 0,
    frame_clock_capture: ?FrameClockCapture = null,

    /// The SPC700 CPU core
    spc: Spc700,

    /// Cycle counter for synchronization with main CPU
    /// The SPC700 runs at 1.024 MHz off its own crystal; we clock it from
    /// the S-CPU's 21.477 MHz master clock via a fixed-point ratio.
    /// i64 because a single call can deliver a whole DMA burst (a 64KB
    /// transfer is 524288 master cycles - already past what i32 can hold
    /// once shifted into 16.16 fixed point).
    cycle_counter: i64,

    /// Master-clock cycles per SPC700 cycle (fixed-point 16.16).
    /// 21.477 MHz / 1.024 MHz ~= 20.98 master cycles per SPC cycle.
    /// In 16.16 fixed point: 20.98 * 65536 = 1,374,876. (Kept as exactly
    /// 6x the old 3.496-CPU-clocks ratio from when the emulator ticked
    /// subsystems in flat CPU cycles, so the effective APU rate is
    /// unchanged by the master-cycle timing refactor.)
    cycles_per_spc: u32 = 1374876,

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
        if (self.frame_clock_capture) |*capture| {
            if (capture.first_port_write_cycles == null)
                capture.first_port_write_cycles = self.master_cycles;
        }
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
        self.master_cycles += master_cycles;
        // Add master cycles to counter (in 16.16 fixed point)
        self.cycle_counter += @as(i64, master_cycles) << 16;

        // Execute SPC700 instructions while we have cycles
        while (self.cycle_counter >= @as(i64, self.cycles_per_spc)) {
            const spc_cycles = self.step();
            self.cycle_counter -= @as(i64, spc_cycles) * self.cycles_per_spc;

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

    /// Begin a non-invasive timing sample around an emulator frame.  The
    /// ordinary APU state and port semantics are untouched; only a diagnostic
    /// cursor observes when the CPU first serviced an APU port.
    pub fn beginFrameClockCapture(self: *Apu) void {
        std.debug.assert(self.frame_clock_capture == null);
        self.frame_clock_capture = .{ .start_master_cycles = self.master_cycles };
    }

    /// Finish the matching timing sample.  Callers that did not begin one get
    /// null rather than a fabricated fixed-field budget.
    pub fn endFrameClockCapture(self: *Apu) ?FrameClock {
        const capture = self.frame_clock_capture orelse return null;
        self.frame_clock_capture = null;
        return .{
            .master_cycles = @intCast(self.master_cycles - capture.start_master_cycles),
            .command_phase_cycles = if (capture.first_port_write_cycles) |at|
                @intCast(at - capture.start_master_cycles)
            else
                null,
        };
    }

    /// Canonical, pointer-free APU state for deterministic capture anchors.
    /// This is an emulator API, not a host-struct dump: the byte layout is
    /// explicit and portable across native and WebAssembly builds.
    pub const state_len: usize = 65536 + @import("dsp.zig").Dsp.state_len + 59;

    pub fn writeState(self: *const Apu, dst: []u8) usize {
        std.debug.assert(dst.len >= state_len);
        var at: usize = 0;
        @memcpy(dst[at..][0..65536], &self.spc.ram);
        at += 65536;
        dst[at] = self.spc.a;
        dst[at + 1] = self.spc.x;
        dst[at + 2] = self.spc.y;
        dst[at + 3] = self.spc.sp;
        at += 4;
        putU16(dst, &at, self.spc.pc);
        dst[at] = self.spc.psw;
        at += 1;
        @memcpy(dst[at..][0..4], &self.spc.port_in);
        at += 4;
        @memcpy(dst[at..][0..4], &self.spc.port_out);
        at += 4;
        for (self.spc.timer_enable) |enabled| {
            dst[at] = @intFromBool(enabled);
            at += 1;
        }
        @memcpy(dst[at..][0..3], &self.spc.timer_div);
        at += 3;
        @memcpy(dst[at..][0..3], &self.spc.timer_counter);
        at += 3;
        for (self.spc.timer_output) |output| {
            dst[at] = output;
            at += 1;
        }
        for (self.spc.timer_cycles) |cycles| putU16(dst, &at, cycles);
        dst[at] = self.spc.dsp_addr;
        dst[at + 1] = @intFromBool(self.spc.ipl_rom_enabled);
        at += 2;
        putU64(dst, &at, self.spc.cycles);
        putU64(dst, &at, @bitCast(self.cycle_counter));
        putU32(dst, &at, self.cycles_per_spc);
        putU32(dst, &at, self.dsp_timer);
        at += self.spc.dsp.writeState(dst[at..]);
        std.debug.assert(at == state_len);
        return at;
    }

    pub fn readState(self: *Apu, src: []const u8) usize {
        std.debug.assert(src.len >= state_len);
        var at: usize = 0;
        @memcpy(&self.spc.ram, src[at..][0..65536]);
        at += 65536;
        self.spc.a = src[at];
        self.spc.x = src[at + 1];
        self.spc.y = src[at + 2];
        self.spc.sp = src[at + 3];
        at += 4;
        self.spc.pc = getU16(src, &at);
        self.spc.psw = src[at];
        at += 1;
        @memcpy(&self.spc.port_in, src[at..][0..4]);
        at += 4;
        @memcpy(&self.spc.port_out, src[at..][0..4]);
        at += 4;
        for (&self.spc.timer_enable) |*enabled| {
            enabled.* = src[at] != 0;
            at += 1;
        }
        @memcpy(&self.spc.timer_div, src[at..][0..3]);
        at += 3;
        @memcpy(&self.spc.timer_counter, src[at..][0..3]);
        at += 3;
        for (&self.spc.timer_output) |*output| {
            output.* = @truncate(src[at]);
            at += 1;
        }
        for (&self.spc.timer_cycles) |*cycles| cycles.* = getU16(src, &at);
        self.spc.dsp_addr = src[at];
        self.spc.ipl_rom_enabled = src[at + 1] != 0;
        at += 2;
        self.spc.cycles = getU64(src, &at);
        self.cycle_counter = @bitCast(getU64(src, &at));
        self.cycles_per_spc = getU32(src, &at);
        self.dsp_timer = getU32(src, &at);
        at += self.spc.dsp.readState(src[at..]);
        std.debug.assert(at == state_len);
        return at;
    }

    fn putU16(dst: []u8, at: *usize, value: u16) void {
        dst[at.*] = @truncate(value);
        dst[at.* + 1] = @truncate(value >> 8);
        at.* += 2;
    }
    fn getU16(src: []const u8, at: *usize) u16 {
        const value = @as(u16, src[at.*]) | (@as(u16, src[at.* + 1]) << 8);
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
        self.master_cycles = 0;
        self.frame_clock_capture = null;
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

test "audio capture state round-trips continuous PCM" {
    var source = Apu.init();
    source.spc.ipl_rom_enabled = false;
    source.spc.pc = 0x0200;
    source.spc.ram[0x0200] = 0x2F; // BRA -2: stable two-cycle loop
    source.spc.ram[0x0201] = 0xFE;
    source.runCycles(357366);
    var discard: [1024][2]i16 = undefined;
    _ = source.readSamples(&discard);

    var state: [Apu.state_len]u8 = undefined;
    try std.testing.expectEqual(Apu.state_len, source.writeState(&state));
    var restored = Apu.init();
    try std.testing.expectEqual(Apu.state_len, restored.readState(&state));

    source.runCycles(357366);
    restored.runCycles(357366);
    var expected: [1024][2]i16 = undefined;
    var actual: [1024][2]i16 = undefined;
    const expected_n = source.readSamples(&expected);
    const actual_n = restored.readSamples(&actual);
    try std.testing.expectEqual(expected_n, actual_n);
    try std.testing.expectEqualSlices([2]i16, expected[0..expected_n], actual[0..actual_n]);
}

test "capture-only frame clock measures elapsed master clocks and first port service" {
    var apu = Apu.init();
    apu.beginFrameClockCapture();
    apu.runCycles(17);
    apu.writePort(2, 0x06);
    apu.runCycles(31);
    const clock = apu.endFrameClockCapture().?;
    try std.testing.expectEqual(@as(u32, 48), clock.master_cycles);
    try std.testing.expectEqual(@as(?u32, 17), clock.command_phase_cycles);

    apu.beginFrameClockCapture();
    apu.runCycles(9);
    const unserviced = apu.endFrameClockCapture().?;
    try std.testing.expectEqual(@as(u32, 9), unserviced.master_cycles);
    try std.testing.expectEqual(@as(?u32, null), unserviced.command_phase_cycles);
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
