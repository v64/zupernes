// ZuperNES browser theater host.
//
// Adapted from ZuperWorld's src/theater/js/main.mjs (commit 954e3f72):
// the NTSC-frame accumulator loop, the keyboard->mask map and focus/blur
// release handling, the AudioBuffer scheduling pattern (32 kHz source
// buffers on a running AudioContext, flushed on every stop path), and the
// WebGPU/2D presenter selection. The session/mod/game machinery of
// ZuperWorld is deliberately NOT carried over - this page runs the real
// ZuperNES core on the user's own cartridges (TASK.md "Reuse appropriate
// host code, not ZuperWorld's game/session/mod machinery").
//
// STRUCTURE
//   session      one loaded cartridge: worker generation, ROM identity
//                (normalized-bytes SHA-256), SRAM clean/dirty tracking
//   persistence  IndexedDB store keyed by romId; restore BEFORE first frame
//   audio        AudioContext at native rate; 32 kHz stereo sources
//   presentation WebGPU CRT (ZuperWorld presenter, copied verbatim) or
//                visible 2D fallback; CRT-off is a true pipeline bypass
//   loop         rAF accumulator at 60.0988 fps, drop-backlog catch-up
//   inputs       KeyboardEvent.code map, release-on-blur/hidden/pause/...

import { createWebGpuPresenter } from "./webgpu-presenter.mjs";

const $ = (id) => document.getElementById(id);
const statusEl = $("status");
const titleEl = $("title");
const fileEl = $("file");
const canvas = $("screen");

const W = 256, H = 224;
const FRAME_MS = 1000 / 60.0988; // NTSC SNES field rate
const KEYMAP = {
  KeyW: 0x0800, KeyS: 0x0400, KeyA: 0x0200, KeyD: 0x0100, // dpad
  KeyK: 0x8000, // B
  KeyJ: 0x4000, // Y
  KeyL: 0x0080, // A
  KeyP: 0x0040, // X
  KeyQ: 0x0020, // L
  KeyE: 0x0010, // R
  KeyO: 0x1000, // Start
  KeyU: 0x2000, // Select
};
// Buttons that must be RE-PRESSED after a release event: a browser may
// auto-repeat a held key; we only accept fresh (non-repeat) keydowns.
let held = 0;
const acceptKeys = { value: true };

const TEST_MODE = new URLSearchParams(location.search).get("test") === "1";

// ---------------------------------------------------------------------------
// status output
// ---------------------------------------------------------------------------
let lastError = null;
function say(text, isError = false) {
  statusEl.textContent = text;
  statusEl.classList.toggle("error", isError);
  if (isError) lastError = String(text);
  else lastError = null;
}
function fail(text) { say("⚠ " + text, true); }

// ---------------------------------------------------------------------------
// worker plumbing
// ---------------------------------------------------------------------------
const worker = new Worker("js/worker.mjs", { type: "module" });
let reqSeq = 0;
const pending = new Map(); // id -> {resolve, reject}
worker.onmessage = (ev) => {
  const m = ev.data;
  if (m.id !== undefined && pending.has(m.id)) {
    const p = pending.get(m.id);
    pending.delete(m.id);
    if (m.type === "error") p.reject(new Error(m.error));
    else p.resolve(m);
  } else if (m.type === "frame") {
    onFrame(m);
  } else if (m.type === "error" && m.crashed) {
    crashWorker(m.error);
  }
};
function call(op, extra = {}) {
  const id = ++reqSeq;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    worker.postMessage({ op, id, ...extra });
  });
}

// ---------------------------------------------------------------------------
// session: exactly one live cartridge. `gen` is the monotonic session id
// (`generation` in state()); every async continuation re-checks it before
// committing anything (says, UI phase flips) so loads that resolve out of
// order cannot revive a discarded session or cross-write saves.
// ---------------------------------------------------------------------------
const session = {
  gen: 0,             // worker-side generation of THIS session (0 = none)
  want: 0,            // latest load attempt ( monotonic by page)
  romId: null,        // normalized SHA-256 hex
  fileName: null,
  bytes: null,        // normalized ROM bytes (header stripped by caller? NO: normalized = raw file with 512-byte copier header stripped)
  sramLen: 0,
  phase: "empty",     // empty | loading | running | paused | error
  frame: 0,
  buttons: 0,
  hasBattery: false,
  sramDirty: false,
  sramShadow: null,   // Uint8Array last persisted
  lastSRamRead: null,
  dead: false,        // replaced by a newer session
};
let presenterMode = "none"; // webgpu | 2d
let crtRequested = localStorage.getItem("zupernes-crt") !== "0";
let crtActive = false;
let audioEnabled = localStorage.getItem("zupernes-sound") !== "0";

