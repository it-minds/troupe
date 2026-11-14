// What a read says while it is under way: a panel says what it loads and nothing more; a
// whole page that takes a while (the audit trail, a check of the whole chain) says a line
// from the shared set first, the same one for the same thing, and the facts after it.

import { LINES } from "@troupe/client";
import { afterEach, describe, expect, it } from "vitest";
import { Loading } from "../src/views/bits";
import { render } from "./support";

let unmount: (() => void) | null = null;

afterEach(() => {
  unmount?.();
  unmount = null;
  document.body.innerHTML = "";
});

const said = (): string => document.querySelector(".state.loading")?.textContent ?? "";

async function drawn(what: string, slow?: boolean): Promise<string> {
  unmount = render(<Loading what={what} slow={slow ?? false} />).unmount;
  await new Promise((r) => setTimeout(r, 0));
  return said();
}

describe("Loading", () => {
  it("says what it loads, and nothing else, on a panel", async () => {
    expect(await drawn("the runs")).toBe("Loading the runs…");
  });

  it("says a line from the shared set first on a slow, whole-page load, and the facts last", async () => {
    const text = await drawn("the audit", true);
    const line = text.split(" — ")[0]!;
    expect(LINES.loading as readonly string[]).toContain(line);
    expect(text).toBe(`${line} — Loading the audit…`);
    expect(line).toBe(line.toLowerCase());
    expect(text).not.toContain("!");
  });

  it("is the same line for the same thing, so it does not change under the person", async () => {
    const first = await drawn("the audit", true);
    unmount?.();
    expect(await drawn("the audit", true)).toBe(first);
  });
});
