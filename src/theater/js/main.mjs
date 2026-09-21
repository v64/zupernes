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
//   loop         NTSC-cadence accumulator; chained runs decouple emulation
//                speed from display refresh (30 Hz rAF still emulates at
//                NTSC speed; 120 Hz never accelerates it)
//   inputs       KeyboardEvent.code map, release-on-blur/hidden/pause/...
//
// LIFECYCLE INVARIANTS (review round 2, enforced across every await):
//   L1  A Stop is immediate and synchronous: phase flips, inputs release
//       and audio stops BEFORE any persistence await. Pending storage I/O
//       can never keep emulation running.
//   L2  Replacing a cartridge flushes the OUTGOING session's SRAM under
//       its own identity BEFORE the worker machine is replaced (A->B->A
//       keeps A's unpaused last-second save).
//   L3  A load is adopted only if it is still the LATEST page-side
//       selection (by request id), no matter how many worker commits or
//       held replies happened in between. The worker's generation number
//       is authoritative and adopted from the reply, never predicted.
//   L4  Worker failures - script error, unserializable message, failed
//       postMessage - reject every pending request, stop playback and put
//       the page in a visible, recoverable error state.
//   L5  Every frame reply is checked for generation AND phase before it
//       may paint, count, or schedule audio (including the eager paint).

import { createWebGpuPresenter } from "./webgpu-presenter.mjs";

const $ = (id) => document.getElementById(id);
const statusEl = $("status");
const titleEl = $("title");
const fileEl = $("file");
// `canvas` may be REPLACED (a canvas that once held a WebGPU context can
// never acquire a 2D one) - it is a `let`, and use2dAfterWebGpu swaps the
// element while preserving id and DOM position.
let canvas = $("screen");

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
// Held pad mask (the $4218/$4219 bit layout). Only fresh (non-repeat)
// keydowns set bits: OS auto-repeat must never re-press a released key.
let held = 0;

const TEST_MODE = new URLSearchParams(location.search).get("test") === "1";

// ---------------------------------------------------------------------------
// status output
// ---------------------------------------------------------------------------
let lastError = null;
// A "sticky notice" survives the final `loaded` say(): storage read
// failures and wrong-size saves must stay visible, not be cleared by the
// success banner of the same load.
let stickyNotice = null;
function say(text, isError = false) {
  statusEl.textContent = text;
  statusEl.classList.toggle("error", isError);
  if (isError) lastError = String(text);
  else lastError = null;
}
function fail(text) { say("⚠ " + text, true); }
function noticeSticky(text) {
  stickyNotice = text;
  say(text, true);
}

// ---------------------------------------------------------------------------
// worker plumbing. onerror/onmessageerror are the REAL failure surfaces:
// a worker script that throws on evaluation never answers `boot`, and the
// pending promise would hang forever without the rejection below.
// ---------------------------------------------------------------------------
const worker = new Worker(`js/worker.mjs${location.search}`, { type: "module" });
let reqSeq = 0;
const pending = new Map(); // id -> {resolve, reject}
let workerBroken = false;

function killWorker(message) {
  if (workerBroken) return;
  workerBroken = true;
  // Reject everything still outstanding so no caller hangs; the loop's
  // catch path turns this into a visible error state.
  const err = new Error(message);
  for (const p of pending.values()) {
    try { p.reject(err); } catch {}
  }
  pending.clear();
  setPhase("error");
  fail(`${message}. Unsaved progress since the last periodic save may be lost - reload the page to recover.`);
}
worker.onerror = (ev) => {
  killWorker(`emulation worker failed (${ev.message || "script error"})`);
};
worker.onmessageerror = () => {
  killWorker("emulation worker received an unserializable message");
};