function setPhase(p) {
  session.phase = p;
  updatePauseLabel();
}
function updatePauseLabel() {
  $("pause").textContent = session.phase === "running" ? "⏸ Pause" : "▶ Play";
  $("pause").setAttribute("aria-label", session.phase === "running" ? "Pause emulation" : "Resume emulation");
}

// ---------------------------------------------------------------------------
// persistence: IndexedDB, keyed by romId (SHA-256 of NORMALIZED bytes).
// Headered/unheadered variants of the same cartridge share the save;
// different bytes with the same filename do not.
// ---------------------------------------------------------------------------
const DB_NAME = "zupernes-theater", DB_STORE = "saves";
function db() {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open(DB_NAME, 1);
    open.onupgradeneeded = () => open.result.createObjectStore(DB_STORE);
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
}
async function saveGet(romId) {
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction(DB_STORE, "readonly");
    const req = tx.objectStore(DB_STORE).get(romId);
    req.onsuccess = () => resolve(req.result ?? null); // {bytes} or null
    req.onerror = () => reject(req.error);
  });
}
async function savePut(romId, bytes) {
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction(DB_STORE, "readwrite");
    tx.objectStore(DB_STORE).put({ bytes, at: Date.now() }, romId);
    tx.oncomplete = () => resolve(true);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}
async function saveDelete(romId) {
  const d = await db();
  return new Promise((resolve, reject) => {
    const tx = d.transaction(DB_STORE, "readwrite");
    tx.objectStore(DB_STORE).delete(romId);
    tx.oncomplete = () => resolve(true);
    tx.onerror = () => reject(tx.error);
  });
}

// Diagnostics the tests can read: never claim persistence before it lands.
const storageDiag = { lastWrite: null, errors: [] };

