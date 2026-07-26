const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const sgfx = sokol.gfx;
const saudio = sokol.audio;
const slog = sokol.log;
const build_options = @import("build_options");

const zupernes = @import("zupernes");
const Emulator = zupernes.Emulator;

const DEBUG = build_options.debug_mode;

const SCREEN_WIDTH = 256;
const SCREEN_HEIGHT = 224;
const SCALE = 3;
const WINDOW_WIDTH = SCREEN_WIDTH * SCALE;
const WINDOW_HEIGHT = SCREEN_HEIGHT * SCALE;

const State = struct {
    emulator: Emulator,
    texture: sgfx.Image,
    view: sgfx.View,
    sampler: sgfx.Sampler,
    pipeline: sgfx.Pipeline,
    bindings: sgfx.Bindings,
    pass_action: sgfx.PassAction,
    rom_loaded: bool,

    // Texture buffer for RGBA conversion
    texture_buffer: [SCREEN_WIDTH * SCREEN_HEIGHT * 4]u8,
};

var state: State = undefined;

// ROM data loaded before sokol init - will be loaded into emulator in init()
var pending_rom_data: ?[]const u8 = null;

// ---- recording (round 82 item 1) --------------------------------------------
// `--record OUT.zmov` arms the Emulator's capture-only input recorder from
// power-on; F2 toggles it; the file is written on stop and on quit so a
// session that ends normally never loses its take. Capacity is fixed and
// generous (an hour at 60fps) because the recorder REPORTS truncation rather
// than silently shortening a movie - see Emulator.recordedInputsDropped.
const RECORD_CAPACITY = 60 * 60 * 60;
var record_path: ?[]const u8 = null;
var record_buffer: []u16 = &.{};
var record_armed = false;
var rom_sha256_hex: [64]u8 = undefined;
var rom_sha256_valid = false;
// `--load-state FILE` starts the session from a snapshot instead of power-on.
var load_state_path: ?[]const u8 = null;
var start_state_sha_hex: [64]u8 = undefined;
var start_state_valid = false;

fn hexDigest(bytes: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    _ = std.fmt.bufPrint(out, "{x}", .{digest}) catch unreachable;
}

/// Write whatever has been captured so far to `--record`'s path. Safe to call
/// repeatedly; a truncated capture is reported and still written, because a
/// short movie you know about beats a short movie you do not.
fn writeRecording() void {
    const path = record_path orelse return;
    const frames = state.emulator.recordedInputs();
    if (frames.len == 0) return;
    const allocator = std.heap.page_allocator;
    var m = zupernes.movie.Movie{ .frames = .empty };
    defer m.deinit(allocator);
    m.frames.appendSlice(allocator, frames) catch return;
    if (rom_sha256_valid) m.meta.rom_sha256 = &rom_sha256_hex;
    m.meta.recorded_frames = @intCast(frames.len);
    if (load_state_path) |p| {
        m.meta.start = .savestate;
        m.meta.start_file = p;
        if (start_state_valid) m.meta.start_sha256 = &start_state_sha_hex;
        // start-origin is deliberately NOT invented here: this session was
        // handed a snapshot and does not know how it was reached. Whoever
        // produced it owns that claim, and an unverifiable one is worse than
        // an absent one.
    }
    const text = m.serialize(allocator, null) catch return;
    defer allocator.free(text);
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = text }) catch |err| {
        std.debug.print("record: could not write {s}: {}\n", .{ path, err });
        return;
    };
    const dropped = state.emulator.recordedInputsDropped();
    if (dropped != 0) {
        std.debug.print("record: TRUNCATED - {d} frames past capacity were dropped\n", .{dropped});
    }
    std.debug.print("record: wrote {s} ({d} frames)\n", .{ path, frames.len });
}