worker.onmessage = (ev) => {
  const m = ev.data;
  if (m.id !== undefined && pending.has(m.id)) {
    // L5: a frame reply is validated BEFORE it may paint, count, or
    // schedule audio. The frame marker and the painted canvas must read
    // as one instant, but staleness (superseded session, paused machine)
    // disqualifies the frame entirely.
    if (m.type === "frame" &&
        m.generation === session.gen &&
        session.phase === "running" &&
        m.framebuffer) {
      lastFrameBytes = new Uint8Array(m.framebuffer).slice(0).buffer;
      lastFrameRgba = fbToRgba(m.framebuffer.slice(0));
      paintCount++;
      presentFrame(new Uint8Array(lastFrameRgba.buffer.slice(0), 0, W * H * 4));
      framePaintedByMessage = true;
    }
    const p = pending.get(m.id);
    pending.delete(m.id);
    if (m.type === "error") {
      if (m.crashed) crashWorkerState(m.error);
      p.reject(new Error(m.error));
    } else {
      p.resolve(m);
    }
  } else if (m.type === "error" && m.crashed) {
    crashWorkerState(m.error);
  }
};
function call(op, extra = {}) {
  const id = ++reqSeq;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    try {
      worker.postMessage({ op, id, ...extra });
    } catch (e) {
      // A failed postMessage leaves the request unanswered forever:
      // reject it here instead of leaking the pending entry.
      pending.delete(id);
      killWorker(`worker communication failed (${e.message || e})`);
      reject(e);
    }
  });
}

// ---------------------------------------------------------------------------
// session: exactly one live cartridge.
//   want   page-side load sequence (increments on every selection attempt)
//   gen    worker-observed generation of the ADOPTED session (0 = none)
// Adopting a load requires being the LATEST want; the worker's own
// generation (which counts every commit, even intermediate ones the page
// skipped) is taken from the adopted reply, never predicted.
// ---------------------------------------------------------------------------
const session = {
  gen: 0,
  want: 0,
  romId: null,
  fileName: null,
  bytes: null,
  sramLen: 0,
  phase: "empty",     // empty | loading | running | paused | error
  frame: 0,
  buttons: 0,
  hasBattery: false,
  sramDirty: false,
  sramShadow: null,   // Uint8Array last persisted
  sramBoot: null,     // Uint8Array baseline at boot/restore (dirty check)
  dead: false,
};
let presenterMode = "none"; // none | webgpu | 2d
let presenterReady = null;
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

// L1: immediate, synchronous stop. Halts the dispatch loop via the phase,
// releases inputs and stops audio NOW; persistence continues afterwards.
function stopSimulation(nextPhase) {
  stopping = true;
  releaseInputs();
  audio.suspend(); // stops every live node; freezes the cursor
  setPhase(nextPhase);
}

