# HVBJOY mapped-read timing experiment

This bounded, copyright-free experiment isolates `$4212` (`HVBJOY`) sampling.
It proposes one generic ZuperNES correction on branch
`arch/hvbjoy-access-time-sol`; it does not change the canonical oracle pin and
does not claim that CPU or raster timing is otherwise complete.

## Defect and minimal correction

`Cpu.accountAccess` calls `Bus.setCpuAccessTiming` before each bus access. That
advances `interrupt_horizon_master` to the end of the access while the PPU
itself remains at the committed instruction-start position until
`Emulator.step` finishes. Pinned `$4212` reads `self.ppu.scanline` and
`self.ppu.dot` directly, so `BIT $4212` samples instruction start.

The first version of this experiment incorrectly sampled the end-of-access
horizon and treated Mesen's Lua read-callback timestamp as the sample. Clean
Mesen2 source `3b058f9fbf6f446028eab3a83c5a3db35b1b960a` establishes a distinct
handler phase:

1. `SnesCpu::Read` selects the six-master I/O speed for `$4212`.
2. `SnesMemoryManager::_execRead` advances two masters for a six-master read.
3. `InternalRegisters::Read($4212)` samples the H-clock and returns the value.
4. `SnesMemoryManager::Read` advances four more masters.
5. `ProcessMemoryRead` invokes the Lua callback.

Thus an ordinary SlowROM `BIT abs` starts 26 masters before the mapped handler
and 30 masters before the Lua callback. A callback timestamp is evidence for
the handler timestamp only when the final four-master interval contains no
event stall.

The corrected candidate records an explicit `cpu_read_sample_master` at the
mapped-read handler phase. `$4212` uses that beam. It does not subtract four
inside the register handler or derive the sample from the access-end horizon.
This separation is required for a future refresh model to place a stall before
or after the handler without moving both timestamps together. The current
candidate still has no refresh event and therefore is not pin-ready.

The handler phase also carries explicit validity. CPU read accounting sets it;
instruction completion, reset, savestate restore, standalone DMA, and each DMA
timing step clear it. Direct/debug reads and DMA A-bus reads therefore use the
committed PPU beam unless their caller has declared a phase. The last handler
beam remains available only through a diagnostic accessor for the synthetic
test. This prevents an unrelated `$4212` read from reusing an earlier CPU
sample after the instruction or machine lifecycle has moved on.

Mesen's current `$4212` rule reports HBlank for H-clock `< 4` or `> 274*4`.
The candidate retains its observable half-cycle: H=274 residual 0 is active,
while residuals 1 through 3 are HBlank. Mesen's CPU advances in two-master
steps in this experiment, so the independent execution directly reaches
residuals 0 and 2; the Zig tests retain residuals 1 and 3 as edge controls.

## Direct synthetic test

The Zig test installs a 19-byte WaitForHBlank program in WRAM, which has the
same eight-master access price as SlowROM. It starts the program directly at
the retained call boundaries, records every `BIT` handler beam and V flag,
then executes the following `BVS` or `BVC` and records its destination. It
includes the six retained tide controls, residuals 0 through 3, the H=274
half-cycle, and alternate delay-loop Y values.

The corrected candidate changes the pinned-profile results as follows. These
remain ZuperNES results because the profile still omits refresh and several
CPU cycles.

| call boundary | Y | pinned instruction-start return | handler-time candidate return |
| --- | ---: | --- | --- |
| 36:105 residual 2 | 31 | 37:190 residual 2 | 37:177 residual 2 |
| 36:105 residual 0 | 31 | 37:190 residual 0 | 37:177 residual 0 |
| 36:109 residual 2 | 31 | 37:181 residual 2 | 37:181 residual 2 |
| 36:109 residual 0 | 31 | 37:194 residual 0 | 37:181 residual 0 |
| 36:102 residual 2 | 31 | 37:187 residual 2 | 37:187 residual 2 |
| 36:103 residual 2 | 31 | 37:188 residual 2 | 37:175 residual 2 |
| 36:109 residual 1 | 31 | 37:194 residual 1 | 37:181 residual 1 |
| 36:109 residual 3 | 31 | 37:181 residual 3 | 37:181 residual 3 |
| 36:102 residual 0 | 31 | 37:187 residual 0 | 37:187 residual 0 |
| 36:102 residual 1 | 31 | 37:187 residual 1 | 37:187 residual 1 |
| 36:109 residual 0 | 7 | 37:14 residual 0 | 37:1 residual 0 |
| 36:109 residual 0 | 32 | 37:201 residual 2 | 37:188 residual 2 |

Every case asserts its exact return line, dot, residual, and read count. More
directly, every read asserts that the returned V flag matches its handler beam,
and every conditional branch asserts the destination selected by that flag.
The alternate-Y controls change only the post-poll delay and retain the same
poll decision, so Y cannot act as a fitted span selector.

