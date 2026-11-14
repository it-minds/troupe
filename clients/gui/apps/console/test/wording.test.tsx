// The console's words: a confirm's way out says what it does, a limit's hint says what the
// platform allows in words and one unit for money and time, an id keeps its case in a
// title, a state reads the same on every page, a delivery's outcome is a sentence, a row's
// buttons are two words, and an address a role may not open says so and is rewritten.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { duration, money } from "../src/views/bits";
import { outcomeWords } from "../src/views/Integrations";
import { PEOPLE, button, field, freshBrowser, render, says, sees, seesButton, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

async function open(hash: string, as: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, as);
  visit(hash);
  unmount = render(<App />).unmount;
}

const heading = (): string => document.querySelector("h1")?.textContent ?? "";
const css = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "../src/styles.css"), "utf8");

describe("a confirm's way out", () => {
  it("says Cancel where nothing was edited first, and how to type the id", async () => {
    await open("#/sessions");
    const row = await waitFor(() => [...document.querySelectorAll<HTMLTableRowElement>("table.sessions tbody tr")].find((r) => says("s-7f3a9c22", r)), "the sessions");
    button("Erase", row)!.click();
    await waitFor(() => says("What will happen"), "the preview");
    expect(button("Back to editing")).toBeNull();
    await seesButton("Cancel", document.querySelector(".preview")!);
    await sees("Type it exactly as shown.");
    expect(says("The name must match exactly")).toBe(false);
  });

  it("says Back to editing where the preview follows a form", async () => {
    await open("#/teams/core/limits");
    (await waitFor(() => button("Change core's limits"), "the limits")).click();
    type(await waitFor(() => field("Idle before it goes dormant"), "the form"), "600");
    button("Preview")!.click();
    await waitFor(() => says("What will happen"), "the preview");
    button("Back to editing")!.click();
    await waitFor(() => field("Idle before it goes dormant"), "the form again");
  });
});

describe("units and limits", () => {
  it("shows money in dollars and time in minutes and hours", () => {
    expect(money(12_500_000)).toBe("$12.50");
    expect(money(1_473_500_000)).toBe("$1,473.50");
    expect(money(0)).toBe("$0.00");
    expect(money(null)).toBe("—");
    expect(duration(1200)).toBe("20 min");
    expect(duration(45)).toBe("45 s");
    expect(duration(5400)).toBe("1 h 30 min");
    expect(duration(7200)).toBe("2 h");
    expect(duration(90)).toBe("1 min 30 s");
  });

  it("says what the platform allows of a switch in words, and the budget's unit", async () => {
    await open("#/teams/core/limits");
    (await waitFor(() => button("Change core's limits"), "the limits")).click();
    await waitFor(() => field("Members may pin a session"), "the form");
    const hints = [...document.querySelectorAll(".field .hint")].map((h) => h.textContent ?? "");
    expect(hints.filter((h) => /at most (yes|no)\b/.test(h))).toEqual([]);
    expect(hints.some((h) => h === "The platform allows it." || h === "The platform does not allow it.")).toBe(true);
    expect(hints.some((h) => h.startsWith("In dollars"))).toBe(true);
    expect(hints.some((h) => h.includes("currency units"))).toBe(false);
  });

  it("puts the unit on the Overview's spend", async () => {
    await open("#/overview");
    const metric = () => [...document.querySelectorAll<HTMLElement>(".metric")].find((m) => says("Spent", m)) ?? null;
    await sees("$473.50", metric);
  });
});

describe("an id in a title", () => {
  it("keeps its case: it is in a code the status does not upper-case", async () => {
    await open("#/sessions/S-Run-Fix-7");
    const empty = await waitFor(() => document.querySelector(".state.empty .status"), "the empty search");
    expect(empty.querySelector("code")?.textContent).toBe('"S-Run-Fix-7"');
    expect(css).toMatch(/\.status code \{[^}]*text-transform: none;/);
  });
});

describe("states, counts and outcomes", () => {
  it("says a session's state in the same words on Connections as on Sessions, never the plane's key", async () => {
    await open("#/connections");
    await waitFor(() => says("Calls go out as"), "the sessions that carry a person-mode server");
    const table = [...document.querySelectorAll("table")].find((t) => says("Calls go out as", t.querySelector("thead")!))!;
    const states = [...table.querySelectorAll("tbody tr")].map((r) => r.lastElementChild?.textContent ?? "").filter(Boolean);
    expect(states.length).toBeGreaterThan(0);
    expect(states.filter((s) => /_|\bread_only\b/.test(s))).toEqual([]);
    for (const s of states) expect(["active", "dormant", "read-only", "erasure pending"].some((w) => s.includes(w))).toBe(true);
  });

  it("says what the plane did with a delivery as a sentence, not by its field", () => {
    expect(outcomeWords({ ignored: "push is not an event this plane acts on" })).toBe("Nothing done: push is not an event this plane acts on.");
    expect(outcomeWords({ resumed: "s-7f3a9c24" })).toBe("Sent s-7f3a9c24 back to work.");
    expect(outcomeWords({ fired: [{ trigger: "nightly", run: "r-1", session_id: "s-1" }] })).toBe("Fired nightly, run r-1.");
    expect(outcomeWords({ fired: [{ trigger: "nightly", run: "r-2", skipped: "one is going" }] })).toBe("Nightly's run r-2 was skipped: one is going.");
    expect(outcomeWords({ failed: "the plane could not act on it" })).toBe("Failed: the plane could not act on it.");
    expect(outcomeWords({ ping: true })).toBe("GitHub checked that the webhook answers.");
  });

  it("reads a machine's two buttons as two words", async () => {
    await open("#/hosts");
    const cell = await waitFor(() => [...document.querySelectorAll<HTMLTableCellElement>("td.row-actions")].find((c) => says("Rotate", c)), "a machine's actions");
    expect(cell.textContent).toMatch(/Rotate\s+Switch (off|on)/);
  });
});

describe("an address the role may not open", () => {
  it("opens Mine for a member, says the page is for administrators, and rewrites the address", async () => {
    await open("#/sessions", PEOPLE.carol);
    await waitFor(() => heading() === "Mine", "Mine");
    await sees("That page is for administrators.");
    expect(globalThis.location.hash).toBe("#/mine");
    button("Dismiss")!.click();
    await waitFor(() => !says("That page is for administrators."), "the line dismissed");
  });

  it("says nothing on an address the role may open", async () => {
    await open("#/mine", PEOPLE.carol);
    await waitFor(() => heading() === "Mine", "Mine");
    expect(says("That page is for")).toBe(false);
  });

  it("tells a team admin a platform admin's page is not theirs", async () => {
    await open("#/hosts", PEOPLE.bob);
    await waitFor(() => heading() === "Overview", "the Overview");
    await sees("That page is for platform administrators.");
    expect(globalThis.location.hash).toBe("#/overview");
  });

  it("names no screen in the title once signed out", async () => {
    await open("#/overview");
    await waitFor(() => document.title === "Overview · Troupe console", "the Overview's title");
    button("Sign out")!.click();
    await waitFor(() => button("Sign in"), "the sign-in screen");
    expect(document.title).toBe("Troupe console");
  });
});
