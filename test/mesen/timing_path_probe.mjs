#!/usr/bin/env node
// Generate copyright-free ROMs and Mesen scripts for the ordered timing path.

import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const [outArg] = process.argv.slice(2);
if (!outArg) {
  console.error("Usage: node test/mesen/timing_path_probe.mjs <out-dir>");
  process.exit(2);
}
const outDir = resolve(outArg);
mkdirSync(outDir, { recursive: true });

function emitRom(name, title, code, extra = () => {}) {
  const dir = join(outDir, name);
  mkdirSync(dir, { recursive: true });
  const rom = Buffer.alloc(0x8000, 0xff);
  Buffer.from(code).copy(rom, 0);
  extra(rom);
  rom.write(title.padEnd(21, " ").slice(0, 21), 0x7fc0, "ascii");
  rom[0x7fd5] = 0x20; // LoROM, SlowROM
  rom[0x7fd6] = 0x00; // ROM only
  rom[0x7fd7] = 0x08; // 32 KiB
  rom[0x7fd8] = 0x00; // no SRAM
  rom[0x7fd9] = 0x01; // NTSC
  rom[0x7fda] = 0x33;
  rom[0x7ffc] = 0x00;
  rom[0x7ffd] = 0x80;
  writeFileSync(join(dir, "probe.sfc"), rom);
  return dir;
}

function ldaSta(code, value, address) {
  code.push(0xa9, value, 0x8d, address & 0xff, address >> 8);
}

function dmaCase(name, { fillers = 0, direction = false, channels = 1 }) {
  const code = [0x78, 0xd8, 0xa2, 0xff, 0x9a, 0x9c, 0x00, 0x42];
  for (let channel = 0; channel < channels; channel++) {
    const base = 0x4300 + channel * 0x10;
    const aAddress = direction ? 0x0100 + channel : 0x4212;
    ldaSta(code, direction ? 0x80 : 0x00, base);
    ldaSta(code, direction ? 0x37 : channel, base + 1);
    ldaSta(code, aAddress & 0xff, base + 2);
    ldaSta(code, aAddress >> 8, base + 3);
    ldaSta(code, direction ? 0x7e : 0x00, base + 4);
    ldaSta(code, 0x01, base + 5);
    ldaSta(code, 0x00, base + 6);
  }
  for (let i = 0; i < fillers; i++) code.push(0x18); // CLC: 8+6 masters
  const mask = (1 << channels) - 1;
  code.push(0xa9, mask, 0x8d, 0x0b, 0x42);
  const marker = 0x8000 + code.length;
  code.push(0x4c, marker & 0xff, marker >> 8);

  const dir = emitRom(name, `T3 ${name.toUpperCase()}`, code);
  const trace = join(dir, "trace.tsv");
  const sourceStart = direction ? 0x002137 : 0x004212;
  const sourceEnd = sourceStart;
  const destStart = direction ? 0x7e0100 : 0x002100;
  const destEnd = destStart + channels - 1;
  const lua = `local output=assert(io.open(${JSON.stringify(trace)},"w"))
output:write("event\\taddress\\tvalue\\tmaster\\tline\\thclock\\tspc_cycle\\n")
local destinations=0
local function row(kind,a,v)
 local s=emu.getState()
 output:write(string.format("%s\\t%06x\\t%02x\\t%d\\t%d\\t%d\\t%d\\n",kind,a,v or 0,s["masterClock"],s["ppu.scanline"],s["memoryManager.hClock"],s["spc.cycle"]))
end
emu.addMemoryCallback(function(a,v) row("mdma_write",a,v) end,emu.callbackType.write,0x00420b,0x00420b,emu.cpuType.snes,emu.memType.snesMemory)
emu.addMemoryCallback(function(a,v) row("dma_source",a,v) end,emu.callbackType.read,${sourceStart},${sourceEnd},emu.cpuType.snes,emu.memType.snesMemory)
emu.addMemoryCallback(function(a,v)
 row("dma_dest",a,v); destinations=destinations+1
 if destinations>=${channels} then output:close();emu.stop(0) end
end,emu.callbackType.write,${destStart},${destEnd},emu.cpuType.snes,emu.memType.snesMemory)
`;
  writeFileSync(join(dir, "probe.lua"), lua);
}

dmaCase("dma-normal", {});
dmaCase("dma-refresh", { fillers: 86 });
dmaCase("dma-reverse", { direction: true });
dmaCase("dma-two-channel", { channels: 2 });

