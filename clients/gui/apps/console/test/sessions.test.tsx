// Sessions: every session an administrator may see, as `admin.sessions.list` describes it
// (owner, profile, state, what it holds, whether it is pinned) and never what was said in
// it; searched, filtered and paged; and erased behind `admin.session.erase.preview`, typed
// by the session's own id.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, signedInAs, startFake, type, visit, waitFor } from "./support";
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

const rows = (): HTMLTableRowElement[] => [...document.querySelectorAll<HTMLTableRowElement>("table.sessions tbody tr")];
const row = (id: string): HTMLTableRowElement | null => rows().find((r) => says(id, r)) ?? null;

async function open(as: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, as);
  visit("#/sessions");
  unmount = render(<App />).unmount;
}

describe("sessions", () => {
  it("lists every session a platform admin may see, newest first, with owner, profile, state, size and pin", async () => {
    await open();
    await waitFor(() => row("s-7f3a9c21"), "the sessions");
    expect(rows()).toHaveLength(10);
    expect(says("s-7f3a9c21", rows()[0]!)).toBe(true);
    const pinned = row("s-7f3a9c22")!;
    expect(says("dan@example.com", pinned)).toBe(true);
    expect(says("dormant", pinned)).toBe(true);
    expect(says("pinned by dan@example.com", pinned)).toBe(true);
    expect(says("171.7 MiB", row("s-7f3a9c21")!)).toBe(true);
    expect(says("Metadata only")).toBe(true);
  });

  it("searches, filters by state and profile at the plane, and says what to do when nothing matches", async () => {
    await open();
    await waitFor(() => row("s-7f3a9c21"), "the sessions");
    type(field("State")!, "dormant");
    await waitFor(() => rows().length === 5, "the dormant sessions");
    type(field("Profile")!, "ux");
    await waitFor(() => rows().length === 3 && row("s-7f3a9c27") !== null, "the dormant sessions on ux");
    type(document.querySelector<HTMLInputElement>('[aria-label="Search sessions"]')!, "fay@");
    await waitFor(() => rows().length === 1 && row("s-4b81d004") !== null, "the search");
    type(document.querySelector<HTMLInputElement>('[aria-label="Search sessions"]')!, "nobody-at-all");
    await waitFor(() => says('No session matches "nobody-at-all"'), "the empty search");
  });

  it("shows a team admin their own team's sessions and none of another's", async () => {
    await open(PEOPLE.bob);
    await waitFor(() => row("s-4b81d003"), "the design team's sessions");
    expect(rows()).toHaveLength(3);
    expect(row("s-7f3a9c21")).toBeNull();
  });

  it("erases a session behind what it holds and the forks that survive it, confirmed by its id", async () => {
    await open();
    await waitFor(() => row("s-7f3a9c22"), "the sessions");
    button("Erase", row("s-7f3a9c22")!)!.click();
    await waitFor(() => says("What will happen") && says("s-7f3a9c25"), "the preview, with the fork that survives");
    expect(says("1 fork survives")).toBe(true);
    expect(says("Its key is destroyed")).toBe(true);
    expect(button("Erase s-7f3a9c22")!.disabled).toBe(true);
    type(field("Type s-7f3a9c22 to confirm")!, "s-7f3a9c2");
    expect(button("Erase s-7f3a9c22")!.disabled).toBe(true);
    type(field("Type s-7f3a9c22 to confirm")!, "s-7f3a9c22");
    await waitFor(() => !button("Erase s-7f3a9c22")!.disabled, "the confirmation");
    expect(fake.admin.sessions.find((s) => s.id === "s-7f3a9c22")!.state).toBe("dormant");
    button("Erase s-7f3a9c22")!.click();

    await waitFor(() => says("Recorded in the audit as session.erase on s-7f3a9c22"), "the audit's note");
    expect(fake.admin.sessions.find((s) => s.id === "s-7f3a9c22")!.state).toBe("erased");
    await waitFor(() => row("s-7f3a9c22") === null, "the list without it");
    expect(row("s-7f3a9c25")).not.toBeNull();
  });

  it("pages through more sessions than one page holds", async () => {
    for (let i = 0; i < 30; i++) {
      fake.admin.sessions.push({ ...fake.admin.sessions[0]!, id: `s-extra-${String(i).padStart(2, "0")}`, last_active_at: `2026-10-01T00:${String(i).padStart(2, "0")}:00Z` });
    }
    await open();
    await waitFor(() => row("s-7f3a9c21"), "the sessions");
    expect(rows()).toHaveLength(25);
    expect(says("1–25 of 40")).toBe(true);
    button("Next")!.click();
    await waitFor(() => says("26–40 of 40"), "the second page");
    expect(rows()).toHaveLength(15);
  });
});
