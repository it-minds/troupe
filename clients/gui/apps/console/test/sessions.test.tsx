// Sessions: every session an administrator may see, as `admin.sessions.list` describes it
// (owner, profile, state, what it holds, whether it is pinned) and never what was said in
// it; searched, filtered and paged; and erased behind `admin.session.erase.preview`, typed
// by the session's own id.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, sees, signedInAs, startFake, type, visit, waitFor } from "./support";
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
    await sees("s-7f3a9c21", rows()[0]!);
    const pinned = row("s-7f3a9c22")!;
    await sees("dan@example.com", pinned);
    await sees("dormant", pinned);
    await sees("pinned by dan@example.com", pinned);
    await sees("171.7 MiB", row("s-7f3a9c21")!);
    await sees("Metadata only");
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

  it("shows what a session did on GitHub: its draft pull request as a link, or its branch, and that it stopped", async () => {
    await open();
    await waitFor(() => row("s-7f3a9c24"), "the sessions");
    const fixed = row("s-7f3a9c24")!;
    const link = fixed.querySelector<HTMLAnchorElement>("a[href]")!;
    expect(link.getAttribute("href")).toBe("https://github.example.com/example-org/widgets/pull/7");
    await sees("#7", fixed);
    await sees("troupe/issue-7-fix-login", fixed);
    await sees("stopped after its red CI rounds", fixed);
    const pushed = row("s-7f3a9c23")!;
    await sees("9e8d7c6", pushed);
    await sees("troupe/session-s-7f3a9c23", pushed);
    expect(pushed.querySelector("a[href]")).toBeNull();
    await sees("—", row("s-7f3a9c21")!);
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
    await sees("1 fork survives");
    await sees("Its key is destroyed");
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
    await sees("1–25 of 40");
    button("Next")!.click();
    await waitFor(() => says("26–40 of 40"), "the second page");
    expect(rows()).toHaveLength(15);
  });
});
