// The audit: who changed what and when, newest first, with what moved, from
// `admin.audit.list`, narrowed at the plane and searched here; and, for a platform admin,
// the chain checked on request through `admin.audit.verify`.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, sees, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
  visit("#/audit");
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

const rows = (): HTMLTableRowElement[] => [...document.querySelectorAll<HTMLTableRowElement>("table.audit tbody tr")];

describe("the audit", () => {
  it("lists who changed what, newest first, with every field that moved", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => rows().length === 7, "the trail");
    await sees("clients.put", rows()[0]!);
    await sees("2026-10-11 09:30 UTC", rows()[0]!);
    const update = rows().find((r) => says("team.update", r))!;
    // Who by name, as the plane's identity record has it, the subject beside it on hover.
    await sees("Dan", update);
    expect(says("dan@example.com", update)).toBe(false);
    expect(update.querySelector("td[title='dan@example.com']")?.textContent).toBe("Dan");
    // A team's limit as its Limits tab says it: by its label, in its unit, never raw seconds.
    await sees("Idle before it falls asleep 30 min → 20 min", update);
    expect(says("1800", update)).toBe(false);
  });

  // #957: a setting's row in the unit the setting is read in, from the plane's settings table.
  it("says a setting's change by its label and in its unit, the key in the row's subject", async () => {
    fake.admin.audit.push({
      actor: "alice@example.com",
      action: "setting.put",
      subject_kind: "setting",
      subject_id: "default_idle_timeout_seconds",
      detail: { default_idle_timeout_seconds: { from: 1800, to: 900 } },
      occurred_at: "2026-10-12T08:00:00Z",
    });
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    const row = await waitFor(() => rows().find((r) => says("default_idle_timeout_seconds", r) && says("15 min", r)), "the setting's row in minutes");
    await sees("Idle before a session goes to sleep 30 min → 15 min", row);
    expect(says("1800", row)).toBe(false);
    // The search reads the words shown as well as the plane's values.
    type(document.querySelector<HTMLInputElement>('[aria-label="Search the audit"]')!, "15 min");
    await waitFor(() => rows().length === 1, "the search by the unit's words");
  });

  it("shows an actor the plane has no name for by subject", async () => {
    fake.admin.audit.push({ actor: "svc:core/nightly", action: "trigger.run", subject_kind: "trigger", subject_id: "nightly", detail: {}, occurred_at: "2026-10-12T08:00:00Z" });
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => rows().length === 8, "the trail");
    const run = rows().find((r) => says("trigger.run", r))!;
    expect(run.querySelector("td.mono")?.textContent).toBe("svc:core/nightly");
  });

  it("narrows by actor, kind and subject at the plane, and searches what came back", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => rows().length === 7, "the trail");
    type(field("Kind")!, "team");
    type(field("Subject")!, "design");
    button("Filter")!.click();
    await waitFor(() => rows().length === 2, "design's team rows");
    expect(rows().every((r) => says("design", r))).toBe(true);

    button("Clear")!.click();
    await waitFor(() => rows().length === 7, "the whole trail again");
    type(document.querySelector<HTMLInputElement>('[aria-label="Search the audit"]')!, "glm-5.2");
    await waitFor(() => rows().length === 1 && says("setting.put", rows()[0]!), "the search");
  });

  it("reads a hundred rows at a time, and more on request", async () => {
    for (let i = 0; i < 120; i++) {
      fake.admin.audit.push({ actor: "alice@example.com", action: "team.update", subject_kind: "team", subject_id: "core", detail: { budget_micros: { from: i, to: i + 1 } }, occurred_at: `2026-10-12T${String(10 + Math.floor(i / 60)).padStart(2, "0")}:${String(i % 60).padStart(2, "0")}:00Z` });
    }
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => rows().length === 100, "the first hundred");
    button("Show 100 more")!.click();
    await waitFor(() => rows().length === 127, "the rest");
    expect(button("Show 100 more")).toBeNull();
  });

  it("checks the chain for a platform admin, on request", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Check the chain"), "the integrity check")).click();
    await waitFor(() => says("The chain verifies"), "the verdict");
    await sees("7 chained rows back to 2026-10-01 09:00 UTC. Every row is chained.");
  });

  it("says plainly when the plane could not check the chain", async () => {
    fake.admin.failing.set("admin.audit.verify", { code: -32603, message: "internal_error", data: { reason: "the trail could not be read" } });
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Check the chain"), "the integrity check")).click();
    await waitFor(() => says("Could not load the chain's check") && says("the trail could not be read"), "the failure");
  });

  it("shows a team admin the trail and not the chain's check, which is the whole plane's", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    await waitFor(() => rows().length > 0, "the trail");
    expect(button("Check the chain")).toBeNull();
  });
});