// Battery presence is decided from the cartridge header exactly like the
// native frontends (src/main.zig setupBatterySave). Offsets are relative to
// the internal header at 0x7FC0 (LoROM) / 0xFFC0 (HiROM) of the normalized
// (copier-header-stripped) bytes.
function batteryInfo(rom) {
  const hirom = detectType(rom) === "HiROM";
  const h = hirom ? 0xffc0 : 0x7fc0;
  if (rom.length <= h + 0x18) return { hasBattery: false, sramShift: 0 };
  const chip = rom[h + 0x16] & 0x0f;
  const hasBattery = [0x02, 0x05, 0x06, 0x09, 0x0a].includes(chip);
  const sramShift = rom[h + 0x18];
  return { hasBattery, sramShift };
}
function detectType(rom) {
  // Mirror of the core's scoring (src/cartridge.zig scoreHeader), good
  // enough to find the header for battery metadata only - the wasm does the
  // authoritative mapping.
  const score = (base, expectHi) => {
    if (rom.length < base + 0x40) return -1;
    let s = 0;
    const ck = rom[base + 0x1c] | (rom[base + 0x1d] << 8);
    const cc = rom[base + 0x1e] | (rom[base + 0x1f] << 8);
    if ((ck + cc) === 0xffff) s += 8;
    const mapMode = rom[base + 0x15];
    if ((mapMode & 0xe0) === 0x20 && !!(mapMode & 1) === expectHi) s += 4;
    const reset = rom[base + 0x3c] | (rom[base + 0x3d] << 8);
    if (reset >= 0x8000) s += 2;
    return s;
  };
  return score(0x7fc0, false) >= score(0xffc0, true) ? "LoROM" : "HiROM";
}
function normalizeRom(bytes) {
  // 512-byte copier header iff size is N*32KB+512 - identical rule to the
  // core (Cartridge.init). The stripped bytes are the identity: headered and
  // unheadered dumps of one cartridge share a save.
  return bytes.length % 0x8000 === 512 ? bytes.subarray(512) : bytes;
}
async function sha256hex(bytes) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------------------
// ROM loading: transactional, latest-wins.
// ---------------------------------------------------------------------------
async function startLoad(file) {
  const forGen = ++session.want;
  setPhase("loading");
  say(`reading ${file.name}…`);
  let bytes;
  try {
    bytes = new Uint8Array(await file.arrayBuffer());
  } catch (e) {
    fail(`could not read ${file.name}: ${e.message}`);
    revertPhase();
    return;
  }
  // The winning load is decided by `session.want` at every await boundary.
  if (forGen !== session.want || session.dead) { return; }
  const norm = normalizeRom(bytes);
  if (norm.length < 0x8000) {
    fail(`${file.name} is too small for a SNES cartridge (need at least 32 KiB after a 512-byte copier header)`);
    revertPhase();
    return;
  }
  if (norm.length > 16 * 1024 * 1024) {
    fail(`${file.name} is too large (over 16 MiB; not an ordinary LoROM/HiROM cartridge)`);
    revertPhase();
    return;
  }
  const romId = await sha256hex(norm);
  if (forGen !== session.want) return; // a newer selection won meanwhile

  const { hasBattery, sramShift } = batteryInfo(norm);
  let loaded;
  try {
    loaded = await call("load", { bytes: norm });
  } catch (e) {
    if (forGen !== session.want) return; // superseded: swallow
    fail(`${file.name}: ${e.message}`);
    revertPhase();
    return;
  }
  if (forGen !== session.want) return; // our worker machine was replaced later
  // Check against the CURRENT session (not a captured one): the worker
  // assigned the generation synchronously inside `load`.
  if (loaded.generation !== session.gen + 1) {
    // Should not happen: the worker is single-message serialized. Guard anyway.
    return;
  }

  session.gen = loaded.generation;
  session.romId = romId;
  session.fileName = file.name;
  session.bytes = norm;
  session.sramLen = loaded.sramLen;
  session.hasBattery = hasBattery && session.sramLen > 0 && sramShift >= 1 && sramShift <= 5
    ? hasBattery : hasBattery && session.sramLen > 0;
  session.sramDirty = false;
  session.sramShadow = null;
  session.sramBoot = null;
  session.frame = 0;
  session.dead = false;
  session.lastSRamRead = null;
  audio.flush();
  releaseInputs();

  // Restore the battery BEFORE the first frame (TASK.md). A missing,
  // corrupt or wrong-sized save must be VISIBLE but never block play.
  if (session.hasBattery) {
    try {
      const rec = await saveGet(romId);
      if (forGen !== session.want) return;
      if (rec) {
        const saved = new Uint8Array(rec.bytes ?? []);
        if (saved.length === session.sramLen) {
          await call("importSram", { bytes: saved });
          session.sramBoot = saved.slice();
        } else if (saved.length) {
          storageDiag.errors.push(`save size ${saved.length} != ${session.sramLen}; starting fresh`);
          say(`stored save has the wrong size for this cartridge - starting without it`, true);
        }
      }
    } catch (e) {
      storageDiag.errors.push(String(e));
      say(`could not read the stored save (${e.message}) - starting fresh; the game remains playable`, true);
    }
  }

  if (forGen !== session.want) return;
  if (session.hasBattery && !session.sramBoot) {
    // Fresh cartridge: snapshot the $FF boot SRAM so the dirty check has a
    // baseline without writing anything to storage.
    try {
      const m = await call("readSram");
      if (forGen === session.want) session.sramBoot = new Uint8Array(m.bytes);
    } catch {}
  }
  if (forGen !== session.want) return;
  // Pause at the load screen, like boot and reset (TASK.md).
  titleEl.textContent = file.name;
  // The drop zone only belongs on the EMPTY screen: loading a cartridge
  // borrows its space for the start overlay, and it must stop intercepting
  // pointer events so #screen clicks (and Playwright's click on #screen)
  // reach the canvas.
  const dropEl = $("drop");
  dropEl.hidden = true;
  dropEl.style.pointerEvents = "none";
  $("start-overlay").hidden = false;
  setPhase("paused");
  presentNow(); // show frame 0 (the paused boot picture)
  say(`${file.name} loaded - press Play`);
}

function revertPhase() {
  // A failed load leaves the previous game untouched.
  if (session.phase === "loading" && session.gen !== 0) setPhase("paused");
  else if (session.gen === 0) setPhase("empty");
}

function crashWorker(message) {
  setPhase("error");
  fail(`emulation worker crashed (${message}) - reload the page to recover. Your battery saves are safe.`);
}

