# Browser theater: full-model evaluation contract

Implement a usable ZuperNES browser theater for locally supplied SNES ROMs.
Use this checkout and branch only. The reviewer decides whether to merge.
This is a browser port of the existing emulator, not a SNES accuracy campaign.

## Product and boundaries

- A static localhost-served app, with a local file picker and drag/drop for
  `.sfc`/`.smc`. No commercial ROM, extracted assets, microcode, remote emulator,
  external service, CDN dependency, upload, telemetry, or automatic ROM fetch.
- Run the actual Zig ZuperNES core in freestanding WASM, in a dedicated worker.
  Keep the main thread responsive and make worker failures visible/recoverable.
  Own ROM bytes for the entire cartridge lifetime. Loading, reset, and disposal
  must not leave dangling core pointers, stale messages or unbounded queues.
- Support the core's ordinary NTSC LoROM and HiROM cartridges, with/without the
  512-byte copier header. Preserve existing native behavior. Document the
  compatibility envelope honestly: no new coprocessors, PAL timing, interlace,
  hi-res or emulator accuracy fixes are required. Reject unsupported cartridges
  with an actionable message; do not claim to emulate an unsupported feature.
  Header validation must not reject normal games merely for a bad checksum.
- The core's source picture is 256x224. No widescreen, mods, SMW-specific hooks,
  gameplay engine, level picker, save states, recording, debugger or game art.
  Keep the 256:224 display aspect ratio used by ZuperWorld, show the whole image,
  and fit desktop/narrow layouts without horizontal overflow. Black letterbox
  margins are fine. Plain presentation is nearest-neighbor, correctly oriented
  RGB15 expanded with component << 3 (as the native screenshot tool does).
- Adapt the appearance and CRT presenter from ZuperWorld. Use its real CRT
  shader, not a CSS filter or an unrelated approximation. Copy appropriate
  source into this project with path/commit provenance; no runtime sibling
  dependency. Preserve the shader's behavior. CRT-off must really bypass CRT.
  If WebGPU is unavailable or initialization fails, fall back to visible 2D
  rendering and truthfully disable/report CRT. Recover visibly from device loss.
- Visible controls: Load ROM, Sound On/Off, CRT On/Off, Play/Pause, Reset, and
  Erase Save. Provide a short keyboard legend, title/filename and status/error
  area. Loading a ROM leaves it paused until Play. Reset is a cold boot of the
  same ROM retaining battery SRAM, and leaves it paused. Erase Save uses
  window.confirm, clears only this ROM's SRAM, then cold boots paused.
  Controls must remain usable with keyboard focus, and have descriptive labels.
- Sound is native stereo i16 PCM at 32000 Hz, resumed by a user gesture. Use an
  appropriate browser playback mechanism with explicit resampling (or source
  buffers at 32000 Hz so AudioContext resamples). No silent dummy output, mono
  mixdown, unbounded scheduling, backlog replay, or audio after pause/hidden/
  reset/replace. Flush old sources and queues. Keep the queue below 250 ms and
  report underruns/overruns in test diagnostics, not necessarily the product UI.
- Pace emulation at the core's NTSC frame cadence, independent of display Hz.
  Bound catch-up work; never replay a hidden tab's wall-time backlog. Hidden
  pauses and releases inputs; becoming visible stays paused until user Play.
  Window blur releases inputs; it need not pause. Release keys on pause, reset,
  ROM change, blur, hidden and loss of gameplay focus. Require a fresh keydown
  after release, so OS repeat cannot re-press a stale held key. Preserve chords.
- Persist battery SRAM automatically, by SHA-256 of normalized ROM bytes, using
  IndexedDB or localStorage. Headered/unheadered variants share saves; different
  ROM bytes with the same filename do not. Restore BEFORE the first frame.
  Flush promptly (at most one second after mutation) and on pause/reset/replace;
  retain save data across reload. No save clear required to receive an app fix.
  Storage failure/corrupt or wrong-sized data must be visible but keep playing
  possible. Do not write battery saves for cartridges without battery RAM.
  Never label persistence as successful before its actual operation succeeds.
- ROM selection is transactional: malformed/oversized/unsupported input leaves
  the previous game and its save intact and gives a visible error. The latest
  selection wins even when reads/hashes/workers resolve out of order. Rapid
  Play/Pause/Reset/Load cannot revive a discarded session or cross-write saves.

Keyboard mapping (KeyboardEvent.code; controller 1):

| Keys | SNES buttons / masks |
| --- | --- |
| W S A D | Up 0800, Down 0400, Left 0200, Right 0100 |
| K J L P | B 8000, Y 4000, A 0080, X 0040 |
| Q E | L 0020, R 0010 |
| O U | Start 1000, Select 2000 |

Ignore game keydown in editable elements or focused toolbar controls. Clear
previous gameplay keys when focus moves there. Play may focus the canvas so
keyboard play begins naturally; do not make a click on every frame necessary.

## Source orientation

