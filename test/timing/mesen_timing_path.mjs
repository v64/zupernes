#!/usr/bin/env node
// Reproducible Mesen side of the ordered-timing cross-oracle.
//
//   node test/timing/mesen_timing_path.mjs <out-dir>
//
// 1. certifies the Mesen checkout/binary (test/mesen/mesen-repo-guard.mjs);
// 2. stages a private copy of the reviewed app bundle with its battery-save
//    directory removed and deterministic settings (test/mesen/mesen-sandbox.mjs),
//    so no mutable canonical app state can leak into the measurement;
// 3. generates the copyright-free probe ROMs + Lua (test/mesen/timing_path_probe.mjs);
// 4. runs every probe headless (--testrunner) and the frame-geometry probe;
// 5. summarizes with test/mesen/summarize_timing_path.mjs into summary.json.
//
// The earlier checkpoint ran an uncertified ~/Repos/Mesen2 build directly. This
// runner replaces that with the certified 3b058f9 build in a sandbox.

import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { assertMesenRepo } from "../mesen/mesen-repo-guard.mjs";
import { stageMesenApp } from "../mesen/mesen-sandbox.mjs";

const outArg = process.argv[2];
if (!outArg) {
  console.error("usage: mesen_timing_path.mjs <out-dir>");
  process.exit(2);
}
const out = resolve(outArg);
mkdirSync(out, { recursive: true });

const guard = assertMesenRepo();
const mesen = stageMesenApp(out, guard);
const probes = join(out, "probes");

function must(cmd, args, label) {
  const p = spawnSync(cmd, args, { encoding: "utf8", timeout: 120000 });
  if (p.status !== 0) {
    throw new Error(`${label} failed (exit ${p.status}): ${(p.stderr || p.stdout).trim().split("\n").slice(-3).join(" | ")}`);
  }
  return p.stdout;
}

must("node", ["test/mesen/timing_path_probe.mjs", probes], "probe generation");
const irqSweep = [];
for (let h = 100; h <= 140; h += 2) irqSweep.push(`irq-h${h}`);
const cases = ["dma-normal", "dma-refresh", "dma-reverse", "dma-two-channel", "clc-refresh", "hdma", "irq", ...irqSweep];
for (const name of cases) {
  must(mesen, ["--testrunner", join(probes, name, "probe.sfc"), join(probes, name, "probe.lua"), "--timeout=30"], `Mesen ${name}`);
}
must(mesen, ["--testrunner", join(probes, "clc-refresh", "probe.sfc"), join(probes, "clc-refresh", "geometry.lua"), "--timeout=30"], "Mesen geometry");

const summary = must("node", ["test/mesen/summarize_timing_path.mjs", probes], "summary");
writeFileSync(join(out, "summary.json"), summary);
writeFileSync(join(out, "provenance.json"), JSON.stringify({ mesen: guard, cases }, null, 2) + "\n");
const s = JSON.parse(summary);
for (const [k, v] of Object.entries(s.dma)) console.log(`${k}: trigger->first source ${v.trigger_to_first_source}, source->dest ${v.source_to_destination}`);
console.log(`hdma: source H=${s.hdma.source_hclock} dest H=${s.hdma.destination_hclock}`);
console.log(`frame lengths: ${s.frame_lengths.join(", ")}`);
console.log(`summary: ${join(out, "summary.json")}`);
