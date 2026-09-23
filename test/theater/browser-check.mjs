// Independent UI smoke gate. Run against the real static server after building.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {fixtures} from './fixtures.mjs';
let pw;try{pw=await import('playwright');}catch{pw=createRequire(join(execFileSync('npm',['root','-g'],{encoding:'utf8'}).trim(),'_loader.cjs'))('playwright');}
const base=process.argv[2]??'http://127.0.0.1:8380';
const out=resolve(process.env.THEATER_ARTIFACTS??'.zig-cache/theater-browser');mkdirSync(out,{recursive:true});
let browser;try{browser=await pw.chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu']});}catch{browser=await pw.chromium.launch({headless:true,args:['--enable-unsafe-webgpu']});}
const context=await browser.newContext({viewport:{width:1100,height:850}}),page=await context.newPage(),errors=[],requests=[];
page.on('pageerror',e=>errors.push(String(e)));
page.on('request',r=>{const u=new URL(r.url());if(['http:','https:'].includes(u.protocol)&&(!['GET','HEAD'].includes(r.method())||u.origin!==new URL(base).origin))requests.push({url:r.url(),method:r.method()});});
const state=()=>page.evaluate(()=>window.__zupernesTest.state());
const read=(offset,length=1)=>page.evaluate(async([o,n])=>Array.from(await window.__zupernesTest.readWram(o,n)),[offset,length]);
async function poll(fn,description,timeout=12000){const start=Date.now();while(Date.now()-start<timeout){if(await fn())return;await new Promise(r=>setTimeout(r,50));}throw Error('Timeout: '+description);}
async function phase(p){await poll(async()=>(await state()).phase===p,'phase '+p);}
async function play(){if((await state()).phase!=='running')await page.locator('#pause').click();await phase('running');await poll(async()=>(await read(0x7ff0))[0]===0xa5,'ROM boot');await page.locator('#screen').click();}
async function pause(){if((await state()).phase==='running')await page.locator('#pause').click();await phase('paused');}
async function load(bytes,name='game.sfc') {
 const generation=(await state()).generation;
 await page.locator('#file').setInputFiles({name,mimeType:'application/octet-stream',buffer:bytes});
 await poll(async()=>{const s=await state();return s.generation>generation&&s.phase==='paused';},'new ROM session');await play();
}
async function pad(value){await poll(async()=>{const a=await read(0x1000,2);return (a[0]|a[1]<<8)===value;},'emulated pad '+value.toString(16));}
try {
 await page.goto(base+'/?test=1');await page.waitForFunction(()=>!!window.__zupernesTest);
 assert.equal((await state()).phase,'empty');
 const f=fixtures();await load(f.lorom);assert.equal((await read(0x1004))[0],255);
 const keymap={KeyW:0x0800,KeyS:0x0400,KeyA:0x0200,KeyD:0x0100,KeyK:0x8000,KeyJ:0x4000,KeyL:0x0080,KeyP:0x0040,KeyQ:0x0020,KeyE:0x0010,KeyO:0x1000,KeyU:0x2000};
 for(const [key,bit] of Object.entries(keymap)){await page.keyboard.down(key);await pad(bit);await page.keyboard.up(key);await pad(0);}
 for(const key of ['KeyW','KeyD','KeyK'])await page.keyboard.down(key);await pad(0x8900);
 await page.evaluate(()=>window.dispatchEvent(new Event('blur')));await pad(0);
 for(const key of ['KeyW','KeyD','KeyK'])await page.keyboard.up(key);
 await page.evaluate(()=>{const i=document.createElement('input');i.id='reviewer-editable';document.body.append(i);i.focus();});
 await page.keyboard.down('KeyK');await page.waitForTimeout(120);await pad(0);await page.keyboard.up('KeyK');
 await page.evaluate(()=>document.querySelector('#reviewer-editable').remove());
 await pause();const before=(await state()).frame;await page.waitForTimeout(300);assert.equal((await state()).frame,before,'pause still advancing');
 await page.screenshot({path:join(out,'desktop.png')});
 const idA=(await state()).romId;assert.match(idA,/^[0-9a-f]{64}$/);
 // KeyK above created SRAM through gameplay. Pause/swap must flush it.
 await load(f.loromB);assert.notEqual((await state()).romId,idA,'filename used as save identity');assert.equal((await read(0x1004))[0],255,'save leaked into different ROM');
 await load(f.headered,'renamed.smc');assert.equal((await state()).romId,idA,'copier header changed identity');assert.equal((await read(0x1004))[0],0x5a,'battery was not restored');
 await page.locator('#reset').click();await phase('paused');await play();assert.equal((await read(0x1004))[0],0x5a,'reset erased save');
 // Erase Save must require a real confirmation; cancelling preserves the save.
 page.once('dialog',d=>d.dismiss());await page.locator('#forget').click();await pause();await load(f.lorom);assert.equal((await read(0x1004))[0],0x5a);
 page.once('dialog',d=>d.accept());await page.locator('#forget').click();await phase('paused');await play();assert.equal((await read(0x1004))[0],255,'erase did not cold boot blank SRAM');
 await pause();await page.locator('#file').setInputFiles({name:'bad.sfc',mimeType:'application/octet-stream',buffer:Buffer.alloc(17)});
 await poll(async()=>!!(await state()).lastError,'load error');
 assert((await page.locator('#status').innerText()).includes((await state()).lastError),'error not visible');
 await load(f.hirom);assert.equal((await read(0x1005))[0],0x41,'HiROM did not boot');
 await pause();await page.setViewportSize({width:390,height:844});
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'horizontal overflow');
 const box=await page.locator('#screen').boundingBox();assert(box&&box.width>0&&box.height>0);assert(Math.abs(box.width/box.height-256/224)<0.02,'canvas stretched or widened');
 await page.screenshot({path:join(out,'narrow.png')});
 // Reload verifies durable storage rather than a process-local map.
 await load(f.lorom);await page.keyboard.down('KeyK');await pad(0x8000);await page.keyboard.up('KeyK');await pause();
 await page.reload();await page.waitForFunction(()=>!!window.__zupernesTest);await load(f.headered);assert.equal((await read(0x1004))[0],0x5a,'save lost across reload');
 // The local test ROM is never uploaded to a server or fetched from a CDN.
 assert.deepEqual(requests,[],'unexpected network traffic');assert.deepEqual(errors,[],'uncaught browser errors');
 writeFileSync(join(out,'primary-state.json'),JSON.stringify(await state(),null,2));
 // WebGPU unavailable is a separate real browser context, not a stub presenter.
 const fallback=await browser.newContext({viewport:{width:900,height:700}});
 await fallback.addInitScript(()=>Object.defineProperty(navigator,'gpu',{get:()=>undefined,configurable:true}));
 const fp=await fallback.newPage();await fp.goto(base+'/?test=1');await fp.waitForFunction(()=>!!window.__zupernesTest);
 await fp.locator('#file').setInputFiles({name:'fallback.sfc',mimeType:'application/octet-stream',buffer:f.lorom});
 await fp.waitForFunction(async()=>((await window.__zupernesTest.state()).phase==='paused'));
 await fp.locator('#pause').click();await fp.waitForFunction(async()=>((await window.__zupernesTest.readWram(0x7ff0,1))[0]===0xa5));
 const fs=await fp.evaluate(()=>window.__zupernesTest.state());assert.equal(fs.presenter,'2d');assert.equal(fs.crtActive,false);
 const pixels=await fp.locator('#screen').evaluate(c=>Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data));
 assert(pixels.some((v,i)=>i%4!==3&&v>0),'fallback canvas is blank');
 await fp.screenshot({path:join(out,'fallback.png')});await fallback.close();
 console.log('PASS: browser input, pause, ROM mapping, save identity/lifetime, reset/erase, reload, layout and WebGPU fallback');
 console.log('Still required: actual CRT on/off capture, audio playback/flush instrumentation, race/failure tests and performance report (see TASK.md).');
} finally {await browser.close();}
