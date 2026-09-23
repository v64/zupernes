#!/usr/bin/env node
// Mesen2 side of the per-frame WRAM log (see test/timing/frame_log.zig).
//
//   node test/timing/mesen_frame_log.mjs <rom> <frames> <out.tsv> [--dump-every N] ADDR...
//
// Runs the certified Mesen 3b058f9 build in a private sandbox with
// RamPowerOnState = AllOnes, matching ZuperNES's $FF power-on WRAM (the
// shared sandbox helper stages AllZeros for the synthetic timing probes,
// whose results do not depend on RAM contents). Each row: the index of the
// frame that just started (Mesen's startFrame event), then the WRAM bytes.
// Only rows are compared; neither side receives input.

import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { assertMesenRepo } from "../mesen/mesen-repo-guard.mjs";
import { stageMesenApp } from "../mesen/mesen-sandbox.mjs";

const argv = process.argv.slice(2);
let dumpEvery = 0;
const di = argv.indexOf("--dump-every");
if (di >= 0) { dumpEvery = Number(argv[di + 1]); argv.splice(di, 2); }
let execAddr = null, execEvery = 0;
const ei = argv.indexOf("--exec-dump");
if (ei >= 0) { execAddr = argv[ei + 1]; execEvery = Number(argv[ei + 2]); argv.splice(ei, 3); }
const [romArg, framesArg, outArg, ...addrs] = argv;
if (!romArg || !framesArg || !outArg || addrs.length === 0) {
  console.error("usage: mesen_frame_log.mjs <rom> <frames> <out.tsv> ADDR...");
  process.exit(2);
}
const out = resolve(outArg);
const work = join(dirname(out), "mesen-frame-log-sandbox");
mkdirSync(work, { recursive: true });
const guard = assertMesenRepo();
const mesen = stageMesenApp(work, guard);
const settings = join(dirname(mesen), "settings.json");
const config = JSON.parse(readFileSync(settings, "utf8").replace(/^﻿/, ""));
config.Snes.RamPowerOnState = "AllOnes";
writeFileSync(settings, JSON.stringify(config, null, 2) + "\n");

const reads = addrs.map((a) => `string.format("%02x", emu.read(0x${a}, emu.memType.snesWorkRam))`).join(' .. "\\t" .. ');
const lua = `local out = assert(io.open(${JSON.stringify(out)}, "w"))
local n = 0
emu.addEventCallback(function()
  n = n + 1
  out:write(n .. "\\t" .. ${reads} .. "\\n")
  if ${dumpEvery} > 0 and n % ${dumpEvery} == 0 then
    local d = assert(io.open(${JSON.stringify(out)} .. "." .. n .. ".wram", "wb"))
    local chunk = {}
    for a = 0, 0x1FFFF do
      chunk[#chunk + 1] = string.char(emu.read(a, emu.memType.snesWorkRam))
      if #chunk == 4096 then d:write(table.concat(chunk)); chunk = {} end
    end
    d:close()
  end
  if n >= ${Number(framesArg)} then out:close(); emu.stop(0) end
end, emu.eventType.startFrame)
${execAddr ? `local ec = 0
emu.addMemoryCallback(function()
  ec = ec + 1
  if ec % ${execEvery} == 0 then
    local d = assert(io.open(${JSON.stringify(out)} .. ".exec" .. ec .. ".wram", "wb"))
    local chunk = {}
    for a = 0, 0x1FFFF do
      chunk[#chunk + 1] = string.char(emu.read(a, emu.memType.snesWorkRam))
      if #chunk == 4096 then d:write(table.concat(chunk)); chunk = {} end
    end
    d:close()
  end
end, emu.callbackType.exec, 0x${execAddr}, 0x${execAddr}, emu.cpuType.snes, emu.memType.snesMemory)` : ""}
`;
const luaPath = join(work, "frame-log.lua");
writeFileSync(luaPath, lua);
const p = spawnSync(mesen, ["--testrunner", resolve(romArg), luaPath, "--timeout=600"], { encoding: "utf8", timeout: 900000 });
if (p.status !== 0) {
  console.error((p.stderr || p.stdout).trim());
  process.exit(1);
}
console.log(`wrote ${out}`);