{
  const boot = [0x78, 0xd8, 0xa2, 0xff, 0x9a, 0xa9, 0x00, 0x8d, 0x00, 0x42, 0x8d, 0x0c, 0x42];
  for (let i = 0; i < 3; i++) boot.push(0x2c, 0x12, 0x42); // shift CLC phase by 6 mod 14
  boot.push(0x4c, 0x00, 0x81);
  const dir = emitRom("clc-refresh", "T3 CLC REFRESH", boot, rom => {
    rom.fill(0x18, 0x100, 0x140);
    rom.set([0x4c, 0x00, 0x81], 0x140);
  });
  const trace = join(dir, "trace.tsv");
  writeFileSync(join(dir, "probe.lua"), `local output=assert(io.open(${JSON.stringify(trace)},"w"))
output:write("address\\tmaster\\tline\\thclock\\tspc_cycle\\n")
local n=0
emu.addMemoryCallback(function(a)
 local s=emu.getState()
 output:write(string.format("%06x\\t%d\\t%d\\t%d\\t%d\\n",a,s["masterClock"],s["ppu.scanline"],s["memoryManager.hClock"],s["spc.cycle"]))
 n=n+1; if n>=5000 then output:close();emu.stop(0) end
end,emu.callbackType.exec,0x008100,0x00813f,emu.cpuType.snes,emu.memType.snesMemory)
`);
  const geometry = join(dir, "geometry.tsv");
  writeFileSync(join(dir, "geometry.lua"), `local output=assert(io.open(${JSON.stringify(geometry)},"w"))
output:write("index\\tmaster\\tline\\thclock\\tspc_cycle\\n")
local n=0
emu.addEventCallback(function(cpu)
 local s=emu.getState()
 output:write(string.format("%d\\t%d\\t%d\\t%d\\t%d\\n",n,s["masterClock"],s["ppu.scanline"],s["memoryManager.hClock"],s["spc.cycle"]))
 n=n+1; if n>=4 then output:close();emu.stop(0) end
end,emu.eventType.startFrame)
`);
}

{
  const code = [0x78, 0xd8, 0xa2, 0xff, 0x9a, 0x9c, 0x00, 0x42];
  for (const [value, address] of [[0x81, 0x0100], [0x0f, 0x0101], [0x00, 0x0102]]) {
    code.push(0xa9, value, 0x8f, address & 0xff, address >> 8, 0x7e); // STA.l $7E01xx
  }
  for (const [value, address] of [[0x00, 0x4300], [0x00, 0x4301], [0x00, 0x4302], [0x01, 0x4303], [0x7e, 0x4304]]) ldaSta(code, value, address);
  code.push(0x2c, 0x12, 0x42, 0x10, 0xfb); // wait until VBlank
  code.push(0xa9, 0x01, 0x8d, 0x0c, 0x42);
  const marker = 0x8000 + code.length;
  code.push(0x4c, marker & 0xff, marker >> 8);
  const dir = emitRom("hdma", "T3 HDMA PHASE", code);
  const trace = join(dir, "trace.tsv");
  writeFileSync(join(dir, "probe.lua"), `local output=assert(io.open(${JSON.stringify(trace)},"w"))
output:write("event\\taddress\\tvalue\\tmaster\\tline\\thclock\\tspc_cycle\\n")
local saw_data=false
local function row(kind,a,v)
 local s=emu.getState(); output:write(string.format("%s\\t%06x\\t%02x\\t%d\\t%d\\t%d\\t%d\\n",kind,a,v or 0,s["masterClock"],s["ppu.scanline"],s["memoryManager.hClock"],s["spc.cycle"]))
end
emu.addMemoryCallback(function(a,v) row("hdma_enable",a,v) end,emu.callbackType.write,0x00420c,0x00420c,emu.cpuType.snes,emu.memType.snesMemory)
emu.addMemoryCallback(function(a,v) if a==0x7e0101 then saw_data=true end; row("hdma_source",a,v) end,emu.callbackType.read,0x7e0100,0x7e0102,emu.cpuType.snes,emu.memType.snesMemory)
emu.addMemoryCallback(function(a,v) row("hdma_dest",a,v); if saw_data then output:close();emu.stop(0) end end,emu.callbackType.write,0x002100,0x002100,emu.cpuType.snes,emu.memType.snesMemory)
`);
}

