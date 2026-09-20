// Original, copyright-free browser-port fixtures: visible tiles, joypad echo,
// SRAM, and an uploaded SPC program producing stereo DSP noise.
import {mkdirSync,writeFileSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
export function makeRom({hirom=false,identity=0x41}={}) {
 const rom=Buffer.alloc(hirom?65536:32768,0xff),code=[],labels=new Map(),fix=[];
 const emit=(...bytes)=>code.push(...bytes),label=n=>labels.set(n,code.length);
 const set=(addr,v)=>emit(0xa9,v,0x8d,addr&255,addr>>8);
 const longSet=(addr,v)=>emit(0xa9,v,0x8f,addr&255,addr>>8&255,addr>>16);
 const branch=(op,n)=>{emit(op,0);fix.push([code.length-1,n]);};
 const wait=(addr,value,n)=>{label(n);emit(0xad,addr&255,addr>>8,0xc9,value);branch(0xd0,n);};
 emit(0x78,0xd8,0x18,0xfb,0xc2,0x10,0xa2,0xff,0x1f,0x9a,0xe2,0x20);
 set(0x4200,1);set(0x420c,0);set(0x2100,0x80);set(0x2133,0);
 const sram=hirom?0x206000:0x700000;
 emit(0xaf,sram&255,sram>>8&255,sram>>16,0x8f,0x04,0x10,0x7e);
 longSet(0x7e1005,identity);
 // Initialize all tilemap words to tile 1. Tile 0 remains transparent.
 set(0x2115,0x80);set(0x2116,0);set(0x2117,0);emit(0xa2,0,4);
 label('map');set(0x2118,1);set(0x2119,0);emit(0xca);branch(0xd0,'map');
 set(0x2116,8);set(0x2117,0x10); // byte $2010: solid 2bpp tile 1
 for(let y=0;y<8;y++){set(0x2118,y%2?0xff:0xaa);set(0x2119,0);}
 // Asymmetric palette markers make orientation and channel swaps observable.
 for(const [word,palette] of [[0,1],[31,2],[27*32,3],[27*32+31,4]]) {
  set(0x2116,word&255);set(0x2117,word>>8);set(0x2118,1);set(0x2119,palette<<2);
 }
 for(const [palette,color] of [[1,0x03e0],[2,0x7c00],[3,0x7fff],[4,0x03ff]]) {
  set(0x2121,palette*4+1);set(0x2122,color&255);set(0x2122,color>>8);
 }
 set(0x2121,0);for(const v of [0,0,31,0])set(0x2122,v);
 set(0x2105,0);set(0x2107,0);set(0x210b,1);
 set(0x210d,0);set(0x210d,0);set(0x210e,0);set(0x210e,0);
 set(0x212c,1);set(0x212d,0);set(0x2130,0);set(0x2131,0);set(0x212e,0);set(0x212f,0);
 // Upload a tiny independently authored SPC program through the normal IPL
 // handshake (docs/spc700-hardware.md and IPL loop in src/apu/spc700.zig).
 const spc=[];const dsp=(reg,v)=>spc.push(0x8f,reg,0xf2,0x8f,v,0xf3);
 for(const [r,v] of [[0x6c,0x3f],[0x0c,0x7f],[0x1c,0x7f],[0x00,0x60],[0x01,0x30],[0x02,0],[0x03,0x10],[0x05,0],[0x07,0x7f],[0x3d,1],[0x5c,0],[0x4c,1]])dsp(r,v);
 spc.push(0x2f,0xfe);
 wait(0x2140,0xaa,'ipl');set(0x2142,0);set(0x2143,2);set(0x2141,1);set(0x2140,0xcc);wait(0x2140,0xcc,'ack');
 spc.forEach((byte,i)=>{set(0x2141,byte);set(0x2140,i);wait(0x2140,i,'byte'+i);});
 set(0x2141,0);set(0x2142,0);set(0x2143,2);set(0x2140,spc.length+1);
 set(0x2100,15);longSet(0x7e7ff0,0xa5);
 label('notblank');emit(0xad,0x12,0x42);branch(0x30,'notblank');
 label('blank');emit(0xad,0x12,0x42);branch(0x10,'blank');
 label('autopoll');emit(0xad,0x12,0x42,0x29,1);branch(0xd0,'autopoll');
 emit(0xad,0x18,0x42,0x8f,0,0x10,0x7e,0xad,0x19,0x42,0x8f,1,0x10,0x7e);
 // B writes a battery byte, so UI keyboard and persistence tests can create
 // a save through emulated gameplay rather than test-only memory mutation.
 emit(0x29,0x80);branch(0xf0,'nosave');longSet(sram,0x5a);label('nosave');
 emit(0xee,2,0x10); // frame counter in low WRAM mirror
 set(0x2121,1);emit(0xad,0x18,0x42,0x09,0x1f,0x8d,0x22,0x21);set(0x2122,0);
 const target=0x8000+labels.get('notblank');emit(0x4c,target&255,target>>8);
 for(const [at,n] of fix){const d=labels.get(n)-at-1;if(d< -128||d>127)throw new Error('Branch overflow');code[at]=d&255;}
 const codeOffset=hirom?0x8000:0;if(code.length>0x7fc0)throw new Error('Code overflow');rom.set(code,codeOffset);
 const h=hirom?0xffc0:0x7fc0;rom.write(`ZN BROWSER ${identity}`.padEnd(21),h,'ascii');rom.set([hirom?0x21:0x20,2,hirom?6:5,3,1,0x33,0],h+0x15);
 rom[h+0x3c]=0;rom[h+0x3d]=0x80;rom.writeUInt16LE(65535,h+0x1c);rom.writeUInt16LE(0,h+0x1e);
 const sum=rom.reduce((a,b)=>(a+b)&65535,0);rom.writeUInt16LE(sum^65535,h+0x1c);rom.writeUInt16LE(sum,h+0x1e);
 return rom;
}
export function fixtures() {
 const a=makeRom(),b=makeRom({identity:0x42}),hi=makeRom({hirom:true});
 return {lorom:a,loromB:b,headered:Buffer.concat([Buffer.alloc(512,0x77),a]),hirom:hi};
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
 const out=resolve(process.argv[2]??'.zig-cache/theater-fixtures');mkdirSync(out,{recursive:true});
 for(const [name,bytes] of Object.entries(fixtures()))writeFileSync(join(out,name+'.sfc'),bytes);
 console.log(out);
}
