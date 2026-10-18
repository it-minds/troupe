// Triggers: a team's list, a trigger read whole with its revisions, and making, changing,
// pausing and deleting one, against the fake plane's `admin.triggers.list`,
// `admin.trigger.put`, `.delete` and `.revisions`, with the plane's two roles and its
// gitops lock.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, link, render, says, sees, seesButton, signedInAs, startFake, type, visit, waitFor } from "./support";
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

const heading = (): string => document.querySelector("h1")?.textContent ?? "";
const row = (name: string): HTMLTableRowElement | null =>
  [...document.querySelectorAll<HTMLTableRowElement>("table.triggers tbody tr")].find((r) => (r.cells[0]?.textContent ?? "") === name) ?? null;
const trigger = (team: string, name: string) => fake.admin.triggerRows.find((t) => t.team === team && t.name === name);

async function open(hash: string, who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App />).unmount;
}

describe("a team's triggers", () => {
  it("lists them per team, and a platform admin picks the team", async () => {
    await open("#/triggers");
    await waitFor(() => row("nightly-deps"), "core's triggers");
    await sees("on a schedule: 0 3 * * 1-5 (UTC)", () => row("nightly-deps"));
    await sees("svc:core/nightly", () => row("nightly-deps"));
    await sees("on", () => row("nightly-deps"));

    type(field("Team")!, "design");
    await waitFor(() => row("weekly-digest"), "design's triggers");
    await sees("paused", () => row("weekly-digest"));
    await sees("by a webhook from github", () => row("weekly-digest"));
    expect(location.hash).toBe("#/triggers/design");
  });

  it("shows a team admin their own team's, and another team's as not found", async () => {
    await open("#/triggers", PEOPLE.bob);
    await waitFor(() => row("weekly-digest"), "design's triggers");
    expect(field("Team")).toBeNull();
    expect(row("nightly-deps")).toBeNull();

    visit("#/triggers/core/nightly-deps");
    await waitFor(() => says("The plane has no such thing, or it is not one you administer."), "core's trigger, not found");
  });
});

