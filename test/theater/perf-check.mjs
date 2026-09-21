// ZuperNES theater performance gate (TASK.md criterion 5).
//   node test/theater/perf-check.mjs [base-url] [seconds]
// Measures the emulated frame count over a wall-time window AFTER warmup,
// on the real (headed, GPU-accelerated) desktop Chrome, plus toolbar
// responsiveness during emulation. Reports:
//   - environment: browser version, headed/headedless, presenter
//   - emulated fps -> % of NTSC 60.0988 (must be 90..110%)
//   - toolbar click -> phase flip latency (must be < 500 ms)
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import {writeFileSync,mkdirSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {fixtures} from './fixtures.mjs';
let pw;try{pw=await import('playwright');}catch{pw=createRequire(join(execFileSync('npm',['root','-g'],{encoding:'utf8'}).trim(),'_loader.cjs'))('playwright');}
const base=process.argv[2]??'http://127.0.0.1:8380';
const seconds=Number(process.argv[3]??10);
const out=resolve(process.env.THEATER_ARTIFACTS??'.zig-cache/theater-perf');mkdirSync(out,{recursive:true});
const report={};

// Headed (not headless) Chrome: an actual accelerated desktop browser, as
// TASK.md requires. Headless results may ONLY supplement, never substitute.
let browser;
try{browser=await pw.chromium.launch({channel:'chrome',headless:false,args:['--enable-unsafe-webgpu']});}
catch(e){console.error('BLOCKED: could not launch headed Chrome:',e.message);process.exit(2);}
const context=await browser.newContext({viewport:{width:1100,height:850}});
const page=await context.newPage();
const errors=[];page.on('pageerror',e=>errors.push(String(e)));
report.browser=await browser.version();
report.headed=true;

await page.goto(base+'/?test=1');
await page.waitForFunction(()=>!!window.__zupernesTest);
const state=()=>page.evaluate(()=>window.__zupernesTest.state());
const read=async(o,l=1)=>Array.from(await page.evaluate(async([o,n])=>await window.__zupernesTest.readWram(o,n),[o,l]));
async function poll(fn,d,t=20000){const t0=Date.now();for(;;){if(await fn())return;if(Date.now()-t0>t)throw Error('timeout '+d);await new Promise(r=>setTimeout(r,50));}}

const f=fixtures();
for(const [name,rom] of [['lorom',f.lorom],['hirom',f.hirom]]){
  const g=(await state()).generation;
  await page.locator('#file').setInputFiles({name:name+'.sfc',mimeType:'application/octet-stream',buffer:rom});
  await poll(async()=>{const s=await state();return s.generation>g&&s.phase==='paused';},'load '+name);
  await poll(async()=>{
    await page.evaluate(()=>window.__zupernesTest.presenterReady?.());
    return true;
  },'presenter ready');
  // Play (gesture) and warm up for 3 seconds.
  await page.locator('#pause').click();
  await poll(async()=>(await state()).phase==='running','running');
  await poll(async()=>(await read(0x7ff0))[0]===0xa5,'boot marker');
  report[name]={};
  report[name].presenter=(await state()).presenter;
  await page.waitForTimeout(3000); // warmup
  // The clean speed window: uninterrupted emulation - pausing inside it
  // would corrupt the measurement (paused time counts as elapsed, but no
  // frames run). Toolbar latency is measured separately afterwards.
  const f0=(await state()).frame;
  const t0=Date.now();
  await page.waitForTimeout(seconds*1000);
  const t1=Date.now();
  const f1=(await state()).frame;
  const dt=(t1-t0)/1000;
  // Toolbar response DURING emulation (measured after the clean window so
  // it cannot pollute the speed number). The clock starts BEFORE the click
  // is dispatched - Playwright's own actionability/dispatch time is part of
  // what a user experiences, not an invisible constant.
  const clickT=Date.now();
  await page.locator('#pause').click();
  let pausedAt=null;
  for(;;){ if((await state()).phase==='paused'){pausedAt=Date.now();break;} if(Date.now()-clickT>5000)break; }
  const flipLatency=pausedAt?pausedAt-clickT:null;
  await page.locator('#pause').click(); // resume for the next measurement
  await poll(async()=>(await state()).phase==='running','resume');
  // Extra frames during the pause window: f1-f0 counts them all, fine.
  const fps=(f1-f0)/dt;
  report[name].seconds=dt.toFixed(2);
  report[name].frames=f1-f0;
  report[name].fps=fps.toFixed(2);
  report[name].percentOfNtsc=(fps/60.0988*100).toFixed(1)+'%';
  report[name].toolbarFlipMs=flipLatency;
  assert(flipLatency!==null,'toolbar never responded');
  assert(flipLatency<500,`toolbar response ${flipLatency}ms >= 500ms`);
  assert(fps>=60.0988*0.9,`${name}: only ${fps.toFixed(1)} fps (<90% NTSC)`);
  assert(fps<=60.0988*1.1,`${name}: ${fps.toFixed(1)} fps (>110% NTSC - unthrottled?)`);
  console.log(`${name}: ${fps.toFixed(2)} fps = ${(fps/60.0988*100).toFixed(1)}% NTSC over ${dt.toFixed(1)}s (${f1-f0} frames), toolbar flip ${flipLatency}ms, presenter=${report[name].presenter}`);
}
assert.deepEqual(errors,[]);
writeFileSync(join(out,'perf.json'),JSON.stringify(report,null,2)+'\n');
console.log('PASS: performance (90-110% NTSC, toolbar <500ms)');
console.log('artifacts:',join(out,'perf.json'));
await browser.close();
