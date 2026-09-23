#!/usr/bin/env node
// Copyright-free 5A22 direct-page indirect probes. Compare completed result
// records, not frame timing: the ROM latches a marker and loops after all cases.
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync} from 'node:fs';
import {resolve, dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
export const root=resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export const sha=b=>createHash('sha256').update(b).digest('hex');
export const resultStart=0x6000, recordSize=6, doneOffset=0x7ff0;
export function generate() {
  const modes=[['ind',0xb2,0x92],['indx',0xa1,0x81],['indy',0xb1,0x91],['long',0xa7,0x87],['longy',0xb7,0x97]];
  const cases=[], code=[0x78,0xd8,0xa2,0xff,0x9a,0x9c,0x00,0x42,0x9c,0x0c,0x42];
  const emit=(...v)=>code.push(...v);
  const write=(address,value)=>emit(0xa9,value,0x8f,address&255,address>>8&255,0x7e);
  const save=address=>emit(0x8f,address&255,address>>8&255,0x7e);
  for (const emulation of [true,false]) for (const aligned of [true,false]) for (const crossing of [true,false]) for (const [mode,load,store] of modes) for (const operation of ['load','store']) {
    const dp=aligned?0x300:0x301, pointer=crossing?0x3ff:0x37e;
    const x=mode==='indx'?3:0, y=mode.endsWith('y')?3:0;
    const operand=pointer-dp-x;
    const id=`${emulation?'emu':'native'}-${aligned?'aligned':'unaligned'}-${crossing?'edge':'middle'}-${mode}-${operation}`;
    const record=resultStart+cases.length*recordSize;
    emit(0x18,0xfb,0xc2,0x20,0xa9,dp&255,dp>>8,0x5b,0xe2,0x30); // native, set D, A/X=8
    emit(0xa9,0x7e,0x48,0xab,0xa2,x,0xa0,y); // DBR=WRAM; indices
    // Distinct values at wrapped and linear pointer destinations. Long
    // pointers deliberately straddle the boundary and must remain linear.
    write(pointer,0x20); write(pointer+1,0x11); write(pointer+2,0x7e);
    if(crossing) write(pointer&0xff00,0x10);
    for(const [a,v] of [[0x1020,0x31],[0x1120,0x72],[0x1023,0x93],[0x1123,0xb4]])write(a,v);
    emit(emulation?0x38:0x18,0xfb); // select E
    emit(0x38,0xa9,0x5a,operation==='load'?load:store,operand);
    save(record); emit(0x08,0x68); save(record+1); // A/result, status
    for(const [i,a] of [0x1020,0x1120,0x1023,0x1123].entries()) {
      emit(0xaf,a&255,a>>8,0x7e); save(record+2+i);
    }
    cases.push({id,emulation,dp,pointer,x,y,operand,mode,operation,record});
  }
  write(doneOffset,0xa5);
  const loop=0x8000+code.length; emit(0x4c,loop&255,loop>>8);
  if(code.length>=0x7fc0)throw new Error('Probe exceeds LoROM code region');
  const rom=Buffer.alloc(0x8000,0xff);rom.set(code);
  rom.write('DP INDIRECT PROBE    ',0x7fc0,'ascii');
  rom.set([0x20,0,5,0,1,0x33,0],0x7fd5); // LoROM / ROM-only / 32KiB / NTSC
  rom[0x7ffc]=0;rom[0x7ffd]=0x80;
  // Valid complement/checksum pair, for strict ROM identification.
  rom.writeUInt16LE(0xffff,0x7fdc);rom.writeUInt16LE(0,0x7fde);
  const sum=rom.reduce((a,b)=>(a+b)&0xffff,0);
  rom.writeUInt16LE(sum^0xffff,0x7fdc);rom.writeUInt16LE(sum,0x7fde);
  return {rom,cases,loop};
}
export function records(wram, cases) {
  if(wram.length!==131072)throw new Error(`Expected 128KiB WRAM, got ${wram.length}`);
  if(wram[doneOffset]!==0xa5)throw new Error('Probe did not finish: completion marker absent');
  return cases.map(c=>({id:c.id,bytes:[...wram.subarray(c.record,c.record+recordSize)]}));
}
export function luaFor(out,probe) {
  return `local finished=false\nemu.addMemoryCallback(function()\n if finished then return end; finished=true\n local f=assert(io.open(${JSON.stringify(resolve(out))},"wb"))\n for i=0,131071 do f:write(string.char(emu.read(i,emu.memType.snesWorkRam,false))) end\n f:close();emu.stop(0)\nend,emu.callbackType.exec,${probe.loop},${probe.loop},emu.cpuType.snes,emu.memType.snesMemory)\n`;
}
export function compare(actual,expected) {
  if(!expected.length||actual.length!==expected.length)throw new Error('Empty or wrong result count');
  return actual.flatMap((r,i)=>{
    if(r.id!==expected[i].id)throw new Error('Case ordering/identity differs');
    return JSON.stringify(r.bytes)===JSON.stringify(expected[i].bytes)?[]:[{id:r.id,expected:expected[i].bytes,actual:r.bytes}];
  });
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [command,outArg]=process.argv.slice(2),probe=generate();
  if(command==='generate') {
    if(!outArg)throw new Error('generate requires an output directory');
    const out=resolve(outArg);mkdirSync(out,{recursive:true});
    writeFileSync(join(out,'probe.sfc'),probe.rom);
    writeFileSync(join(out,'probe.lua'),luaFor(join(out,'wram.bin'),probe));
    writeFileSync(join(out,'cases.json'),JSON.stringify(probe.cases,null,2)+'\n');
    console.log(`${probe.cases.length} cases, ROM ${sha(probe.rom)}`);
  } else if(command==='check') {
    const start=Date.now(),fixture=JSON.parse(readFileSync(join(root,'test/mesen/fixtures/dp-indirect.json')));
    if(fixture.romSha256!==sha(probe.rom))throw new Error('ROM differs from frozen Mesen reference');
    const parent=join(root,'.zig-cache/dp-indirect');mkdirSync(parent,{recursive:true});
    const out=mkdtempSync(join(parent,'run-'));
    writeFileSync(join(out,'probe.sfc'),probe.rom);
    const run=spawnSync('zig',['build','screenshot','-Doptimize=ReleaseFast','--',join(out,'probe.sfc'),'2',join(out,'frame.ppm'),'--dump-wram',join(out,'wram.bin')],{cwd:root,encoding:'utf8',timeout:120000});
    writeFileSync(join(out,'runner.log'),(run.stdout??'')+(run.stderr??''));
    if(run.status!==0)throw new Error(`Build/run failed: ${run.error??run.stderr}`);
    const actual=records(readFileSync(join(out,'wram.bin')),probe.cases),failures=compare(actual,fixture.records);
    const result={cases:actual.length,passed:actual.length-failures.length,failed:failures.length,elapsedMs:Date.now()-start,failures};
    writeFileSync(join(out,'result.json'),JSON.stringify(result,null,2)+'\n');
    for(const f of failures)console.log(`FAIL ${f.id}: expected ${f.expected} got ${f.actual}`);
    console.log(`${result.passed}/${result.cases} passed; ${result.failed} failed; ${result.elapsedMs}ms\nEvidence: ${out}`);
    if(failures.length)process.exitCode=1;
  } else {console.error('Usage: node test/mesen/dp_indirect_probe.mjs generate DIR | check');process.exitCode=2;}
}