export fn init() void {
    sgfx.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = slog.func },
    });

    state.emulator = Emulator.init();
    state.emulator.setup(); // Set up internal pointers now that emulator is in final location
    state.rom_loaded = false;
    state.texture_buffer = [_]u8{0} ** (SCREEN_WIDTH * SCREEN_HEIGHT * 4);

    // Load pending ROM if one was specified on command line
    if (pending_rom_data) |rom_data| {
        state.emulator.loadRom(rom_data) catch |err| {
            std.debug.print("Failed to load ROM: {}\n", .{err});
            return;
        };
        state.rom_loaded = true;
        hexDigest(rom_data, &rom_sha256_hex);
        rom_sha256_valid = true;

        // A savestate start replaces power-on entirely, so it must happen
        // before the first frame is recorded or run.
        if (load_state_path) |path| {
            // The SHARED loader (Emulator.readStateFile), not a second copy:
            // the headless recorder resumes through this exact code.
            const snapshot = state.emulator.readStateFile(
                std.heap.page_allocator,
                path,
                &start_state_sha_hex,
            ) catch |err| {
                std.debug.print("Savestate {s} rejected: {}\n", .{ path, err });
                return;
            };
            std.heap.page_allocator.free(snapshot);
            start_state_valid = true;
            std.debug.print("Resumed from savestate: {s}\n", .{path});
        }

        if (record_path) |path| {
            record_buffer = std.heap.page_allocator.alloc(u16, RECORD_CAPACITY) catch &.{};
            if (record_buffer.len == 0) {
                std.debug.print("record: could not allocate the capture buffer\n", .{});
            } else {
                state.emulator.recordInputs(record_buffer);
                record_armed = true;
                std.debug.print("record: capturing to {s} (F2 stops and writes)\n", .{path});
            }
        }
    }

    // Create texture for framebuffer
    state.texture = sgfx.makeImage(.{
        .width = SCREEN_WIDTH,
        .height = SCREEN_HEIGHT,
        .pixel_format = .RGBA8,
        .usage = .{ .stream_update = true },
    });

    // Create view from texture
    state.view = sgfx.makeView(.{
        .texture = .{ .image = state.texture },
    });

    state.sampler = sgfx.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
    });

    // Create shader and pipeline for fullscreen quad
    const shader = sgfx.makeShader(shaderDesc());

    state.pipeline = sgfx.makePipeline(.{
        .shader = shader,
    });

    state.bindings.views[0] = state.view;
    state.bindings.samplers[0] = state.sampler;

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 },
    };

    // Audio output: the S-DSP produces stereo 16-bit at exactly 32kHz.
    // CoreAudio accepts arbitrary sample rates, so no resampling needed.
    saudio.setup(.{
        .sample_rate = 32000,
        .num_channels = 2,
        .logger = .{ .func = slog.func },
    });
}

var frame_count: u32 = if (DEBUG) 0 else undefined;