describe("a trigger", () => {
  it("reads every field the plane keeps of it, and every revision with what it said", async () => {
    await open("#/triggers/core/nightly-deps");
    await waitFor(() => heading() === "nightly-deps" && says("Revisions"), "nightly-deps");
    await sees("Update the dependencies of {{trigger.name}} and open a pull request.");
    await sees("max_turns: 80, approvals: deny");
    await sees("dan@example.com");
    await sees("pr-reviewer");
    await sees("2026-10-13 03:00 UTC");
    await sees("Revision 1");
    // Running it is offered here, and nothing sends a person to the admin API or a page under /admin for it.
    await seesButton("Run nightly-deps now");
    expect(says("admin.trigger.run")).toBe(false);
    expect([...document.querySelectorAll("a")].filter((a) => a.href.includes("/admin"))).toEqual([]);
    // A schedule is fired by the plane, so it has no key to rotate.
    expect(button("Rotate nightly-deps's key")).toBeNull();
  });

  it("is made from a form, previewed, and shown as the audit recorded it", async () => {
    await open("#/triggers/core");
    (await waitFor(() => button("New trigger"), "core's triggers")).click();
    type(await waitFor(() => field("Name"), "the form"), "weekly-audit");
    const principal = await waitFor(() => (field("Runs as") as HTMLSelectElement | null)?.querySelector('option[value="svc:core/nightly"]') && field("Runs as"), "the principals");
    type(principal, "svc:core/nightly");
    type(field("Profile")!, "dev");
    type(field("Schedule")!, "0 6 * * 1");
    type(field("What each session is asked to do")!, "Audit the week's changes.");
    button("Preview")!.click();
    await waitFor(() => says("weekly-audit fires on a schedule: 0 6 * * 1 (UTC)"), "the preview");
    button("Create weekly-audit")!.click();
    await waitFor(() => says("Recorded in the audit as trigger.put on core/weekly-audit"), "the audit's note");
    await waitFor(() => row("weekly-audit"), "weekly-audit in the list");
    const made = trigger("core", "weekly-audit")!;
    expect(made.principal).toBe("svc:core/nightly");
    expect(made.source).toEqual({ kind: "schedule", cron: "0 6 * * 1", tz: "UTC" });
  });

  it("is changed by sending only what moved, so what the form does not show is left as it was", async () => {
    await open("#/triggers/core/nightly-deps");
    (await waitFor(() => button("Change nightly-deps"), "nightly-deps")).click();
    type(await waitFor(() => field("Schedule"), "the form"), "0 4 * * 1-5");
    button("Preview")!.click();
    await waitFor(() => says("What will happen") && says("From now it fires on a schedule: 0 4 * * 1-5 (UTC)."), "the preview");
    expect(says("profile:")).toBe(false);
    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as trigger.put on core/nightly-deps"), "the audit's note");
    const t = trigger("core", "nightly-deps")!;
    expect(t.source).toEqual({ kind: "schedule", cron: "0 4 * * 1-5", tz: "UTC" });
    expect(t.terms).toEqual({ max_turns: 80, approvals: "deny" });
    expect(t.notify).toEqual(["dan@example.com"]);
    expect(t.revisions.length).toBe(2);
    await waitFor(() => says("Revision 2"), "the new revision");
  });

  it("is paused with a plain confirm, and deleted by typing its name", async () => {
    await open("#/triggers/core/nightly-deps");
    (await waitFor(() => button("Pause nightly-deps"), "nightly-deps")).click();
    await waitFor(() => says("nightly-deps stops firing"), "the preview");
    button("Pause nightly-deps")!.click();
    await waitFor(() => says("Recorded in the audit as trigger.put on core/nightly-deps"), "the audit's note");
    expect(trigger("core", "nightly-deps")!.enabled).toBe(false);
    // Switching it off is not a new revision of what it says.
    expect(trigger("core", "nightly-deps")!.revisions.length).toBe(1);

    (await waitFor(() => button("Delete nightly-deps"), "the page again")).click();
    await waitFor(() => says("Type nightly-deps to confirm"), "the typed confirmation");
    expect((await seesButton("Delete nightly-deps")).disabled).toBe(true);
    type(field("Type nightly-deps to confirm")!, "nightly-deps");
    await waitFor(() => !button("Delete nightly-deps")!.disabled, "the name typed");
    button("Delete nightly-deps")!.click();
    await waitFor(() => says("Recorded in the audit as trigger.delete on core/nightly-deps") && says("nightly-deps is no longer a trigger of core"), "the audit's note");
    expect(trigger("core", "nightly-deps")).toBeUndefined();
  });

  it("is resumed by its own team's admin", async () => {
    await open("#/triggers/design/weekly-digest", PEOPLE.bob);
    (await waitFor(() => button("Resume weekly-digest"), "weekly-digest")).click();
    await waitFor(() => says("weekly-digest fires again by a webhook from github."), "the preview");
    button("Resume weekly-digest")!.click();
    await waitFor(() => says("Recorded in the audit as trigger.put on design/weekly-digest"), "the audit's note");
    expect(trigger("design", "weekly-digest")!.enabled).toBe(true);
  });
});

