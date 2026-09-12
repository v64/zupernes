# HVBJOY CPU-access timing experiment

This bounded, copyright-free experiment isolates `$4212` (`HVBJOY`) sampling.
It proposes one generic ZuperNES correction on branch
`arch/hvbjoy-access-time-sol`; it does not change the canonical oracle pin and
does not claim that CPU or raster timing is otherwise complete.

## Defect and minimal correction

`Cpu.accountAccess` already calls `Bus.setCpuAccessTiming` before each bus
access. That advances `interrupt_horizon_master` to the end of the access while
the PPU itself remains at the committed instruction-start position until
`Emulator.step` finishes. `$4210` and `$4211` consult that projected horizon,
but pinned `$4212` reads `self.ppu.scanline` and `self.ppu.dot` directly. A
`BIT $4212` can therefore return the blanking state from 30 master clocks
earlier than its I/O read.

The candidate adds `Bus.cpuAccessBeam`, derived from the later of the committed
PPU master and the current access horizon, and uses it for all three `$4212`
fields. This is a general CPU-register rule; it does not recognize a game,
routine, scenario, frame, or expected output.

The exact horizontal edge also matters. Clean Mesen2 source
`3b058f9fbf6f446028eab3a83c5a3db35b1b960a` reads the current H-clock in
`InternalRegisters::Read($4212)` after `SnesMemoryManager::Read` has executed
the bus cycle. It reports HBlank for H-clock `< 4` or `> 274*4`. The candidate
uses the same counter rule, retaining the observable half-cycle: H=274
residual 0 is active display, while residuals 1 through 3 are HBlank.

## Direct synthetic test

The Zig test installs a 19-byte WaitForHBlank program in WRAM, which has the
same eight-master access price as SlowROM. It starts the program directly at
the retained call boundaries, records every `BIT` access beam and V flag, then
executes the following `BVS` or `BVC` and records its destination. It includes
the six retained tide controls, residuals 1 and 3, the H=274 residual edge, and
alternate delay-loop Y values.

The candidate changes the pinned-profile results as follows. These remain
ZuperNES results because the profile still omits refresh and several CPU
cycles.

| call boundary | Y | pinned instruction-start return | access-time candidate return |
| --- | ---: | --- | --- |
| 36:105 residual 2 | 31 | 37:190 residual 2 | 37:177 residual 2 |
| 36:105 residual 0 | 31 | 37:190 residual 0 | 37:177 residual 0 |
| 36:109 residual 2 | 31 | 37:181 residual 2 | 37:181 residual 2 |
| 36:109 residual 0 | 31 | 37:194 residual 0 | 37:181 residual 0 |
| 36:102 residual 2 | 31 | 37:187 residual 2 | 37:174 residual 2 |
| 36:103 residual 2 | 31 | 37:188 residual 2 | 37:175 residual 2 |
| 36:109 residual 1 | 31 | 37:194 residual 1 | 37:181 residual 1 |
| 36:109 residual 3 | 31 | 37:181 residual 3 | 37:181 residual 3 |
| 36:102 residual 0 | 31 | 37:187 residual 0 | 37:187 residual 0 |
| 36:102 residual 1 | 31 | 37:187 residual 1 | 37:174 residual 1 |
| 36:109 residual 0 | 7 | 37:14 residual 0 | 37:1 residual 0 |
| 36:109 residual 0 | 32 | 37:201 residual 2 | 37:188 residual 2 |

Every access-time case asserts its exact return line/dot/residual and read
count. More directly, every read asserts that the returned V flag matches its
projected access beam, and every conditional branch asserts the destination
selected by that flag. The alternate-Y controls change only the post-poll
delay. They retain the same extra-poll decision, so Y cannot accidentally act
as a fitted span selector.

The H=274 controls are discriminating. Starting the call at 36:102 residual 0
places the decisive access at H=274 residual 0, which remains active and takes
one more 52-master polling iteration. Residuals 1, 2, and 3 return HBlank on
that access and leave immediately. A dot-only model cannot express this.

## Independent Mesen execution

`test/mesen/hvbjoy_access_probe.mjs` generates a 32 KiB ROM from literal
instructions plus a Lua trace. The ROM disables interrupts and HDMA, varies a
small delay before each call, and contains no commercial ROM data. The Lua
trace records the instruction-start and actual-access H-clock of every `$4212`
read, its value, the following branch, and the next executed PC.

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
inspected clean source revision above:

| Y | calls | reads | read latency | start/access blanking disagreements | branch outcomes |
| ---: | ---: | ---: | --- | ---: | --- |
| 31 | 160 | 2320 | 30 or 70 masters | 94 (84 entering, 10 leaving) | 2320/2320 correct |
| 7 | 160 | 1940 | 30 or 70 masters | 84 (80 entering, 4 leaving) | 1940/1940 correct |

The ordinary `BIT abs` path is 30 masters: three eight-master SlowROM fetches
plus the six-master I/O read. The 70-master cases cross Mesen's independent
40-master DRAM-refresh event. For example, Y=31 call 2 begins a `BIT` at
scanline 2 H-clock 1092, performs the read at H-clock 1122, returns `$42`, and
the following `BVC` falls through to the delay loop. An instruction-start
sample would have returned active display for that same operation.

The retained local artifact hashes are:

| artifact | SHA-256 |
| --- | --- |
| Y=31 ROM | `948250aaf0e1f13af49d42d510ab9a813248f0b64fe3680d5be4b553668c4386` |
| Y=31 Lua | `828555b2438bdab131f6ac360ac40517aca0cf9a983110857e9ece8bd7ac74be` |
| Y=31 trace | `b2ae7ff591a6c9b9ef2ea841f8729771b70c46fb99265602f703443860f638c6` |
| Y=7 ROM | `e9f880dadbd28a4e5406058fe0c765c014e8f64ff1ce2997384963818e61b67d` |
| Y=7 Lua | `9fc99cd2240989e8b6ba5bc7cceb6b83032b8bc6fe5bd22708be3fd71d05a296` |
| Y=7 trace | `7e1421277c47e70ec45b9eba9c6887404a4f31a9acd3a747b05d6e64fe09dd7b` |

## Scope boundary

This source comparison and synthetic execution independently justify the
access-time `$4212` correction. They do not justify promoting this branch as a
new oracle pin. The candidate intentionally retains the pin's missing
40-master refresh event and its existing CPU instruction timings. Mesen's
synthetic endpoint differs for those reasons: JSR, DEY, RTS, and other implied
or stack operations still need the separately scoped cycle audit, and a
refresh crossing changes individual read intervals from 30 to 70 masters.

For T3, the causal conclusion is narrower and useful: the frame-166 residual
split in the old tide capture is not a stable hardware timing class. With
access-time sampling both 36:109 residual paths take the same poll count and
return at dot 181 in the candidate profile. A runtime span chosen from the old
13-dot difference would encode an oracle artifact. Hardware-faithful tide
write dots must wait for the remaining CPU/refresh work and a new independently
reviewed oracle pin; existing canonical evidence stays historical and
unchanged.
