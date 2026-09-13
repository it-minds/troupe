// Generate `apps/desktop/src/tokens.css` from `docs/design/themes/*.tokens.json`.
//
//   pnpm tokens
//
// The design files are the source of truth for every colour, radius and duration in
// the product. Copying them into a stylesheet by hand is how a design system stops
// being one, so they are generated and the generated file is committed.
// `pnpm tokens:check` fails if it is stale, which is what CI runs.
//
// Three themes, one contract. Every theme file exposes *exactly* the same token names;
// a theme swaps values and nothing else. That is enforced here rather than trusted: a
// theme that has grown or lost a token fails the build, because a component that reads
// `--waiting-solid` must get an answer in all three.
//
// The output is keyed on two attributes on the document root, which are separate
// questions and are never merged into one:
//
//   data-theme="signal" | "footlight" | "limelight"    which palette
//   data-mode="light" | "dark" | absent                absent means follow the system
//
// Selectors are attribute-only — `[data-theme="x"]`, not `:root[data-theme="x"]` — so a
// nested element can carry a theme of its own. That is what makes the live previews on
// the Appearance screen real rather than swatches: each card is a subtree in its theme.

import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

interface Themed {
  dark: string;
  light: string;
}

type Mode = "dark" | "light";

const root = fileURLToPath(new URL("..", import.meta.url));
const themeDir = `${root}docs/design/themes`;

/** Signal ships as the default: neutral graphite never fights a pasted screenshot. */
const DEFAULT_THEME = "signal";

const themes = readdirSync(themeDir)
  .filter((f) => f.endsWith(".tokens.json"))
  .map((f) => ({ id: f.replace(".tokens.json", ""), tokens: JSON.parse(readFileSync(`${themeDir}/${f}`, "utf8")) as Record<string, any> }))
  .sort((a, b) => (a.id === DEFAULT_THEME ? -1 : b.id === DEFAULT_THEME ? 1 : a.id.localeCompare(b.id)));

if (!themes.some((t) => t.id === DEFAULT_THEME)) throw new Error(`no ${DEFAULT_THEME}.tokens.json in docs/design/themes`);

/** Collects `--name: value` lines for one pass over one theme. */
class Sheet {
  readonly lines: string[] = [];
  constructor(private readonly mode: Mode | null) {}

  put(name: string, value: Themed | string | undefined): void {
    if (value === undefined) return;
    const resolved = typeof value === "string" ? value : this.mode ? value[this.mode] : undefined;
    if (resolved === undefined) return;
    this.lines.push(`  --${name}: ${resolved};`);
  }

  blank(): void {
    this.lines.push("");
  }
}

/** The colours. Everything here changes with the theme; nothing else does. */
function colours(tokens: Record<string, any>, mode: Mode): string[] {
  const s = new Sheet(mode);
  const c = tokens["color"];

  for (const [k, v] of Object.entries(c.bg)) s.put(k === "scrim" ? "scrim" : `bg-${k}`, v as Themed);
  s.blank();
  // `link` and `linkHover` live under `text` in the design file but read better on
  // their own, so they are emitted once, below, rather than twice under two names.
  for (const [k, v] of Object.entries(c.text)) {
    if (k === "link" || k === "linkHover") continue;
    s.put(`text-${k}`, v as Themed);
  }
  s.put("link", c.text.link);
  s.put("link-hover", c.text.linkHover);
  s.blank();
  s.put("border-hairline", c.border.hairline);
  s.put("border-strong", c.border.strong);
  s.put("focus", c.border.focus);
  s.put("divider", c.border.divider);
  s.blank();

  // Status: `fg`, `bg`, `border`, and the two extras the reserved colour alone carries.
  for (const [status, body] of Object.entries<any>(c.status)) {
    s.put(`${status}-fg`, body.fg);
    s.put(`${status}-bg`, body.bg);
    s.put(`${status}-bd`, body.border);
    if (body.solid) s.put(`${status}-solid`, body.solid);
    if (body.glow) s.put(`${status}-glow`, body.glow);
  }
  s.blank();

  s.put("diff-add-bg", c.diff.addedBg);
  s.put("diff-add-fg", c.diff.addedText);
  s.put("diff-add-mark", c.diff.addedMarker);
  s.put("diff-del-bg", c.diff.removedBg);
  s.put("diff-del-fg", c.diff.removedText);
  s.put("diff-del-mark", c.diff.removedMarker);
  s.put("diff-ctx", c.diff.contextText);
  s.put("diff-gutter-bg", c.diff.gutterBg);
  s.put("diff-gutter-fg", c.diff.gutterText);
  s.put("diff-hunk", c.diff.hunkHeader);
  s.blank();

  for (let i = 1; i <= 6; i++) s.put(`p${i}`, c.person[String(i)]);
  s.put("p-self", c.person.self);
  s.put("p-agent", c.person.agent);
  s.blank();

  for (const [k, v] of Object.entries<any>(tokens["shadow"])) {
    if (k === "none" || k === "$note" || k === "note") continue;
    s.put(`sh-${k}`, { dark: v.dark, light: v.light });
  }

  return s.lines;
}