describe("running a trigger now", () => {
  it("is confirmed after saying what it starts, and the run it makes is on Runs", async () => {
    const before = fake.admin.runRows.length;
    await open("#/triggers/core/nightly-deps");
    (await waitFor(() => button("Run nightly-deps now"), "nightly-deps")).click();
    await waitFor(() => says("nightly-deps fires now, by hand: a session on dev, run as svc:core/nightly, which spends core's budget."), "the preview");
    await sees("is listed on Runs and review as fired by hand, by you");
    await sees("If a run of it is going already, this one is recorded as skipped");
    // Nothing fires by looking.
    expect(fake.admin.runRows.length).toBe(before);

    button("Run nightly-deps now")!.click();
    await waitFor(() => says("Recorded in the audit as trigger.run on core/nightly-deps"), "the audit's note");
    const made = fake.admin.runRows.at(-1)!;
    expect(fake.admin.runRows.length).toBe(before + 1);
    expect(made).toMatchObject({ team: "core", trigger: "nightly-deps", source: "manual", fired_by: PEOPLE.alice.subject, state: "created" });
    await sees(made.idempotency_key);

    (await waitFor(() => link("Its run, on Runs and review"), "the run's link")).click();
    await waitFor(() => location.hash === `#/runs/${made.id}` && says(made.session_id!), "the run's page");

    visit("#/runs");
    await waitFor(() => document.querySelector(`a[href="#/runs/${made.id}"]`), "the run on Runs");
  });

  it("is not offered on a paused trigger, which says why", async () => {
    await open("#/triggers/design/weekly-digest", PEOPLE.bob);
    await waitFor(() => button("Resume weekly-digest"), "weekly-digest");
    expect(button("Run weekly-digest now")).toBeNull();
    await sees("A paused trigger is not run, by hand or otherwise; resume it first.");
  });
});

