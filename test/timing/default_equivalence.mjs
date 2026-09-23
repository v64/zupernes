#!/usr/bin/env node
// Default-path equivalence gate for the ordered-clock research line.
//
// The ordered wall owner (src/refresh_timing.zig) is OPT-IN. Until it is
// deliberately promoted, the default aggregate emulation path must stay
// bit-identical to the pinned oracle, because ZuperWorld compares its port
// against that path frame by frame. This gate runs the same ROMs for the same
// number of frames through a REFERENCE `screenshot` build (the pin) and a
// CANDIDATE build (this branch), then compares three independent outputs:
//
//   - the final framebuffer (PPM)          -> PPU / render-timing drift
//   - all 128 KiB of WRAM after the run    -> CPU / game-logic drift
//   - the full audio stream (WAV)          -> APU / DSP timing drift
//
// Any mismatch fails. Usage:
//   node test/timing/default_equivalence.mjs <ref-screenshot> <cand-screenshot> <out-dir> [frames]
//
// Both binaries run with cwd = this checkout so DSP-1 microcode resolves from
// test/dsp (gitignored; copyrighted dumps stay local). Games come from the
// gitignored test/games; missing ROMs are reported as SKIP, never as PASS.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve, basename } from "node:path";

const [refBin, candBin, outArg, framesArg] = process.argv.slice(2);
if (!refBin || !candBin || !outArg) {
  console.error("usage: default_equivalence.mjs <ref-screenshot> <cand-screenshot> <out-dir> [frames]");
  process.exit(2);
}
const frames = Number(framesArg ?? 1200);
const out = resolve(outArg);
mkdirSync(out, { recursive: true });

// Commercial games exercise the paths timing work touches: SMW (the
// ZuperWorld oracle itself), Super Mario Kart (DSP-1 blind-timed DMA reads),
// DKC/FF/Chrono (heavy HDMA and DMA), plus every hardware test ROM.
const games = [
  "Super Mario World (USA).sfc",
  "Super Mario Kart (USA).sfc",
  "Donkey Kong Country (USA) (Rev 2).sfc",
  "Chrono Trigger (USA).sfc",
  "Final Fantasy III (USA) (Rev 1).sfc",
  "Super Mario All-Stars (USA).sfc",
].map((g) => join("test/games", g));
const testRoms = readdirSync("test/snes-test-roms")
  .filter((f) => f.endsWith(".sfc") || f.endsWith(".smc"))
  .map((f) => join("test/snes-test-roms", f));

const sha = (p) => createHash("sha256").update(readFileSync(p)).digest("hex");

function run(bin, rom, tag) {
  const stem = join(out, `${basename(rom).replace(/[^A-Za-z0-9]+/g, "_")}.${tag}`);
  const args = [rom, String(frames), `${stem}.ppm`, "--dump-wram", `${stem}.wram`, "--wav", `${stem}.wav`];
  const p = spawnSync(resolve(bin), args, { encoding: "utf8", timeout: 600000 });
  if (p.status !== 0) return { error: `exit ${p.status}: ${(p.stderr || p.stdout).trim().split("\n").slice(-2).join(" | ")}` };
  return { ppm: sha(`${stem}.ppm`), wram: sha(`${stem}.wram`), wav: sha(`${stem}.wav`) };
}

const results = [];
let failed = 0;
for (const rom of [...games, ...testRoms]) {
  if (!existsSync(rom)) {
    results.push({ rom, status: "SKIP", reason: "ROM not present" });
    console.log(`SKIP ${rom} (not present)`);
    continue;
  }
  const ref = run(refBin, rom, "ref");
  const cand = run(candBin, rom, "cand");
  let status = "PASS";
  const diff = [];
  if (ref.error || cand.error) {
    // Both builds refusing the same ROM identically (e.g. an unsupported
    // coprocessor) is equivalent behavior; anything else is a failure.
    status = ref.error === cand.error ? "PASS" : "FAIL";
    if (status === "FAIL") diff.push(`ref: ${ref.error ?? "ok"}; cand: ${cand.error ?? "ok"}`);
  } else {
    for (const k of ["ppm", "wram", "wav"]) if (ref[k] !== cand[k]) diff.push(k);
    if (diff.length) status = "FAIL";
  }
  if (status === "FAIL") failed++;
  results.push({ rom, status, diff, ref, cand });
  console.log(`${status} ${rom}${diff.length ? " differs: " + diff.join(", ") : ""}`);
}
writeFileSync(join(out, "results.json"), JSON.stringify({ frames, refBin, candBin, results }, null, 2) + "\n");
const skipped = results.filter((r) => r.status === "SKIP").length;
console.log(`${failed ? "FAIL" : "PASS"}: ${results.length - skipped - failed} identical, ${failed} different, ${skipped} skipped (${frames} frames)`);
process.exit(failed ? 1 : 0);