// ---------------------------------------------------------------------------
// audio: schedule 32 kHz stereo AudioBuffers ahead of a running cursor.
// The DSP emits ~534 frames per emulated frame; we keep the queue below
// 250 ms and flush on pause/hidden/reset/replace/off.
// ---------------------------------------------------------------------------
const audio = {
  ctx: null,
  cursor: 0,
  nodes: [], // live buffers for flush()
  underruns: 0,
  peakQueueMs: 0,
  underrunEvents: 0,
  ensure() {
    if (!this.ctx) this.ctx = new AudioContext({ sampleRate: 32000 });
    return this.ctx;
  },
  queueMs() {
    if (!this.ctx || this.ctx.state !== "running" || !this.cursor) return 0;
    return Math.max(0, (this.cursor - this.ctx.currentTime) * 1000);
  },
  flush() {
    for (const n of this.nodes) { try { n.onended = null; n.stop(); n.disconnect(); } catch {} }
    this.nodes.length = 0;
    this.cursor = 0;
  },
  suspend() {
    this.flush();
    if (this.ctx && this.ctx.state === "running") this.ctx.suspend().catch(() => {});
  },
  resume() {
    this.flush();
    if (this.ctx && this.ctx.state !== "running") this.ctx.resume().catch(() => {});
  },
  push(pcmBuffer) {
    if (!audioEnabled || !this.ctx || this.ctx.state !== "running") return;
    const samples = new Int16Array(pcmBuffer);
    const n = samples.length >> 1;
    if (!n) return;
    const buf = this.ctx.createBuffer(2, n, 32000);
    const L = buf.getChannelData(0), R = buf.getChannelData(1);
    for (let i = 0; i < n; i++) { L[i] = samples[i * 2] / 32768; R[i] = samples[i * 2 + 1] / 32768; }
    const node = this.ctx.createBufferSource();
    node.buffer = buf;
    node.connect(this.ctx.destination);
    node.onended = () => {
      node.disconnect();
      const i = this.nodes.indexOf(node);
      if (i >= 0) this.nodes.splice(i, 1);
    };
    this.nodes.push(node);
    const now = this.ctx.currentTime;
    if (this.cursor < now + 0.02) {
      // Would underflow: start cleanly ahead rather than dump a burst.
      if (this.cursor !== 0) this.underrunEvents++;
      this.cursor = now + 0.05;
    }
    node.start(this.cursor);
    this.cursor += n / 32000;
    const q = this.queueMs();
    if (q > this.peakQueueMs) {
      this.peakQueueMs = q;
      if (q > 250) this.underruns++;
    }
  },
};

// ---------------------------------------------------------------------------
// presentation: WebGPU (CRT/plain via the ZuperWorld presenter) else 2D.
// ---------------------------------------------------------------------------
let gpuPresenter = null;
let mode2d = null;
let deviceLost = false;

// RGB15 -> RGB32 for both backends, exactly the native screenshot tool's
// component << 3 expansion (src/screenshot.zig writePpm).
const rgb15ToRgba8 = (() => {
  const lut = new Uint8Array(32);
  for (let i = 0; i < 32; i++) lut[i] = i << 3;
  return (fbU16, out, w, h) => {
    for (let i = 0; i < w * h; i++) {
      const c = fbU16[i];
      out[i * 4] = lut[c & 31];
      out[i * 4 + 1] = lut[(c >> 5) & 31];
      out[i * 4 + 2] = lut[(c >> 10) & 31];
      out[i * 4 + 3] = 255;
    }
    return out;
  };
})();

let rgbaBuffer = new Uint8ClampedArray(W * H * 4);
function fbToRgba(fb) {
  // fb arrives as a transferred ArrayBuffer of 256*224 LE u16s.
  rgb15ToRgba8(new Uint16Array(fb), rgbaBuffer, W, H);
  return rgbaBuffer;
}

function fitCanvas() {
  // Integer-scale the backing store where possible (ZuperWorld's
  // fitCanvas policy), keeping the whole 256x224 frame visible with no
  // horizontal overflow on narrow layouts (CSS letterboxes the rest).
  if (presenterMode === "webgpu" && gpuPresenter) return; // presenter owns output size
  const dpr = window.devicePixelRatio || 1;
  const cssW = canvas.getBoundingClientRect();
  const availW = Math.max(1, Math.floor((cssW.width || W) * dpr));
  const availH = Math.max(1, Math.floor((cssW.height || H) * dpr));
  let k = Math.max(1, Math.min(Math.floor(availW / W), Math.floor(availH / H)));
  if (k * W > availW || k * H > availH) k = Math.max(1, Math.min(Math.floor(availW / W), Math.floor(availH / H)));
  const w = W * k, h = H * k;
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
    if (mode2d) mode2d.imageSmoothingEnabled = false;
  }
}

