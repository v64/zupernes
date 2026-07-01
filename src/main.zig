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
    // Check for ROM argument
    var args = std.process.args();
    _ = args.skip(); // Skip program name

    if (args.next()) |rom_path| {
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
        std.debug.print("Usage: zupernes <rom.sfc>\n", .{});
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
