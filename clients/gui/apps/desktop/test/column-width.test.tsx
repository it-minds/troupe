// The session's one column (troupe #926): 760px on a laptop, widening with the window to a
// cap of 1200px, which the transcript, the cards at its foot and the composer share through
// the gutter. jsdom lays nothing out, so the sheet's rule is read and worked out at the
// widths the pull request measured in the pane.

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// A name in a variable, so the bundler reads it as a file to open and not as an asset.
const sheet = "../src/styles.css";
const css = readFileSync(new URL(sheet, import.meta.url), "utf8");

function conversationRule(): string {
  const match = /\n\.conversation \{([^}]*)\}/.exec(css);
  if (!match) throw new Error("no .conversation rule in the sheet");
  return match[1]!;
}

/** The column's width at a window this wide, from `clamp(<min>px, <a>vw - <b>px, <max>px)`. */
function columnAt(windowWidth: number): number {
  const m = /--column: clamp\((\d+)px, (\d+(?:\.\d+)?)vw - (\d+)px, (\d+)px\);/.exec(conversationRule());
  if (!m) throw new Error("--column is not the clamp this test reads");
  const [min, vw, less, max] = m.slice(1).map(Number) as [number, number, number, number];
  return Math.min(max, Math.max(min, (vw * windowWidth) / 100 - less));
}

describe("the session's column", () => {
  it("is 760px on a laptop and widens with the window to 1200px, where it stops", () => {
    expect(Math.round(columnAt(1024))).toBe(760);
    expect(columnAt(1280)).toBe(760);
    expect(Math.round(columnAt(1600))).toBe(987);
    expect(columnAt(1920)).toBe(1200);
    expect(columnAt(2560)).toBe(1200);
  });

  it("is what the gutter centres, so the transcript, the cards and the composer follow it", () => {
    expect(conversationRule()).toMatch(/--gutter: max\(var\(--space-5\), calc\(\(100% - var\(--column\)\) \/ 2\)\);/);
    // The transcript, the cards at its foot and the composer take their inset from it.
    expect(css).toMatch(/\.stream \{[^}]*padding: 28px var\(--gutter\) 32px;/);
    expect(css).toMatch(/\.conversation > \.approval \{[^}]*margin-inline: var\(--gutter\);/);
    expect(css).toMatch(/\.dock \{[^}]*padding: 0 var\(--gutter\) 18px;/);
  });
});
