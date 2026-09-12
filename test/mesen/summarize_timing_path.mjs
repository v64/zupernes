#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

const [outArg] = process.argv.slice(2);
if (!outArg) {
  console.error("Usage: node test/mesen/summarize_timing_path.mjs <out-dir>");
  process.exit(2);
}
const outDir = resolve(outArg);

function rows(name, file = "trace.tsv") {
  const lines = readFileSync(join(outDir, name, file), "utf8").trim().split("\n");
  const keys = lines.shift().split("\t");
  return lines.map(line => Object.fromEntries(line.split("\t").map((value, i) => [keys[i], value])));
}
function masters(row) { return Number(row.master); }
function requireEqual(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, found ${actual}`);
}

const clc = rows("clc-refresh");
const sequential = [];
for (let i = 0; i + 1 < clc.length; i++) {
  if (Number.parseInt(clc[i + 1].address, 16) === Number.parseInt(clc[i].address, 16) + 1) {
    sequential.push(masters(clc[i + 1]) - masters(clc[i]));
  }
}
const clcNormal = sequential.filter(value => value === 14).length;
const clcRefresh = sequential.filter(value => value === 54).length;
requireEqual(clcNormal + clcRefresh, sequential.length, "CLC interval classes");
const h532 = clc.findIndex((row, i) => row.hclock === "532" && clc[i + 1]?.hclock === "586");
if (h532 < 0) throw new Error("missing H532->H586 final-phase refresh control");

const dma = {};
for (const name of ["dma-normal", "dma-refresh", "dma-reverse", "dma-two-channel"]) {
  const trace = rows(name);
  const trigger = trace.find(row => row.event === "mdma_write");
  const sources = trace.filter(row => row.event === "dma_source");
  const destinations = trace.filter(row => row.event === "dma_dest");
  if (!trigger || sources.length === 0 || destinations.length === 0) throw new Error(`${name}: incomplete trace`);
  for (let i = 0; i < Math.min(sources.length, destinations.length); i++) {
    requireEqual(masters(destinations[i]) - masters(sources[i]), 4, `${name} source->destination ${i}`);
  }
  dma[name] = {
    trigger_to_first_source: masters(sources[0]) - masters(trigger),
    source_to_destination: masters(destinations[0]) - masters(sources[0]),
    events: trace.map(row => ({ event: row.event, master: masters(row), line: Number(row.line), hclock: Number(row.hclock) })),
  };
}

const hdmaTrace = rows("hdma");
const hdmaData = hdmaTrace.find(row => row.event === "hdma_source" && row.address === "7e0101");
const hdmaDest = hdmaTrace.find(row => row.event === "hdma_dest");
if (!hdmaData || !hdmaDest) throw new Error("HDMA trace incomplete");
requireEqual(masters(hdmaDest) - masters(hdmaData), 4, "HDMA source->destination");

const geometry = rows("clc-refresh", "geometry.tsv");
const frameLengths = geometry.slice(1).map((row, i) => masters(row) - masters(geometry[i]));
requireEqual(frameLengths.join(","), "357364,357368,357364", "NTSC frame lengths");

const irq = rows("irq");
const irqService = irq.find(row => row.event === "irq_service");
const handlerExec = irq.find(row => row.event === "handler_exec");
if (!irqService || !handlerExec) throw new Error("IRQ trace incomplete");
requireEqual(masters(handlerExec), masters(irqService), "IRQ service callback/handler entry");

const report = {
  clc: { normal_14: clcNormal, refresh_54: clcRefresh, exact_final_phase_control: { from_hclock: 532, to_hclock: 586 } },
  dma,
  hdma: { source_hclock: Number(hdmaData.hclock), destination_hclock: Number(hdmaDest.hclock), source_to_destination: 4 },
  frame_lengths: frameLengths,
  irq: irq.map(row => ({ event: row.event, master: masters(row), hclock: Number(row.hclock) })),
};
console.log(JSON.stringify(report, null, 2));