export fn frame() void {
    if (state.rom_loaded) {
        // Run one frame of emulation
        state.emulator.runFrame();

        // Debug output every 60 frames (once per second)
        if (comptime DEBUG) {
            frame_count += 1;
            if (frame_count % 60 == 1) {
                const ppu = &state.emulator.ppu;
                const cpu = &state.emulator.cpu;
                std.debug.print("Frame {}: INIDISP=${x:0>2} BGMODE=${x:0>2} TM=${x:0>2} PC=${x:0>4} cycles={} NMITIMEN=${x:0>2}\n", .{
                    frame_count,
                    ppu.inidisp,
                    ppu.bgmode,
                    ppu.tm,
                    cpu.pc,
                    cpu.total_cycles,
                    state.emulator.bus.nmitimen,
                });
            }
        }

        // Push this frame's audio to the sound device. The DSP generates
        // ~533 stereo frames per video frame; convert i16 -> f32 for sokol.
        // saudio.expect() throttles us to what the device buffer can take,
        // so emulation and audio clocks can drift slightly without pops
        // from overfeeding (underruns produce brief silence instead).
        {
            var chunk: [2048][2]i16 = undefined;
            var fbuf: [4096]f32 = undefined;
            var budget = saudio.expect();
            while (budget > 0) {
                const want = @min(@as(usize, @intCast(budget)), chunk.len);
                const n = state.emulator.readAudioSamples(chunk[0..want]);
                if (n == 0) break;
                for (0..n) |s| {
                    fbuf[s * 2 + 0] = @as(f32, @floatFromInt(chunk[s][0])) / 32768.0;
                    fbuf[s * 2 + 1] = @as(f32, @floatFromInt(chunk[s][1])) / 32768.0;
                }
                _ = saudio.push(&fbuf[0], @intCast(n));
                budget -= @intCast(n);
            }
        }

        // Convert framebuffer from 15-bit BGR to RGBA8
        const fb = state.emulator.getFramebuffer();
        for (0..fb.len) |i| {
            const color = fb[i];
            // SNES: -bbbbbgg gggrrrrr (15-bit BGR)
            const r: u8 = @truncate((color & 0x1F) << 3);
            const g: u8 = @truncate(((color >> 5) & 0x1F) << 3);
            const b: u8 = @truncate(((color >> 10) & 0x1F) << 3);
            state.texture_buffer[i * 4 + 0] = r;
            state.texture_buffer[i * 4 + 1] = g;
            state.texture_buffer[i * 4 + 2] = b;
            state.texture_buffer[i * 4 + 3] = 255;
        }

        // Update texture
        var img_data: sgfx.ImageData = .{};
        img_data.mip_levels[0] = .{
            .ptr = &state.texture_buffer,
            .size = state.texture_buffer.len,
        };
        sgfx.updateImage(state.texture, img_data);
    }

    // Render
    sgfx.beginPass(.{
        .action = state.pass_action,
        .swapchain = sokol.glue.swapchain(),
    });

    if (state.rom_loaded) {
        sgfx.applyPipeline(state.pipeline);
        sgfx.applyBindings(state.bindings);
        sgfx.draw(0, 3, 1);
    }

    sgfx.endPass();
    sgfx.commit();
}

export fn cleanup() void {
    // A session that ends normally never loses its take.
    if (record_armed) {
        state.emulator.stopRecording();
        record_armed = false;
        writeRecording();
    }
    saudio.shutdown();
    sgfx.shutdown();
}

// =============================================================================
// KEYBOARD -> SNES CONTROLLER MAPPING
// =============================================================================
// Layout (roughly matching a real pad held in two hands):
//   Arrow keys = D-pad          Enter = Start    Right Shift = Select
//   Z = B (jump)   A = Y (run/carry)   X = A (spin)   S = X
//   Q = L shoulder   W = R shoulder
// Button bit layout matches Emulator.setJoypad ($4219:$4218 order).
// =============================================================================
var joypad_state: u16 = 0;

fn keyToButton(key: sapp.Keycode) u16 {
    return switch (key) {
        .Z => 0x8000, // B
        .A => 0x4000, // Y
        .RIGHT_SHIFT => 0x2000, // Select
        .ENTER => 0x1000, // Start
        .UP => 0x0800,
        .DOWN => 0x0400,
        .LEFT => 0x0200,
        .RIGHT => 0x0100,
        .X => 0x0080, // A
        .S => 0x0040, // X
        .Q => 0x0020, // L
        .W => 0x0010, // R
        else => 0,
    };
}

export fn event(ev: [*c]const sapp.Event) void {
    const e = ev[0];
    switch (e.type) {
        .KEY_DOWN => {
            if (e.key_code == .ESCAPE) {
                sapp.requestQuit();
                return;
            }
            // F2 toggles the capture. Stopping writes immediately so a take
            // survives even if the session later crashes; restarting clears
            // the previous capture, which is why the write happens on stop
            // rather than only at quit.
            if (e.key_code == .F2 and record_path != null and record_buffer.len != 0) {
                if (record_armed) {
                    state.emulator.stopRecording();
                    record_armed = false;
                    writeRecording();
                } else {
                    state.emulator.recordInputs(record_buffer);
                    record_armed = true;
                    std.debug.print("record: capturing (previous take discarded)\n", .{});
                }
                return;
            }
            joypad_state |= keyToButton(e.key_code);
            state.emulator.setJoypad(0, joypad_state);
        },
        .KEY_UP => {
            joypad_state &= ~keyToButton(e.key_code);
            state.emulator.setJoypad(0, joypad_state);
        },
        else => {},
    }
}

