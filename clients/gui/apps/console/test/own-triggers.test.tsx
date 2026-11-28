// A person's own triggers on the console (troupe #1235): Your triggers under Your sessions on
// Sessions' Mine, for a member as for an administrator, each saying whether it is on and
// when it runs next and how its last run went, with Switch off or on and Remove asked once
// more, and nobody else's; every call one the person's own client makes, never `admin.*`.
// An administrator's Triggers page marks a person's own as theirs.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PEOPLE, button, freshBrowser, opener, recordCalls, sees, startFake, waitFor } from "./support";
import type { FakeDeployment } from "./support";

let fake: FakeDeployment;
let restore: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  close();
  restore?.();
  restore = null;
  await fake.stop();
});

const { open, close } = opener(() => fake);
const section = (): HTMLElement | null => document.querySelector<HTMLElement>('[aria-label="Your triggers"]');
const rowOf = (name: string): HTMLTableRowElement | null => [...(section()?.querySelectorAll<HTMLTableRowElement>("tbody tr") ?? [])].find((r) => r.cells[0]?.textContent === name) ?? null;

describe("Your triggers", () => {
  it("lists a member's own, switches one off and removes it, through no administrative call", async () => {
    fake.plane.seedOwnTrigger(PEOPLE.carol.subject, {
      name: "rerun-icons-report",
      team: "core",
      last_run: { fired_at: "2026-11-23T06:00:00Z", state: "failed", session_id: "s-run" },
    });
    fake.plane.seedOwnTrigger(PEOPLE.alice.subject, { name: "alices-rerun", team: "core" });
    const recorded = recordCalls();
    restore = recorded.restore;
    await open("#/sessions/mine", PEOPLE.carol);

    const row = await waitFor(() => rowOf("rerun-icons-report"), "her trigger");
    expect(rowOf("alices-rerun")).toBeNull();
    expect(row.textContent).toMatch(/On, every Monday at 06:00 UTC; next \w{3} \d+ \w{3}, 06:00 UTC/);
    expect(row.textContent).toContain("Last ran Mon 23 Nov, 06:00 UTC: failed");
    expect(row.textContent).toContain("up to $1.00 a run, as you");

    button("Switch off", row)!.click();
    await sees("Off: it does not run until you switch it on", () => rowOf("rerun-icons-report"));
    expect(fake.admin.triggerRows.find((t) => t.name === "rerun-icons-report")?.enabled).toBe(false);

    button("Remove", rowOf("rerun-icons-report")!)!.click();
    const asked = await waitFor(() => rowOf("rerun-icons-report")?.querySelector<HTMLElement>('[role="group"]'), "Remove asked once more");
    expect(asked.textContent).toContain("This cannot be undone.");
    button("Remove", asked)!.click();
    await sees("No triggers of yours", section);
    expect(fake.admin.triggerRows.some((t) => t.name === "rerun-icons-report")).toBe(false);
    expect(fake.admin.audit.filter((a) => a.detail["via"] === "own").map((a) => [a.actor, a.action, a.subject_id])).toEqual([
      [PEOPLE.carol.subject, "trigger.put", "core/rerun-icons-report"],
      [PEOPLE.carol.subject, "trigger.delete", "core/rerun-icons-report"],
    ]);

    const methods = recorded.calls.filter((c) => c.url.startsWith(fake.plane.baseUrl)).map((c) => c.method).filter((m): m is string => m !== null);
    expect(methods).toEqual(expect.arrayContaining(["trigger.own.list", "trigger.own.disable", "trigger.own.delete"]));
    expect(methods.filter((m) => m.startsWith("admin.") && m !== "admin.teams.list")).toEqual([]);
  });

  it("on a gitops plane, says what the refusal said beside the row", async () => {
    fake.admin.mode = "gitops";
    fake.plane.seedOwnTrigger(PEOPLE.carol.subject, { name: "rerun-icons-report", team: "core" });
    await open("#/sessions/mine", PEOPLE.carol);
    button("Switch off", await waitFor(() => rowOf("rerun-icons-report"), "her trigger"))!.click();
    await sees("It was not switched off: this plane is in gitops mode: a Trigger is a resource a repository holds", () => rowOf("rerun-icons-report"));
  });
});

describe("an administrator's Triggers page", () => {
  it("marks a person's own trigger as theirs, in the list and on its page", async () => {
    fake.plane.seedOwnTrigger(PEOPLE.carol.subject, { name: "rerun-icons-report", team: "core" });
    await open("#/triggers");
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLTableRowElement>("table.triggers tbody tr")].find((r) => r.cells[0]?.textContent === "rerun-icons-report") ?? null,
      "the own trigger on core's list",
    );
    expect(row.textContent).toContain("carol@example.com's own: turned on from a session of theirs, and theirs to switch off or remove");
    const nightly = [...document.querySelectorAll<HTMLTableRowElement>("table.triggers tbody tr")].find((r) => r.cells[0]?.textContent === "nightly-deps");
    expect(nightly?.textContent).not.toContain("'s own");
  });
});
