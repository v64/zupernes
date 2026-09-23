# Direct-page indirect CPU comparison

This is a small, game-independent 5A22 comparison against a pinned Mesen.
It is an addressing/result test, not a CPU timing or whole-emulator accuracy
claim. The generator creates an original 32 KiB LoROM; no commercial ROM or
extracted game data is required.

## Fast iteration

```
node test/mesen/dp_indirect_probe.mjs check
```

The command rebuilds the screenshot runner with ReleaseFast, runs the ROM for
two frames, requires its completion marker, and compares every result byte to
the frozen reference. It exits nonzero for any mismatch, missing completion,
build/run error, wrong fixture identity, or wrong ROM hash. Runs use fresh
`.zig-cache/dp-indirect/run-*` directories. A warm baseline run took 177 ms on
the setup machine; compilation after an edit can take longer.

The unmodified baseline at a51c724 passes 72/80 cases. Its eight failures are
emulation-mode boundary loads/stores through `(dp)`, `(dp,X)`, `(dp),Y` with
page-aligned D, and `(dp,X)` with unaligned D. The 72 passing cases are also
mandatory: native mode, non-boundary accesses, unaligned non-indexed pointers,
and long pointers must not be broken by a general wrapping change.

Each case sets E, D, DBR, X/Y and the relevant RAM explicitly. Six result bytes
record A, PHP and four possible store destinations, so both the selected
address and unintended writes are observable. Results are latched before the
completion marker and an idle loop. Mesen captures at execution of that loop;
ZuperNES captures later, after two frames. No state in the compared result
records changes in between. No timing equality is assumed or asserted.

## Reference and conflicting evidence

The committed fixture was captured twice from Mesen revision
`3b058f9fbf6f446028eab3a83c5a3db35b1b960a`, branch `atomic-snapshot`.
Both complete 128 KiB WRAM dumps were identical (SHA-256
`223dd17dc64ced9a0a22ec18f48b35970661bceab477f54d6254916dcbd715de`).
ROM and Mesen executable hashes are in `fixtures/dp-indirect.json`.
The certified app was copied into an isolated portable directory with cleared
Saves and AllZeros RAM initialization; the canonical app was not modified.

Relevant source at `/Users/v64/Repos/mesen-src`:

- `Core/SNES/SnesCpu.Shared.h`: GetDirectAddress,
  GetDirectAddressIndirectWord, GetDirectAddressIndirectWordWithPageWrap,
  GetDirectAddressIndirectLong.
- `Core/SNES/SnesCpu.Instructions.h`: AddrMode_DirInd, AddrMode_DirIdxIndX,
  AddrMode_DirIndIdxY, AddrMode_DirIndLng, AddrMode_DirIndLngIdxY.

Independent corroboration: Ares's [WDC65816 memory helpers](https://github.com/ares-emulator/ares/blob/master/ares/component/processor/wdc65816/memory.cpp)
(readDirect, readDirectX, readDirectN) distinguish the same cases.

The existing ZuperNES comment above addrDirectIndirect cites SingleStepTests
`e1 e 8669`. That vector really does fetch the pointer high byte at F500
rather than F400 with E=1/D=F400. It therefore conflicts with these Mesen ROM
results; it must not be described as agreeing, silently rewritten, or used to
claim that the present test proves real hardware behavior. The repository's
CPU is the SNES 5A22 target; reconcile/document this evidence boundary when
correcting its Mesen compatibility. This comparison does not settle every
possible WDC revision or establish a physical-console measurement.

## Regenerating independent evidence

Generate ROM, case metadata, and a Mesen Lua capture script:

```
node test/mesen/dp_indirect_probe.mjs generate /absolute/fresh/output
```

Run that directory's probe.sfc and probe.lua with a verified, isolated Mesen
`--testrunner <probe.sfc> <probe.lua> --timeout=30`. The script produces
wram.bin at the latched completion boundary. Repeated captures must agree.
The exported `records` function extracts result records and enforces the
completion marker. Refreshing expected fixtures is a reviewer operation,
never a way for a candidate implementation to make its own failures pass.

Local setup evidence and capture reproduction script are retained under
`/Users/v64/Repos/zuperworld/.oracle/glm-eval/dp-indirect/`.