/**
 * Everything a theme is not allowed to touch: type, space, radii, borders, motion,
 * sizes, breakpoints. Emitted once, from the default theme's file, because all three
 * carry identical values and a difference here would be a redesign, not a theme.
 */
function structure(tokens: Record<string, any>): string[] {
  const s = new Sheet(null);

  s.put("font-sans", tokens["typography"].family.sans.value);
  s.put("font-mono", tokens["typography"].family.mono.value);
  s.blank();
  for (const [k, v] of Object.entries<string>(tokens["space"])) s.put(`space-${k}`, v);
  s.blank();
  for (const [k, v] of Object.entries<string>(tokens["radius"])) {
    if (k.startsWith("$") || k === "note") continue;
    s.put(`radius-${k}`, v);
  }
  s.blank();
  for (const [k, v] of Object.entries<string>(tokens["border"])) {
    if (k.startsWith("$") || k === "note") continue;
    s.put(`bw-${k}`, v);
  }
  s.blank();
  for (const [k, v] of Object.entries<string>(tokens["motion"].duration)) s.put(`dur-${k}`, v);
  for (const [k, v] of Object.entries<string>(tokens["motion"].easing)) s.put(`ease-${k}`, v);
  s.blank();
  s.put("touch-target", tokens["size"].touchTarget.value);
  s.put("rail-width", tokens["size"].railWidth);
  s.put("backstage-width", tokens["size"].backstageWidth);
  s.put("composer-min-height", tokens["size"].composerMinHeight);
  for (const [k, v] of Object.entries<string>(tokens["size"].avatar)) s.put(`avatar-${k}`, v);
  s.blank();
  for (const [k, v] of Object.entries<any>(tokens["breakpoint"])) s.put(`bp-${k}`, v.value);

  return s.lines;
}

const trim = (lines: string[]) => lines.join("\n").replace(/\n{3,}/g, "\n\n").replace(/^\n+|\n+$/g, "");
const indent = (text: string, by = "  ") =>
  text
    .split("\n")
    .map((l) => (l ? `${by}${l}` : l))
    .join("\n");

// One contract, checked. Two themes that disagree about which tokens exist would leave
// a component reading a variable that resolves to nothing in one of them, and a missing
// colour is invisible until it is on someone's screen.
const contract = new Set(colours(themes[0]!.tokens, "dark").map((l) => l.trim().split(":")[0]));
for (const theme of themes.slice(1)) {
  for (const mode of ["dark", "light"] as const) {
    const names = new Set(colours(theme.tokens, mode).map((l) => l.trim().split(":")[0]));
    const missing = [...contract].filter((n) => n && !names.has(n));
    const extra = [...names].filter((n) => n && !contract.has(n));
    if (missing.length || extra.length) {
      throw new Error(
        `${theme.id} (${mode}) breaks the token contract: ${missing.length ? `missing ${missing.join(", ")}` : ""}` +
          `${extra.length ? ` extra ${extra.join(", ")}` : ""}. A theme that needs a new token name is a redesign, not a theme.`,
      );
    }
  }
}

