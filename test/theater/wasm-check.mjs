import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {fixtures} from './fixtures.mjs';
import {buttons,sha} from './contract.mjs';
const golden=JSON.parse(readFileSync(new URL('./expected.json',import.meta.url)));
assert.equal(sha(readFileSync(new URL('./fixtures.mjs',import.meta.url))),golden.fixtureSource,'fixture changed');
const wasm=readFileSync(process.argv[2]??'src/theater/zupernes.wasm');
const {instance}=await WebAssembly.instantiate(wasm,{}),e=instance.exports;
for(const name of ['zn_alloc','zn_free','zn_load_rom','zn_run_frame','zn_reset','zn_framebuffer_ptr','zn_width','zn_height','zn_wram_ptr','zn_sram_ptr','zn_sram_len','zn_read_audio'])assert.equal(typeof e[name],'function',name);
assert(e.memory instanceof WebAssembly.Memory);
const mem=()=>new Uint8Array(e.memory.buffer);
function load(bytes,success=true) {
 const p=e.zn_alloc(bytes.length);assert(p>0,'allocation');mem().set(bytes,p);
 const result=e.zn_load_rom(p,bytes.length);
 // ROM lifetime belongs to the adapter; the caller's upload is temporary.
 mem().fill(0xcc,p,p+bytes.length);e.zn_free(p,bytes.length);
 success?assert.equal(result,0,'load'):assert.notEqual(result,0,'invalid ROM accepted');
}
function rgb() {
 assert.equal(e.zn_width(),256);assert.equal(e.zn_height(),224);
 const p=e.zn_framebuffer_ptr(),view=new DataView(e.memory.buffer),out=Buffer.alloc(256*224*3);
 for(let i=0;i<256*224;i++){const c=view.getUint16(p+2*i,true);out[i*3]=(c&31)<<3;out[i*3+1]=(c>>5&31)<<3;out[i*3+2]=(c>>10&31)<<3;}
 return out;
}
const wram=()=>Buffer.from(mem().slice(e.zn_wram_ptr(),e.zn_wram_ptr()+131072));
function drain() {
 const p=e.zn_alloc(2048*4),chunks=[];
 for(let j=0;;j++) {
  assert(j<64,'audio drain never terminates');const n=e.zn_read_audio(p,2048);
  assert(n>=0&&n<=2048,'audio capacity');if(!n)break;
  chunks.push(Buffer.from(mem().slice(p,p+n*4)));
 }
 e.zn_free(p,2048*4);return Buffer.concat(chunks);
}
let checked=0;
for(const [name,rom] of Object.entries(fixtures())) {
 load(rom);assert.equal(e.zn_sram_len(),8192);assert(mem().slice(e.zn_sram_ptr(),e.zn_sram_ptr()+8192).every(v=>v===255),'fresh SRAM');
 const audio=[];
 for(let f=0;f<120;f++) {
  assert.equal(e.zn_run_frame(buttons[f]),0);audio.push(drain());
  const target=golden.cases.find(c=>c.name===name&&c.frames===f+1);if(!target)continue;
  assert.equal(sha(rom),target.romSha);assert.equal(sha(rgb()),target.rgbSha,`${name}/${f+1} RGB`);
  assert.equal(sha(wram()),target.wramSha,`${name}/${f+1} WRAM`);
  const pcm=Buffer.concat(audio);assert.equal(pcm.length/4,target.pcmFrames);assert.equal(sha(pcm),target.pcmSha,`${name}/${f+1} PCM`);
  checked++;console.log('parity',name,f+1,'OK');
 }
 assert.equal(mem()[e.zn_sram_ptr()],0x5a,'gameplay battery write');
 assert.equal(e.zn_reset(),0);assert.equal(drain().length,0,'reset leaked old audio');
 for(let i=0;i<60;i++){assert.equal(e.zn_run_frame(0),0);drain();}
 assert.equal(wram()[0x1004],0x5a,'reset must cold boot preserving SRAM');
 const before=wram();load(new Uint8Array(17),false);assert.deepEqual(wram(),before,'failed load mutated running machine');
}
// Reloading the same ROM starts a new machine; SRAM import is the host's job.
load(fixtures().lorom);for(let i=0;i<60;i++){e.zn_run_frame(0);drain();}
assert.equal(wram()[0x1004],255,'ROM reload retained unrelated SRAM');
console.log(`PASS: ${checked} exact RGB/WRAM/PCM checkpoints; ROM ownership, reset, load failure and SRAM lifetime`);