{
  const code = [0x78, 0xd8, 0xa2, 0xff, 0x9a];
  ldaSta(code, 100, 0x4207);
  ldaSta(code, 0, 0x4208);
  ldaSta(code, 0x10, 0x4200);
  code.push(0x58); // CLI
  const loop = 0x8000 + code.length;
  code.push(0xea, 0x4c, loop & 0xff, loop >> 8);
  const dir = emitRom("irq", "T3 IRQ PHASE", code, rom => {
    rom.set([0xad, 0x11, 0x42, 0xee, 0x00, 0x01, 0x40], 0x100); // ack, marker, RTI
    rom[0x7ffe] = 0x00;
    rom[0x7fff] = 0x81;
  });
  const trace = join(dir, "trace.tsv");
  writeFileSync(join(dir, "probe.lua"), `local output=assert(io.open(${JSON.stringify(trace)},"w"))
output:write("event\\taddress\\tvalue\\tmaster\\tline\\thclock\\tspc_cycle\\n")
local function row(kind,a,v)
 local s=emu.getState(); output:write(string.format("%s\\t%06x\\t%02x\\t%d\\t%d\\t%d\\t%d\\n",kind,a or 0,v or 0,s["masterClock"],s["ppu.scanline"],s["memoryManager.hClock"],s["spc.cycle"]))
end
emu.addEventCallback(function(cpu) row("irq_service",0,0) end,emu.eventType.irq)
emu.addMemoryCallback(function(a) row("handler_exec",a,0) end,emu.callbackType.exec,0x008100,0x008100,emu.cpuType.snes,emu.memType.snesMemory)
emu.addMemoryCallback(function(a,v) row("handler_write",a,v);output:close();emu.stop(0) end,emu.callbackType.write,0x000100,0x000100,emu.cpuType.snes,emu.memType.snesMemory)
`);
}

// IRQ sweep: the same NOP/JMP loop as "irq", with the H-IRQ time varied so
// the interrupt is sampled on different cycles of the loop - including
// NOP's implied IdleOrRead cycle, which Mesen2 turns into a real read of the
// next opcode when an interrupt is imminent (SnesCpu::IdleOrRead). Each
// case records the handler's first instruction and its marker write.
for (let htime = 100; htime <= 140; htime += 2) {
  const code = [0x78, 0xd8, 0xa2, 0xff, 0x9a];
  ldaSta(code, htime, 0x4207);
  ldaSta(code, 0, 0x4208);
  ldaSta(code, 0x10, 0x4200);
  code.push(0x58); // CLI
  const loop = 0x8000 + code.length;
  code.push(0xea, 0x4c, loop & 0xff, loop >> 8);
  const name = `irq-h${htime}`;
  const dir = emitRom(name, `T3 IRQ H${htime}`, code, rom => {
    rom.set([0xad, 0x11, 0x42, 0xee, 0x00, 0x01, 0x40], 0x100); // ack, marker, RTI
    rom[0x7ffe] = 0x00;
    rom[0x7fff] = 0x81;
  });
  const trace = join(dir, "trace.tsv");
  writeFileSync(join(dir, "probe.lua"), `local output=assert(io.open(${JSON.stringify(trace)},"w"))
output:write("event\\taddress\\tvalue\\tmaster\\tline\\thclock\\tspc_cycle\\n")
local n=0
local function row(kind,a,v)
 local s=emu.getState(); output:write(string.format("%s\\t%06x\\t%02x\\t%d\\t%d\\t%d\\t%d\\n",kind,a or 0,v or 0,s["masterClock"],s["ppu.scanline"],s["memoryManager.hClock"],s["spc.cycle"]))
end
emu.addMemoryCallback(function(a) row("handler_exec",a,0) end,emu.callbackType.exec,0x008100,0x008100,emu.cpuType.snes,emu.memType.snesMemory)
emu.addMemoryCallback(function(a,v) row("handler_write",a,v); n=n+1; if n>=4 then output:close();emu.stop(0) end end,emu.callbackType.write,0x000100,0x000100,emu.cpuType.snes,emu.memType.snesMemory)
`);
}

