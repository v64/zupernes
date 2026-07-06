# 65816 Test-Vector Verification — Status & Resume Notes

## Current state (2026-07-03)

**5,120,000 / 5,120,000 vectors passing (100%)** — the CPU is fully
vector-clean. Suite: SingleStepTests 65816 (10,000 tests per opcode per
mode). Remaining CPU work is per-cycle timing only (2.65M cycle-count
mismatches tallied as telemetry; see OPTIMIZATIONS.md roadmap).

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
7. **E-mode SP rest-state pin + 16-bit walk for new stack ops** (fixed
   2026-07-03, closing the last 979): SPH=1 is the REST state - pinned
   between instructions - but the eight "new" stack instructions
   (PEA/PEI/PER/PHD/PLD/PLB/JSL/RTL) do full 16-bit SP arithmetic
   DURING execution: RTL from SP=$01FD reads $01FE/$01FF/$0200 (not a
   page-1 wrap), then the final SP pins back to $01xx. Implemented as
   pushByteRaw/pullByteRaw + a pin after executeOpcode. The original
   instruction set keeps in-page wrapping (pushByte/pullByte).
8. **DL=0 direct-page wrap in e-mode** (fixed 2026-07-03): dp,X / dp,Y
   ADDRESS computation wraps within the page (8-bit add) when the
   direct-page register's low byte is 0 - 6502 zero-page indexing.
   Crucially the pointer FETCHES of (dp)/(dp,X)/(dp),Y do NOT wrap
   (no 6502 ($FF)-bug reproduction): proven by vector "e1 e 8669"
   (D=$F400, pointer at $F4FF reads its high byte from $F500). An
   initial implementation that wrapped the pointer fetch passed
   5,119,999/5,120,000 - one vector in five million caught it.

Games verified pixel-identical after all fixes (SMW 2000-frame capture
byte-for-byte vs pre-fix). SMW runs in native mode, so these were mostly
latent bugs - but latent CPU bugs poison oracle traces eventually.

## Remaining: none (functional). Per-cycle timing only.

All 512 files pass completely. Games verified pixel-identical after the
final fixes (SMW 2800-frame movie replay byte-for-byte). The 2.65M
cycle-count mismatches are the per-access 6/8/12 master-cycle work
already in OPTIMIZATIONS.md - a separate project, and the same gap the
Mesen2 cross-validation quantified at the frame level (boot +17, level
loads 14-26 frames; see test/mesen/README.md).

## Where this fits

This was step one of hardening zupernes as the ZuperWorld physics oracle
(see ~/Repos/zuperworld PLAN.md). Next hardening steps after the two
quirks: golden-image suite for test/snes-test-roms, cross-emulator trace
validation once the shared TAS format exists.

# SPC700 Test-Vector Verification (2026-07-05)

**256,000 / 256,000 vectors passing (100%)** — the sound CPU joins the
65816 as fully vector-clean. Suite: SingleStepTests spc700 (1,000 tests
per opcode, 256 opcodes). This matters double: the APU is vendored into
ZuperWorld (src/engine/apu/), so its correctness is oracle
infrastructure for the SMW driver there too.

- Vectors in the session scratchpad (`spc700-vectors/spc700-main/v1/`,
  81MB). Re-fetch: `curl -L codeload.github.com/SingleStepTests/spc700/tar.gz/refs/heads/main`
- Run: `zig build -Doptimize=ReleaseFast spc-vectors -- <dir> [filter] [--max-fail N]`
- Harness: `src/test_spc_vectors.zig` (the core's `test_flat_ram` mode:
  vectors model all 64KB as plain RAM — no $F0-$FF I/O, no IPL overlay;
  full 64KB image diff per test, so spurious writes can't hide).

## Bugs found and FIXED (first run: 251,993/256,000, 7 bad opcodes)

1. **TSET1/TCLR1 ($0E/$4E)**: N/Z come from `A - mem` (a CMP), not
   `A & mem` as many opcode summaries claim. 544/451 failures each.
2. **BRK ($0F)**: sets B but CLEARS I — opposite of the 6502 family's
   I-set. All 1,000 vectors failed on the psw.
3. **ADDW ($7A)**: H and V were never computed ("simplified"). The
   hardware runs two chained 8-bit adds: H = half-carry of the HIGH
   byte add (carry out of bit 11 of the word), V = high-byte signed
   overflow, C = carry out of bit 15.
4. **SUBW ($9A)**: same story with borrows (H/C are inverted-borrow).
5. **DIV ($9E)**: full quirk algorithm: H = (Y&15) >= (X&15) on the
   ORIGINAL registers, V = Y >= X, and when the quotient needs more
   than 9 bits the divider wraps into the closed form
   `A = 255 - (YA - (X<<9)) / (256 - X)`, `Y = X + (YA - (X<<9)) % (256 - X)`
   (X=0 lands here naturally — no special case).
6. **MOVW YA,dp ($BA)**: Z must test the full 16-bit word; the old
   setNZ(Y)-then-OR-Z could never clear a wrong Z (4/1,000 caught it).

## Remaining: none (functional). Cycle telemetry only.

SLEEP ($EF) / STOP ($FF): 1,000 cycle-count mismatches each, state
exact — the vectors snapshot the halt loop mid-wait (7 cycles), we
model both as 3-cycle no-ops. No game code executes either (a real
STOP is unrecoverable without an APU reset), so the halt loop stays
unmodeled by choice.