const base = themes.find((t) => t.id === DEFAULT_THEME)!;

const blocks = themes.map((theme) => {
  const meta = theme.tokens["$meta"];
  const dark = trim(colours(theme.tokens, "dark"));
  const light = trim(colours(theme.tokens, "light"));
  return `/* ${meta.name} — ${meta.description} */
[data-theme="${theme.id}"] {
${dark}

  color-scheme: dark;
}

[data-theme="${theme.id}"][data-mode="light"] {
${light}

  color-scheme: light;
}

@media (prefers-color-scheme: light) {
  [data-theme="${theme.id}"]:not([data-mode="dark"]) {
${indent(light)}

    color-scheme: light;
  }
}`;
});

const css = `/* Generated from docs/design/themes/*.tokens.json by scripts/tokens.ts. Do not edit by
   hand: run \`pnpm tokens\` instead. The design files are the source of truth for every
   colour, radius and duration in the product.

   Three themes, one contract. Every theme exposes exactly the same token names, so a
   component reads \`--waiting-solid\` and never a hex, and never branches on a theme.

   Two attributes on the document root, because they are two questions:

     data-theme  which palette — ${themes.map((t) => t.id).join(", ")}
     data-mode   light, dark, or absent for "follow the system"

   The selectors are attribute-only rather than \`:root[...]\`, so any subtree can carry a
   theme of its own — which is how the Appearance screen previews a theme you are not
   using yet. \`:root\` below is the floor: ${DEFAULT_THEME} in dark, for the instant before
   anything has set an attribute. */

:root {
${trim(structure(base.tokens))}
}

/* The floor. index.html ships data-theme="${DEFAULT_THEME}" on <html>, so this is only ever
   reached by a document that lost the attribute. */
:root {
${trim(colours(base.tokens, "dark"))}

  color-scheme: dark;
}

${blocks.join("\n\n")}
`;

writeFileSync(`${root}apps/desktop/src/tokens.css`, css);

// The mask, as data. The brand is one silhouette drawn by one component, so the
// geometry is generated out of the design file too rather than retyped into a `<path>`
// where nobody would ever notice it drifting. It is not a colour and never changes
// between themes, so it comes from the default theme's file alone.
const m = base.tokens["mark"] as Record<string, any>;
const mark = `// Generated from docs/design/themes/${DEFAULT_THEME}.tokens.json by scripts/tokens.ts. Do not
// edit by hand: run \`pnpm tokens\`.
//
// ${m["$note"]}
//
// The rules that go with it, from the design file:
${(m["rules"] as string[]).map((r) => `//   - ${r}`).join("\n")}

export const MARK = {
  viewBox: ${JSON.stringify(m["viewBox"])},
  path: ${JSON.stringify(m["path"])},
  eyeLeft: ${JSON.stringify(m["eyeLeft"])},
  eyeRight: ${JSON.stringify(m["eyeRight"])},
  seam: ${JSON.stringify(m["seam"].path)},
  /** ${m["seam"].description} */
  seamMinSize: ${parseInt(m["seam"].minSize, 10)},
  stroke: { lg: ${JSON.stringify(m["strokeWidth"].lg)}, md: ${JSON.stringify(m["strokeWidth"].md)}, sm: ${JSON.stringify(m["strokeWidth"].sm)} },
  lightDirection: ${JSON.stringify(m["lightDirection"])},
} as const;
`;
writeFileSync(`${root}apps/desktop/src/mark.ts`, mark);

console.log(`wrote apps/desktop/src/tokens.css (${css.split("\n").length} lines, ${themes.length} themes, default ${DEFAULT_THEME}) and apps/desktop/src/mark.ts`);