async function initPresenter() {
  const requested = new URLSearchParams(location.search).get("presenter");
  if (requested === "2d") return use2d("forced by ?presenter=2d");
  if (!navigator.gpu) return use2d("WebGPU unavailable in this browser");
  try {
    gpuPresenter = await createWebGpuPresenter(canvas);
    gpuPresenter.lost.then((info) => {
      deviceLost = true;
      gpuPresenter?.destroy?.();
      gpuPresenter = null;
      use2d(`WebGPU device lost (${info?.reason ?? "unknown"}) - switched to 2D`);
      if (crtRequested) say("CRT display lost (WebGPU device reset); showing plain 2D", true);
    });
    presenterMode = "webgpu";
    presenterMode && gpuPresenter.configure({ width: W, height: H, outputWidth: W * 4, outputHeight: H * 4, crt: crtRequested && true });
    fitCanvas();
    crtActive = crtRequested;
    if (crtActive) {
      gpuPresenter.configure({ width: W, height: H, outputWidth: canvas.width, outputHeight: canvas.height, crt: true });
    }
    updateCrtLabel();
  } catch (e) {
    gpuPresenter = null;
    use2d(`WebGPU initialization failed (${e.message})`);
  }
}
function use2d(reason) {
  presenterMode = "2d";
  crtActive = false; // 2D fallback has no shader path: report truthfully
  canvas.width = W;
  canvas.height = H;
  mode2d = canvas.getContext("2d", { alpha: false });
  if (mode2d) mode2d.imageSmoothingEnabled = false;
  fitCanvas();
  updateCrtLabel();
  if (reason) console.info("[theater] 2D fallback:", reason);
}
function updateCrtLabel() {
  const btn = $("crt");
  if (presenterMode === "webgpu") {
    btn.textContent = crtRequested ? "🖥 CRT: On" : "🖥 CRT: Off";
    btn.title = "Toggle the CRT scanline/phosphor presentation filter";
    btn.disabled = false;
  } else {
    btn.textContent = "🖥 CRT: Off";
    btn.title = "CRT needs WebGPU; using the 2D canvas fallback";
    btn.disabled = false; // still clickable; keeps 2d and reports honestly
  }
}
// The 2D path renders into an offscreen 256x224 canvas then scales it to
// the output canvas with drawImage (putImageData is always unscaled, so it
// could only ever fill the top-left corner of a larger backing store).
// drawImage with imageSmoothingEnabled=false is the nearest-neighbor
// upscale, matching the plain WebGPU pipeline 1:1.
const offscreen = document.createElement("canvas");
offscreen.width = W;
offscreen.height = H;
const offCtx = offscreen.getContext("2d", { alpha: false });

function presentFrame(fb) {
  const rgba = fbToRgba(fb);
  if (presenterMode === "webgpu" && gpuPresenter) {
    // writeTexture needs exactly W*4 bytesPerRow; rgbaBuffer length matches.
    gpuPresenter.present(new Uint8Array(rgba.buffer, 0, W * H * 4));
    return;
  }
  if (!mode2d) return;
  offCtx.putImageData(new ImageData(rgbaBuffer, W, H), 0, 0);
  mode2d.imageSmoothingEnabled = false;
  mode2d.drawImage(offscreen, 0, 0, W, H, 0, 0, canvas.width, canvas.height);
}
function presentNow() {
  // Repaint the LAST received frame (used at load/pause/reset so the canvas
  // is not blank while the loop is stopped).
  if (!lastFrameRgba || !mode2d) return;
  offCtx.putImageData(new ImageData(lastFrameRgba, W, H), 0, 0);
  mode2d.imageSmoothingEnabled = false;
  mode2d.drawImage(offscreen, 0, 0, W, H, 0, 0, canvas.width, canvas.height);
}
let lastFrameRgba = null;

