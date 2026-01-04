// =============================================================================
// DEBUG CONFIGURATION
// =============================================================================
// Central debug configuration for the emulator. All debug code uses comptime
// checks so disabled features have ZERO runtime cost in release builds.
//
// Usage in other modules:
//   const dbg = @import("debug.zig");
//   if (comptime dbg.trace_cpu) { std.debug.print(...); }
//
// Build with: zig build -Ddebug=true
// =============================================================================

const std = @import("std");
const build_options = @import("build_options");

// Master debug switch - controlled by build system (-Ddebug=true)
// When false, ALL debug code is compiled out
pub const enabled = build_options.debug_mode;

// =============================================================================
// CPU DEBUGGING
// =============================================================================

/// Trace CPU instructions (opcode, registers, flags)
/// When enabled, traces ALL instructions - use with caution, very verbose!
pub const trace_cpu = enabled and true;

// =============================================================================
// APU DEBUGGING
// =============================================================================

/// Trace APU port reads/writes (useful for debugging APU handshake issues)
pub const trace_apu = enabled and true;

/// Print APU read
pub fn apuRead(addr: u16, value: u8, ports: [4]u8) void {
    if (comptime trace_apu) {
        std.debug.print("[APU] Read  ${x:0>4} = ${x:0>2} (ports={any})\n", .{ addr, value, ports });
    }
}

/// Print APU write
pub fn apuWrite(addr: u16, value: u8, echoed: bool) void {
    if (comptime trace_apu) {
        const echo_str = if (echoed) " [ECHO]" else "";
        std.debug.print("[APU] Write ${x:0>4} = ${x:0>2}{s}\n", .{ addr, value, echo_str });
    }
}

// =============================================================================
// DMA DEBUGGING
// =============================================================================

/// Trace DMA transfers
pub const trace_dma = enabled and false;

/// Trace HDMA operations
pub const trace_hdma = enabled and false;

// =============================================================================
// PPU DEBUGGING
// =============================================================================

/// Trace PPU register writes
pub const trace_ppu_regs = enabled and false;

/// Trace PPU rendering (very verbose!)
pub const trace_ppu_render = enabled and false;

// =============================================================================
// MEMORY DEBUGGING
// =============================================================================

/// Trace ROM/SRAM reads
pub const trace_memory = enabled and false;

// =============================================================================
// FRAME DEBUGGING (main.zig uses this)
// =============================================================================

/// Print frame summary every N frames (0 = every frame when enabled)
pub const frame_interval: u32 = 60;

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/// Generic trace print that compiles out when not needed
pub fn trace(comptime category: bool, comptime fmt: []const u8, args: anytype) void {
    if (comptime category) {
        std.debug.print(fmt, args);
    }
}