Read CLAUDE.md. Native core: src/root.zig (Emulator), src/cartridge.zig,
src/bus.zig, src/screenshot.zig, src/movie.zig and build.zig. Emulator.setup
requires a stable address. Cartridge borrows ROM memory. Emulator.reset alone
is not a full machine power cycle. Native loadRom has a filesystem-dependent
DSP bootstrap; isolate host-only work without changing native behavior.

Read-only references at /Users/v64/Repos/zuperworld (main 954e3f72 when scoped):
- src/theater/index.html and css/theater.css: visual layout/controls;
- src/theater/js/main.mjs: exact key map, audio scheduling, focus behavior;
- src/theater/js/webgpu-presenter.mjs: reusable CRT/plain WebGPU presenter;
- src/theater/test/input-focus-browser-check.mjs: browser testing precedent.

Reuse appropriate host code, not ZuperWorld's game/session/mod machinery. Do not
modify ZuperWorld, primary ZuperNES, Mesen, another worktree, the ongoing CPU/PPU
experiments, external ROMs or an oracle pin. Do not merge/cherry-pick those tasks.
Production scope: build.zig, new browser/WASM adapter files, src/theater/,
.gitignore for generated theater artifacts, documentation and focused tests.
Minimal core portability refactoring is allowed with preserved native parity;
no CPU/PPU/APU/bus accuracy changes. If a core bug blocks the port, isolate and
report it rather than silently fixing it in this task or changing references.

## Stable build and adapter contract

- `zig build theater -Doptimize=ReleaseFast` builds/stages the exact WASM used by
  the page at src/theater/zupernes.wasm. Generated binary must be gitignored.
- `python3 src/theater/serve.py --port 8380` serves the standalone app from this
  checkout at http://127.0.0.1:8380/, with correct WASM/JS MIME and no stale
  caching. No dependency on a ZuperWorld server or generated bundle.
- `zig build` and `zig build test` retain their existing native behavior.
- A WASM instance can be instantiated from Node with no imports: exports memory
  and the following functions. Return 0 for success, nonzero for failure where
  status is specified. Document numeric errors. Pointers are wasm32 byte offsets.

| Export | Contract |
| --- | --- |
| zn_alloc(len) -> ptr | Owned upload/output memory; positive pointer or 0 on failure |
| zn_free(ptr,len) | Release a matching allocation |
| zn_load_rom(ptr,len) -> status | Clone/own valid ROM, create fresh machine and default FF SRAM; fail atomically |
| zn_run_frame(buttons) -> status | Set controller 1 then run exactly one frame; error before load |
| zn_reset() -> status | Cold boot current ROM preserving SRAM; clear pending audio |
| zn_width(), zn_height() | 256, 224 |
| zn_framebuffer_ptr() | Current 256x224 little-endian RGB15 u16 buffer |
| zn_wram_ptr() | Current 128 KiB WRAM, diagnostic read surface |
| zn_sram_ptr(), zn_sram_len() | Cartridge SRAM bytes and size; host imports/exports before running |
| zn_read_audio(ptr,maxFrames) -> count | Drain up to maxFrames stereo i16 pairs, never exceed capacity; 0 when empty |

Do not cache JS TypedArray views across memory growth or machine replacement.
Do not expose arbitrary remote code or filesystem access. These hooks expose
real core state; never implement fixtures or expected outputs specially.

For browser tests, retain IDs #screen (canvas), #file (file input), #pause,
#reset, #forget, #sound, #crt and #status. Only in `?test=1`, expose
window.__zupernesTest with asynchronous `state()` and `readWram(offset,len)`.
`readWram` returns actual current worker memory bytes, never a cached keyboard
mask. `state()` returns truthful fields:
phase (empty/loading/running/paused/error), generation (monotonic session ID,
increment on successful replacement), frame (emulated frame count), romId
(normalized SHA-256), lastError (message or null), presenter (webgpu/2d),
crtRequested, crtActive, audioEnabled, audioQueuedSeconds. Extra diagnostics
are welcome. Normal startup, initial load, reset, erase, and reload start paused.
Audio and presentation diagnostics must describe actual activity.

## Objective acceptance gates

1. Frozen native parity:
   `node test/theater/wasm-check.mjs`
   Exact RGB pixels, all 128 KiB WRAM and PCM bytes at 20 checkpoints, covering
   LoROM, different same-sized ROM, copier-header variant and HiROM, with a
   varied controller movie. Also checks caller ROM-buffer ownership, battery
   mutation via gameplay, reset/SRAM lifetime and atomic short-ROM failure.
   Fixtures are original assembly (no game data); expected.json was captured
   from native base a51c724 and repeated. This measures port equivalence, not
   correctness of existing SNES emulation. Do not regenerate the expected file.
