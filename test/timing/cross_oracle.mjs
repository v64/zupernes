#!/usr/bin/env node
// Ordered-timing cross-oracle: ZuperNES vs Mesen2 on copyright-free probes.
//
//   node test/timing/cross_oracle.mjs <mesen-out-dir> [timing-trace-binary]
//
// <mesen-out-dir> is the output of test/timing/mesen_timing_path.mjs (probe
// ROMs + Mesen traces). For each probe ROM this runs ZuperNES's timing-trace
// tool (ordered wall owner, from power-on) and compares the SAME events at
// ABSOLUTE instants: master clock since power-on, scanline and H-clock.
// Intervals are not enough - both emulators start from the same 186-master
// power-on origin, so agreement must be exact, and every mismatch is
// reported with both sides' positions.
//
// Values (e.g. open-bus bits of $4212/$2137) are recorded but are not part
// of this timing comparison.

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";

const [mesenArg, binArg] = process.argv.slice(2);
if (!mesenArg) {
  console.error("usage: cross_oracle.mjs <mesen-out-dir> [timing-trace-binary]");
  process.exit(2);
}
const probes = join(resolve(mesenArg), "probes");
const bin = resolve(binArg ?? "zig-out/bin/timing-trace");
const out = join(resolve(mesenArg), "zupernes");
mkdirSync(out, { recursive: true });

function tsv(path) {
  const [head, ...lines] = readFileSync(path, "utf8").trim().split("\n");
  const cols = head.split("\t");
  return lines.map((l) => Object.fromEntries(l.split("\t").map((v, i) => [cols[i], v])));
}
function trace(name, frames, execRange) {
  const file = join(out, `${name}.tsv`);
  const args = [join(probes, name, "probe.sfc"), file, "--frames", String(frames)];
  if (execRange) args.push("--exec", ...execRange);
  const p = spawnSync(bin, args, { encoding: "utf8" });
  if (p.status !== 0) throw new Error(`timing-trace ${name}: ${p.stderr}`);
  return tsv(file);
}
const at = (r) => ({ master: Number(r.master), line: Number(r.line), hclock: Number(r.hclock) });

const results = [];
function compare(caseName, label, mesenRows, oursRows, limit = Infinity) {
  const n = Math.min(limit, Math.max(mesenRows.length, oursRows.length));
  let ok = true;
  const diffs = [];
  for (let i = 0; i < n; i++) {
    const m = mesenRows[i], z = oursRows[i];
    if (!m || !z) { ok = false; diffs.push({ i, mesen: m && at(m), zupernes: z && at(z) }); continue; }
    const a = at(m), b = at(z);
    if (a.master !== b.master || a.line !== b.line || a.hclock !== b.hclock) {
      ok = false;
      if (diffs.length < 3) diffs.push({ i, mesen: a, zupernes: b });
    }
  }
  results.push({ case: caseName, event: label, compared: n, pass: ok, diffs });
  const first = diffs[0];
  console.log(`${ok ? "PASS" : "FAIL"} ${caseName} ${label} (${n})` +
    (first ? `  first diff #${first.i}: mesen ${JSON.stringify(first.mesen)} zupernes ${JSON.stringify(first.zupernes)}` : ""));
}

// ---- general DMA: trigger, every source read, every destination write ----
for (const name of ["dma-normal", "dma-refresh", "dma-reverse", "dma-two-channel"]) {
  const m = tsv(join(probes, name, "trace.tsv"));
  const z = trace(name, 1);
  compare(name, "$420B write", m.filter((r) => r.event === "mdma_write"), z.filter((r) => r.event === "cpu_write" && r.address === "00420b"));
  const srcAddrs = new Set(m.filter((r) => r.event === "dma_source").map((r) => r.address));
  const dstAddrs = new Set(m.filter((r) => r.event === "dma_dest").map((r) => r.address));
  compare(name, "DMA source", m.filter((r) => r.event === "dma_source"), z.filter((r) => r.event === "dma_read" && srcAddrs.has(r.address)));
  compare(name, "DMA destination", m.filter((r) => r.event === "dma_dest"), z.filter((r) => r.event === "dma_write" && dstAddrs.has(r.address)));
}

