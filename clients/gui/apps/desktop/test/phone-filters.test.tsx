// The sessions list's head at phone width (issue #950). Below 720px the four filters are
// not in the head: a Filter button beside the search opens them in the phone's sheet,
// reads "Filter · n" while n are set, and the "x of y" count stays beside it, so the list
// starts above the fold. A wide window keeps them inline.
//
// jsdom lays nothing out and answers no media query, so the window's width is what
// `matchMedia` says it is here; the heights are measured in a browser and written in the
// pull request.

import { afterEach, describe, expect, it } from "vitest";
import type { FleetRow } from "@troupe/client";
import { NARROW_QUERY } from "../src/narrow";
import { Sessions } from "../src/views/Sessions";
import { render, sees, seesButton, waitFor } from "./support";

let unmount: (() => void) | null = null;

afterEach(() => {
  unmount?.();
  unmount = null;
  delete (globalThis as { matchMedia?: unknown }).matchMedia;
});

/** A window whose width answers `narrow` to the app's phone query. */
function windowOf(narrow: boolean): void {
  globalThis.matchMedia = ((query: string) => ({
    matches: narrow && query === NARROW_QUERY,
    media: query,
    onchange: null,
    addEventListener: () => undefined,
    removeEventListener: () => undefined,
    addListener: () => undefined,
    removeListener: () => undefined,
    dispatchEvent: () => false,
  })) as unknown as typeof matchMedia;
}

function row(overrides: Partial<FleetRow>): FleetRow {
  return {
    id: "s-1",
    kind: "local",
    source: "daemon",
    title: "A session",
    profile: "build",
    owner: null,
    state: "active",
    status: "idle",
    doneReason: null,
    pendingApprovals: 0,
    pendingQuestions: 0,
    costMicros: null,
    lastActiveAt: new Date(Date.now() - 5 * 60_000).toISOString(),
    pinned: false,
    yourRole: null,
    origin: null,
    reviewedBy: null,
    sync: null,
    raw: null,
    ...overrides,
  };
}

// Two places and two states, so all four selects are drawn.
const rows = [
  row({ id: "s-1", title: "Ledger", kind: "local", state: "active" }),
  row({ id: "s-2", title: "Notes", kind: "team", state: "done", status: null, profile: "review" }),
  row({ id: "s-3", title: "Plans", kind: "team", state: "active" }),
];

async function list(): Promise<void> {
  unmount = render(<Sessions rows={rows} loading={false} error={null} onOpen={() => undefined} onStart={() => undefined} />).unmount;
  await waitFor(toolbar, "the list's head");
}

function choose(select: HTMLSelectElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

const toolbar = (): HTMLElement | null => document.querySelector(".toolbar");
const sheet = (): HTMLElement | null => document.querySelector('.nav-sheet[aria-label="Filters"]');
const titles = (): string[] => [...document.querySelectorAll(".rows .title")].map((t) => t.textContent ?? "");

describe("the sessions list's filters at phone width", () => {
  it("keeps the search, a Filter button, the count and Start in the head, and the four selects in a sheet", async () => {
    windowOf(true);
    await list();

    const filter = await seesButton("Filter", toolbar()!);
    expect(toolbar()!.querySelectorAll("select")).toHaveLength(0);
    expect(toolbar()!.querySelector("input.search")).not.toBeNull();
    expect(filter.textContent).toBe("Filter");
    expect(filter.getAttribute("aria-haspopup")).toBe("dialog");
    expect(toolbar()!.querySelector(".count")?.textContent).toBe("3 of 3");
    await seesButton("Start a session", toolbar()!);
    expect(sheet()).toBeNull();

    filter.focus();
    filter.click();
    const opened = await waitFor(sheet, "the filter sheet");
    expect(opened.getAttribute("role")).toBe("dialog");
    expect([...opened.querySelectorAll("select")].map((s) => s.getAttribute("aria-label"))).toEqual(["State", "Status", "Profile", "Where it runs"]);
    expect(document.activeElement?.textContent).toBe("Done");

    // A value chosen applies at once: the list behind and the count follow, and the
    // button counts what is set.
    choose(opened.querySelector<HTMLSelectElement>('select[aria-label="State"]')!, "active");
    await waitFor(() => titles().join(",") === "Ledger,Plans", "the list filtered");
    choose(opened.querySelector<HTMLSelectElement>('select[aria-label="Where it runs"]')!, "team");
    await waitFor(() => titles().join(",") === "Plans", "the list filtered twice");
    await waitFor(() => filter.textContent === "Filter · 2", "the count on the button");
    expect(toolbar()!.querySelector(".count")?.textContent).toBe("1 of 3");
    expect(opened.querySelector(".count")?.textContent).toBe("1 of 3");

    // Done shuts it and the focus goes back to the button.
    (await seesButton("Done", opened)).click();
    await waitFor(() => !sheet(), "the sheet shut by Done");
    expect(document.activeElement).toBe(filter);

    // Escape shuts it too, and what was chosen stays chosen.
    filter.click();
    const again = await waitFor(sheet, "the sheet again");
    expect(again.querySelector<HTMLSelectElement>('select[aria-label="State"]')?.value).toBe("active");
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    await waitFor(() => !sheet(), "the sheet shut by Escape");
    await sees("Plans");
  });

  it("keeps Tab inside the sheet", async () => {
    windowOf(true);
    await list();
    (await seesButton("Filter", toolbar()!)).click();
    const opened = await waitFor(sheet, "the filter sheet");
    const done = await seesButton("Done", opened);
    const last = opened.querySelector<HTMLSelectElement>('select[aria-label="Where it runs"]')!;

    expect(document.activeElement).toBe(done);
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true }));
    expect(document.activeElement).toBe(last);
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
    expect(document.activeElement).toBe(done);
  });

  it("leaves the filters inline on a wide window", async () => {
    windowOf(false);
    await list();
    await seesButton("Start a session", toolbar()!);
    expect([...toolbar()!.querySelectorAll("select")].map((s) => s.getAttribute("aria-label"))).toEqual(["State", "Status", "Profile", "Where it runs"]);
    expect(toolbar()!.querySelector(".filter-open")).toBeNull();
    expect(toolbar()!.querySelector(".count")?.textContent).toBe("3 of 3");
    expect(sheet()).toBeNull();
  });
});