// ---------------------------------------------------------------------------
// persistence: IndexedDB, keyed by romId (SHA-256 of NORMALIZED bytes).
// Connections are closed when their work is done (a long-lived handle
// keeps a version pin and leaks file descriptors in some profiles).
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
  try {
    return await new Promise((resolve, reject) => {
      const tx = d.transaction(DB_STORE, "readonly");
      const req = tx.objectStore(DB_STORE).get(romId);
      req.onsuccess = () => resolve(req.result ?? null); // {bytes} or null
      req.onerror = () => reject(req.error);
    });
  } finally {
    d.close();
  }
}
async function savePut(romId, bytes) {
  const d = await db();
  try {
    return await new Promise((resolve, reject) => {
      const tx = d.transaction(DB_STORE, "readwrite");
      tx.objectStore(DB_STORE).put({ bytes, at: Date.now() }, romId);
      tx.oncomplete = () => resolve(true);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  } finally {
    d.close();
  }
}
async function saveDelete(romId) {
  const d = await db();
  try {
    return await new Promise((resolve, reject) => {
      const tx = d.transaction(DB_STORE, "readwrite");
      tx.objectStore(DB_STORE).delete(romId);
      tx.oncomplete = () => resolve(true);
      tx.onerror = () => reject(tx.error);
    });
  } finally {
    d.close();
  }
}

const storageDiag = { lastWrite: null, errors: [] };

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
  // core (Cartridge.init). The stripped bytes are the identity: headered
  // and unheadered dumps of one cartridge share a save.
  return bytes.length % 0x8000 === 512 ? bytes.subarray(512) : bytes;
}
async function sha256hex(bytes) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------------------
// ROM loading: transactional, latest-wins, with pre-replacement flushing.
// ---------------------------------------------------------------------------
async function startLoad(file) {
  const myLoad = ++session.want;
  // L1: a selection attempt stops the current game immediately; the L2
  // flush below is what makes the stop durable.
  stopSimulation("loading");
  say(`reading ${file.name}…`);
  stickyNotice = null;
  let bytes;
  try {
    bytes = new Uint8Array(await file.arrayBuffer());
  } catch (e) {
    fail(`could not read ${file.name}: ${e.message}`);
    revertPhase();
    return;
  }
  if (myLoad !== session.want || session.dead || workerBroken) return;
  await installSession(file.name, bytes, myLoad);
}

// Shared by the picker/drop path (startLoad) and Erase Save (fresh boot).
// `myLoad` is the page-side load sequence number that must remain the
// latest at every await, or the whole install is abandoned.
// `opts.skipOutgoingFlush` suppresses the L2 pre-replacement SRAM flush -
// used ONLY by Erase Save, which has just deliberately deleted that save.
async function installSession(fileName, rawBytes, myLoad, opts = {}) {
  const stillMine = () => myLoad === session.want && !session.dead && !workerBroken;
  const norm = normalizeRom(rawBytes);
  if (norm.length < 0x8000) {
    fail(`${fileName} is too small for a SNES cartridge (need at least 32 KiB after a 512-byte copier header)`);
    revertPhase();
    return;
  }
  if (norm.length > 16 * 1024 * 1024) {
    fail(`${fileName} is too large (over 16 MiB; not an ordinary LoROM/HiROM cartridge)`);
    revertPhase();
    return;
  }

  // L2: SNAPSHOT AND FLUSH THE OUTGOING SESSION under its own identity,
  // before the worker machine is replaced. This is what keeps A->B->A
  // from losing A's unpaused save: the snapshot is read from A's machine
  // (the worker serializes requests, so this read completes before the
  // load below commits) and written under A's romId, all guarded so a
  // superseded install never writes a stale save.
  const prevRomId = session.romId;
  const prevGen = session.gen;
  const prevHadBattery = session.hasBattery;
  if (!opts.skipOutgoingFlush && prevGen !== 0 && prevRomId && prevHadBattery) {
    try {
      const m = await call("readSram", { generation: prevGen });
      if (prevGen !== session.gen) {
        // The machine was replaced meanwhile: the bytes belong to a
        // session we no longer own. Discard - do NOT write them under
        // prevRomId (they may be B's data by now if an even newer load
        // raced us; the guard keeps identity honest either way).
      } else {
        const snap = new Uint8Array(m.bytes);
        // Replace-time write only when SRAM actually CHANGED since the
        // boot/restore baseline (shadow OR sramBoot). Writing an unmodified
        // $FF boot image here would clobber a stored save (of any shape)
        // that the NEXT session's restore still needs to see.
        const unchanged = (session.sramShadow && arraysEqual(snap, session.sramShadow)) ||
          (session.sramBoot && arraysEqual(snap, session.sramBoot));
        if (!unchanged) {
          await savePut(prevRomId, snap);
          if (prevGen === session.gen) {
            session.sramShadow = snap.slice();
            session.sramDirty = false;
            storageDiag.lastWrite = { romId: prevRomId, why: "replace", at: Date.now(), bytes: snap.length };
          }
        }
      }
    } catch (e) {
      // Visible but not fatal: the new cartridge still loads, and the
      // periodic flush may yet retry for the SAME session.
      storageDiag.errors.push(`save flush on replace failed (${e.message})`);
    }
  }
  if (!stillMine()) return;

  const romId = await sha256hex(norm);
  if (!stillMine()) return; // a newer selection won meanwhile

  const { hasBattery, sramShift } = batteryInfo(norm);
  let loaded;
  try {
    loaded = await call("load", { bytes: norm });
  } catch (e) {
    if (!stillMine()) return; // superseded: swallow
    // The preflight and core rejections explain themselves (DSP, mapping,
    // PAL, unrecognizable dump, size). The previous session is untouched.
    fail(`${fileName}: ${e.message}`);
    revertPhase();
    return;
  }
  // L3: adoption is by LATEST WANT, never by generation arithmetic - the
  // worker may have committed intermediate loads the page skipped. The
  // adopted reply's generation is authoritative.
  if (!stillMine()) return;
  session.gen = loaded.generation;
  session.romId = romId;
  session.fileName = fileName;
  session.bytes = norm;
  session.sramLen = loaded.sramLen;
  session.hasBattery = hasBattery && session.sramLen > 0 && sramShift >= 1 && sramShift <= 5;
  session.sramDirty = false;
  session.sramShadow = null;
  session.sramBoot = null;
  session.frame = 0;
  session.dead = false;
  stopping = false;
  audio.flush();
  releaseInputs();

  // Restore the battery BEFORE the first frame. A missing, corrupt or
  // wrong-sized save stays VISIBLE (sticky) but never blocks play.
  if (session.hasBattery) {
    try {
      const rec = await saveGet(romId);
      if (!stillMine()) return;
      if (rec) {
        const saved = new Uint8Array(rec.bytes ?? []);
        if (saved.length === session.sramLen) {
          await call("importSram", { bytes: saved });
          if (!stillMine()) return;
          session.sramBoot = saved.slice();
        } else if (saved.length) {
          storageDiag.errors.push(`save size ${saved.length} != ${session.sramLen}; starting fresh`);
          noticeSticky(`stored save has the wrong size for this cartridge - starting without it; the game remains playable`);
        }
      }
    } catch (e) {
      storageDiag.errors.push(String(e));
      noticeSticky(`could not read the stored save (${e.message}) - starting fresh; the game remains playable`);
    }
  }

  if (!stillMine()) return;
  if (session.hasBattery && !session.sramBoot) {
    // Fresh cartridge: snapshot the $FF boot SRAM so the dirty check has
    // a baseline without writing anything to storage.
    try {
      const m = await call("readSram");
      if (stillMine()) session.sramBoot = new Uint8Array(m.bytes);
    } catch {}
  }
  if (!stillMine()) return;
  titleEl.textContent = fileName;
  const dropEl = $("drop");
  dropEl.hidden = true;
  dropEl.style.pointerEvents = "none";
  $("start-overlay").hidden = false;
  setPhase("paused");
  presentNow(); // show the paused boot picture
  if (!stickyNotice) say(`${fileName} loaded - press Play`);
}

function revertPhase() {
  // A failed load leaves the previous game untouched.
  if (session.phase === "loading" && session.gen !== 0) setPhase("paused");
  else if (session.gen === 0) setPhase("empty");
}

// A crashed WORKER (wasm trap, protocol error): the machine state is
// unknown and the worker refuses further ops. No unverifiable claims
// about save safety: the LAST PERSISTED save stands, but anything since
// may be lost.
function crashWorkerState(message) {
  setPhase("error");
  fail(`emulation worker crashed (${message}). The last save in storage is safe; progress since then may be lost - reload the page to recover.`);
}

// ---------------------------------------------------------------------------
// audio: schedule 32 kHz stereo AudioBuffers ahead of a running cursor.
// ---------------------------------------------------------------------------
const audio = {
  ctx: null,
  cursor: 0,
  nodes: [],
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
  rgb15ToRgba8(new Uint16Array(fb), rgbaBuffer, W, H);
  return rgbaBuffer;
}

function fitCanvas() {
  if (presenterMode === "webgpu" && gpuPresenter) return; // presenter owns output size
  const dpr = window.devicePixelRatio || 1;
  const cssW = canvas.getBoundingClientRect();
  const availW = Math.max(1, Math.floor((cssW.width || W) * dpr));
  const availH = Math.max(1, Math.floor((cssW.height || H) * dpr));
  let k = Math.max(1, Math.min(Math.floor(availW / W), Math.floor(availH / H)));
  const w = W * k, h = H * k;
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
    if (mode2d) mode2d.imageSmoothingEnabled = false;
  }
}

