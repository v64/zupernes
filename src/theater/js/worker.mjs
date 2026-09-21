// ZuperNES theater worker: owns the single WASM instance.
//
// Protocol (main.mjs <-> worker.mjs): request/response keyed by id. Every
// `run` reply carries its generation (session id); the page drops replies
// whose generation is stale - this is what makes "latest selection wins"
// transactional when loads, resets and failures race.
//
//   -> boot                    instantiate wasm once, report dimensions
//   -> load {bytes}            zn_load_rom clone; new generation
//   -> importSram {bytes}      battery SRAM restore BEFORE the first frame
//   -> reset                   cold boot same ROM, SRAM preserved
//   -> run {buttons}           one frame; reply = framebuffer + PCM
//   -> readSram / readWram     diagnostics for the test hooks
//
// Crash policy: a wasm RuntimeError puts the worker into `crashed`; the
// machine's state is unknown, so every later op fails visibly until the
// page reloads the worker. The page offers that reload.

let wasm = null;
let exports = null;
let romLive = false;
let crashed = false;
let generation = 0;

// zn_alloc/zn_free are LIFO by contract (src/theater/wasm/main.zig): we
// upload, act, free - never two live allocations crossing an allocation.
function withUpload(bytes, fn) {
  const ptr = exports.zn_alloc(bytes.length);
  if (!ptr) throw new Error("zn_alloc failed");
  const view = new Uint8Array(exports.memory.buffer, ptr, bytes.length);
  view.set(bytes);
  try {
    return fn(ptr, view);
  } finally {
    exports.zn_free(ptr, bytes.length);
  }
}

const ZN_ERRORS = {
  1: "no cartridge loaded",
  2: "cartridge rejected by the emulator",
  3: "wasm allocation failure",
  4: "invalid argument to the emulator",
  5: "this cartridge uses a coprocessor (DSP etc.) this browser build cannot support; use an ordinary LoROM/HiROM game",
  6: "unsupported cartridge mapping (ExHiROM-style); only ordinary LoROM and HiROM are supported",
  7: "PAL or unsupported region cartridge; only NTSC games are supported",
  8: "not a recognizable SNES cartridge (no plausible internal header)",
};

function znCheck(status, what) {
  if (status !== 0) {
    throw new Error(`${what}: ${ZN_ERRORS[status] ?? `error ${status}`}`);
  }
}

const TEST_HOOKS = new URLSearchParams(location.search).get("test") === "1";

// One frame's DSP output at 32 kHz is ~534 stereo pairs; 2048 is plenty.
const AUDIO_SCRATCH_FRAMES = 2048;

