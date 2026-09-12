# Ordered timing path cross-oracle checkpoint

This checkpoint tests the opt-in ordered wall owner against copyright-free
Mesen controls. It is based on frozen ZuperNES research revision
`39aa19213304ca386661a5d667b3f6578af67d6d`; the canonical oracle remains at
`e17dc5e3f68b417db8351b091885c4af921a2b3d` and is not promoted. Independent
source is Mesen revision
`3b058f9fbf6f446028eab3a83c5a3db35b1b960a`.

Generate and run the probes:

```sh
node test/mesen/timing_path_probe.mjs .oracle/mesen-timing-path
for case_name in dma-normal dma-refresh dma-reverse dma-two-channel clc-refresh hdma irq; do
  /Users/v64/Repos/Mesen2/Mesen.app/Contents/MacOS/Mesen --testrunner \
    .oracle/mesen-timing-path/$case_name/probe.sfc \
    .oracle/mesen-timing-path/$case_name/probe.lua
done
/Users/v64/Repos/Mesen2/Mesen.app/Contents/MacOS/Mesen --testrunner \
  .oracle/mesen-timing-path/clc-refresh/probe.sfc \
  .oracle/mesen-timing-path/clc-refresh/geometry.lua
node test/mesen/summarize_timing_path.mjs .oracle/mesen-timing-path
```

The local summary SHA-256 is
`c104dc11f91631a5865bcb53901c72692a3a02f2b41985a087874dd1d6ae8f7b`.
The generator and summarizer hashes are respectively
`d0a047b8d71c6c52a1dbedb8546ad58ebe5c991383ad9cb85e7e1786e775f586`
and
`f942b4f8ea501d789e688d2936340748223f9a9929c96f7c50925a7ec2b0240c`.

## Results

The CLC control has 4,869 sequential 14-master spans and 52 spans of 54
masters, with no third class. The first deliberately aligned case enters the
CLC opcode callback at H=532. Mesen then runs `AddrMode_Imp`'s six-master
`IdleOrRead` before changing carry; refresh fires at H=538 and the next opcode
callback is H=586. This independently supports the candidate's pre-effect
phase and 40-master refresh placement.

General DMA establishes a narrower pass and a material failure:

| control | `$420B` handler to first source | source to destination |
| --- | ---: | ---: |
| one channel, A to B | 34 | 4 |
| one channel, B to A | 34 | 4 |
| one channel crossing refresh | 70 | 4 |
| two channels | 32 | 4 |

For the two-channel control, the first destination is master 1040 and the
second source is 1052. This preserves the next channel's own overhead. In the
boundary control, `$420B` is handled at line 1 H=522, refresh fires during the
controller start sequence, the source is sampled at H=592, and the destination
effect is H=596.

The candidate's same copyright-free normal ROM starts `STA $420B` at wall 426,
reaches the handler at 456, samples at 460, and writes at 464. Its four-master
source/destination split is correct, but DMA still runs synchronously in the
`$420B` handler. Mesen's control flow defers it through a CPU cycle, aligns the
controller to the reset-relative eight-master phase, then charges global and
per-channel work before the source. The missing 30 masters in this one case is
not a constant to add: the normal, boundary, and two-channel controls vary it.

The first valid HDMA data byte is sampled at line 0 H=1132 and written at
H=1136. The candidate's current fixture writes at H=1146. This rejects its
existing H=278 event plus fixed 18+8 overhead as a hardware model, while again
confirming four masters between source and destination. HDMA must use the same
pending CPU-halt/alignment machinery as general DMA, with its descriptor reads
and per-channel work kept in execution order.

Mesen frame-start callbacks give consecutive NTSC non-interlace field lengths
357364, 357368, and 357364 masters. Source inspection locates the short line at
odd-frame V=240 with length 1360 rather than 1364. The candidate PPU still
reports 357368 for every field. The wall owner can accept actual line
boundaries, but the live PPU does not yet supply this geometry.

The IRQ control services the configured H-IRQ and enters `$008100` at master
488; its handler marker write occurs at 598. Candidate fixtures exercise the
actual opt-in interrupt sampler, including a refresh-stretched final internal
cycle. This is bounded support for the ordered sampler, not proof of all
interrupt paths: the conditional `IdleOrRead` next-PC dummy read remains
unimplemented.

Every candidate ordered CPU, DMA, HDMA, and refresh segment advances the APU
and DSP accumulator. Its cross-refresh savestate test proves complete state
equality after matching-profile restore. It does not prove PCM equivalence.
Malformed timing-profile restore is rejected before mutation; a valid-profile
state with a malformed refresh schedule can still partially mutate the target
before rejection.

## Remaining acceptance bar

The smallest next implementation is a controller state machine driven at real
CPU cycle boundaries: `$420B` records pending DMA, the first eligible CPU cycle
supplies the start delay, the shared wall phase supplies 2--8-master alignment,
and global/per-channel/byte/end phases advance the existing owner. HDMA uses
the same halt path. Tests must vary alignment, direction, channel count, and a
refresh inside the start phase; copying the observed 30- or 14-master gaps as
constants would fail these controls.

Separately, PPU line-boundary ownership must include the odd non-interlace
V=240 short line and serialized parity. Conditional `IdleOrRead`, atomic
malformed-schedule restore, and broader opcode/interrupt coverage remain
promotion gates. Only after those generic controls and independent review
should a candidate-identity SMW A/B inspect the Iris and tide timing inputs.
That diagnostic would assess T3 evidence; it would not be an acceptance capture
from the fixed canonical pin.

Completing the controller state machine, geometry integration, independent
review, synthetic reruns, and one bounded SMW A/B is likely another focused
workday. A general T3 timing model may take longer if the controls expose more
CPU or PPU phase gaps.
