// The check behind the apps' waiting assertions: no test asserts at once on what arrives
// after an async step.
//
// Most of the GUI's flakes were one shape: `await waitFor(…)` on one thing, then
// `expect(says(…)).toBe(true)` on another that a later render draws, true on a fast
// machine and false on a busy one. The apps' supports wait instead (`await sees(…)`,
// `await seesLink(…)`), and each app's `waits.test.tsx` runs this over its test files so
// the bare form cannot come back. A line meant at once says why on itself or the line
// above: `// at once: <why>`.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** The assertions this refuses: a positive check of the page's words or of a link, not waited for. */
const BARE: Array<{ call: string; matchers: RegExp }> = [
  { call: "says", matchers: /^\s*\)\s*\.(toBe\(\s*true\s*\)|toBeTruthy\(\s*\))/ },
  { call: "link", matchers: /^\s*\)\s*\.(not\.toBeNull\(\s*\)|toBeTruthy\(\s*\)|toBeDefined\(\s*\))/ },
];

const MARK = "// at once:";

/** The index of the parenthesis that closes the one at `open`, past strings and templates. */
function closing(text: string, open: number): number {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === '"' || c === "'" || c === "`") {
      for (i++; i < text.length && text[i] !== c; i++) if (text[i] === "\\") i++;
      continue;
    }
    if (c === "(") depth++;
    else if (c === ")" && --depth === 0) return i;
  }
  return -1;
}

/** Every bare assertion in one file's text, as `<line>: <the line>`. */
export function bareIn(text: string): string[] {
  const found: string[] = [];
  const lines = text.split("\n");
  const re = /expect\(\s*(says|link)\(/g;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    const form = BARE.find((b) => b.call === m![1])!;
    const close = closing(text, m.index + m[0].length - 1);
    if (close < 0 || !form.matchers.test(text.slice(close + 1))) continue;
    const line = text.slice(0, m.index).split("\n").length;
    if (/^\s*(\/\/|\*)/.test(lines[line - 1]!)) continue; // a comment that names the form
    if (lines[line - 1]!.includes(MARK) || (lines[line - 2] ?? "").includes(MARK)) continue;
    found.push(`${line}: ${lines[line - 1]!.trim()}`);
  }
  return found;
}

/** Every bare assertion in the test files of `dir`, as `<file>:<line>: <the line>`. */
export function bareAssertions(dir: string): string[] {
  return readdirSync(dir)
    .filter((f) => /\.test\.tsx?$/.test(f))
    .sort()
    .flatMap((f) => bareIn(readFileSync(join(dir, f), "utf8")).map((hit) => `${f}:${hit}`));
}