// ---------------------------------------------------------------------------
// main loop: rAF accumulator at the NTSC cadence, independent of display Hz.
// ---------------------------------------------------------------------------
let acc = 0, last = 0, running = false;
let inFlight = false;
let saveFlushTimer = 0;

// The accumulator subtracts each run's budget instead of clearing, so a
// 33ms rAF tick still buys one emulated frame per elapsed FRAME_MS of wall
// time (an emulator can run ahead of a slow display; here we only ever run
// ONE run in flight, so surplus beyond that is DROPPED as bounded catch-up,
// never replayed as a burst).
function loop(t) {
  requestAnimationFrame(loop);
  if (!running || session.phase !== "running") { last = t; return; }
  acc += Math.min(t - last, 100); // bound catch-up: never replay a backlog
  last = t;
  if (inFlight) return;
  if (acc < FRAME_MS) return;
  acc -= FRAME_MS;
  // Surplus beyond one frame of debt is discarded: a hidden tab's wall-time
  // backlog must never be worked off after becoming visible again.
  if (acc > FRAME_MS) acc = 0;
  const gen = session.gen;
  inFlight = true;
  session.buttons = held;
  call("run", { buttons: held, generation: gen })
    .then((m) => {
      inFlight = false;
      if (m.generation !== session.gen || session.phase !== "running") return; // stale session
      session.frame++;
      if (m.framebuffer) { lastFrameRgba = fbToRgba(m.framebuffer); presentFrame(m.framebuffer); }
      if (m.pcm.byteLength) audio.push(m.pcm);
      scheduleSRamPoll();
    })
    .catch((e) => {
      inFlight = false;
      if (/crashed/.test(e.message)) { crashWorker(e.message); return; }
      fail(`emulation error: ${e.message}`);
    });
}

let sramReadBusy = false;
let sramPollDue = 0;
function scheduleSRamPoll() {
  // At most one dirty-check per second of emulated time; the flush itself
  // happens within a second of a mutation (TASK.md).
  if (!session.hasBattery || session.phase !== "running") return;
  const now = performance.now();
  if (now < sramPollDue || sramReadBusy) return;
  sramPollDue = now + 900;
  sramReadBusy = true;
  const gen = session.gen;
  call("readSram", { generation: gen })
    .then((m) => {
      sramReadBusy = false;
      if (gen !== session.gen) {
        // Session replaced mid-read: DISCARD (do not write a stale save).
        return;
      }
      const bytes = new Uint8Array(m.bytes);
      // Dirty check against the LAST PERSISTED (or restored) snapshot. The
      // snapshot may be null before the first successful write - treat that
      // as "unknown, compare against what the machine booted with" via the
      // session's restore-time snapshot (set by importSram), else cheap
      // fallback: compare against the previous poll.
      const baseline = session.sramShadow ?? session.sramBoot;
      if (!session.sramDirty && !arraysEqual(bytes, baseline)) {
        session.sramDirty = true; // will be flushed by the timer below
      }
      session.lastSRamRead = bytes;
      if (session.sramDirty) queueSRamFlush();
    })
    .catch(() => { sramReadBusy = false; });
}
function arraysEqual(a, b) {
  if (!a || a.length !== b.length) return false;
  for (let i = 0; i < b.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
function queueSRamFlush() {
  if (saveFlushTimer) return;
  saveFlushTimer = setTimeout(async () => {
    saveFlushTimer = 0;
    await flushSave("timer");
  }, 250);
}
async function flushSave(why) {
  if (!session.hasBattery || session.dead || !session.romId) return false;
  const gen = session.gen;
  try {
    const m = await call("readSram", { generation: gen });
    if (gen !== session.gen) return false; // replaced: do not cross-write
    const bytes = new Uint8Array(m.bytes);
    if (session.sramShadow && arraysEqual(bytes, session.sramShadow)) {
      session.sramDirty = false;
      return true; // unchanged: no write
    }
    await savePut(session.romId, bytes);
    if (gen !== session.gen) return false; // replaced DURING the write
    session.sramShadow = bytes.slice();
    session.sramDirty = false;
    storageDiag.lastWrite = { romId: session.romId, why, at: Date.now(), bytes: bytes.length };
    return true;
  } catch (e) {
    storageDiag.errors.push(`save write failed (${e.message})`);
    say(`could not persist the battery save (${e.message}); play continues`, true);
    return false;
  }
}

function startLoop() {
  if (!running) {
    running = true;
    last = performance.now();
    acc = 0;
  }
}

// ---------------------------------------------------------------------------
// input plumbing
// ---------------------------------------------------------------------------
function isEditableTarget(t) {
  if (!t) return false;
  return t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT", "BUTTON"].includes(t.tagName);
}
addEventListener("keydown", (e) => {
  const bit = KEYMAP[e.code];
  if (!bit) return;
  if (e.repeat) { e.preventDefault(); return; } // fresh keydown required
  if (isEditableTarget(e.target) || isEditableTarget(document.activeElement)) {
    // Typing goes to the toolbar, not to the game. Also clear live holds.
    held = 0;
    return;
  }
  e.preventDefault();
  held |= bit;
});
addEventListener("keyup", (e) => {
  const bit = KEYMAP[e.code];
  if (!bit) return;
  e.preventDefault();
  held &= ~bit;
});
function releaseInputs() { held = 0; }
addEventListener("blur", releaseInputs);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    releaseInputs();
    audio.suspend();
    // Hidden pauses: no wall-clock backlog, and it stays paused on return.
    if (session.phase === "running") doPause(true);
  }
});

