// Reviewer-owned baseline recorder. GLM must not regenerate expected.json.
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
import {fixtures} from './fixtures.mjs';
import {checkpoints,movie,sha,ppmPixels,wavPcm} from './contract.mjs';
if(process.argv[2]!=='--capture')throw Error('Explicit --capture required; reviewer only');
const out=resolve('.zig-cache/theater-native-reference');mkdirSync(out,{recursive:true});
writeFileSync(join(out,'input.zmov'),movie);
const expected={schema:1,base:'a51c7240d9e60e6176b7e1bef96d18cd0fb39678',fixtureSource:sha(readFileSync(new URL('./fixtures.mjs',import.meta.url))),cases:[]};
for(const [name,rom] of Object.entries(fixtures())) {
 const path=join(out,name+'.sfc');writeFileSync(path,rom);
 for(const frames of checkpoints) {
  const stem=join(out,`${name}-${frames}`);
  const result=spawnSync('zig',['build','screenshot','-Doptimize=ReleaseFast','--',path,String(frames),stem+'.ppm','--dump-wram',stem+'.wram','--wav',stem+'.wav','--movie',join(out,'input.zmov')],{encoding:'utf8',timeout:180000});
  writeFileSync(stem+'.log',(result.stdout??'')+(result.stderr??'')+`\nexit=${result.status}\n`);
  assert.equal(result.status,0,stem+'.log');
  const rgb=ppmPixels(readFileSync(stem+'.ppm')),wram=readFileSync(stem+'.wram'),pcm=wavPcm(readFileSync(stem+'.wav'));
  assert.equal(wram.length,131072);assert.equal(wram[0x7ff0],0xa5);assert.equal(wram[0x1005],name==='loromB'?0x42:0x41);
  if(frames>=60){
   assert(pcm.some(v=>v!==0),'silent fixture');
   let stereo=false;for(let i=0;i<pcm.length;i+=4)if(pcm.readInt16LE(i)!==pcm.readInt16LE(i+2)){stereo=true;break;}
   assert(stereo,'fixture lost stereo distinction');
  }
  expected.cases.push({name,frames,romSha:sha(rom),rgbSha:sha(rgb),wramSha:sha(wram),pcmSha:sha(pcm),pcmFrames:pcm.length/4,pad:wram.readUInt16LE(0x1000)});
  console.log(name,frames,'OK');
 }
}
assert.notEqual(expected.cases.find(c=>c.name==='lorom'&&c.frames===60).rgbSha,expected.cases.find(c=>c.name==='lorom'&&c.frames===110).rgbSha,'input must change visible pixels');
writeFileSync(new URL('./expected.json',import.meta.url),JSON.stringify(expected,null,2)+'\n');
