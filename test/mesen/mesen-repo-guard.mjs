// Certifies the checkout that supplied the Mesen testrunner, independently of
// ZuperNES's guard.  The pin is the reviewed `zuperworld-headless` checkout.
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";

export const MESEN_REPO = "/Users/v64/Repos/mesen-src";
export const MESEN_BINARY = "/Users/v64/Repos/mesen-src/bin/osx-arm64/Release/osx-arm64/publish/Mesen.app/Contents/MacOS/Mesen";
export const MESEN_BRANCH = "atomic-snapshot";
// Deliberately literal: a changed Mesen checkout needs an explicit review and
// pin update, never a silently new third vote.
export const MESEN_REVISION = "3b058f9fbf6f446028eab3a83c5a3db35b1b960a";

function git(...args) {
  const p = spawnSync("git", ["-C", MESEN_REPO, ...args], { encoding: "utf8" });
  if (p.status !== 0) throw new Error((p.stderr || p.stdout).trim());
  return p.stdout.trim();
}

export function assertMesenRepo(binary = MESEN_BINARY) {
  const repo = realpathSync(MESEN_REPO), executable = realpathSync(binary);
  if (!executable.startsWith(`${repo}/`)) throw new Error(`MESEN REPO CHECK FAILED: binary is outside certified checkout: ${executable}`);
  const branch = git("branch", "--show-current"), revision = git("rev-parse", "HEAD"), dirty = git("status", "--porcelain=v1", "--untracked-files=all");
  if (branch !== MESEN_BRANCH) throw new Error(`MESEN REPO CHECK FAILED: expected branch ${MESEN_BRANCH}, got ${branch}`);
  if (revision !== MESEN_REVISION) throw new Error(`MESEN REPO CHECK FAILED: expected ${MESEN_REVISION}, got ${revision}`);
  if (dirty) throw new Error(`MESEN REPO DIRTY: refusing to record from ${repo} at ${revision}\n${dirty}`);
  return { repo, executable, branch, revision };
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname)) {
  try { const r = assertMesenRepo(process.argv[2] ?? MESEN_BINARY); console.log(`MESEN REPO CLEAN: ${r.revision} (${r.repo})`); }
  catch (err) { console.error(err.message); process.exit(1); }
}