// ---- CPU + refresh: every opcode fetch of the CLC loop (Mesen records 5000) ----
{
  const m = tsv(join(probes, "clc-refresh", "trace.tsv")).map((r) => ({ ...r, event: "exec" }));
  const z = trace("clc-refresh", 1, ["008100", "00813f"]).filter((r) => r.event === "exec");
  compare("clc-refresh", "opcode fetch", m, z, m.length);
}

// ---- frame geometry: Mesen startFrame events (frames 1..4) ----
{
  const m = tsv(join(probes, "clc-refresh", "geometry.tsv"));
  const file = join(out, "geometry.tsv");
  const p = spawnSync(bin, [join(probes, "clc-refresh", "probe.sfc"), file, "--frames", String(m.length + 1)], { encoding: "utf8" });
  if (p.status !== 0) throw new Error(p.stderr);
  const z = tsv(file).filter((r) => r.event === "frame_start" && Number(r.master) > 0);
  compare("geometry", "frame start", m, z, m.length);
}

// ---- HDMA: enable write, table/data reads, destination write ----
{
  const m = tsv(join(probes, "hdma", "trace.tsv"));
  const z = trace("hdma", 2);
  compare("hdma", "$420C write", m.filter((r) => r.event === "hdma_enable"), z.filter((r) => r.event === "cpu_write" && r.address === "00420c"));
  compare("hdma", "HDMA table/data read", m.filter((r) => r.event === "hdma_source"),
    z.filter((r) => r.event === "dma_read" && ["7e0100", "7e0101", "7e0102"].includes(r.address)), m.filter((r) => r.event === "hdma_source").length);
  compare("hdma", "HDMA destination", m.filter((r) => r.event === "hdma_dest"),
    z.filter((r) => r.event === "dma_write" && r.address === "002100"), 1);
}

// ---- IRQ: handler entry and its first write ----
{
  const m = tsv(join(probes, "irq", "trace.tsv"));
  const z = trace("irq", 1, ["008100", "008100"]);
  compare("irq", "handler entry", m.filter((r) => r.event === "handler_exec"), z.filter((r) => r.event === "exec"), 1);
  compare("irq", "handler write", m.filter((r) => r.event === "handler_write"), z.filter((r) => r.event === "cpu_write" && r.address === "000100"), 1);
}

// ---- IRQ sweep: interrupts sampled on every cycle of a NOP/JMP loop,
// including NOP's implied IdleOrRead (a real read when an IRQ is imminent).
for (const kind of ["irq", "wai"]) for (let h = 100; h <= 140; h += 2) {
  const name = `${kind}-h${h}`;
  const m = tsv(join(probes, name, "trace.tsv"));
  const z = trace(name, 1, ["008100", "008100"]);
  compare(name, "handler entries", m.filter((r) => r.event === "handler_exec"), z.filter((r) => r.event === "exec"), m.filter((r) => r.event === "handler_exec").length);
  compare(name, "handler writes", m.filter((r) => r.event === "handler_write"), z.filter((r) => r.event === "cpu_write" && r.address === "000100"), m.filter((r) => r.event === "handler_write").length);
}

// ---- NMI sweep: V=225 NMI edge against NOP/JMP and WAI loops at ten
// alignments; four NMIs (frames) each.
for (const loop of ["nop", "wai"]) for (let k = 0; k <= 9; k++) {
  const name = `nmi-${loop}-k${k}`;
  const m = tsv(join(probes, name, "trace.tsv"));
  const z = trace(name, 5, ["008100", "008100"]);
  const n = m.filter((r) => r.event === "handler_exec").length;
  compare(name, "handler entries", m.filter((r) => r.event === "handler_exec"), z.filter((r) => r.event === "exec"), n);
  compare(name, "handler writes", m.filter((r) => r.event === "handler_write"), z.filter((r) => r.event === "cpu_write" && r.address === "000100"), n);
}

writeFileSync(join(out, "cross-oracle.json"), JSON.stringify(results, null, 2) + "\n");
const failed = results.filter((r) => !r.pass).length;
console.log(`${failed ? "FAIL" : "PASS"}: ${results.length - failed}/${results.length} event streams agree exactly`);
process.exit(failed ? 1 : 0);
