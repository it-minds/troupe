// No test here asserts at once on words that arrive after an async step: it waits for
// them with `await sees(…)`. The bare `expect(says(…)).toBe(true)` was the shape of most
// of this suite's flakes; a line meant at once says why (`// at once: <why>`).

import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { bareAssertions, bareIn } from "../../../packages/client/test/support/waits.js";

const bare = (call: string, matcher: string) => `expect(${call}("Ready")).${matcher};`;

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
});
