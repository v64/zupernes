#!/usr/bin/env node

import { readFileSync } from "node:fs";

const lineMasters = 341 * 4;

function refreshForLine(line) {
  const lineStart = line * lineMasters;
  return lineStart + 538 - (lineStart & 7);
}

function countRefreshesAfterThrough(start, end) {
  let line = Math.floor(start / lineMasters);
  let event = refreshForLine(line);
  if (event <= start) event = refreshForLine(++line);
  let count = 0;
  while (event <= end) {
    count++;
    event = refreshForLine(++line);
  }
  return count;
}

export function summarize(path) {
  const rows = readFileSync(path, "utf8").trim().split(/\r?\n/).slice(1).map(line => {
    const [address, master, scanline, hclock] = line.split("\t");
    return { address: Number.parseInt(address, 16), master: Number(master), scanline: Number(scanline), hclock: Number(hclock) };
  });
  const spans = [];
  for (let i = 0; i + 1 < rows.length; i++) {
    const start = rows[i];
    const end = rows[i + 1];
    if (start.address < 0x8100 || start.address >= 0x813e || end.address !== start.address + 2) continue;
    const refreshes = countRefreshesAfterThrough(start.master, end.master);
    spans.push({ start, end, refreshes, elapsed: end.master - start.master, expected: 16 + refreshes * 40 });
  }
  const bad = spans.filter(span => span.elapsed !== span.expected);
  const refreshSpans = spans.filter(span => span.refreshes !== 0);
  return {
    instruction_spans: spans.length,
    normal_16_master: spans.filter(span => span.elapsed === 16).length,
    refresh_56_master: spans.filter(span => span.elapsed === 56).length,
    unexpected_spans: bad.length,
    refresh_examples: refreshSpans.slice(0, 8).map(span => ({
      address: span.start.address.toString(16),
      start: `${span.start.scanline}:${span.start.hclock}`,
      end: `${span.end.scanline}:${span.end.hclock}`,
      master: `${span.start.master}->${span.end.master}`,
    })),
  };
}

if (process.argv.length !== 3) {
  console.error("Usage: node test/mesen/summarize_dram_refresh.mjs <trace.tsv>");
  process.exit(2);
}
console.log(JSON.stringify(summarize(process.argv[2]), null, 2));
