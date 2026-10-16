// Triggers: a team's list, a trigger read whole with its revisions, and making, changing,
// pausing and deleting one, against the fake plane's `admin.triggers.list`,
// `admin.trigger.put`, `.delete` and `.revisions`, with the plane's two roles and its
// gitops lock.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, link, render, says, signedInAs, startFake, type, visit, waitFor } from "./support";
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
    expect(says("on a schedule: 0 3 * * 1-5 (UTC)", row("nightly-deps")!)).toBe(true);
    expect(says("svc:core/nightly", row("nightly-deps")!)).toBe(true);
    expect(says("on", row("nightly-deps")!)).toBe(true);

    type(field("Team")!, "design");
    await waitFor(() => row("weekly-digest"), "design's triggers");
    expect(says("paused", row("weekly-digest")!)).toBe(true);
    expect(says("by a webhook from github", row("weekly-digest")!)).toBe(true);
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
    expect(says("Update the dependencies of {{trigger.name}} and open a pull request.")).toBe(true);
    expect(says("max_turns: 80, approvals: deny")).toBe(true);
    expect(says("dan@example.com")).toBe(true);
    expect(says("pr-reviewer")).toBe(true);
    expect(says("2026-10-13 03:00 UTC")).toBe(true);
    expect(says("Revision 1")).toBe(true);
    expect(link("current console's Triggers page")!.href).toBe(`${fake.plane.baseUrl}/admin/triggers/core`);
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
    expect(button("Delete nightly-deps")!.disabled).toBe(true);
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

describe("a webhook's key and a trigger on a GitHub repository", () => {
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
    expect(says("it is not shown again", panel)).toBe(true);
    expect(says(`${fake.plane.baseUrl}/trigger/trg-core-deploys`, panel)).toBe(true);
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
    expect(button("Preview")!.disabled).toBe(true);
    type(field("Repository")!, "example-org/widgets");
    await waitFor(() => button("Preview")!.disabled, "a label or a command still wanted");
    type(field("Label")!, "troupe-fix");
    type(field("Command")!, "/troupe fix");
    await waitFor(() => !button("Preview")!.disabled, "the form complete");
    button("Preview")!.click();
    await waitFor(() => says("by GitHub on example-org/widgets: an issue labelled troupe-fix, or a comment saying /troupe fix"), "the preview");
    expect(says("it has no key")).toBe(true);
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

    visit("#/triggers/core/nightly-deps");
    await waitFor(() => heading() === "nightly-deps" && says("It comes from the resource core.nightly-deps"), "the locked trigger");
    expect(says("https://git.example.com/platform/troupe.git")).toBe(true);
    expect(button("Change nightly-deps")).toBeNull();
    expect(button("Pause nightly-deps")).toBeNull();
    expect(button("Delete nightly-deps")).toBeNull();
  });
});