async function initPresenter() {
  presenterReady = (async () => {
  const requested = new URLSearchParams(location.search).get("presenter");
  if (requested === "2d") return use2d("forced by ?presenter=2d");
  if (!navigator.gpu) return use2d("WebGPU unavailable in this browser");
  try {
    gpuPresenter = await createWebGpuPresenter(canvas);
    gpuPresenter.lost.then((info) => {
      deviceLost = true;
      gpuPresenter?.destroy?.();
      gpuPresenter = null;
      // Real device loss: the presenter is gone AND this canvas can never
      // return a 2D context after holding a WebGPU one. Swap in a FRESH
      // canvas element (same id, same DOM slot) and present the live frame
      // through it, then PROVE it renders (paintCount keeps counting).
      use2dAfterWebGpu(`WebGPU device lost (${info?.reason ?? "unknown"}) - switched to 2D`);
      if (crtRequested) noticeSticky("CRT display lost (WebGPU device reset); showing plain 2D");
    });
    presenterMode = "webgpu";
    fitWebGpuOutput();
    crtActive = crtRequested;
    updateCrtLabel();
  } catch (e) {
    gpuPresenter = null;
    use2d(`WebGPU initialization failed (${e.message})`);
  }
  })();
  return presenterReady;
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
// Replacement for a canvas that held a WebGPU context: create a fresh
// element (a WebGPU canvas can never acquire a 2D context, by spec), swap
// it into the same DOM slot with the same id, and draw the LAST frame
// through a real 2D context so the picture updates again.
function use2dAfterWebGpu(reason) {
  const fresh = document.createElement("canvas");
  fresh.id = canvas.id;
  fresh.setAttribute("aria-label", canvas.getAttribute("aria-label") || "SNES display");
  fresh.width = W;
  fresh.height = H;
  canvas.replaceWith(fresh);
  canvas = fresh;
  presenterMode = "2d";
  crtActive = false;
  mode2d = canvas.getContext("2d", { alpha: false });
  if (mode2d) mode2d.imageSmoothingEnabled = false;
  fitCanvas();
  updateCrtLabel();
  presentNow(); // repaint the current frame onto the fresh canvas
  if (reason) console.info("[theater] 2D fallback (fresh canvas):", reason);
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
const offscreen = document.createElement("canvas");
offscreen.width = W;
offscreen.height = H;
const offCtx = offscreen.getContext("2d", { alpha: false });

let paintCount = 0; // diagnostics: visible in the test hook
function presentFrame(rgba) {
  if (presenterMode === "webgpu" && gpuPresenter) {
    gpuPresenter.present(new Uint8Array(rgba.buffer, rgba.byteOffset, W * H * 4));
    return;
  }
  if (!mode2d) return;
  offCtx.putImageData(new ImageData(new Uint8ClampedArray(rgba.buffer, rgba.byteOffset, W * H * 4), W, H), 0, 0);
  mode2d.imageSmoothingEnabled = false;
  mode2d.drawImage(offscreen, 0, 0, W, H, 0, 0, canvas.width, canvas.height);
}
let lastFrameBytes = null;
function presentNow() {
  if (!lastFrameBytes) return;
  if (presenterMode === "webgpu" && gpuPresenter && lastFrameRgba) {
    gpuPresenter.present(new Uint8Array(lastFrameRgba.buffer, lastFrameRgba.byteOffset, W * H * 4));
    return;
  }
  if (!lastFrameRgba || !mode2d) return;
  offCtx.putImageData(new ImageData(new Uint8ClampedArray(lastFrameRgba.buffer, lastFrameRgba.byteOffset, W * H * 4), W, H), 0, 0);
  mode2d.imageSmoothingEnabled = false;
  mode2d.drawImage(offscreen, 0, 0, W, H, 0, 0, canvas.width, canvas.height);
}
let lastFrameRgba = null;
let framePaintedByMessage = false; // the eager paint consumed this frame's paint

// ---------------------------------------------------------------------------
// main loop. The accumulator subtracts each run's budget; runs CHAIN on
// their replies while budget remains, so emulation speed is decoupled
// from display refresh: a 30 Hz rAF still emulates at (near) NTSC speed -
// two frames per tick - while a 120 Hz display can never add budget faster
// than wall time. Bounded catch-up: the accumulator is clamped at 100 ms
// and a reply chain yields after CHAIN_LIMIT runs (the next rAF resumes
// it), so a backlog can never burst and a hidden tab (which pauses
// outright) never replays wall-clock time.
// ---------------------------------------------------------------------------
const CHAIN_LIMIT = 3;
// `stopping` halts frame dispatch INSTANTLY (before any persistence await)
// while the observable phase still shows 'running' until the save lands:
// no frame may run after the pause click, AND phase==='paused' continues to
// mean 'persisted' (a reload racing the pause cannot lose the save).
let stopping = false;
let acc = 0, last = 0, running = false;
let inFlight = false;
let chainDepth = 0;
let saveFlushTimer = 0;

function loop(t) {
  requestAnimationFrame(loop);
  if (!running || stopping || session.phase !== "running") { last = t; return; }
  acc += Math.min(t - last, 100); // bound catch-up: never replay a backlog
  last = t;
  chainDepth = 0;
  dispatchRun();
}
function dispatchRun() {
  if (inFlight || stopping || session.phase !== "running") return;
  if (acc < FRAME_MS) return;
  acc -= FRAME_MS;
  sendRun();
}
function sendRun() {
  inFlight = true;
  const gen = session.gen;
  call("run", { buttons: held, generation: gen })
    .then((m) => {
      inFlight = false;
      // L5: stale sessions and paused machines consume the frame silently.
      if (m.generation !== session.gen || session.phase !== "running" || stopping) return;
      session.frame++;
      if (!framePaintedByMessage && m.framebuffer) {
        lastFrameBytes = m.framebuffer.slice(0);
        lastFrameRgba = fbToRgba(m.framebuffer);
        paintCount++;
        presentFrame(lastFrameRgba);
      }
      framePaintedByMessage = false;
      if (m.pcm.byteLength) audio.push(m.pcm);
      scheduleSRamPoll();
      // The CHAIN: budget still pending (slow display) -> run again now,
      // yielding to rAF after CHAIN_LIMIT consecutive runs. The phase is
      // re-checked here: a Pause that landed while this reply was in flight
      // must never submit ANOTHER frame to the worker.
      if (acc >= FRAME_MS && chainDepth < CHAIN_LIMIT && !stopping && session.phase === "running") {
        acc -= FRAME_MS;
        chainDepth++;
        sendRun();
      } else {
        chainDepth = 0;
      }
    })
    .catch((e) => {
      inFlight = false;
      if (workerBroken) return; // killWorker already surfaced it
      if (/crashed/.test(e.message)) { crashWorkerState(e.message); return; }
      fail(`emulation error: ${e.message}`);
    });
}

let sramReadBusy = false;
let sramPollDue = 0;
function scheduleSRamPoll() {
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
        return; // session replaced mid-read: DISCARD
      }
      const bytes = new Uint8Array(m.bytes);
      const baseline = session.sramShadow ?? session.sramBoot;
      if (!session.sramDirty && !arraysEqual(bytes, baseline)) {
        session.sramDirty = true;
      }
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
  const romId = session.romId;
  try {
    const m = await call("readSram", { generation: gen });
    if (gen !== session.gen || romId !== session.romId) return false;
    const bytes = new Uint8Array(m.bytes);
    if (session.sramShadow && arraysEqual(bytes, session.sramShadow)) {
      session.sramDirty = false;
      return true;
    }
    await savePut(romId, bytes);
    if (gen !== session.gen || romId !== session.romId) return false;
    session.sramShadow = bytes.slice();
    session.sramDirty = false;
    storageDiag.lastWrite = { romId, why, at: Date.now(), bytes: bytes.length };
    return true;
  } catch (e) {
    if (!workerBroken) {
      storageDiag.errors.push(`save write failed (${e.message})`);
      say(`could not persist the battery save (${e.message}); play continues`, true);
    }
    return false;
  }
}

function startLoop() {
  if (!running) {
    running = true;
    last = performance.now();
    acc = 0;
    chainDepth = 0;
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
  if (e.repeat) { e.preventDefault(); return; }
  if (isEditableTarget(e.target) || isEditableTarget(document.activeElement)) {
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
    // Hidden pauses immediately (L1) and stays paused on return.
    stopSimulation("paused");
    $("start-overlay").hidden = false;
  }
});

// ---------------------------------------------------------------------------
// controls
// ---------------------------------------------------------------------------
async function doPlay() {
  if (session.phase !== "paused" || session.dead || workerBroken) return;
  stopping = false;
  if (audioEnabled) {
    const ctx = audio.ensure();
    if (ctx.state !== "running") {
      try { await ctx.resume(); } catch {}
    }
  }
  if (session.phase !== "paused") return; // a racing load changed plans
  setPhase("running");
  $("start-overlay").hidden = true;
  startLoop();
  // Kick the FIRST frame immediately: the observer of the boot marker
  // sees the canvas painted with the first frame rather than a tick
  // late. dispatchRun (not sendRun) so the budget is SUBTRACTED like
  // every other frame - a phantom extra budget would double the cadence.
  acc += FRAME_MS;
  dispatchRun();
  canvas.focus({ preventScroll: true });
}
async function doPause(hide) {
  if (session.phase === "running" && !stopping) {
    // Halt IMMEDIATELY - inputs, audio, and (via `stopping`) every frame
    // dispatch - BEFORE any persistence await. The observable phase flips
    // to 'paused' only once the save has landed, so a page reload racing
    // this pause cannot lose the save, and no frame runs after the click.
    stopping = true;
    releaseInputs();
    audio.suspend();
    await flushSave("pause");
    stopping = false;
    setPhase("paused");
  } else if (session.phase === "paused") {
    await flushSave("pause");
  }
  if (!hide) $("start-overlay").hidden = false;
}
async function doReset() {
  if (session.dead || session.gen === 0 || workerBroken) return;
  const gen = session.gen;
  const romId = session.romId;
  stopSimulation("loading");
  // Snapshot the live SRAM BEFORE the machine resets (the worker
  // serializes: this read reflects the pre-reset machine).
  try {
    const m = await call("readSram", { generation: gen });
    if (gen === session.gen && romId === session.romId && session.hasBattery) {
      const bytes = new Uint8Array(m.bytes);
      if (!session.sramShadow || !arraysEqual(bytes, session.sramShadow)) {
        await savePut(romId, bytes);
        if (gen === session.gen) {
          session.sramShadow = bytes.slice();
          session.sramDirty = false;
        }
      }
    }
  } catch (e) {
    storageDiag.errors.push(`save flush on reset failed (${e.message})`);
  }
  if (gen !== session.gen) return; // replaced meanwhile
  await call("reset").catch(() => {});
  audio.flush();
  releaseInputs();
  session.frame = 0;
  setPhase("paused");
  $("start-overlay").hidden = false;
  say("cold boot - press Play");
  presentNow();
}
// transactional erase: confirm, stop, clear, cold boot paused
async function doForget() {
  if (session.gen === 0 || session.dead || workerBroken) return;
  const name = session.fileName ?? "this cartridge";
  if (!window.confirm(`Erase the battery save for ${name}? This cannot be undone.`)) return;
  // L1: stop immediately; the erase then proceeds through one path.
  const myLoad = ++session.want;
  stopSimulation("loading");
  session.sramDirty = false;
  if (session.romId) {
    try { await saveDelete(session.romId); }
    catch (e) {
      fail(`could not erase the stored save (${e.message})`);
      revertPhase();
      return;
    }
  }
  if (myLoad !== session.want) return;
  // Cold boot the SAME ROM with a FRESH machine (default $FF SRAM -
  // zn_reset alone would preserve SRAM, the opposite of erasing), through
  // the same install path as a normal selection - WITHOUT the outgoing
  // flush, which would resurrect the save that was just deleted.
  await installSession(name, new Uint8Array(session.bytes), myLoad, { skipOutgoingFlush: true });
  if (myLoad === session.want && session.phase === "paused") {
    say("battery save erased - cold boot, press Play");
    presentNow();
  }
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
    fitWebGpuOutput();
    crtActive = crtRequested;
    presentNow();
  } else {
    crtActive = false; // 2D fallback: truthfully off
    say("CRT is unavailable without WebGPU; showing the plain picture");
  }
  updateCrtLabel();
}
function fitWebGpuOutput() {
  const dpr = window.devicePixelRatio || 1;
  const rect = canvas.getBoundingClientRect();
  const availW = Math.max(1, Math.floor((rect.width || W) * dpr));
  const availH = Math.max(1, Math.floor((rect.height || H) * dpr));
  let k = Math.max(1, Math.min(Math.floor(availW / W), Math.floor(availH / H)));
  gpuPresenter.configure({ width: W, height: H, outputWidth: W * k, outputHeight: H * k, crt: crtRequested });
}
addEventListener("resize", () => { if (presenterMode === "webgpu" && gpuPresenter) fitWebGpuOutput(); });

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