2. Supplied UI smoke gate, against the live server:
   `node test/theater/browser-check.mjs http://127.0.0.1:8380`
   Checks all 12 keys via emulated $4218/$4219 echo, a chord, blur/focus release,
   pause, LoROM/HiROM load, battery write through gameplay, cross-ROM isolation,
   copier normalization, Reset, Erase Save cancel/confirm, durable reload,
   narrow aspect/layout, visible invalid-ROM handling, no external requests,
   no uncaught page errors and actual nonblack 2D WebGPU fallback.
   Uses installed Playwright (local or global) and Chrome/Chromium. Artifacts
   default to .zig-cache/theater-browser; do not commit captures.
3. Add and run your own focused automated browser tests for the remaining
   requirements. A command named `node test/theater/feature-check.mjs <url>`
   must run them, with nonzero exit on failure. At minimum:
   - actual drag/drop and rejected malformed/oversized/unsupported ROMs;
   - latest-load-wins with deliberately delayed reads/worker responses, stale
     frame/audio/save rejection, rapid pause/reset/load, crash and retry;
   - real hidden/resume and focus transitions, held-key repeat suppression;
   - persistence write failure, corrupt/wrong-sized save, cancellation and
     save isolation during in-flight replacement; no-battery cartridge;
   - nonzero stereo PCM reaching a real AudioContext output path after a
     gesture, Sound toggle, bounded queue and stopped sources on pause/hidden/
     reset/ROM replacement. Test sample-rate behavior at 44100 and 48000 Hz
     (a deterministic scheduling/resampling unit check may supplement the
     live browser). Instrument real AudioNodes/AudioWorklet, not UI flags;
   - real WebGPU CRT on/off screenshots at the same paused frame and viewport,
     clearly differing CRT effect while preserving image orientation and
     colors. Assert an actual WebGPU backend for this gate; unavailable is
     BLOCKED, not a pass. Force initialization failure separately from absence;
     exercise device-loss handling. Plain 2D pixels at native size must equal
     fixture/native RGB (exact, no masked regions). Do not judge CRT only by
     changed-pixel count: inspect the captures for clipping, stretch, blank or
     dark output and note what was inspected;
   - 30 alternating ROM replacements and resets after warmup: bounded worker,
     listener/audio-node counts and memory use; no stale SRAM, ROM or audio.
     WASM committed memory may retain its high-water mark, not grow each cycle.
4. Native preservation: `zig build`, `zig build test`, `git diff --check`.
   Read actual logs and exit status. Native baseline here passes (67 passed,
   3 skipped in the test runner); do not claim broader ROM suites were run.
5. Performance: record environment, optimization/backend, wall time and actual
   emulated frame count for 10 seconds after warmup on original LoROM/HiROM.
   At least 90% of nominal NTSC speed in a real accelerated desktop browser
   on this machine, and no more than 110% speed. Check toolbar response within
   500 ms during emulation. Software/headless GPU results may be supplemental;
   do not excuse a failed actual-browser gate by reporting a mocked benchmark.
6. Capture desktop (1100x850) and narrow (390x844) layouts, CRT on/off and fallback.
   Open and inspect them. Document results, limits and instructions in
   docs/browser-theater.md. Optional local owned-game smoke is useful; no
   copyrighted ROM, image, audio, SRAM or hash-derived title data in git.

The supplied tests are a floor, not the entire product contract. New tests must
fail for the bug they protect against and exercise real implementation. Do not
replace them with source-text assertions, empty promises or implementation
mirrors. Preserve reproducible evidence for any defect found during testing.
The fixture has static asymmetric palette markers and an input-dependent color
change; a nonblack canvas alone is not full video parity. Audio is an original
uploaded SPC/DSP noise program with distinct left/right levels.

## Work and handoff

Start with the external clock helper (path in relay prompt). Record UTC start,
finish, elapsed wall time and checkpoints for wasm, UI, verification. Flex waits
count toward elapsed time; do not describe total wall time as inference time.
Read the contract, state a short plan and proceed autonomously. Work in stages:
(1) exact native/WASM parity, (2) playable host, (3) lifecycle/storage/audio/CRT
failure cases and visual/performance verification. Commit logical milestones.
If there is a true blocker, report exact command/error and a bounded attempted
resolution. Do not spend hours rewriting emulator internals. Report honestly
what remains; compilation or a screenshot is not completion.

Frozen reviewer files: everything already under test/theater/ at handoff and
external full-browser-theater reports. You may ADD feature-check.mjs and other
new tests there, but do not edit supplied fixtures/checks/spec/goldens. Report a
harness bug with evidence instead of working around it. Scratch and output
belong in .zig-cache. Preserve unrelated work. No dependency upgrades or new
packages without a concrete need; existing Zig, Python, Node and Playwright
are sufficient. Capture both stdout/stderr and the actual command exit status
(use subprocess or `> log 2>&1`, not the reversed redirection in CLAUDE.md).

Final report: commit IDs; every gate PASS/FAIL/BLOCKED with command, measured
result and artifact path; screenshots inspected; tested browser(s); known
compatibility limits; exact UTC start/finish and wall duration; launch command;
remaining dirty files. Do not merge, publish, advance the oracle or declare a
blocked gate passed. The user relays this report for independent review.