self.onmessage = async (ev) => {
  const msg = ev.data;
  try {
    if (crashed && msg.op !== "boot") {
      throw new Error("emulation worker crashed; a page reload is required");
    }
    // Test-only crash injection (?test=1): exercises the page's real error
    // plumbing against a worker that dies mid-session.
    if (msg.op === "__crash" && TEST_HOOKS) {
      crashed = true;
      romLive = false;
      throw new Error("injected crash (test)");
    }
    switch (msg.op) {
      case "boot": {
        if (!wasm) {
          // The worker module lives at js/worker.mjs, so the artifact staged at
// src/theater/zupernes.wasm resolves one directory up from this module.
const res = await fetch(new URL("../zupernes.wasm", import.meta.url), { cache: "no-store" });
          if (!res.ok) throw new Error(`wasm fetch failed: ${res.status}`);
          const bytes = new Uint8Array(await res.arrayBuffer());
          if (!(bytes[0] === 0 && bytes[1] === 0x61 && bytes[2] === 0x73 && bytes[3] === 0x6d)) {
            throw new Error("zupernes.wasm is not a WASM module (stale deploy?)");
          }
          const { instance } = await WebAssembly.instantiate(bytes, {});
          wasm = instance;
          exports = instance.exports;
        }
        postMessage({ type: "booted", id: msg.id, width: exports.zn_width(), height: exports.zn_height() });
        return;
      }
      case "load": {
        const bytes = new Uint8Array(msg.bytes);
        // Reject absurd files before they touch the machine. The core's
        // own floor is 32 KB; its native loader caps at 16 MB.
        if (bytes.length < 0x8000) throw new Error("file too small to be a SNES cartridge (need at least 32 KiB)");
        if (bytes.length > 16 * 1024 * 1024 + 512) throw new Error("file too large (over 16 MiB)");
        const wasLive = romLive;
        // withUpload frees the scratch before the machine commits, which is
        // safe: zn_load_rom clones the bytes into its own storage.
        withUpload(bytes, (ptr) => {
          znCheck(exports.zn_load_rom(ptr, bytes.length), "load");
        });
        generation += 1;
        romLive = true;
        // Re-derive views AFTER the load (memory may have grown).
        postMessage({
          type: "loaded", id: msg.id, status: 0, generation,
          sramLen: exports.zn_sram_len(), replacement: wasLive,
        });
        return;
      }
      case "importSram": {
        if (!romLive) throw new Error("no cartridge");
        const bytes = new Uint8Array(msg.bytes);
        const len = exports.zn_sram_len();
        if (bytes.length !== len) throw new Error(`save size ${bytes.length} does not match cartridge (${len})`);
        new Uint8Array(exports.memory.buffer, exports.zn_sram_ptr(), len).set(bytes);
        postMessage({ type: "sramImported", id: msg.id });
        return;
      }
      case "reset": {
        if (!romLive) throw new Error("no cartridge");
        znCheck(exports.zn_reset(), "reset");
        postMessage({ type: "reset", id: msg.id, generation });
        return;
      }
      case "run": {
        if (!romLive) throw new Error("no cartridge");
        znCheck(exports.zn_run_frame(msg.buttons | 0), "run frame");
        // Drain this frame's PCM into a transferable copy. The scratch is
        // zn_alloc'd (LIFO) and freed immediately after the copy.
        const aPtr = exports.zn_alloc(AUDIO_SCRATCH_FRAMES * 4);
        let pcm;
        try {
          const n = exports.zn_read_audio(aPtr, AUDIO_SCRATCH_FRAMES);
          // Copy out while the view is valid (alloc may have grown memory).
          pcm = n > 0
            ? new Int16Array(exports.memory.buffer, aPtr, n * 2).slice().buffer
            : new ArrayBuffer(0);
        } finally {
          exports.zn_free(aPtr, AUDIO_SCRATCH_FRAMES * 4);
        }
        const fb = new Uint8Array(exports.memory.buffer, exports.zn_framebuffer_ptr(), 256 * 224 * 2).slice();
        const wram = new Uint8Array(exports.memory.buffer, exports.zn_wram_ptr(), 128 * 1024);
        // The page's test hook reads the live $1000 window each frame; copy
        // a small head so emulated-pad polling is observable without
        // transferring 128 KB every frame.
        const wramHead = wram.slice(0x1000, 0x1010);
        postMessage({
          type: "frame", id: msg.id, generation,
          framebuffer: fb.buffer, pcm, wramHead: wramHead.buffer,
        }, [fb.buffer, pcm, wramHead.buffer]);
        return;
      }
      case "stats": {
        // Real worker observability for the test hooks: actual WASM
        // committed memory (not a page-side JS heap reading) and the
        // worker/generation counters.
        postMessage({
          type: "stats", id: msg.id,
          wasmBytes: exports.memory.buffer.byteLength,
          generation, romLive, crashed,
        });
        return;
      }
      case "readSram": {
        if (!romLive) throw new Error("no cartridge");
        const len = exports.zn_sram_len();
        const bytes = new Uint8Array(exports.memory.buffer, exports.zn_sram_ptr(), len).slice();
        postMessage({ type: "sram", id: msg.id, bytes });
        return;
      }
      case "readWram": {
        if (!romLive) throw new Error("no cartridge");
        // Bounds per the diagnostic contract: 128 KiB surface.
        const off = Math.max(0, msg.offset | 0);
        const len = Math.min(msg.len | 0, 131072 - off);
        const bytes = new Uint8Array(exports.memory.buffer, exports.zn_wram_ptr() + off, Math.max(0, len)).slice();
        postMessage({ type: "wram", id: msg.id, bytes });
        return;
      }
      default:
        throw new Error(`unknown op ${msg.op}`);
    }
  } catch (err) {
    if (String(err).includes("RuntimeError") || String(err.message).includes("memory access out of bounds")) {
      crashed = true;
      romLive = false;
    }
    postMessage({ type: "error", id: msg.id, error: String((err && err.message) || err), crashed });
  }
};