addEventListener("dragover", (e) => { e.preventDefault(); $("drop")?.classList.add("armed"); });
addEventListener("dragleave", () => $("drop")?.classList.remove("armed"));
addEventListener("drop", (e) => {
  e.preventDefault();
  $("drop")?.classList.remove("armed");
  const f = e.dataTransfer.files && e.dataTransfer.files[0];
  if (f) startLoad(f);
});

document.querySelectorAll("#bar button, #bar input").forEach((el) => {
  el.addEventListener("focus", releaseInputs);
});
addEventListener("keydown", (e) => {
  if (e.code === "Space" && document.activeElement === document.body) {
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
      // Everything observable must resolve without a worker round trip so a
      // state() call sandwiched around a Pause click is instantaneous: the
      // frame counter is page-side, and worker/wasm diagnostics live behind
      // an explicit workerStats() query.
      return {
        phase: session.phase,
        generation: session.gen,
        want: session.want,
        frame: session.frame,
        romId: session.romId,
        lastError,
        presenter: presenterMode === "webgpu" ? "webgpu" : presenterMode === "2d" ? "2d" : "initializing",
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
        paintCount,
        workerBroken,
      };
    },
    // Real worker observability: wasm memory pages + worker counters,
    // behind an explicit query so plain state() stays round-trip free.
    workerStats: () => workerBroken ? null : call("stats"),
    presenterReady: () => presenterReady,
    // Test-only: make the worker die mid-session (real error plumbing).
    forceCrash: () => call("__crash"),
    repaint: (skipFit) => { if (!skipFit) fitCanvas(); presentNow(); },
    async readWram(offset, len = 1) {
      const m = await call("readWram", { offset, len });
      return Array.isArray(m.bytes) ? m.bytes : Array.from(m.bytes);
    },
    readSram: async () => {
      const m = await call("readSram");
      return Array.from(m.bytes);
    },
    audio: () => audio,
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
    fail(`could not start (${e.message || e}) - reload the page`);
    setPhase("error");
  }
})();