fn shaderDesc() sgfx.ShaderDesc {
    var desc: sgfx.ShaderDesc = .{};

    // Metal shaders for macOS
    desc.vertex_func.source =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\
        \\struct vs_out {
        \\    float4 pos [[position]];
        \\    float2 uv;
        \\};
        \\
        \\vertex vs_out vs_main(uint vid [[vertex_id]]) {
        \\    vs_out out;
        \\    out.uv = float2((vid << 1) & 2, vid & 2);
        \\    out.pos = float4(out.uv * 2.0 - 1.0, 0.0, 1.0);
        \\    out.pos.y = -out.pos.y;
        \\    return out;
        \\}
    ;
    desc.vertex_func.entry = "vs_main";

    desc.fragment_func.source =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\
        \\struct fs_in {
        \\    float2 uv;
        \\};
        \\
        \\fragment float4 fs_main(fs_in in [[stage_in]],
        \\                        texture2d<float> tex [[texture(0)]],
        \\                        sampler smp [[sampler(0)]]) {
        \\    return tex.sample(smp, in.uv);
        \\}
    ;
    desc.fragment_func.entry = "fs_main";

    // Set up texture view binding
    desc.views[0] = .{
        .texture = .{
            .stage = .FRAGMENT,
            .image_type = ._2D,
        },
    };

    desc.samplers[0] = .{
        .stage = .FRAGMENT,
        .sampler_type = .FILTERING,
    };

    desc.texture_sampler_pairs[0] = .{
        .stage = .FRAGMENT,
        .view_slot = 0,
        .sampler_slot = 0,
    };

    return desc;
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip(); // Skip program name

    // First positional argument is the ROM; the rest are flags. Kept this
    // simple deliberately - the headless tools own the elaborate CLIs.
    var rom_arg: ?[]const u8 = null;
    var pending: enum { none, record, load_state } = .none;
    while (args.next()) |arg| {
        switch (pending) {
            .record => {
                record_path = arg;
                pending = .none;
                continue;
            },
            .load_state => {
                load_state_path = arg;
                pending = .none;
                continue;
            },
            .none => {},
        }
        if (std.mem.eql(u8, arg, "--record")) {
            pending = .record;
        } else if (std.mem.eql(u8, arg, "--load-state")) {
            pending = .load_state;
        } else if (rom_arg == null) {
            rom_arg = arg;
        } else {
            std.debug.print("Unexpected argument: {s}\n", .{arg});
            return;
        }
    }
    if (pending != .none) {
        std.debug.print("Usage: zupernes <rom.sfc> [--record OUT.zmov] [--load-state FILE]\n", .{});
        return;
    }

    if (rom_arg) |rom_path| {
        // Load ROM file
        const file = std.fs.cwd().openFile(rom_path, .{}) catch |err| {
            std.debug.print("Failed to open ROM: {s}: {}\n", .{ rom_path, err });
            return;
        };
        defer file.close();

        const rom_data = file.readToEndAlloc(std.heap.page_allocator, 16 * 1024 * 1024) catch |err| {
            std.debug.print("Failed to read ROM: {}\n", .{err});
            return;
        };

        // Store ROM data - will be loaded into emulator in init() callback
        pending_rom_data = rom_data;
        std.debug.print("Loaded ROM: {s} ({d} bytes)\n", .{ rom_path, rom_data.len });
    } else {
        std.debug.print("ZuperNES\n", .{});
        std.debug.print("Usage: zupernes <rom.sfc> [--record OUT.zmov] [--load-state FILE]\n", .{});
        std.debug.print("Starting without ROM...\n", .{});
    }

    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = WINDOW_WIDTH,
        .height = WINDOW_HEIGHT,
        .window_title = "ZuperNES",
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
