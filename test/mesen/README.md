# Mesen2 Cross-Validation Harness

Mesen2 (installed at `~/Repos/Mesen2/Mesen.app`) is the third-vote
emulator: when zupernes and the ZuperWorld port disagree, a Mesen2 trace
arbitrates (and the disassembly remains the constitution).

## Usage

```bash
# 1. Generate the Lua trace script from a shared .zmov movie
python3 test/mesen/make_trace_script.py movie.zmov <frames> /tmp/run.lua /tmp/mesen.trace

# 2. Run headless (no window; --testrunner is console-only)
~/Repos/Mesen2/Mesen.app/Contents/MacOS/Mesen --testrunner rom.sfc /tmp/run.lua

# 3. Same movie through zupernes (via the ZuperWorld oracle)
cd ../zuperworld && zig build oracle -- rom.sfc <frames> /tmp/z.trace --movie movie.zmov
```

Both traces share the column set (frame, mode, state, powerup, dir, air,
water, xspd, yspd, x, y, lf) where `lf` is SMW's own frame counter $13.

One-time Mesen setup (already applied):
- `Debug.ScriptWindow.AllowIoOsAccess: true` in
  `Mesen.app/Contents/MacOS/settings.json` (portable-mode config; file
  has a UTF-8 BOM - read with utf-8-sig) so Lua can write trace files.
- `Snes.Port1.Type: "SnesController"` - a fresh config has NO controller
  attached and emu.setInput silently does nothing.

## Findings from the first cross-validation (SMW YI1 walk movie)

1. **Mario's physics are logic-frame-exact between zupernes and Mesen2**:
   aligned at level entry, 80 consecutive logic frames of the walk
   (acceleration ramp 01,03,04,06,07,... to the 13/14/15 steady state,
   relative X, and Y) are identical until the runs diverge for input
   reasons (below). No physics bugs found in zupernes.
2. **Absolute-frame movies do not sync across emulators**: zupernes
   reaches each game-mode transition earlier than Mesen2 (boot +17
   frames; each level load 14-26 frames faster). Inputs indexed by
   absolute frame land at different game-relative times, so runs
   macro-match but micro-diverge (each Mario met the Rex at a different
   walk frame). Closing these gaps = the cycle-accuracy roadmap in
   OPTIMIZATIONS.md (per-access memory timing, DMA cycle accounting).
   Until then, cross-emulator comparisons anchor on game events, and
   TAS movies recorded against hardware timing will not sync on
   zupernes.
3. **Trace sampling must anchor on $13, not the video frame**: with
   approximate CPU timing, SMW's main loop occasionally spills past the
   video-frame boundary, so boundary sampling produces phantom
   skips/repeats in otherwise-correct physics. The oracle now snapshots
   state at the instant $13 increments (previous logic frame guaranteed
   complete). The spill itself is another symptom of the intra-frame
   timing gap - roadmap, not game-logic bug.
