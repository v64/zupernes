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
      reads.push({ start, callback: row });
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
  // SnesMemoryManager::Read calls the mapped handler after the leading part
  // of a read, then advances four masters before ProcessMemoryRead invokes
  // the Lua callback. Limit callback-minus-four analysis to the event-free
  // interval after DRAM refresh and before the H=276 HDMA event. This avoids
  // assuming the same subtraction across a post-handler event stall.
  const eventFreeReads = reads.filter(({ callback }) => callback.hclock >= 600 && callback.hclock <= 1102).map(pair => {
    const handlerHclock = pair.callback.hclock - 4;
    return {
      ...pair,
      handlerHclock,
      startHblank: pair.start.hclock < 4 || pair.start.hclock > 274 * 4,
      handlerHblank: handlerHclock < 4 || handlerHclock > 274 * 4,
      returnedHblank: (pair.callback.value & 0x40) !== 0,
    };
  });
  const instructionStartDisagreements = eventFreeReads.filter(pair => pair.startHblank !== pair.handlerHblank);
  const handlerValueMismatches = eventFreeReads.filter(pair => pair.handlerHblank !== pair.returnedHblank);
  const edgeZero = eventFreeReads.filter(pair => pair.handlerHclock === 274 * 4);
  const edgeTwo = eventFreeReads.filter(pair => pair.handlerHclock === 274 * 4 + 2);
  return {
    calls: rows.filter(row => row.kind === "return").length,
    reads: reads.length,
    callback_latency_masters: [...new Set(reads.map(({ start, callback }) => callback.master - start.master))].sort((a, b) => a - b),
    event_free_handler_reads: eventFreeReads.length,
    instruction_start_handler_disagreements: instructionStartDisagreements.length,
    handler_value_mismatches: handlerValueMismatches.length,
    h274_residual_0: { reads: edgeZero.length, hblank_returns: edgeZero.filter(pair => pair.returnedHblank).length },
    h274_residual_2: { reads: edgeTwo.length, hblank_returns: edgeTwo.filter(pair => pair.returnedHblank).length },
    branch_outcomes: branchCount,
    bad_branch_outcomes: badBranchOutcomes,
    first_disagreements: instructionStartDisagreements.slice(0, 5).map(({ start, callback, handlerHclock }) => ({
      call: callback.call,
      start: `${start.scanline}:${start.hclock}`,
      handler: `${callback.scanline}:${handlerHclock}`,
      callback: `${callback.scanline}:${callback.hclock}`,
      value: callback.value,
    })),
  };
}

if (process.argv.length < 3) {
  console.error("Usage: node test/mesen/summarize_hvbjoy_access.mjs <trace.tsv>...");
  process.exit(2);
}
for (const path of process.argv.slice(2)) console.log(JSON.stringify({ path, ...summarize(path) }, null, 2));