// ---------------------------------------------------------------------------
// controls
// ---------------------------------------------------------------------------
async function doPlay() {
  if (session.phase !== "paused" || session.dead) return;
  if (audioEnabled) {
    const ctx = audio.ensure();
    if (ctx.state !== "running") {
      try { await ctx.resume(); } catch {}
    }
  }
  setPhase("running");
  $("start-overlay").hidden = true;
  startLoop();
  // Focus the canvas so keyboard play begins naturally (TASK.md).
  canvas.focus({ preventScroll: true });
}
async function doPause(hide) {
  // Flush the save BEFORE the observable phase flip: the test hooks (and
  // anyone polling phase==='paused') treat pause as "persisted"; flipping
  // the phase first would leave a window where a reload races the
  // IndexedDB write. Persistence is claimed only after it has landed.
  if (session.phase === "running") {
    releaseInputs();
    audio.suspend();
    await flushSave("pause");
    setPhase("paused");
  }
  if (!hide) $("start-overlay").hidden = false;
}
async function doReset() {
  if (session.dead || session.gen === 0) return;
  await flushSave("reset"); // preserve any last-second SRAM change
  await call("reset").catch(() => {});
  audio.flush();
  releaseInputs();
  session.frame = 0;
  setPhase("paused");
  $("start-overlay").hidden = false;
  say("cold boot - press Play");
  presentNow();
}
// transactional erase: confirm, clear, cold boot paused
async function doForget() {
  if (session.gen === 0 || session.dead) return;
  const name = session.fileName ?? "this cartridge";
  if (!window.confirm(`Erase the battery save for ${name}? This cannot be undone.`)) return;
  session.sramDirty = false;
  if (session.romId) {
    try { await saveDelete(session.romId); }
    catch (e) {
      fail(`could not erase the stored save (${e.message})`);
      return;
    }
  }
  // Cold boot the SAME ROM with a FRESH machine (default $FF SRAM -
  // zn_reset alone would preserve SRAM, which is the opposite of erasing).
  let loaded;
  try {
    loaded = await call("load", { bytes: session.bytes });
  } catch (e) {
    fail(`could not rebuild the cartridge after erasing (${e.message})`);
    return;
  }
  // The worker's generation moved with the reload; adopt it exactly (never
  // a manual ++, which would desync the mirror by one).
  session.gen = loaded.generation;
  // The dirtiness baseline must reflect the ERASED machine: the new SRAM IS
  // the $FF boot state, and no stale shadow may survive the erase.
  session.sramShadow = null;
  session.sramBoot = null;
  try {
    const m = await call("readSram");
    session.sramBoot = new Uint8Array(m.bytes);
  } catch {}
  audio.flush();
  releaseInputs();
  session.frame = 0;
  setPhase("paused");
  $("start-overlay").hidden = false;
  say("battery save erased - cold boot, press Play");
  presentNow();
}
function toggleSound() {
  audioEnabled = !audioEnabled;
  localStorage.setItem("zupernes-sound", audioEnabled ? "1" : "0");
  $("sound").textContent = audioEnabled ? "🔊 Sound: On" : "🔇 Sound: Off";
  if (audioEnabled) {
    const ctx = audio.ensure();
    if (ctx.state !== "running" && session.phase === "running") ctx.resume().catch(() => {});
  } else {
    audio.suspend();
  }
}
function toggleCrt() {
  crtRequested = !crtRequested;
  localStorage.setItem("zupernes-crt", crtRequested ? "1" : "0");
  if (presenterMode === "webgpu" && gpuPresenter) {
    // CRT toggle is pure presentation: one configure() flips the pipeline.
    gpuPresenter.configure({ width: W, height: H, outputWidth: canvas.width, outputHeight: canvas.height, crt: crtRequested });
    crtActive = crtRequested;
  } else {
    crtActive = false; // 2D fallback: truthfully off
    say("CRT is unavailable without WebGPU; showing the plain picture");
  }
  updateCrtLabel();
}