describe("a webhook's key and a trigger on a GitHub repository", () => {
  it("rotates a webhook trigger's key, typed, saying first that the old one stops working at once", async () => {
    let copied: string | null = null;
    Object.defineProperty(globalThis.navigator, "clipboard", { value: { writeText: async (text: string) => void (copied = text) }, configurable: true });
    trigger("design", "weekly-digest")!.key = "twk_theoldone";

    await open("#/triggers/design/weekly-digest", PEOPLE.bob);
    (await waitFor(() => button("Rotate weekly-digest's key"), "weekly-digest")).click();
    await waitFor(() => says("stops working the moment you rotate it"), "the preview");
    await sees("There is no overlap.");
    await sees("The new key is shown once");
    expect((await seesButton("Rotate weekly-digest's key")).disabled).toBe(true);
    expect(trigger("design", "weekly-digest")!.key).toBe("twk_theoldone");

    type(field("Type weekly-digest to confirm")!, "weekly-digest");
    await waitFor(() => !button("Rotate weekly-digest's key")!.disabled, "the name typed");
    button("Rotate weekly-digest's key")!.click();

    const panel = await waitFor(() => document.querySelector<HTMLElement>("section.key-once"), "the new key");
    const key = panel.querySelector("code.secret")!.textContent!;
    expect(key).toMatch(/^twk_/);
    // The plane's key is now the new one: the old one fires nothing.
    expect(trigger("design", "weekly-digest")!.key).toBe(key);
    expect(key).not.toBe("twk_theoldone");
    await sees(`${fake.plane.baseUrl}/trigger/trg-design-weekly-digest`, panel);
    await waitFor(() => says("Recorded in the audit as trigger.key.rotate on design/weekly-digest"), "the audit's note");
    expect(fake.admin.audit.at(-1)!.detail).toEqual({ had_key: true });

    button("Copy the key", panel)!.click();
    await waitFor(() => says("Copied.", panel), "copied");
    expect(copied).toBe(key);
    button("I have copied it", panel)!.click();
    await waitFor(() => !document.querySelector("section.key-once"), "the key, gone");
    expect(says(key)).toBe(false);
  });

  async function newTrigger(name: string): Promise<void> {
    await open("#/triggers/core");
    (await waitFor(() => button("New trigger"), "core's triggers")).click();
    type(await waitFor(() => field("Name"), "the form"), name);
    const principal = await waitFor(() => (field("Runs as") as HTMLSelectElement | null)?.querySelector('option[value="svc:core/nightly"]') && field("Runs as"), "the principals");
    type(principal, "svc:core/nightly");
    type(field("Profile")!, "dev");
  }

  it("makes a webhook trigger with its key, shown once with a button that copies it", async () => {
    let copied: string | null = null;
    Object.defineProperty(globalThis.navigator, "clipboard", { value: { writeText: async (text: string) => void (copied = text) }, configurable: true });

    await newTrigger("deploys");
    type(field("Fired by")!, "webhook");
    button("Preview")!.click();
    await waitFor(() => says("It is made with its webhook key, which is shown once"), "the preview");
    button("Create deploys")!.click();

    const panel = await waitFor(() => document.querySelector<HTMLElement>("section.key-once"), "the key");
    const key = panel.querySelector("code.secret")!.textContent!;
    expect(key).toMatch(/^twk_/);
    await sees("it is not shown again", panel);
    await sees(`${fake.plane.baseUrl}/trigger/trg-core-deploys`, panel);
    expect(trigger("core", "deploys")!.has_key).toBe(true);
    expect(fake.admin.audit.find((a) => a.action === "trigger.put" && a.subject_id === "core/deploys")?.detail?.["__key_minted__"]).toBe(true);

    button("Copy the key", panel)!.click();
    await waitFor(() => says("Copied.", panel), "copied");
    expect(copied).toBe(key);

    button("I have copied it", panel)!.click();
    await waitFor(() => !document.querySelector("section.key-once"), "the key, gone");
    expect(says(key)).toBe(false);

    // Its page says only that it has one.
    visit("#/triggers/core/deploys");
    await waitFor(() => heading() === "deploys" && says("Webhook key"), "deploys");
    expect(says(key)).toBe(false);
  });

  it("makes a trigger on a GitHub repository, fired by a label or a command, with no key", async () => {
    await newTrigger("fix-issues");
    type(field("Fired by")!, "github");
    type(await waitFor(() => field("Repository"), "the GitHub fields"), "not a repository");
    await waitFor(() => says("owner/name, as GitHub writes it."), "the repository refused");
    expect((await seesButton("Preview")).disabled).toBe(true);
    type(field("Repository")!, "example-org/widgets");
    await waitFor(() => button("Preview")!.disabled, "a label or a command still wanted");
    type(field("Label")!, "troupe-fix");
    type(field("Command")!, "/troupe fix");
    await waitFor(() => !button("Preview")!.disabled, "the form complete");
    button("Preview")!.click();
    await waitFor(() => says("by GitHub on example-org/widgets: an issue labelled troupe-fix, or a comment saying /troupe fix"), "the preview");
    await sees("it has no key");
    button("Create fix-issues")!.click();
    await waitFor(() => says("Recorded in the audit as trigger.put on core/fix-issues"), "the audit's note");
    expect(document.querySelector("section.key-once")).toBeNull();
    expect(trigger("core", "fix-issues")!.source).toEqual({ kind: "webhook", provider: "github", repository: "example-org/widgets", label: "troupe-fix", command: "/troupe fix" });
    expect(trigger("core", "fix-issues")!.has_key).toBe(false);
  });
});

describe("a plane in gitops mode", () => {
  it("shows the triggers locked, with where they come from, and offers no change", async () => {
    fake.admin.mode = "gitops";
    fake.admin.gitopsSource = "https://git.example.com/platform/troupe.git";
    await open("#/triggers/core");
    await waitFor(() => row("nightly-deps") && says("Held in a repository"), "the locked list");
    expect(button("New trigger")).toBeNull();
    await sees("Running one by hand and rotating its webhook key still work, from its page");

    visit("#/triggers/core/nightly-deps");
    await waitFor(() => heading() === "nightly-deps" && says("It comes from the resource core.nightly-deps"), "the locked trigger");
    await sees("https://git.example.com/platform/troupe.git");
    expect(button("Change nightly-deps")).toBeNull();
    expect(button("Pause nightly-deps")).toBeNull();
    expect(button("Delete nightly-deps")).toBeNull();
    // Running it is something done with it, not a change to what the repository holds.
    await seesButton("Run nightly-deps now");
  });
});
