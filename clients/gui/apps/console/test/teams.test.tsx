// Teams: the list, and a team in the brief's five tabs. Every tab reads through
// `admin.teams.list` (and the danger zone through `admin.team.disable.preview`); Limits
// also changes, through `admin.team.update`, previewed first, with the ladder's ceiling
// quoted and the plane's refusal shown where it was made.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, link, render, says, sees, seesLink, signedInAs, startFake, type, visit, waitFor } from "./support";
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
const tabs = (): string[] => [...document.querySelectorAll(".tabs a")].map((a) => a.textContent ?? "");
const limit = (name: string): HTMLElement | null => [...document.querySelectorAll<HTMLElement>(".limit")].find((l) => (l.textContent ?? "").startsWith(name)) ?? null;

describe("the team list", () => {
  it("lists every team for a platform admin, with its people, groups, profiles, admins and spend, and searches them", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams");
    unmount = render(<App />).unmount;
    await waitFor(() => link("core") && link("design") && link("research"), "the teams");
    await sees("Core engineering");
    await sees("dev, ux");
    await sees("dan@example.com");
    await sees("over budget");
    await sees("no ceiling");

    type(document.querySelector<HTMLInputElement>('[aria-label="Search teams"]')!, "bob@");
    await waitFor(() => link("core") === null, "the search");
    await seesLink("design");
    type(document.querySelector<HTMLInputElement>('[aria-label="Search teams"]')!, "nobody-at-all");
    await waitFor(() => says('No team matches "nobody-at-all"'), "the empty search");
  });

  it("says what to do when there are no teams at all", async () => {
    fake.admin.teams.clear();
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams");
    unmount = render(<App />).unmount;
    await waitFor(() => says("No teams yet"), "the empty state");
    await sees("Enable a group as a team to begin");
    expect(button("Enable a group as a team")).not.toBeNull();
  });
});