Two groups distinguish handler time from access end. Calls at 36:102 place the
decisive access end on H=274, but its handler is four masters earlier; all four
residuals stay active and take another polling iteration. Calls at 36:103 put
the handler on H=274 itself: residual 0 stays active, while residuals 1, 2, and
3 return HBlank. The test also drives a direct register read that ends at
H=274 residual 2 but samples at H=273 residual 2 and must return active.

## Independent Mesen execution

`test/mesen/hvbjoy_access_probe.mjs` generates a 32 KiB ROM from literal
instructions plus a Lua trace. The ROM disables interrupts and HDMA, varies a
small delay before each call, and contains no commercial ROM data. The Lua
trace records the instruction start, post-read callback H-clock and value, the
following branch, and the next executed PC.

Run both semantic delay-loop controls:

```sh
node test/mesen/hvbjoy_access_probe.mjs .oracle/mesen-hvbjoy/y31 31 160
/path/to/Mesen --testrunner .oracle/mesen-hvbjoy/y31/hvbjoy-y31.sfc .oracle/mesen-hvbjoy/y31/hvbjoy-y31.lua
node test/mesen/hvbjoy_access_probe.mjs .oracle/mesen-hvbjoy/y7 7 160
/path/to/Mesen --testrunner .oracle/mesen-hvbjoy/y7/hvbjoy-y7.sfc .oracle/mesen-hvbjoy/y7/hvbjoy-y7.lua
node test/mesen/summarize_hvbjoy_access.mjs .oracle/mesen-hvbjoy/y31/hvbjoy-y31.tsv .oracle/mesen-hvbjoy/y7/hvbjoy-y7.tsv
```

The local run used the established Mesen application at
`/Users/v64/Repos/Mesen2/Mesen.app/Contents/MacOS/Mesen` and the independently
inspected clean source revision above.

The analyzer does not subtract four globally. It limits handler reconstruction
to callbacks from H-clock 600 through 1102. This interval is after Mesen's
line refresh position near H-clock 538 and ends before the H=276 event at
H-clock 1104. Therefore the final four-master handler-to-callback interval is
event-free. Reads outside this interval are excluded from sample-phase claims.

| Y | calls | reads | callback latency | event-free handler reads | start/handler disagreements | H=274 r0 active | H=274 r2 HBlank | branches |
| ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 31 | 160 | 2320 | 30 or 70 masters | 1307 | 3 | 6/6 | 3/3 | 2320/2320 correct |
| 7 | 160 | 1940 | 30 or 70 masters | 1229 | 6 | 3/3 | 6/6 | 1940/1940 correct |

All 2,536 reconstructed event-free handler samples agree with the returned
HBlank bit. The nine start/handler disagreements all have instruction start at
H-clock 1072 (active), handler at 1098 (H=274 residual 2, HBlank), and callback
at 1102. The following branches use the HBlank value. At the other side of the
edge, nine reads have handler H-clock 1096 (H=274 residual 0) and all return
active. This is direct execution evidence for handler-time sampling at the
specific half-cycle boundary.

All 4,260 branches follow their returned values, which validates the control
flow probe but does not by itself locate the sample phase. The 70-master
callback latencies include Mesen's 40-master refresh event. Their handler phase
is intentionally not reconstructed because the trace does not reveal whether
the stall occurred before or after the handler.

The retained local artifact hashes are unchanged:

| artifact | SHA-256 |
| --- | --- |
| Y=31 ROM | `948250aaf0e1f13af49d42d510ab9a813248f0b64fe3680d5be4b553668c4386` |
| Y=31 Lua | `828555b2438bdab131f6ac360ac40517aca0cf9a983110857e9ece8bd7ac74be` |
| Y=31 trace | `b2ae7ff591a6c9b9ef2ea841f8729771b70c46fb99265602f703443860f638c6` |
| Y=7 ROM | `e9f880dadbd28a4e5406058fe0c765c014e8f64ff1ce2997384963818e61b67d` |
| Y=7 Lua | `9fc99cd2240989e8b6ba5bc7cceb6b83032b8bc6fe5bd22708be3fd71d05a296` |
| Y=7 trace | `7e1421277c47e70ec45b9eba9c6887404a4f31a9acd3a747b05d6e64fe09dd7b` |

## Scope boundary

The source order and event-free execution establish Mesen's mapped-handler
phase and justify correcting the pinned oracle's instruction-start sample.
They do not justify promoting this branch as a new oracle pin. The candidate
retains the pin's missing 40-master refresh event and existing CPU instruction
timings. JSR, DEY, RTS, and other implied or stack operations still need the
separately scoped cycle audit.

For T3, the causal conclusion remains narrow: the frame-166 residual split in
the old tide capture is not a stable timing class. With handler-time sampling,
both 36:109 residual paths take the same poll count and return at dot 181 in
the candidate profile. A runtime span chosen from the old 13-dot difference
would encode an oracle artifact. Hardware-faithful tide write dots must wait
for the remaining CPU/refresh work and a new independently reviewed oracle
pin; existing canonical evidence stays historical and unchanged.
