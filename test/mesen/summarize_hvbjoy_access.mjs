#!/usr/bin/env node

import { readFileSync } from "node:fs";

export function summarize(path) {
  const lines = readFileSync(path, "utf8").trim().split(/\r?\n/);
  const keys = lines.shift().split("\t");
  const rows = lines.map(line => Object.fromEntries(line.split("\t").map((value, i) => [keys[i], value]))).map(row => ({
    ...row,
    call: Number(row.call), address: Number.parseInt(row.address, 16), value: Number.parseInt(row.value, 16),
    master: Number(row.master), scanline: Number(row.scanline), hclock: Number(row.hclock),
    residual: Number(row.residual), branch_from: Number.parseInt(row.branch_from, 16),
  }));
  const pendingStarts = [];
  const reads = [];
  for (const row of rows) {
    if (row.kind === "bit-start") pendingStarts.push(row);
    if (row.kind === "read") {
      const start = pendingStarts.shift();
      if (!start || start.call !== row.call) throw new Error(`${path}: BIT/read pairing failed at call ${row.call}`);
      reads.push({ start, access: row });
    }
  }
  if (pendingStarts.length !== 0) throw new Error(`${path}: ${pendingStarts.length} BIT starts have no read`);
  let badBranchOutcomes = 0;
  let branchCount = 0;
  for (let i = 0; i < rows.length; i++) {
    const branch = rows[i];
    if (branch.kind !== "branch") continue;
    branchCount++;
    const next = rows.slice(i + 1).find(row => row.kind === "next" && row.branch_from === branch.address);
    if (!next) { badBranchOutcomes++; continue; }
    const hblank = (branch.value & 0x40) !== 0;
    const expected = branch.address === 0x8033 ? (hblank ? 0x802e : 0x8035) : (hblank ? 0x803a : 0x8035);
    if (next.address !== expected) badBranchOutcomes++;
  }
  const classifiedReads = reads.map(pair => ({
    ...pair,
    startHblank: pair.start.hclock < 4 || pair.start.hclock > 274 * 4,
    accessHblank: (pair.access.value & 0x40) !== 0,
  }));
  const instructionStartDisagreements = classifiedReads.filter(pair => pair.startHblank !== pair.accessHblank);
  return {
    calls: rows.filter(row => row.kind === "return").length,
    reads: reads.length,
    read_latency_masters: [...new Set(reads.map(({ start, access }) => access.master - start.master))].sort((a, b) => a - b),
    instruction_start_disagreements: instructionStartDisagreements.length,
    active_to_hblank: instructionStartDisagreements.filter(pair => !pair.startHblank && pair.accessHblank).length,
    hblank_to_active: instructionStartDisagreements.filter(pair => pair.startHblank && !pair.accessHblank).length,
    branch_outcomes: branchCount,
    bad_branch_outcomes: badBranchOutcomes,
    first_disagreements: instructionStartDisagreements.slice(0, 5).map(({ start, access }) => ({
      call: access.call,
      start: `${start.scanline}:${start.hclock}`,
      access: `${access.scanline}:${access.hclock}`,
      value: access.value,
    })),
  };
}

if (process.argv.length < 3) {
  console.error("Usage: node test/mesen/summarize_hvbjoy_access.mjs <trace.tsv>...");
  process.exit(2);
}
for (const path of process.argv.slice(2)) console.log(JSON.stringify({ path, ...summarize(path) }, null, 2));