describe("a team", () => {
  it("reads its members and groups, its access and its admins, each in its tab", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core");
    unmount = render(<App />).unmount;
    await waitFor(() => heading() === "core" && says("Membership is the identity provider's"), "the members tab");
    expect(tabs()).toEqual(["Members and groups", "Access", "Admins", "Limits", "Danger zone"]);
    await sees("grp-core");
    await sees("erin@example.com");
    await sees("150.00");

    link("Access")!.click();
    await waitFor(() => says("A profile grant is the only way core gains reach"), "the access tab");
    await sees("read and write");

    link("Admins")!.click();
    await waitFor(() => says("Who may administer core"), "the admins tab");
    await sees("dan@example.com");
  });

  it("shows a platform admin what removing a team would take, and reads it from the plane", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/danger");
    unmount = render(<App />).unmount;
    await waitFor(() => says("What removing it would take") && says("nightly-deps"), "the danger zone");
    await sees("Grants revoked: dev, ux");
    await sees("svc:core/nightly");
    await sees("7 sessions are kept, with no team.");
    expect(fake.admin.teams.has("core")).toBe(true);
  });

  it("shows a team admin their own team without the danger zone, and another team as not found", async () => {
    await signedInAs(fake, PEOPLE.bob);
    visit("#/teams/design");
    unmount = render(<App />).unmount;
    await waitFor(() => heading() === "design" && tabs().length > 0, "the design team");
    expect(tabs()).not.toContain("Danger zone");

    visit("#/teams/core");
    await waitFor(() => says("No team called core"), "core, not found");
  });

  it("shows each limit in force, the rung that decided it, and the ladder behind it", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/limits");
    unmount = render(<App />).unmount;
    const erase = await waitFor(() => limit("Sessions erased after"), "the limits");
    // The team asked for 90 days; the platform stored 180 and the deployment 365, so the team's is in force.
    await sees("90 days", erase);
    await sees("team", erase);
    const idle = limit("Idle before it goes dormant")!;
    await sees("1200 s", idle);
    button("Why?", erase)!.click();
    await waitFor(() => says("deployment", limit("Sessions erased after")!) && says("365 days", limit("Sessions erased after")!), "the ladder");
    await sees("180 days", () => limit("Sessions erased after"));
    await sees("500.00", () => limit("Budget"));
  });

  it("previews a narrower limit in words, applies it on confirm, and shows what the audit recorded", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/limits");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change core's limits"), "the limits")).click();
    type(await waitFor(() => field("Idle before it goes dormant"), "the form"), "600");
    await sees("The platform allows at most 1800 s.");
    button("Preview")!.click();

    await waitFor(() => says("What will happen"), "the preview");
    await sees("idle_timeout_seconds: 1200 s");
    await sees("idle_timeout_seconds: 600 s");
    await sees("A core session idle for 600 seconds goes dormant");
    expect(fake.admin.teams.get("core")!.idle_timeout_seconds).toBe(1200);

    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as team.update on core"), "the audit's note");
    expect(fake.admin.teams.get("core")!.idle_timeout_seconds).toBe(600);
    expect(fake.admin.audit.at(-1)).toMatchObject({ action: "team.update", subject_id: "core", detail: { idle_timeout_seconds: { from: 1200, to: 600 } } });
    await waitFor(() => says("600 s", limit("Idle before it goes dormant") ?? document.body), "the limit as it now is");
  });

  it("says before sending that the plane will refuse a wider limit, and shows the plane's refusal", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/limits");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change core's limits"), "the limits")).click();
    type(await waitFor(() => field("Idle before it goes dormant"), "the form"), "7200");
    button("Preview")!.click();
    await waitFor(() => says("The plane will refuse idle_timeout_seconds: 7200 is wider than 1800"), "the warning");
    const recorded = fake.admin.audit.length;
    button("Apply")!.click();
    await waitFor(() => says("idle_timeout_seconds: 7200 is wider than 1800, which the deployment decided. A lower rung may only narrow."), "the refusal");
    expect(fake.admin.teams.get("core")!.idle_timeout_seconds).toBe(1200);
    expect(fake.admin.audit).toHaveLength(recorded);
  });

  it("asks for the team's name before a shorter retention, since erasing cannot be undone", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/limits");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change core's limits"), "the limits")).click();
    type(await waitFor(() => field("Sessions erased after"), "the form"), "30");
    button("Preview")!.click();
    await waitFor(() => says("core's sessions older than 30 days are erased. Erasure cannot be undone."), "the preview");
    expect(button("Apply")!.disabled).toBe(true);
    type(field("Type core to confirm")!, "cor");
    expect(button("Apply")!.disabled).toBe(true);
    type(field("Type core to confirm")!, "core");
    await waitFor(() => !button("Apply")!.disabled, "the confirmation");
    button("Apply")!.click();
    await waitFor(() => says("Recorded in the audit as team.update on core"), "the audit's note");
    expect(fake.admin.teams.get("core")!.erase_after_days).toBe(30);
  });

  it("lets a team admin change their team's limits but not whether it may use unenforced workers", async () => {
    await signedInAs(fake, PEOPLE.bob);
    visit("#/teams/design/limits");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change design's limits"), "the limits")).click();
    await waitFor(() => field("Members may pin a session"), "the form");
    expect(field("May use workers nothing is enforced on")).toBeNull();
  });
});

