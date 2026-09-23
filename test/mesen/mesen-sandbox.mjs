import { cpSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

// The staged app is ~128 MB; a parallel tail campaign stages one copy per
// tail, so on APFS use clonefile (`cp -c`) for a copy-on-write duplicate with
// byte-identical content. macOS `cp -c` itself falls back to copyfile(2) on
// non-cloning filesystems; any cp failure falls back to plain cpSync.
function copyAppBundle(src, dest) {
  if (process.platform === "darwin") {
    const p=spawnSync("cp",["-cR",src,dest],{encoding:"utf8"});
    if (p.status === 0) return;
  }
  cpSync(src,dest,{recursive:true});
}
// The reviewed app bundle is a binary input, not a session-state input.
// Mesen stores battery SRAM below Contents/MacOS/Saves; copying that directory
// made a prior run's valid SMW file silently preserve the title-demo $0109
// level override. LoadMapGameMode then took CODE_00A096..00A0AD and bypassed
// the overworld, so the navigator could never observe or drive mode $0E.
export function stageMesenApp(outPath, guard) {
  const sandbox=join(outPath,"mesen-app");
  copyAppBundle(resolve(guard.executable,"../../.."),sandbox);
  const portable=join(sandbox,"Contents/MacOS");
  rmSync(join(portable,"Saves"),{recursive:true,force:true});
  const settings=join(portable,"settings.json"), config=JSON.parse(readFileSync(settings,"utf8").replace(/^\uFEFF/,""));
  config.Snes.RamPowerOnState="AllZeros";
  config.Snes.Overscan={Top:7,Bottom:8,Left:0,Right:0};
  writeFileSync(settings,JSON.stringify(config,null,2)+"\n");
  return join(portable,"Mesen");
}
