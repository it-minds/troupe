// No test here asserts at once on words that arrive after an async step: it waits for
// them with `await sees(…)`. The bare `expect(says(…)).toBe(true)` was the shape of most
// of this suite's flakes; a line meant at once says why (`// at once: <why>`). A control
// is waited for the same way (`await seesButton(…)`, `await seesField(…)`), not found at
// once with `button(…)` or `field(…)`.

import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { bareAssertions, bareIn } from "../../../packages/client/test/support/waits.js";

const bare = (call: string, matcher: string) => `expect(${call}("Ready")).${matcher};`;
// A read of a control found at once: what follows its call, as `!.disabled).toBe(true);`.
const read = (call: string, rest: string) => `expect(${call}("Save")${rest}`;

describe("the suite's assertions on the page's words", () => {
  it("wait for them in every test file", () => {
    expect(bareAssertions(dirname(fileURLToPath(import.meta.url)))).toEqual([]);
  });

  it("refuses the bare forms, and lets a line marked at once through", () => {
    expect(bareIn(`await sees("Ready");\n${bare("says", "toBe(true)")}`)).toEqual([`2: ${bare("says", "toBe(true)")}`]);
    expect(bareIn(bare("says", "toBeTruthy()"))).toHaveLength(1);
    expect(bareIn(bare("link", "not.toBeNull()"))).toHaveLength(1);
    expect(bareIn(`// at once: drawn by the first render\n${bare("says", "toBe(true)")}`)).toEqual([]);
    expect(bareIn(bare("says", "toBe(false)"))).toEqual([]);
  });

  it("refuses a control found at once, there or read, and lets its absence through", () => {
    expect(bareIn(bare("button", "not.toBeNull()"))).toHaveLength(1);
    expect(bareIn(bare("field", "toBeTruthy()"))).toHaveLength(1);
    expect(bareIn(bare("row", "toBeDefined()"))).toHaveLength(1);
    expect(bareIn(read("button", "!.disabled).toBe(true);"))).toHaveLength(1);
    expect(bareIn(read("field", "?.value).toBe(\"ops\");"))).toHaveLength(1);
    expect(bareIn(`// at once: drawn by the first render\n${read("button", "!.disabled).toBe(true);")}`)).toEqual([]);
    expect(bareIn(bare("button", "toBeNull()"))).toEqual([]);
    expect(bareIn(`expect((await seesButton("Save")).disabled).toBe(true);`)).toEqual([]);
  });
});
