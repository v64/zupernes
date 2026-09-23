#!/usr/bin/env node
// Original ROM atlas generator and exact, scoped PPU comparison. No game assets.
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync} from 'node:fs';
import {resolve,dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
export const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
export const sha=b=>createHash('sha256').update(b).digest('hex');
export const configurations=[0,1,9,2,3,4].flatMap(mode=>['main','sub'].map(screen=>({name:`mode${mode}-${screen}`,mode,screen})));
const depths=mode=>mode===0?[2,2,2,2]:(mode&7)===1?[4,4,2]:mode===2?[4,4]:mode===3?[8,4]:[8,2];
export function generate(config) {
 const {mode,screen,name}=config,bpp=depths(mode),cases=[];
 const add=(group,id,layers=[],obj=null)=>cases.push({group,id,layers,obj});
 add('control','transparent');
 for(let bg=0;bg<bpp.length;bg++)for(const palette of [0,1,7])add(mode===0?'palette':'control',`bg${bg+1}-palette${palette}`,[[bg,0,palette]]);
 for(let a=0;a<bpp.length;a++)for(let b=a+1;b<bpp.length;b++)for(const ap of [0,1])for(const bp of [0,1])add('bg-priority',`bg${a+1}${ap}-bg${b+1}${bp}`,[[a,ap,0],[b,bp,0]]);
 if(screen==='main') {
  for(let bg=0;bg<bpp.length;bg++)for(const bp of [0,1])for(let sp=0;sp<4;sp++)add('obj-priority',`bg${bg+1}${bp}-obj${sp}`,[[bg,bp,0]],sp);
  for(let sp=0;sp<4;sp++)add('control',`obj${sp}-only`,[],sp);
 }
 const vram=Buffer.alloc(65536),cgram=Buffer.alloc(512),oam=Buffer.alloc(544);
 for(let i=1;i<256;i++)cgram.writeUInt16LE((15<<10)|i,i*2);
 for(let i=0;i<128;i++){oam[i*4]=0;oam[i*4+1]=240;}
 // Tile 0 is transparent; tile 1 is a solid per-layer color index. Each BG
 // receives its own 8KiB CHR bank. Tilemaps occupy the first 8KiB of VRAM.
 for(let bg=0;bg<bpp.length;bg++) {
  const color=(bg%3)+1,base=0x2000+bg*0x2000+bpp[bg]*8;
  for(let plane=0;plane<bpp[bg];plane++)for(let y=0;y<8;y++)vram[base+(plane>>1)*16+y*2+(plane&1)]=(color>>plane&1)?255:0;
 }
 // OBJ uses byte $A000; tile 1, 4bpp, pixel index 7.
 for(let plane=0;plane<4;plane++)for(let y=0;y<8;y++)vram[0xc020+(plane>>1)*16+y*2+(plane&1)]=(7>>plane&1)?255:0;
 let sprite=0;
 cases.forEach((c,i)=>{
  const x=8+(i%8)*32,y=16+Math.floor(i/8)*16;
  c.x=x+2;c.y=y+2;c.width=4;c.height=4;
  for(const [bg,priority,palette] of c.layers)vram.writeUInt16LE(1|(palette<<10)|(priority<<13),bg*0x800+((y/8)*32+x/8)*2);
  if(c.obj!==null){oam[sprite*4]=x;oam[sprite*4+1]=y;oam[sprite*4+2]=1;oam[sprite*4+3]=(c.obj<<4)|(4<<1);sprite++;}
 });
 if(sprite>128||cases.length>96)throw new Error('Atlas overflow');
 const rom=Buffer.alloc(32768,0xff),code=[0x78,0xd8,0x18,0xfb,0xc2,0x10,0xa2,0xff,0x1f,0x9a,0xe2,0x20];
 let dataAt=0x1000;
 const emit=(...v)=>code.push(...v),set=(reg,v)=>emit(0xa9,v,0x8d,reg&255,reg>>8);
 const dma=(data,dest,transferMode)=>{
  const start=dataAt;rom.set(data,start);dataAt+=data.length;
  set(0x4300,transferMode);set(0x4301,dest);set(0x4302,start&255);set(0x4303,(0x8000+start)>>8);set(0x4304,0);
  set(0x4305,data.length&255);set(0x4306,data.length>>8);set(0x420b,1);
 };
 set(0x4200,0);set(0x420c,0);set(0x2100,0x80);set(0x2133,0);
 set(0x2115,0x80);set(0x2116,0);set(0x2117,0);
 dma(vram.subarray(0,0x2000),0x18,1);
 for(let bg=0;bg<bpp.length;bg++){
  const address=0x2000+bg*0x2000;set(0x2116,address/2&255);set(0x2117,address>>9);
  dma(vram.subarray(address,address+128),0x18,1);
 }
 set(0x2116,0);set(0x2117,0x60);dma(vram.subarray(0xc000,0xc040),0x18,1);
 set(0x2121,0);dma(cgram,0x22,0);
 set(0x2102,0);set(0x2103,0);dma(oam,0x04,0);
 set(0x2105,mode);set(0x2101,3); // OBJ byte base $A000
 for(let bg=0;bg<4;bg++)set(0x2107+bg,bg*4);
 set(0x210b,0x21);set(0x210c,0x43);
 for(let reg=0x210d;reg<=0x2114;reg++){set(reg,0);set(reg,0);}
 for(let reg=0x2123;reg<=0x212b;reg++)set(reg,0);
 set(0x212e,0);set(0x212f,0);set(0x2132,0xe0);
 const mask=(1<<bpp.length)-1;
 set(0x212c,screen==='main'?mask|16:0);set(0x212d,screen==='sub'?mask:0);
 set(0x2130,screen==='sub'?2:0);set(0x2131,screen==='sub'?0x20:0);
 set(0x2100,15);emit(0xa9,0xa5,0x8f,0xf0,0x7f,0x7e);
 const loop=0x8000+code.length;emit(0x4c,loop&255,loop>>8);
 if(code.length>=0x1000||dataAt>=0x7fc0)throw new Error('ROM overlap');
 rom.set(code);rom.write(`PPU ${name}`.padEnd(21).slice(0,21),0x7fc0,'ascii');
 rom.set([0x20,0,5,0,1,0x33,0],0x7fd5);rom[0x7ffc]=0;rom[0x7ffd]=0x80;
 rom.writeUInt16LE(65535,0x7fdc);rom.writeUInt16LE(0,0x7fde);
 const sum=rom.reduce((a,b)=>(a+b)&65535,0);rom.writeUInt16LE(sum^65535,0x7fdc);rom.writeUInt16LE(sum,0x7fde);
 return {config,cases,rom};
}
export function captureLua(dir) {
 return `emu.getAtomicSnapshot()\nlocal frame=0\nemu.addEventCallback(function()\n frame=frame+1\n if frame==5 or frame==6 then\n  assert(emu.read(0x7ff0,emu.memType.snesWorkRam,false)==0xa5,"probe not complete")\n  local s=assert(emu.getAtomicSnapshot());assert(s.width==256 and (s.height==224 or s.height==239),"unexpected dimensions")\n  local y0=s.height==239 and 6 or 0\n  local f=assert(io.open(${JSON.stringify(join(dir,'frame-'))}..frame..".rgb15","wb"))\n  for y=y0,y0+223 do for x=0,255 do local c=s.frameBuffer[y*s.width+x+1];local v=(((c>>16)&255)>>3)|(((((c>>8)&255)>>3))<<5)|(((c&255)>>3)<<10);f:write(string.char(v&255,(v>>8)&255)) end end;f:close()\n  if frame==6 then emu.stop(0) end\n end\nend,emu.eventType.endFrame)\n`;
}
export function samples(rgb,cases) {
 if(rgb.length!==256*224*2)throw new Error('Wrong RGB15 size');
 return cases.map(c=>({id:c.id,group:c.group,pixels:Array.from({length:c.width*c.height},(_,i)=>rgb.readUInt16LE(((c.y+Math.floor(i/c.width))*256+c.x+i%c.width)*2))}));
}
export function fromPpm(ppm) {
 const h=/^P6\s+(\d+)\s+(\d+)\s+255\s/.exec(ppm.toString('ascii',0,40));
 if(!h||+h[1]!==256||+h[2]!==224||ppm.length!==h[0].length+256*224*3)throw new Error('Invalid PPM');
 const pixels=ppm.subarray(h[0].length),out=Buffer.alloc(256*224*2);
 for(let i=0;i<256*224;i++)out.writeUInt16LE((pixels[i*3]>>3)|((pixels[i*3+1]>>3)<<5)|((pixels[i*3+2]>>3)<<10),i*2);
 return out;
}
export function compare(actual,expected) {
 if(!expected.length||actual.length!==expected.length)throw new Error('Wrong case count');
 return actual.flatMap((a,i)=>{
  const e=expected[i];if(a.id!==e.id||a.group!==e.group)throw new Error('Case identity changed');
  return JSON.stringify(a.pixels)===JSON.stringify(e.pixels)?[]:[{id:a.id,group:a.group,expected:e.pixels,actual:a.pixels}];
 });
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
 const [command,which='all']=process.argv.slice(2);
 if(command!=='check')throw new Error('Usage: node test/mesen/ppu_campaign.mjs check [all|mode0-main|...]');
 const configs=configurations.filter(c=>which==='all'||c.name===which);if(!configs.length)throw new Error('Unknown case selector');
 const start=Date.now(),fixture=JSON.parse(readFileSync(join(root,'test/mesen/fixtures/ppu-campaign.json')));
 const parent=join(root,'.zig-cache/ppu-campaign');mkdirSync(parent,{recursive:true});const out=mkdtempSync(join(parent,'run-'));
 const results=[];
 for(const config of configs) {
  const probe=generate(config),ref=fixture.captures[config.name];
  if(!ref||ref.romSha256!==sha(probe.rom))throw new Error('Frozen ROM identity mismatch');
  const dir=join(out,config.name);mkdirSync(dir);writeFileSync(join(dir,'probe.sfc'),probe.rom);
  const args=[join(dir,'probe.sfc'),'6',join(dir,'final.ppm'),'--every','1',dir,'--range','4:5','--dump-wram',join(dir,'wram.bin')];
  const p=spawnSync('zig',['build','screenshot','-Doptimize=ReleaseFast','--',...args],{cwd:root,encoding:'utf8',timeout:120000});
  writeFileSync(join(dir,'runner.log'),(p.stdout??'')+(p.stderr??''));
  if(p.status!==0)throw new Error(`Build/run failed (${p.status}): ${p.error??p.stderr}`);
  const wram=readFileSync(join(dir,'wram.bin'));if(wram.length!==131072||wram[0x7ff0]!==0xa5)throw new Error('Incomplete ROM execution');
  const frames=[4,5].map(n=>samples(fromPpm(readFileSync(join(dir,`frame_${String(n).padStart(5,'0')}.ppm`))),probe.cases));
  if(compare(frames[0],frames[1]).length)throw new Error('Unstable atlas results');
  const failures=compare(frames[1],ref.samples),result={name:config.name,total:probe.cases.length,passed:probe.cases.length-failures.length,failures};
  results.push(result);console.log(`${result.name}: ${result.passed}/${result.total}`);
 }
 const report={elapsedMs:Date.now()-start,results};writeFileSync(join(out,'result.json'),JSON.stringify(report,null,2)+'\n');
 console.log(`Evidence: ${out}; ${report.elapsedMs}ms`);
 if(results.some(r=>r.failures.length))process.exitCode=1;
}
