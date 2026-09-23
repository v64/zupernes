# ZuperNES Browser Theater

A standalone, fully local browser SNES player: the real ZuperNES Zig core
compiled to freestanding WASM and run in a dedicated worker, presented with
ZuperWorld's CRT WebGPU shader (or a plain 2D canvas fallback). No ROM
ships with it — you supply your own cartridges.

## Launch

```sh
zig build theater -Doptimize=ReleaseFast   # stages src/theater/zupernes.wasm
python3 src/theater/serve.py --port 8380   # http://127.0.0.1:8380/
```

Open <http://127.0.0.1:8380/>, then **Load ROM…** (or drag/drop a
`.sfc`/`.smc` anywhere) and press **Play**. Everything runs locally; the
static server only serves the page.

## What it emulates

The same NTSC LoROM/HiROM cartridges the native emulator supports,
including dumps with a 512-byte copier header (stripped automatically —
headered and unheadered dumps of one cartridge share saves). This is the
existing core's compatibility envelope; nothing about accuracy changes in
the browser build (verified byte-exact against native goldens — see
"Verification").

The adapter enforces this envelope at load time with actionable errors
(error codes 5-8 in the `zn_load_rom` contract): coprocessor cartridges
(DSP chips 0x03-0x05 and others >= 0x0F) announce hardware this build
cannot support and are rejected up front with a visible message rather
than "booting" into a hang; ExHiROM-style mapping bytes and PAL/other
regions (destination code >= 2) are likewise rejected while NTSC/US/
Japan dumps load. A plausibility gate requires real internal-header
evidence (map byte or checksum agreement - a reset vector alone is not
enough) before any machine is committed, and the previous session and
its save are untouched on every rejection. **Bad checksums are never a
rejection reason**, and dumps with a copier header validate against
their stripped content.

Remaining honest limits:

- **Not emulated:** coprocessors of any kind (the browser has no
  microcode source; such cartridges are visibly rejected at load),
  PAL timing/interlace/hi-res, ExHiROM.
- **> 16 MiB files** are rejected as not ordinary cartridges.

The picture is the core's native 256x224, displayed at 256:224 with black
letterbox margins — no widescreen — integer-scaled where possible,
nearest-neighbor, RGB15 expanded with components `<< 3` exactly like the
native screenshot tool.

## Controls

| Control | Action |
| --- | --- |
| Load ROM… | pick a `.sfc`/`.smc` from disk (latest selection wins) |
| ▶ Play / ⏸ Pause | run/pause; loading, reset, erase, and reload leave it paused |
| ↺ Reset | cold boot of the same cartridge, battery SRAM preserved |
| 🔊 Sound | 32 kHz stereo PCM through WebAudio (user-gesture resumed) |
| 🖥 CRT | ZuperWorld's WebGPU CRT shader on/off (plain pipeline = real bypass) |
| Erase Save | window.confirm, then wipes ONLY this cartridge's SRAM and cold boots |

Keyboard (controller 1; `KeyboardEvent.code`): **W S A D** = dpad,
**K J L P** = B Y A X, **Q E** = L R, **O U** = Start Select.

Keys release on blur, tab-hide, pause, reset and ROM swap, and OS
auto-repeat can never re-press a released key. Typing in the toolbar or any
editable element never leaks into the emulated pad.

## Operation ownership

Everything that changes what the player sees or controls obeys one rule
(`src/theater/js/main.mjs`, header comment O1-O4):

- **One owner token.** Load, Erase Save, Play, Pause, Reset, and hiding
  the tab while a game runs each *claim* the token synchronously when they
  start. Only the newest claimant may change the phase, the stop flag,
  inputs, audio or the picture.
- **Continuations re-check.** Code that resumes after an await (a save
  landing, a worker reply) first checks that it still owns the token. If
  not, it returns without touching anything, so a slow Pause can never
  pause or un-stop a cartridge loaded or erased after it.
- **Refuse, don't race.** Play only from paused, Pause only while running,
  Reset/Erase never while a load/erase/reset is in progress, and a hidden
  tab only stops a *running* game; a load in progress continues and ends
  paused.
- **Page and worker agree.** If a newer selection is rejected - by the
  page (size, unreadable file) or by the worker (coprocessor, mapping) -
  the page asks the worker which machine it holds. If a skipped earlier
  load committed there, the page reinstalls its own last adopted
  cartridge before showing the error.

Saves have their own ordering rule. All writes and deletes run through
one serialized queue, so IndexedDB sees them in request order. Erase
Save advances a per-cartridge *erase token* at the moment it is
requested, and every write carries the token that was current when its
SRAM bytes were read from the worker. Bytes read before an erase are
never written after it, however late their write is queued. A write
already executing when the erase is requested finishes first and is then
deleted. The worker also refuses run/reset/SRAM requests that name
another cartridge's generation.

## Battery saves

