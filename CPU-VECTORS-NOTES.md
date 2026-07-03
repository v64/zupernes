# 65816 Test-Vector Verification — Status & Resume Notes

## Current state (2026-07-02)

**5,119,021 / 5,120,000 vectors passing (99.98%)**, up from 96.9% before
fixes. Suite: SingleStepTests 65816 (10,000 tests per opcode per mode).

- Vectors live in the session scratchpad (`65816-main/v1/`, 2.7GB). To
  re-fetch: `curl -L codeload.github.com/SingleStepTests/65816/tar.gz/refs/heads/main`
- Run: `zig build -Doptimize=ReleaseFast cpu-vectors -- <dir> [filter] [--max-fail N]`
- Harness: `src/test_cpu_vectors.zig` (flat-memory Bus mode, final-state
  verification; MVN/MVP run bundled iterations with PC exempt when the
  vector snapshots mid-move - their cycle traces cap at 100).

## Bugs found and FIXED this session

1. **BCD arithmetic** (ADC/SBC 8/16-bit decimal): high-nibble adjust
   leaked into A's high byte; flags from wrong intermediates; 16-bit BCD
   SBC was plain binary and ADC lacked V. Rewritten as the hardware
   nibble cascade (V before final adjust; C/N/Z after).
2. **Bank carry in DBR-relative indexed addressing** (the big one -
   ~2,500 failures in EVERY abs,X / abs,Y / (dp),Y / [dp],Y / (sr,S),Y
   file): effective addresses now carry into the bank byte via the new
   `ea_bank` mechanism, and 16-bit DATA accesses cross into the next
   bank at $xx:FFFF (`readWordData`/`writeWordData` vs pointer fetches
   which wrap).
3. **X-flag truncation**: setting X=1 (SEP/PLP/RTI/XCE) clears the index
   registers' high bytes (`truncateIndexRegs`).
4. **Emulation-mode P forcing**: PLP/RTI force M=X=1 in e-mode.
5. **Emulation-mode SP**: forced to $01xx each instruction (SPH doesn't
   exist); TCS forces too.
6. **MVN/MVP**: 8-bit index mode wraps X/Y at 8 bits.

Games verified pixel-identical after all fixes (SMW 2000-frame capture
byte-for-byte vs pre-fix). SMW runs in native mode, so these were mostly
latent bugs - but latent CPU bugs poison oracle traces eventually.

## Remaining: 979 failures, all emulation-mode, two known quirks

1. **New stack instructions use 16-bit SP in e-mode** (no page-1 wrap):
   failing files 6b(RTL) 2b(PLD) 22(JSL) f4(PEA) d4(PEI) ab(PLB) 62(PER)
   0b(PHD). Fix: non-wrapping push/pull variants for exactly these ops
   (check whether PHB/PHK need it too - 8b/4b currently pass, verify
   why). Old ops (PHA/PLA/JSR/RTS...) keep page-1 wrapping.
2. **Direct-page wrap when DL=0 in e-mode**: dp,X / dp,Y and the pointer
   fetches of (dp,X)/(dp)/(dp),Y wrap within the page (8-bit add) when
   the direct-page register's low byte is 0. Failing: every dp-indexed
   file's `.e` variant at ~15-30/10000 (exactly the DL=0 cases).
   Fix in `addrDirectX/Y` + the dp pointer fetch paths.

Neither affects SMW (native mode). Fix for completeness, then the CPU is
fully vector-clean. Also unaddressed: per-cycle timing (2.65M cycle-count
mismatches tallied as telemetry - that's the per-access 6/8/12 master-
cycle work already in OPTIMIZATIONS.md, a separate project).

## Where this fits

This was step one of hardening zupernes as the ZuperWorld physics oracle
(see ~/Repos/zuperworld PLAN.md). Next hardening steps after the two
quirks: golden-image suite for test/snes-test-roms, cross-emulator trace
validation once the shared TAS format exists.
