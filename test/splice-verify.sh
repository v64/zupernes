#!/bin/bash
# =============================================================================
# SPLICE VERIFIER - proves a resumed recording is self-contained.
# =============================================================================
# The acceptance test for the record-time splice. `--record-movie` after
# `--load-state` used to emit a TAIL: correct inputs, but replayable only if a
# 412 KB savestate travelled beside it. It now reads the .origin sidecar and
# writes the origin's inputs 0..N-1 in front of the tail, so the recording
# replays from power-on on its own.
#
# The claim to prove is exact, not approximate:
#
#   playing the spliced movie from power-on lands in the SAME MACHINE STATE
#   as the resumed run it was recorded from.
#
# So the comparison is a complete savestate - CPU, PPU, VRAM/CGRAM/OAM,
# framebuffer, intra-frame position, WRAM, SRAM, DMA, APU, DSP-1 - captured at
# the same global frame from both paths and compared byte for byte. A
# screenshot check would pass on an off-by-one in the prefix length; this does
# not.
#
# An off-by-one is the specific failure this guards. The state is written at
# the START of frame N, before it runs, so the prefix is frames 0..N-1. Taking
# 0..N instead replays one input twice and diverges immediately.
#
# The negative control at the end corrupts one frame of the spliced movie and
# requires the comparison to FAIL. A check that cannot fail proves nothing.
#
# Usage: test/splice-verify.sh <rom.sfc>
# Exit 0 means the splice is exact and the fallbacks are marked correctly.
# =============================================================================
set -u
set -o pipefail

ROM="${1:-}"
if [ -z "$ROM" ] || [ ! -f "$ROM" ]; then
    echo "usage: $0 <rom.sfc>" >&2
    exit 2
fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SHOT="$HERE/zig-out/bin/screenshot"
[ -x "$SHOT" ] || { echo "build first: zig build" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# WHAT EACH CHECK CAN AND CANNOT PROVE, MEASURED RATHER THAN ASSUMED.
#
# Both paths run the same NUMBER of frames, so a state comparison only carries
# information where the machine's state depends on the inputs being compared.
# At this prefix SMW is in its attract demo: game mode reads $14, but player
# input is ignored, so the state proves the PREFIX (control 2 catches a
# one-frame shift, because the boot presses move) and says nothing about the
# TAIL. Control 1 therefore proves the tail in the text.
#
# The earlier draft of this file used a ~300-frame window and a single-frame
# input flip as its negative control. Both passed while proving nothing: the
# flip was never consumed, and the tail inputs changed no state at all.
PREFIX=1100     # savestate is taken here
TAIL=200        # frames run after the resume
fails=0

note() { printf '  %s\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# The origin boots SMW to gameplay: Start at 700, A at 800 and 900. These are
# the ROM's own menu cadence, not an invented one, and by ~frame 1014 the
# machine is in a level where input moves Mario.
python3 - "$WORK/origin.zmov" "$PREFIX" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
frames = ["."] * n
for at, ch in ((700, "S"), (800, "A"), (900, "A")):
    for i in range(30):
        frames[at + i] = ch
open(path, "w").write("\n".join(["# zmov 1"] + frames) + "\n")
PY

echo "== A: play the origin and snapshot at frame $PREFIX =="
"$SHOT" "$ROM" $((PREFIX + 1)) "$WORK/a.ppm" \
    --movie "$WORK/origin.zmov" \
    --save-state-at "$PREFIX:$WORK/st.state" >"$WORK/a.log" 2>&1 || {
    bad "run A failed"; cat "$WORK/a.log"; exit 1; }

grep -q '^origin-file:' "$WORK/st.state.origin" \
    && ok "sidecar names the origin movie (origin-file)" \
    || bad "sidecar has no origin-file - the origin is unreachable"

echo "== B: resume, run a tail, record it =="
"$SHOT" "$ROM" $TAIL "$WORK/b.ppm" \
    --load-state "$WORK/st.state" \
    --input 5:R:190 --input 40:A:12 --input 120:A:10 \
    --record-movie "$WORK/spliced.zmov" \
    --save-state-at "$((TAIL - 1)):$WORK/endB.state" >"$WORK/b.log" 2>&1 || {
    bad "run B failed"; cat "$WORK/b.log"; exit 1; }

grep -q 'movie is self-contained' "$WORK/b.log" \
    && ok "recorder spliced rather than truncating" \
    || { bad "recorder did not splice"; grep -i splice "$WORK/b.log"; }

# A spliced movie starts at power-on BECAUSE it carries its prefix. If it
# still declared a savestate start it would be asking for a file it no
# longer needs.
grep -q '^# spliced-origin:' "$WORK/spliced.zmov" \
    && ok "spliced movie records its origin" \
    || bad "spliced movie has no spliced-origin key"
grep -q '^# start: savestate' "$WORK/spliced.zmov" \
    && bad "spliced movie still claims a savestate start" \
    || ok "spliced movie starts at power-on"

want=$((PREFIX + TAIL - 1))
got=$(grep -c -v '^#' "$WORK/spliced.zmov")
[ "$got" -eq "$((PREFIX + TAIL))" ] \
    && ok "spliced length is $got = $PREFIX prefix + $TAIL tail" \
    || bad "spliced length $got, expected $((PREFIX + TAIL))"

echo "== C: replay the spliced movie from power-on =="
# endB was captured after PREFIX+TAIL-1 emulated frames; land C on the same one.
"$SHOT" "$ROM" $((PREFIX + TAIL)) "$WORK/c.ppm" \
    --movie "$WORK/spliced.zmov" \
    --save-state-at "$want:$WORK/endC.state" >"$WORK/c.log" 2>&1 || {
    bad "run C failed"; cat "$WORK/c.log"; exit 1; }

if cmp -s "$WORK/endB.state" "$WORK/endC.state"; then
    ok "COMPLETE MACHINE STATE identical: resumed run == spliced replay"
else
    bad "state mismatch - the spliced movie does not reproduce the resumed run"
    cmp "$WORK/endB.state" "$WORK/endC.state" | head -3
fi

# -----------------------------------------------------------------------------
# The identity above is only evidence if this comparison can tell runs apart.
# Both paths execute the same NUMBER of frames, so if the machine ignored input
# in this window the states would match for any prefix length at all and the
# check would pass vacuously. These two controls close that hole, and the
# second is the exact failure the splice arithmetic risks.
# -----------------------------------------------------------------------------
echo "== control 1: the movie text must carry both halves exactly =="
# WHY TEXT AND NOT STATE, FOR THE TAIL.
#
# Measured: this boot lands in SMW's ATTRACT DEMO. Game mode is $14, which
# reads as "in a level", but Mario is driven by the demo script and player
# input is ignored - holding Right for 200 frames leaves marioX at $0080 and
# xspd at $00, and blanking the whole tail reproduces the state byte for byte.
#
# So a state comparison cannot prove the TAIL was carried; it can only prove
# the PREFIX arithmetic, which is what control 2 exercises. Claiming the
# state identity covers both would be the vacuous-check trap wearing the
# strongest-comparison badge. The tail is therefore proved where its evidence
# actually lives - in the movie text - by requiring the spliced file to be
# the origin's first N frames followed by the recorded tail, in order.
python3 - "$WORK/origin.zmov" "$WORK/spliced.zmov" "$PREFIX" <<'PY' && ok "prefix region is the origin's first N frames, verbatim" || bad "prefix region does not match the origin movie"
import sys
origin, spliced, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
# `.` is the format's optional padding character and serialize() writes a bare
# empty line for a blank frame, so compare the BUTTONS each line denotes
# rather than its spelling.
def body(p):
    return [frozenset(l.replace(".", ""))
            for l in open(p).read().splitlines() if not l.startswith("#")]
o, s = body(origin), body(spliced)
if o[:n] == s[:n]:
    sys.exit(0)
for i, (a, b) in enumerate(zip(o[:n], s[:n])):
    if a != b:
        print(f"  prefix frame {i}: origin {sorted(a)}, spliced {sorted(b)}")
        break
sys.exit(1)
PY

# The tail the recorder captured is re-derived from the same --input schedule
# rather than read back from the artifact under test, so this compares the
# movie against the intent, not against itself.
python3 - "$WORK/spliced.zmov" "$PREFIX" "$TAIL" <<'PY' && ok "tail region matches the input schedule that was run" || bad "tail region does not match the inputs the run was given"
import sys
spliced, n, tail = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
body = [l for l in open(spliced).read().splitlines() if not l.startswith("#")]
got = body[n:]
if len(got) != tail:
    print(f"  tail is {len(got)} frames, expected {tail}")
    sys.exit(1)
# Mirrors --input 5:R:190 --input 40:A:12 --input 120:A:10 (events OR together).
def want(f):
    b = set()
    if 5 <= f < 195: b.add("R")
    if 40 <= f < 52: b.add("A")
    if 120 <= f < 130: b.add("A")
    return b
for f, line in enumerate(got):
    if set(line.replace(".", "")) != want(f):
        print(f"  tail frame {f}: got {line!r}, wanted {''.join(sorted(want(f))) or '.'}")
        sys.exit(1)
sys.exit(0)
PY

echo "== control 2: an off-by-one prefix must fail =="
# The state is written at the START of frame N, so the prefix is 0..N-1.
# Taking one frame too few shifts every tail input a frame early. This is the
# mistake the splice is one character away from, so it must be caught.
python3 - "$WORK/spliced.zmov" "$WORK/offby1.zmov" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines()
head = [l for l in lines if l.startswith("#")]
body = [l for l in lines if not l.startswith("#")]
open(dst, "w").write("\n".join(head + body[1:]) + "\n")   # one prefix frame short
PY
"$SHOT" "$ROM" $((PREFIX + TAIL)) "$WORK/e2.ppm" \
    --movie "$WORK/offby1.zmov" \
    --save-state-at "$want:$WORK/endE2.state" >"$WORK/e2.log" 2>&1
if cmp -s "$WORK/endB.state" "$WORK/endE2.state"; then
    bad "a prefix one frame short still matched - the check cannot catch the off-by-one it exists for"
else
    ok "an off-by-one prefix diverges, as it must"
fi

echo "== fallback: no sidecar means the tail is MARKED, not faked =="
cp "$WORK/st.state" "$WORK/bare.state"        # deliberately no .origin beside it
"$SHOT" "$ROM" 30 "$WORK/e.ppm" \
    --load-state "$WORK/bare.state" \
    --record-movie "$WORK/bare.zmov" >"$WORK/e.log" 2>&1 || {
    bad "run E failed"; cat "$WORK/e.log"; exit 1; }
grep -q '^# non-regenerable:' "$WORK/bare.zmov" \
    && ok "sidecar-less recording is marked non-regenerable" \
    || bad "sidecar-less recording carries no marking"
grep -q '^# start-origin:' "$WORK/bare.zmov" \
    && bad "an origin was invented with no sidecar to read it from" \
    || ok "no origin invented"

echo "== fallback: an unreachable origin still stamps the triple =="
sed '/^origin-file:/d' "$WORK/st.state.origin" > "$WORK/noloc.state.origin"
cp "$WORK/st.state" "$WORK/noloc.state"
"$SHOT" "$ROM" 30 "$WORK/f.ppm" \
    --load-state "$WORK/noloc.state" \
    --record-movie "$WORK/noloc.zmov" >"$WORK/f.log" 2>&1 || {
    bad "run F failed"; cat "$WORK/f.log"; exit 1; }
grep -q '^# start-origin:' "$WORK/noloc.zmov" \
    && ok "unlocatable origin is still stamped (the triple is complete)" \
    || bad "start-origin was dropped even though the sidecar carried it"

echo "== fallback: a sidecar describing a different state is discarded =="
sed 's/^start-sha256: ./start-sha256: f/' "$WORK/st.state.origin" > "$WORK/wrong.state.origin"
cp "$WORK/st.state" "$WORK/wrong.state"
"$SHOT" "$ROM" 30 "$WORK/g.ppm" \
    --load-state "$WORK/wrong.state" \
    --record-movie "$WORK/wrong.zmov" >"$WORK/g.log" 2>&1 || {
    bad "run G failed"; cat "$WORK/g.log"; exit 1; }
grep -q 'describes a different savestate' "$WORK/g.log" \
    && ok "mismatched sidecar rejected" \
    || bad "mismatched sidecar was believed"
grep -q '^# start-origin:' "$WORK/wrong.zmov" \
    && bad "a rejected sidecar's origin was stamped anyway" \
    || ok "rejected sidecar contributed nothing"

echo
if [ "$fails" -eq 0 ]; then
    echo "splice-verify: ALL CHECKS PASSED"
    exit 0
fi
echo "splice-verify: $fails CHECK(S) FAILED"
exit 1