$("pause").addEventListener("click", () => {
  if (session.phase === "running") doPause();
  else if (session.phase === "paused") doPlay();
});
$("start-session").addEventListener("click", doPlay);
$("reset").addEventListener("click", doReset);
$("forget").addEventListener("click", doForget);
$("sound").addEventListener("click", toggleSound);
$("crt").addEventListener("click", toggleCrt);
$("load").addEventListener("click", () => fileEl.click());
fileEl.addEventListener("change", (e) => {
  const f = e.target.files[0];
  e.target.value = ""; // allow re-selecting the same file
  if (f) startLoad(f);
});

// drag/drop
addEventListener("dragover", (e) => { e.preventDefault(); $("drop")?.classList.add("armed"); });
addEventListener("dragleave", () => $("drop")?.classList.remove("armed"));
addEventListener("drop", (e) => {
  e.preventDefault();
  $("drop")?.classList.remove("armed");
  const f = e.dataTransfer.files && e.dataTransfer.files[0];
  if (f) startLoad(f);
});

// Toolbar focus outlets: entering any control drops live gameplay keys so
// typed keys never leak into the pad (TASK.md).
document.querySelectorAll("#bar button, #bar input").forEach((el) => {
  el.addEventListener("focus", releaseInputs);
});
addEventListener("keydown", (e) => {
  if (e.code === "Space" && document.activeElement === document.body) {
    // Space toggles play/pause when nothing is focused (not while typing).
    e.preventDefault();
    session.phase === "running" ? doPause() : doPlay();
  }
});

window.addEventListener("pagehide", () => { flushSave("pagehide"); });
window.addEventListener("beforeunload", () => { flushSave("unload"); });

// ---------------------------------------------------------------------------
// test hook (?test=1): state() and readWram() backed by REAL worker memory
// ---------------------------------------------------------------------------
if (TEST_MODE) {
  window.__zupernesTest = {
    async state() {
      return {
        phase: session.phase,
        generation: session.gen,
        frame: session.frame,
        romId: session.romId,
        lastError,
        presenter: presenterMode === "webgpu" ? "webgpu" : "2d",
        crtRequested, crtActive,
        audioEnabled,
        audioQueuedSeconds: audio.queueMs() / 1000,
        fileName: session.fileName,
        hasBattery: session.hasBattery,
        sramLen: session.sramLen,
        storageErrors: storageDiag.errors.slice(),
        audioNodes: audio.nodes.length,
        audioUnderruns: audio.underruns + audio.underrunEvents,
        audioPeakQueueMs: Math.round(audio.peakQueueMs),
        deviceLost,
      };
    },
    async readWram(offset, len = 1) {
      const m = await call("readWram", { offset, len });
      return Array.isArray(m.bytes) ? m.bytes : Array.from(m.bytes);
    },
    readSram: async () => {
      const m = await call("readSram");
      return Array.from(m.bytes);
    },
    audio: () => audio, // instrumentation surface for tests
    _flushSave: () => flushSave("test"),
  };
}

// ---------------------------------------------------------------------------
// boot
// ---------------------------------------------------------------------------
requestAnimationFrame(loop);
window.addEventListener("resize", fitCanvas);
(async () => {
  say("starting the emulator core…");
  try {
    await call("boot");
    await initPresenter();
    fitCanvas();
    $("drop").hidden = false;
    say("drop or load a cartridge to begin");
    $("sound").textContent = audioEnabled ? "🔊 Sound: On" : "🔇 Sound: Off";
    updateCrtLabel();
  } catch (e) {
    fail(`could not start (${e.message}) - reload the page`);
    setPhase("error");
  }
})();
