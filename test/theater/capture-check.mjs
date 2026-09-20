// ZuperNES theater screenshot capture (TASK.md criterion 6): desktop
// (1100x850) and narrow (390x844) layouts, CRT on/off and the 2D fallback,
// exercising a real game interaction (button press changes palette marker).
//   node test/theater/capture-check.mjs [base-url]
// Captures land in .zig-cache/theater-captures; inspect them visually.
import {mkdirSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import {fixtures} from './fixtures.mjs';
let pw;try{pw=await import('playwright');}catch{pw=createRequire(join(execFileSync('npm',['root','-g'],{encoding:'utf8'}).trim(),'_loader.cjs'))('playwright');}
const base=process.argv[2]??'http://127.0.0.1:8380';
const out=resolve('.zig-cache/theater-captures');mkdirSync(out,{recursive:true});
let browser;try{browser=await pw.chromium.launch({channel:'chrome',headless:true,args:['--enable-unsafe-webgpu']});}
catch{browser=await pw.chromium.launch({headless:true,args:['--enable-unsafe-webgpu']});}
const state=p=>p.evaluate(()=>window.__zupernesTest.state());
const read=async(p,o,l=1)=>Array.from(await p.evaluate(async([o,n])=>await window.__zupernesTest.readWram(o,n),[o,l]));
async function poll(fn,d,t=15000){const t0=Date.now();for(;;){if(await fn())return;if(Date.now()-t0>t)throw Error('to '+d);await new Promise(r=>setTimeout(r,50));}}
const f=fixtures();

// ---- desktop, CRT on and off (WebGPU context) ----
{
  const ctx=await browser.newContext({viewport:{width:1100,height:850}});
  const page=await ctx.newPage();
  await page.goto(base+'/?test=1');await page.waitForFunction(()=>!!window.__zupernesTest);
  await page.evaluate(()=>window.__zupernesTest.presenterReady?.());
  const g=(await state(page)).generation;
  await page.locator('#file').setInputFiles({name:'game.sfc',mimeType:'application/octet-stream',buffer:f.lorom});
  await poll(async()=>{const s=await state(page);return s.generation>g&&s.phase==='paused';},'load');
  await page.locator('#pause').click();
  await poll(async()=>(await state(page)).phase==='running','running');
  await poll(async()=>(await read(page,0x7ff0))[0]===0xa5,'boot');
  await page.locator('#screen').click(); // keyboard focus for gameplay
  await poll(async()=>(await state(page)).frame>30,'frames');
  // press B: the palette-1 marker color becomes input-dependent (bright)
  await page.keyboard.down('KeyK');
  await poll(async()=>{const a=await read(page,0x1000,2);return (a[0]|a[1]<<8)===0x8000;},'B held');
  await page.keyboard.up('KeyK');
  await page.waitForTimeout(250);
  await page.locator('#pause').click();
  await poll(async()=>(await state(page)).phase==='paused','paused');
  await page.evaluate(()=>{document.getElementById('start-overlay').style.visibility='hidden';});
  await page.screenshot({path:join(out,'desktop-crt-on.png')});
  await page.locator('#crt').click();
  await page.waitForTimeout(120);
  await page.screenshot({path:join(out,'desktop-crt-off.png')});
  await page.evaluate(()=>{document.getElementById('start-overlay').style.visibility='';});
  await ctx.close();
}

// ---- narrow 390x844, CRT on ----
{
  const ctx=await browser.newContext({viewport:{width:390,height:844}});
  const page=await ctx.newPage();
  await page.goto(base+'/?test=1');await page.waitForFunction(()=>!!window.__zupernesTest);
  await page.evaluate(()=>window.__zupernesTest.presenterReady?.());
  const g=(await state(page)).generation;
  await page.locator('#file').setInputFiles({name:'game.sfc',mimeType:'application/octet-stream',buffer:f.lorom});
  await poll(async()=>{const s=await state(page);return s.generation>g&&s.phase==='paused';},'load');
  await page.locator('#pause').click();
  await poll(async()=>(await state(page)).phase==='running','running');
  await poll(async()=>(await read(page,0x7ff0))[0]===0xa5,'boot');
  await poll(async()=>(await state(page)).frame>30,'frames');
  await page.locator('#pause').click();
  await poll(async()=>(await state(page)).phase==='paused','paused');
  await page.evaluate(()=>{document.getElementById('start-overlay').style.visibility='hidden';});
  await page.screenshot({path:join(out,'narrow-crt-on.png')});
  await page.evaluate(()=>{document.getElementById('start-overlay').style.visibility='';});
  await ctx.close();
}

// ---- 2D fallback (WebGPU unavailable), CRT truthfully off ----
{
  const ctx=await browser.newContext({viewport:{width:1100,height:850}});
  await ctx.addInitScript(()=>Object.defineProperty(navigator,'gpu',{get:()=>undefined,configurable:true}));
  const page=await ctx.newPage();
  await page.goto(base+'/?test=1');await page.waitForFunction(()=>!!window.__zupernesTest);
  const g=(await state(page)).generation;
  await page.locator('#file').setInputFiles({name:'fallback.sfc',mimeType:'application/octet-stream',buffer:f.lorom});
  await poll(async()=>{const s=await state(page);return s.generation>g&&s.phase==='paused';},'load');
  await page.locator('#pause').click();
  await poll(async()=>(await state(page)).phase==='running','running');
  await poll(async()=>(await read(page,0x7ff0))[0]===0xa5,'boot');
  await poll(async()=>(await state(page)).frame>30,'frames');
  await page.locator('#pause').click();
  await poll(async()=>(await state(page)).phase==='paused','paused');
  await page.evaluate(()=>{document.getElementById('start-overlay').style.visibility='hidden';});
  await page.screenshot({path:join(out,'fallback-2d.png')});
  await page.evaluate(()=>{document.getElementById('start-overlay').style.visibility='';});
  await ctx.close();
}
await browser.close();
console.log('captures in',out);