Automatic, keyed by the SHA-256 of the *normalized* ROM bytes (copier
header stripped), stored in IndexedDB in this browser profile. Restored
before the first frame of a session; flushed within a second of any
change, on pause/reset/replace/page unload, and on cartridge
replacement BEFORE the outgoing machine is swapped (an unpaused A->B
swap keeps A's last-second save). Pausing halts emulation immediately
and only shows itself as paused once the save has landed, so a reload
racing a pause cannot lose data. Cartridges without battery RAM are
never written. A storage failure or wrong-sized stored save is
reported (and stays visible) but never blocks play.

## Verification (this checkout)

Run in order; all must pass:

```sh
zig build theater -Doptimize=ReleaseFast
node test/theater/wasm-check.mjs          # 20 exact RGB/WRAM/PCM parity checkpoints
python3 src/theater/serve.py --port 8380 &  # then:
node test/theater/browser-check.mjs http://127.0.0.1:8380   # supplied UI smoke gate
node test/theater/feature-check.mjs http://127.0.0.1:8380   # extended gate (28 scenarios)
node test/theater/perf-check.mjs http://127.0.0.1:8380 10  # real headed Chrome
zig build && zig build test               # native behavior unchanged
```

- **wasm-check.mjs** proves the browser artifact matches the frozen
  native-captured goldens bit-for-bit (RGB, all 128 KiB WRAM, PCM), plus
  ROM-buffer ownership, reset/SRAM lifetime and atomic load failure.
- **browser-check.mjs** (reviewer-supplied) covers the 12-key mapping via
  the emulated $4218/$4219 echo, chords, blur release, pause, LoROM/HiROM
  load, battery write through gameplay, cross-ROM save isolation, copier
  normalization, reset, Erase Save cancel/confirm, durable reload, narrow
  layout, invalid-ROM handling, no network traffic, and the nonblank 2D
  WebGPU fallback.
- **feature-check.mjs** (this task) covers drag/drop, malformed/oversized
  rejection, out-of-order load races, rapid operations, worker-crash
  injection and recovery, hidden/resume with bounded catch-up, auto-repeat
  suppression, storage failure/corruption, no-battery cartridges, real
  AudioNode stereo at 44.1/48 kHz with bounded scheduling and full stop on
  every stop path, WebGPU CRT on/off captures at one paused frame,
  forced-init-failure fallback, exact 2D pixel equality versus the live
  wasm core, and a 30-cycle replacement/reset stress with bounded heap.
- **perf-check.mjs** measures 10 s of emulation in headed GPU-accelerated
  Chrome after warmup: 60.1 fps (100.0% of NTSC) with the WebGPU
  presenter; toolbar response 38-43 ms measured from before the click
  dispatch (harness transit included).
- **feature-check.mjs ownership and storage regressions** (the gate
  runs 28 scenarios in total). Each one holds a real worker reply or
  IndexedDB open, performs the racing operation, releases it, and asserts
  the result; none uses a sleep as synchronization:
  - held Pause write vs Erase Save (no resurrection);
  - SRAM read before an Erase, written after the delete (skipped);
  - old Pause completion vs an in-flight load and vs an in-flight erase;
  - tab hidden during a load;
  - a committed-but-unadopted load followed by a worker-rejected (after
    an earlier ordinary rejection) or page-rejected selection
    (reconciles, frames advance);
  - the original held-reply/rejected-follow-up case;
  - WebGPU `configure` throwing after the canvas handed out a WebGPU
    context (live 2D replacement canvas with lit pixels);
  - an outgoing save failure that stays visible after a successful
    no-battery replacement.

  Each new regression fails on the pre-fix code and passes now:
  `.zig-cache/round-4-evidence/summary.md`, local, not committed.
  Robustness checks:
  - real GPUDevice.destroy() recovery with continuing paints;
  - 1,000 worker-side alloc/free pairs plus 34 load cycles, asserting
    that WASM memory plateaus;
  - Worker constructions counted through a Proxy construct trap, and
    window/canvas listener counts across 30 replacement cycles;
  - a 30 Hz driver and a measured ~110 callbacks/s driver, each asserting
    minimum progress and no acceleration.

### Tested environment

- macOS 14.6, Apple M1 Pro
- Google Chrome 153 (headed for performance; headless for functional
  gates), WebGPU presenter; the 2D fallback verified via
  `navigator.gpu`-removed contexts
- Zig 0.15.2, `-Doptimize=ReleaseFast`, wasm32-freestanding baseline CPU

## Architecture notes

- `src/theater/wasm/main.zig` — the WASM adapter around the unchanged
  core: `zn_*` exports (see test/theater/TASK.md for the contract). The
  ~940 KB self-referential `Emulator` lives at one stable wasm-heap
  address for the whole cartridge lifetime; a 4 MB wasm stack covers its
  value-typed construction. `rdynamic` is required or wasm-ld GCs every
  export.
- `src/root.zig` — `Emulator.loadRomFilesystemFree` splits portable
  machine construction from the host-only DSP microcode lookup; native
  `loadRom` delegates, so native and WASM build the identical machine.
- `src/theater/js/worker.mjs` — owns the single WASM instance; a
  generationed protocol makes every load/replace transactional and a
  wasm trap surfaces as a visible, recoverable error.
- `src/theater/js/main.mjs` — host: NTSC-cadence rAF loop with bounded
  catch-up, IndexedDB persistence, focus-safe input, audio scheduling.
  The keyboard map, audio scheduling pattern, focus/blur release handling
  and presentation policy are adapted from ZuperWorld's
  `src/theater/js/main.mjs` at commit 954e3f72; the session/mod/game
  machinery is deliberately not carried over.
- `src/theater/js/webgpu-presenter.mjs` — copied VERBATIM from ZuperWorld
  (954e3f72) with provenance header; only addition is device-loss
  tracking. CRT-off is the original plain pipeline, byte-for-byte.
- `src/theater/serve.py` — stdlib-only static server, correct
  wasm/mjs MIME, no-store.

Generated artifacts (`src/theater/zupernes.wasm`, `.zig-cache/theater-*`)
are gitignored.
