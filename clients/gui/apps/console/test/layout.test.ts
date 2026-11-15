// The console never scrolls sideways as a page: a table wider than its page scrolls in its
// own box, a setting's row stacks before its columns run past the window, and a table's
// actions stay at the box's edge rather than past it.
//
// jsdom lays nothing out, so this reads the views and the stylesheet: every `<table>` a
// view draws sits directly in a `.scroll` box, every actions column is marked as one, and
// the rules that pin it and stack the rows are there.

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const src = resolve(dirname(fileURLToPath(import.meta.url)), "../src");
const views = readdirSync(join(src, "views"))
  .filter((name) => name.endsWith(".tsx"))
  .map((name) => ({ name, lines: readFileSync(join(src, "views", name), "utf8").split(/\r?\n/) }));
const css = readFileSync(join(src, "styles.css"), "utf8");

describe("the console's layout at narrow widths", () => {
  it("draws every table inside a box that scrolls sideways on its own", () => {
    const bare: string[] = [];
    for (const { name, lines } of views) {
      lines.forEach((line, i) => {
        if (!/^\s*<table\b/.test(line)) return;
        let j = i - 1;
        while (j >= 0 && lines[j]!.trim() === "") j--;
        if (!/<div className="scroll">\s*$/.test(lines[j] ?? "")) bare.push(`${name}:${i + 1}`);
      });
    }
    expect(bare).toEqual([]);
  });

  it("marks every actions column so it stays at the table's right edge", () => {
    const unmarked = views.flatMap(({ name, lines }) =>
      lines.flatMap((line, i) => (/<th\b[^>]*aria-label="Actions"/.test(line) && !/className="row-actions"/.test(line) ? [`${name}:${i + 1}`] : [])),
    );
    expect(unmarked).toEqual([]);
    expect(css).toMatch(/\.scroll th\.row-actions,\s*\.scroll td\.row-actions \{[^}]*position: sticky;[^}]*right: 0;/);
  });

  it("stacks a setting's row before its four columns run past a 1024px window", () => {
    const stack = /@media \(max-width: (\d+)px\) \{\s*\.row \{\s*grid-template-columns: 1fr;/.exec(css);
    expect(stack).not.toBeNull();
    expect(Number(stack![1])).toBeGreaterThanOrEqual(1100);
  });
});
