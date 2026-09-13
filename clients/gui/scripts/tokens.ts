// Generate `apps/desktop/src/tokens.css` from `docs/design/tokens.json`.
//
//   pnpm tokens
//
// The design file is the source of truth for every colour, radius and duration in the
// product. Copying them into a stylesheet by hand is how a design system stops being
// one, so they are generated and the generated file is committed. `pnpm tokens:check`
// fails if it is stale, which is what CI should run.
//
// The variable names match `docs/design/example.dc.html`, so a screen prototyped there
// pastes into the app and keeps its colours.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

interface Themed {
  dark: string;
  light: string;
}

const root = fileURLToPath(new URL("..", import.meta.url));
const tokens = JSON.parse(readFileSync(`${root}docs/design/tokens.json`, "utf8")) as Record<string, any>;

const dark: string[] = [];
const light: string[] = [];

function put(name: string, value: Themed | string | undefined): void {
  if (value === undefined) return;
  if (typeof value === "string") {
    dark.push(`  --${name}: ${value};`);
    return;
  }
  dark.push(`  --${name}: ${value.dark};`);
  light.push(`  --${name}: ${value.light};`);
}

function blank(): void {
  dark.push("");
  light.push("");
}

const c = tokens["color"];

put("font-sans", tokens["typography"].family.sans.value);
put("font-mono", tokens["typography"].family.mono.value);
blank();

for (const [k, v] of Object.entries(c.bg)) put(k === "scrim" ? "scrim" : `bg-${k}`, v as Themed);
blank();
// `link` and `linkHover` live under `text` in the design file but read better on their
// own, so they are emitted once, below, rather than twice under two names.
for (const [k, v] of Object.entries(c.text)) {
  if (k === "link" || k === "linkHover") continue;
  put(`text-${k}`, v as Themed);
}
put("link", c.text.link);
put("link-hover", c.text.linkHover);
blank();
put("border-hairline", c.border.hairline);
put("border-strong", c.border.strong);
put("focus", c.border.focus);
put("divider", c.border.divider);
blank();

// Status: `fg`, `bg`, `border`, and the two extras amber alone carries.
for (const [status, body] of Object.entries<any>(c.status)) {
  const short = status === "readonly" ? "readonly" : status;
  put(`${short}-fg`, body.fg);
  put(`${short}-bg`, body.bg);
  put(`${short}-bd`, body.border);
  if (body.solid) put(`${short}-solid`, body.solid);
  if (body.glow) put(`${short}-glow`, body.glow);
}
blank();

put("diff-add-bg", c.diff.addedBg);
put("diff-add-fg", c.diff.addedText);
put("diff-add-mark", c.diff.addedMarker);
put("diff-del-bg", c.diff.removedBg);
put("diff-del-fg", c.diff.removedText);
put("diff-del-mark", c.diff.removedMarker);
put("diff-ctx", c.diff.contextText);
put("diff-gutter-bg", c.diff.gutterBg);
put("diff-gutter-fg", c.diff.gutterText);
put("diff-hunk", c.diff.hunkHeader);
blank();

for (let i = 1; i <= 6; i++) put(`p${i}`, c.person[String(i)]);
put("p-self", c.person.self);
put("p-agent", c.person.agent);
blank();

for (const [k, v] of Object.entries<any>(tokens["shadow"])) {
  if (k === "none" || k === "note") continue;
  put(`sh-${k === "footlight" ? "footlight" : k}`, { dark: v.dark, light: v.light });
}
blank();

for (const [k, v] of Object.entries<string>(tokens["space"])) put(`space-${k}`, v);
blank();
for (const [k, v] of Object.entries<string>(tokens["radius"])) {
  if (k === "note") continue;
  put(`radius-${k}`, v);
}
blank();
for (const [k, v] of Object.entries<string>(tokens["border"])) {
  if (k === "note") continue;
  put(`bw-${k}`, v);
}
blank();
for (const [k, v] of Object.entries<string>(tokens["motion"].duration)) put(`dur-${k}`, v);
for (const [k, v] of Object.entries<string>(tokens["motion"].easing)) put(`ease-${k}`, v);
blank();
put("touch-target", tokens["size"].touchTarget.value);
put("rail-width", tokens["size"].railWidth);
put("backstage-width", tokens["size"].backstageWidth);
put("composer-min-height", tokens["size"].composerMinHeight);
for (const [k, v] of Object.entries<string>(tokens["size"].avatar)) put(`avatar-${k}`, v);
blank();
for (const [k, v] of Object.entries<any>(tokens["breakpoint"])) put(`bp-${k}`, v.value);

const trim = (lines: string[]) => lines.join("\n").replace(/\n{3,}/g, "\n\n").replace(/\n+$/, "");

const css = `/* Generated from docs/design/tokens.json by scripts/tokens.ts. Do not edit by hand:
   run \`pnpm tokens\` instead. The design file is the source of truth for every colour,
   radius and duration in the product.

   Dark is the default theme — this is a tool people sit in all day watching output
   stream. Light is the same tokens under a different set of values; components never
   choose between them. */

:root {
${trim(dark)}

  color-scheme: dark;
}

:root[data-theme="light"] {
${trim(light)}

  color-scheme: light;
}

/* A person who has asked their system for light and never touched the toggle gets it. */
@media (prefers-color-scheme: light) {
  :root:not([data-theme="dark"]) {
${trim(light)
  .split("\n")
  .map((l) => (l ? `  ${l}` : l))
  .join("\n")}

    color-scheme: light;
  }
}
`;

writeFileSync(`${root}apps/desktop/src/tokens.css`, css);
console.log(`wrote apps/desktop/src/tokens.css (${css.split("\n").length} lines)`);
