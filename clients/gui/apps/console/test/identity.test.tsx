// Identity: who administers the platform, the groups seen and the people and groups that
// look held twice, and a team's service principals made, rotated and disabled, against the
// fake plane's `admin.identity.check`, `.duplicates`, `admin.groups.list` and
// `admin.principal.*`, with the plane's two roles. And the look-alike flag where a team
// links a group.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, recordCalls, render, says, signedInAs, startFake, type, visit, waitFor } from "./support";
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

async function open(hash = "#/identity", who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App />).unmount;
}

const section = (label: string): HTMLElement | null => document.querySelector<HTMLElement>(`section[aria-label="${label}"]`);
const row = (subject: string): HTMLTableRowElement | null => [...document.querySelectorAll<HTMLTableRowElement>("tr")].find((r) => (r.cells[0]?.textContent ?? "").startsWith(subject)) ?? null;

describe("who administers the platform", () => {
  it("checks the group in the field, not the one stored, and says whether you are one of them", async () => {
    await open();
    await waitFor(() => section("Who administers this platform") && says("including you.", section("Who administers this platform")!), "the check of the group set now");
    type(field("Group")!, "nobody-carries-this");
    button("Run the check")!.click();
    await waitFor(() => says("nobody-carries-this has never arrived in the groups claim"), "the check of the typed group");
  });
});

describe("what looks held twice", () => {
  it("lists the people with each key and where each came from, and the mismatch at the provider", async () => {
    await open();
    const twice = await waitFor(() => section("People and groups that look held twice"), "the section");
    await waitFor(() => says("2 people share an email: dan@example.com", twice), "Dan, twice");
    expect(says("sign-in", twice)).toBe(true);
    expect(says("scim", twice)).toBe(true);
    expect(says("6f1e2d3c-4b5a-4968-8776-1a2b3c4d5e6f", twice)).toBe(true);
    expect(says("make them the same at the provider", twice)).toBe(true);
  });

  it("flags a group held twice where it is listed, and says what else the plane says of a set", async () => {
    const likely = "the groups claim names this group by its name and SCIM by its id";
    fake.admin.groups.push({ external_id: "Platform owners", display_name: "Platform owners", looks_duplicated: { others: ["grp-platform"], likely } });
    fake.admin.groups.find((g) => g.external_id === "grp-platform")!.looks_duplicated = { others: ["Platform owners"], likely };
    fake.admin.peopleAlike[0]!["reason"] = "the sign-in was not adopted: its email does not agree";
    await open();
    const groups = await waitFor(() => section("Groups this plane has seen"), "the groups");
    await waitFor(() => says("looks held twice", groups), "the flag");
    expect(says("Platform owners looks held twice: grp-platform has the same name.", groups)).toBe(true);
    const twice = section("People and groups that look held twice")!;
    await waitFor(() => says("2 groups share the name Platform owners", twice), "the groups' set");
    expect(says("the sign-in was not adopted", twice)).toBe(true);
  });

  it("is not asked for by a team admin, who is shown their team's principals alone", async () => {
    const { calls, restore } = recordCalls();
    try {
      await open("#/identity", PEOPLE.bob);
      await waitFor(() => row("svc:design/digest"), "design's principal");
      expect(section("Who administers this platform")).toBeNull();
      expect(section("Groups this plane has seen")).toBeNull();
      expect(field("Team")).toBeNull();
      expect(calls.some((c) => c.method === "admin.identity.duplicates")).toBe(false);
    } finally {
      restore();
    }
  });
});

describe("a team's service principals", () => {
  it("are made behind a preview, the secret shown once and recorded nowhere", async () => {
    await open();
    (await waitFor(() => button("Make a principal for core"), "core's principals")).click();
    type(await waitFor(() => field("Name"), "the form"), "weekly-audit");
    (await waitFor(() => document.querySelector<HTMLInputElement>('fieldset input[type="checkbox"]'), "the profiles")).click();
    type(field("Sponsor")!, "dan@example.com");
    button("Preview")!.click();
    await waitFor(() => says("dan@example.com is answerable for what it does"), "the preview");
    button("Make it")!.click();
    await waitFor(() => says("Recorded in the audit as principal.create on svc:core/weekly-audit"), "the audit's note");
    const shown = document.querySelector(".shown-once pre")?.textContent ?? "";
    expect(shown).toMatch(/^tps_/);
    expect(JSON.stringify(fake.admin.audit)).not.toContain(shown);
    await waitFor(() => row("svc:core/weekly-audit"), "the new principal listed");
    expect(says("works", row("svc:core/weekly-audit")!)).toBe(true);
  });

  it("are rotated and disabled, each typed by the subject", async () => {
    await open();
    await waitFor(() => row("svc:core/nightly"), "core's principal");
    button("Rotate", row("svc:core/nightly")!)!.click();
    await waitFor(() => says("Type svc:core/nightly to confirm"), "the typed confirmation");
    const go = (verb: string) => [...document.querySelectorAll<HTMLButtonElement>(".preview button")].find((b) => (b.textContent ?? "").startsWith(verb))!;
    expect(go("Rotate").disabled).toBe(true);
    type(field("Type svc:core/nightly to confirm")!, "svc:core/nightly");
    await waitFor(() => !go("Rotate").disabled, "the subject typed");
    go("Rotate").click();
    await waitFor(() => says("svc:core/nightly's secret, shown once"), "the new secret");

    (await waitFor(() => button("Disable", row("svc:core/nightly")!), "the list again")).click();
    type(await waitFor(() => field("Type svc:core/nightly to confirm"), "the typed confirmation"), "svc:core/nightly");
    await waitFor(() => !go("Disable").disabled, "the subject typed");
    go("Disable").click();
    await waitFor(() => says("Recorded in the audit as principal.disable on svc:core/nightly"), "the audit's note");
    await waitFor(() => says("disabled", row("svc:core/nightly")!), "the principal disabled");
    expect(fake.admin.principalRows.get("svc:core/nightly")!.disabled_at).not.toBeNull();
  });

  it("say one whose sponsor left needs a sponsor, rather than that it is broken", async () => {
    fake.admin.teams.get("core")!.principals.push("svc:core/orphan");
    fake.admin.principalRows.set("svc:core/orphan", {
      subject: "svc:core/orphan",
      team: "core",
      name: "orphan",
      description: null,
      profiles: ["dev"],
      sponsor: "gone@example.com",
      created_by: "alice@example.com",
      created_at: "2026-10-01T09:30:00Z",
      disabled_at: null,
      disabled_reason: null,
      last_used_at: null,
    });
    await open();
    await waitFor(() => row("svc:core/orphan"), "the orphan");
    expect(says("needs a sponsor", row("svc:core/orphan")!)).toBe(true);
  });
});

describe("linking a group to a team", () => {
  it("says on the picker which group looks held twice", async () => {
    const likely = "the groups claim names this group by its name and SCIM by its id";
    fake.admin.groups.push({ external_id: "Research", display_name: "Research", looks_duplicated: { others: ["grp-research"], likely } });
    await open("#/teams/core/members");
    (await waitFor(() => button("Link a group"), "core's members")).click();
    const picker = await waitFor(() => field("Group") as HTMLSelectElement | null, "the picker");
    await waitFor(() => [...picker.options].some((o) => o.textContent?.includes("looks held twice")), "the flag on the option");
    type(picker, "Research");
    await waitFor(() => says("Research looks held twice: grp-research has the same name."), "what it means");
  });
});
