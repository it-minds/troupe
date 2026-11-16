// Generate the documentation site's sharing card, `docs/assets/social-card.png` at the
// repository root: the picture a link to any page of the site shows where it is posted
// (Open Graph and Twitter, from `docs/overrides/main.html`).
//
//   pnpm social-card                  # with Chrome or Edge where they usually are
//   CHROME=/path/to/chromium pnpm social-card
//
// 1200 by 630, the size those cards are drawn at. Drawn from the same files the product is:
// the colours are Afterglow's dark values from `docs/design/themes/afterglow.tokens.json`,
// the mask is `apps/desktop/src/mark.ts` drawn as `views/brand.tsx` draws it, and the type
// is the app's own Figtree, DM Mono and VT323 from the packages the desktop app bundles.
// Text needs a font renderer, so a headless Chromium takes the picture of a page built
// here; it opens a local file and nothing else. The output is committed, and run again
// when the tokens, the mark or the words change.

import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { MARK } from "../apps/desktop/src/mark";

const root = fileURLToPath(new URL("..", import.meta.url));
const out = fileURLToPath(new URL("../../../docs/assets/social-card.png", import.meta.url));
const tokens = JSON.parse(readFileSync(`${root}docs/design/themes/afterglow.tokens.json`, "utf8"));
const dark = (path: string): string => path.split(".").reduce((node, key) => node[key], tokens.color).dark;

const c = {
  ground: dark("bg.canvas"),
  panel: dark("bg.panel"),
  rule: dark("border.hairline"),
  shadow: dark("bg.shadow"),
  ink: dark("text.primary"),
  body: dark("text.secondary"),
  inverse: dark("text.inverse"),
  reserved: dark("status.waiting.solid"),
  machine: dark("status.running.fg"),
};

const font = (pkg: string, file: string): string =>
  pathToFileURL(`${root}apps/desktop/node_modules/@fontsource/${pkg}/files/${file}`).href;

const mask = `
<svg width="208" height="208" viewBox="${MARK.viewBox}" aria-hidden="true">
  <defs><clipPath id="lit"><rect x="24" y="0" width="24" height="48"/></clipPath></defs>
  <path d="${MARK.path}" fill="${c.reserved}" clip-path="url(#lit)"/>
  <path d="${MARK.path}" fill="none" stroke="${c.ink}" stroke-width="${MARK.stroke.lg}" stroke-linejoin="round"/>
  <path d="${MARK.seam}" stroke="${c.ink}" stroke-width="1.4"/>
  <path d="${MARK.eyeLeft}" fill="${c.ink}"/>
  <path d="${MARK.eyeRight}" fill="${c.inverse}"/>
</svg>`;

const page = `<!doctype html>
<meta charset="utf-8">
<style>
  @font-face { font-family: Figtree; font-weight: 900; src: url(${font("figtree", "figtree-latin-900-normal.woff2")}); }
  @font-face { font-family: Figtree; font-weight: 400; src: url(${font("figtree", "figtree-latin-400-normal.woff2")}); }
  @font-face { font-family: "DM Mono"; font-weight: 400; src: url(${font("dm-mono", "dm-mono-latin-400-normal.woff2")}); }
  @font-face { font-family: VT323; src: url(${font("vt323", "vt323-latin-400-normal.woff2")}); }
  html, body { margin: 0; width: 1200px; height: 630px; overflow: hidden; background: ${c.ground}; }
  body { box-sizing: border-box; padding: 72px 80px; display: flex; flex-direction: column; justify-content: space-between; font-family: Figtree, sans-serif; color: ${c.ink}; }
  .label { font-family: VT323, monospace; font-size: 34px; letter-spacing: 0.18em; color: ${c.machine}; }
  .lockup { display: flex; align-items: center; gap: 48px; }
  h1 { margin: 0; font-weight: 900; font-size: 168px; line-height: 0.9; letter-spacing: -0.02em; }
  h1 span { color: ${c.reserved}; }
  p { margin: 0; font-size: 40px; line-height: 1.3; max-width: 980px; color: ${c.ink}; }
  .foot { display: flex; white-space: nowrap; font-family: "DM Mono", monospace; font-size: 24px; letter-spacing: 0.08em; text-transform: uppercase; color: ${c.body}; border-top: 1px solid ${c.rule}; padding-top: 24px; }
  .foot b { font-weight: 400; color: ${c.ink}; }
  .foot i { font-style: normal; padding: 0 16px; color: ${c.rule}; }
</style>
<div class="label">// A COMPANY OF AGENTS</div>
<div class="lockup">${mask}<h1>TROU<span>PE</span></h1></div>
<p>Coding agents on your own machine and on your team's Kubernetes cluster.</p>
<div class="foot"><b>Open source</b><i>/</i>Apache-2.0<i>/</i>Self-hosted<i>/</i>Bring your own model</div>
`;

const candidates = [
  process.env["CHROME"],
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome",
].filter((p): p is string => !!p);
const chrome = candidates.find((p) => existsSync(p));
if (!chrome) throw new Error(`no Chromium found; set CHROME to one (looked in ${candidates.join(", ")})`);

const dir = mkdtempSync(join(tmpdir(), "troupe-card-"));
try {
  writeFileSync(join(dir, "card.html"), page);
  execFileSync(chrome, [
    "--headless=new",
    `--user-data-dir=${join(dir, "profile")}`,
    "--no-first-run",
    "--hide-scrollbars",
    "--force-device-scale-factor=1",
    "--window-size=1200,630",
    "--virtual-time-budget=3000",
    `--screenshot=${out}`,
    pathToFileURL(join(dir, "card.html")).href,
  ], { stdio: "inherit" });
} finally {
  rmSync(dir, { recursive: true, force: true });
}
console.log(`wrote ${out}`);