// The rest of what a team's tabs change, each a platform admin's: previewed, confirmed
// (by typing the name where it takes something away nobody can simply give back), and
// then shown as the audit recorded it, read back with `admin.audit.list`.
describe("a team's edits", () => {
  const groupRow = (id: string): HTMLElement | null => [...document.querySelectorAll<HTMLElement>("tr")].find((r) => says(id, r)) ?? null;

  it("links a group behind a preview, and unlinks one behind who loses the team, typed by the group's id", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/members");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Link a group"), "the members tab")).click();
    type(await waitFor(() => field("Group"), "the form"), "grp-platform");
    button("Preview")!.click();
    await waitFor(() => says("What will happen") && says("Everyone in Platform owners is in core"), "the preview");
    await sees("groups: grp-core, grp-platform");
    expect(fake.admin.teams.get("core")!.groups).toHaveLength(1);
    button("Link")!.click();
    await waitFor(() => says("Recorded in the audit as team.link on core"), "the audit's note");
    await sees("grp-platform", () => document.querySelector(".audit-note"));
    expect(fake.admin.teams.get("core")!.groups.map((g) => g.external_id)).toEqual(["grp-core", "grp-platform"]);
    await waitFor(() => says("hana@example.com"), "the person the group brought in");

    button("Unlink", groupRow("grp-platform")!)!.click();
    await waitFor(() => says("1 person loses core: hana@example.com"), "the unlink preview");
    await sees("1 keeps it through another group");
    await sees("Sessions do not move");
    expect(button("Unlink grp-platform")!.disabled).toBe(true);
    type(field("Type grp-platform to confirm")!, "grp-platform");
    await waitFor(() => !button("Unlink grp-platform")!.disabled, "the confirmation");
    button("Unlink grp-platform")!.click();
    await waitFor(() => says("Recorded in the audit as team.unlink on core"), "the audit's note");
    expect(fake.admin.teams.get("core")!.groups.map((g) => g.external_id)).toEqual(["grp-core"]);
    const people = (): Element => [...document.querySelectorAll(".tab table")].at(-1)!;
    await waitFor(() => !says("hana@example.com", people()) && says("erin@example.com", people()), "hana gone from the people");
  });

  it("grants a profile, and revokes one behind a warning of the sessions it turns read-only, typed by its name", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/access");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Grant a profile"), "the access tab")).click();
    type(await waitFor(() => field("Profile"), "the form"), "heavy");
    type(field("Team volume")!, "rw");
    button("Preview")!.click();
    await waitFor(() => says("core's people may start sessions on heavy"), "the preview");
    button("Grant")!.click();
    await waitFor(() => says("Recorded in the audit as team.grant on core"), "the audit's note");
    expect(fake.admin.teams.get("core")!.grants).toContainEqual({ profile: "heavy", volume_mode: "rw" });

    button("Revoke", groupRow("dev")!)!.click();
    // The team is read again after the grant, so heavy can join the lines a moment after the warning.
    await waitFor(() => says("Every core session on dev turns read-only"), "the warning");
    await waitFor(() => says("grants: dev, ux, heavy") && says("grants: ux, heavy"), "the grants before and after");
    expect(button("Revoke dev")!.disabled).toBe(true);
    type(field("Type dev to confirm")!, "dev");
    await waitFor(() => !button("Revoke dev")!.disabled, "the confirmation");
    button("Revoke dev")!.click();
    await waitFor(() => says("Recorded in the audit as team.revoke on core"), "the audit's note");
    expect(fake.admin.teams.get("core")!.grants.map((g) => g.profile)).toEqual(["ux", "heavy"]);
    expect(fake.admin.sessions.filter((s) => s.team === "core" && s.profile === "dev").map((s) => s.state)).toEqual(["read_only", "read_only", "read_only", "read_only", "read_only"]);
  });

  it("says before sending that the plane will refuse a profile nothing is enforced on, and shows its refusal", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/access");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Grant a profile"), "the access tab")).click();
    type(await waitFor(() => field("Profile"), "the form"), "build-box");
    button("Preview")!.click();
    await waitFor(() => says("The plane will refuse this: build-box runs where nothing is enforced"), "the warning");
    button("Grant")!.click();
    await waitFor(() => says("this substrate does not provide sandbox, egress_by_hostname"), "the refusal");
    expect(fake.admin.teams.get("core")!.grants.map((g) => g.profile)).toEqual(["dev", "ux"]);
  });

  it("names a team admin and removes one, each behind a preview and a plain confirm", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/admins");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Name an administrator"), "the admins tab")).click();
    type(await waitFor(() => field("Subject"), "the form"), "erin@example.com");
    button("Preview")!.click();
    await waitFor(() => says("erin@example.com may change core's limits"), "the preview");
    button("Name")!.click();
    await waitFor(() => says("Recorded in the audit as team.admin.add on core"), "the audit's note");
    expect(fake.admin.teams.get("core")!.admins).toEqual(["dan@example.com", "erin@example.com"]);

    button("Remove", groupRow("dan@example.com") ?? [...document.querySelectorAll("li")].find((l) => says("dan@example.com", l))!)!.click();
    await waitFor(() => says("dan@example.com stops administering core"), "the preview");
    button("Remove dan@example.com")!.click();
    await waitFor(() => says("Recorded in the audit as team.admin.remove on core"), "the audit's note");
    expect(fake.admin.teams.get("core")!.admins).toEqual(["erin@example.com"]);
  });

  it("removes a team behind its typed name, and shows what the audit recorded", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/research/danger");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Remove research"), "the danger zone")).click();
    await waitFor(() => says("What will happen"), "the preview");
    const go = () => [...document.querySelectorAll<HTMLButtonElement>(".preview button")].find((b) => (b.textContent ?? "").startsWith("Remove research"))!;
    expect(go().disabled).toBe(true);
    type(field("Type research to confirm")!, "research");
    await waitFor(() => !go().disabled, "the confirmation");
    go().click();
    await waitFor(() => says("Recorded in the audit as team.disable on research"), "the audit's note");
    expect(fake.admin.teams.has("research")).toBe(false);
    await waitFor(() => link("All teams"), "the way back to the list");
  });

  it("enables a group as a team from the list, and will not send a name that is already a team's", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Enable a group as a team"), "the team list")).click();
    type(await waitFor(() => field("Group"), "the form"), "grp-platform");
    await waitFor(() => (field("Team name") as HTMLInputElement).value === "platform-owners", "the name made from the group's");
    type(field("Team name")!, "core");
    await waitFor(() => says("There is already a team called core"), "the collision");
    expect(button("Preview")!.disabled).toBe(true);
    type(field("Team name")!, "platform");
    button("Preview")!.click();
    await waitFor(() => says("Platform owners becomes the team platform"), "the preview");
    button("Enable")!.click();
    await waitFor(() => says("Recorded in the audit as team.enable on platform"), "the audit's note");
    expect(fake.admin.teams.get("platform")!.groups.map((g) => g.external_id)).toEqual(["grp-platform"]);
    // The note is drawn from the write's answer; the list is read again after it.
    await waitFor(() => link("platform"), "the new team in the list");
  });

  it("says which group looks held twice, and the mismatch the plane thinks made it, before it is chosen", async () => {
    // A groups claim that names the group by its name, beside the one SCIM pushed by its id.
    const likely = "the groups claim names this group by its name and SCIM by its id";
    fake.admin.groups.push({ external_id: "Platform owners", display_name: "Platform owners", looks_duplicated: { others: ["grp-platform"], likely } });
    const pushed = fake.admin.groups.find((g) => g.external_id === "grp-platform")!;
    pushed.looks_duplicated = { others: ["Platform owners"], likely };

    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Enable a group as a team"), "the team list")).click();
    const group = await waitFor(() => field("Group"), "the form");
    await sees("Platform owners (grp-platform) · looks held twice");
    expect(says("looks held twice:")).toBe(false);

    type(group, "grp-platform");
    await waitFor(() => says("Platform owners looks held twice: Platform owners has the same name."), "the flag");
    await sees(`Most likely ${likely}.`);

    type(group, "grp-core");
    await waitFor(() => !says("looks held twice:"), "the flag going with the other group");
  });

  it("offers a team admin none of a platform admin's edits", async () => {
    await signedInAs(fake, PEOPLE.bob);
    visit("#/teams/design/members");
    unmount = render(<App />).unmount;
    await waitFor(() => says("Membership is the identity provider's"), "the members tab");
    expect(button("Link a group")).toBeNull();
    expect(button("Unlink")).toBeNull();
    link("Access")!.click();
    await waitFor(() => says("A profile grant is the only way design gains reach"), "the access tab");
    expect(button("Grant a profile")).toBeNull();
    expect(button("Revoke")).toBeNull();
    link("Admins")!.click();
    await waitFor(() => says("Who may administer design"), "the admins tab");
    expect(button("Name an administrator")).toBeNull();
    expect(button("Remove")).toBeNull();
    visit("#/teams");
    await waitFor(() => link("design"), "the team list");
    expect(button("Enable a group as a team")).toBeNull();
  });
});