// WAI sweep: the CPU halts in WAI and is woken by the H-IRQ. Mesen2 runs
// six-master idle cycles while halted (SnesCpu::ProcessHaltedState) and
// services the IRQ one cycle after the wake condition is seen.
for (let htime = 100; htime <= 140; htime += 2) {
  const code = [0x78, 0xd8, 0xa2, 0xff, 0x9a];
  ldaSta(code, htime, 0x4207);
  ldaSta(code, 0, 0x4208);
  ldaSta(code, 0x10, 0x4200);
  code.push(0x58); // CLI
  const loop = 0x8000 + code.length;
  code.push(0xcb, 0x80, 0xfd); // WAI; BRA loop
  const name = `wai-h${htime}`;
  const dir = emitRom(name, `T3 WAI H${htime}`, code, rom => {
    rom.set([0xad, 0x11, 0x42, 0xee, 0x00, 0x01, 0x40], 0x100); // ack, marker, RTI
    rom[0x7ffe] = 0x00;
    rom[0x7fff] = 0x81;
  });
  const trace = join(dir, "trace.tsv");
  writeFileSync(join(dir, "probe.lua"), `local output=assert(io.open(${JSON.stringify(trace)},"w"))
output:write("event\\taddress\\tvalue\\tmaster\\tline\\thclock\\tspc_cycle\\n")
local n=0
local function row(kind,a,v)
 local s=emu.getState(); output:write(string.format("%s\\t%06x\\t%02x\\t%d\\t%d\\t%d\\t%d\\n",kind,a or 0,v or 0,s["masterClock"],s["ppu.scanline"],s["memoryManager.hClock"],s["spc.cycle"]))
end
emu.addMemoryCallback(function(a) row("handler_exec",a,0) end,emu.callbackType.exec,0x008100,0x008100,emu.cpuType.snes,emu.memType.snesMemory)
emu.addMemoryCallback(function(a,v) row("handler_write",a,v); n=n+1; if n>=4 then output:close();emu.stop(0) end end,emu.callbackType.write,0x000100,0x000100,emu.cpuType.snes,emu.memType.snesMemory)
`);
}

// NMI sweep: NMI enabled, then a NOP/JMP loop or a WAI; BRA loop, entered
// after k CLC fillers (14 masters each) so the V=225 NMI edge meets
// different cycles. The NMI handler at $8100 INCs $0100 and returns; four
// NMIs (four frames) are recorded per case.
for (const waiLoop of [false, true]) {
  for (let k = 0; k <= 9; k++) {
    const code = [0x78, 0xd8, 0xa2, 0xff, 0x9a];
    ldaSta(code, 0x80, 0x4200); // NMITIMEN: NMI only
    for (let i = 0; i < k; i++) code.push(0x18);
    const loop = 0x8000 + code.length;
    if (waiLoop) code.push(0xcb, 0x80, 0xfd); // WAI; BRA loop
    else code.push(0xea, 0x4c, loop & 0xff, loop >> 8); // NOP; JMP loop
    const name = `nmi-${waiLoop ? "wai" : "nop"}-k${k}`;
    const dir = emitRom(name, `T3 NMI ${waiLoop ? "W" : "N"}${k}`, code, rom => {
      rom.set([0xad, 0x10, 0x42, 0xee, 0x00, 0x01, 0x40], 0x100); // LDA $4210; INC $0100; RTI
      rom[0x7ffa] = 0x00; // emulation-mode NMI vector -> $8100
      rom[0x7ffb] = 0x81;
    });
    const trace = join(dir, "trace.tsv");
    writeFileSync(join(dir, "probe.lua"), `local output=assert(io.open(${JSON.stringify(trace)},"w"))
output:write("event\\taddress\\tvalue\\tmaster\\tline\\thclock\\tspc_cycle\\n")
local n=0
local function row(kind,a,v)
 local s=emu.getState(); output:write(string.format("%s\\t%06x\\t%02x\\t%d\\t%d\\t%d\\t%d\\n",kind,a or 0,v or 0,s["masterClock"],s["ppu.scanline"],s["memoryManager.hClock"],s["spc.cycle"]))
end
emu.addMemoryCallback(function(a) row("handler_exec",a,0) end,emu.callbackType.exec,0x008100,0x008100,emu.cpuType.snes,emu.memType.snesMemory)
emu.addMemoryCallback(function(a,v) row("handler_write",a,v); n=n+1; if n>=4 then output:close();emu.stop(0) end end,emu.callbackType.write,0x000100,0x000100,emu.cpuType.snes,emu.memType.snesMemory)
`);
  }
}

console.log(`wrote timing probes under ${outDir}`);
