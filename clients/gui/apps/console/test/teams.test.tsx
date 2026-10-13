// Teams: the list, and a team in the brief's five tabs. Every tab reads through
// `admin.teams.list` (and the danger zone through `admin.team.disable.preview`); Limits
// also changes, through `admin.team.update`, previewed first, with the ladder's ceiling
// quoted and the plane's refusal shown where it was made.

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
const tabs = (): string[] => [...document.querySelectorAll(".tabs a")].map((a) => a.textContent ?? "");
const limit = (name: string): HTMLElement | null => [...document.querySelectorAll<HTMLElement>(".limit")].find((l) => (l.textContent ?? "").startsWith(name)) ?? null;

describe("the team list", () => {
  it("lists every team for a platform admin, with its people, groups, profiles, admins and spend, and searches them", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams");
    unmount = render(<App />).unmount;
    await waitFor(() => link("core") && link("design") && link("research"), "the teams");
    expect(says("Core engineering")).toBe(true);
    expect(says("dev, ux")).toBe(true);
    expect(says("dan@example.com")).toBe(true);
    expect(says("over budget")).toBe(true);
    expect(says("no ceiling")).toBe(true);

    type(document.querySelector<HTMLInputElement>('[aria-label="Search teams"]')!, "bob@");
    await waitFor(() => link("core") === null, "the search");
    expect(link("design")).not.toBeNull();
    type(document.querySelector<HTMLInputElement>('[aria-label="Search teams"]')!, "nobody-at-all");
    await waitFor(() => says('No team matches "nobody-at-all"'), "the empty search");
  });

  it("says what to do when there are no teams at all", async () => {
    fake.admin.teams.clear();
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => says("No teams yet"), "the empty state");
    expect(link("current console's Teams page")!.href).toBe(`${fake.plane.baseUrl}/admin/teams`);
  });
});

describe("a team", () => {
  it("reads its members and groups, its access and its admins, each in its tab", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core");
    unmount = render(<App />).unmount;
    await waitFor(() => heading() === "core" && says("Membership is the identity provider's"), "the members tab");
    expect(tabs()).toEqual(["Members and groups", "Access", "Admins", "Limits", "Danger zone"]);
    expect(says("grp-core")).toBe(true);
    expect(says("erin@example.com")).toBe(true);
    expect(says("150.00")).toBe(true);

    link("Access")!.click();
    await waitFor(() => says("A profile grant is the only way core gains reach"), "the access tab");
    expect(says("shared")).toBe(true);
    expect(says("Granting a profile")).toBe(true);

    link("Admins")!.click();
    await waitFor(() => says("Who may administer core"), "the admins tab");
    expect(says("dan@example.com")).toBe(true);
  });

  it("shows a platform admin what removing a team would take, and reads it from the plane", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/danger");
    unmount = render(<App />).unmount;
    await waitFor(() => says("What removing it would take") && says("nightly-deps"), "the danger zone");
    expect(says("Grants revoked: dev, ux")).toBe(true);
    expect(says("svc:core/nightly")).toBe(true);
    expect(says("7 sessions are kept, with no team.")).toBe(true);
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
    expect(says("90 days", erase)).toBe(true);
    expect(says("team", erase)).toBe(true);
    const idle = limit("Idle before it goes dormant")!;
    expect(says("1200 s", idle)).toBe(true);
    button("Why?", erase)!.click();
    await waitFor(() => says("deployment", limit("Sessions erased after")!) && says("365 days", limit("Sessions erased after")!), "the ladder");
    expect(says("180 days", limit("Sessions erased after")!)).toBe(true);
    expect(says("500.00", limit("Budget")!)).toBe(true);
  });

  it("previews a narrower limit in words, applies it on confirm, and shows what the audit recorded", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/teams/core/limits");
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Change core's limits"), "the limits")).click();
    type(await waitFor(() => field("Idle before it goes dormant"), "the form"), "600");
    expect(says("The platform allows at most 1800 s.")).toBe(true);
    button("Preview")!.click();

    await waitFor(() => says("What will happen"), "the preview");
    expect(says("idle_timeout_seconds: 1200 s")).toBe(true);
    expect(says("idle_timeout_seconds: 600 s")).toBe(true);
    expect(says("A core session idle for 600 seconds goes dormant")).toBe(true);
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
    button("Apply")!.click();
    await waitFor(() => says("idle_timeout_seconds: 7200 is wider than 1800, which the deployment decided. A lower rung may only narrow."), "the refusal");
    expect(fake.admin.teams.get("core")!.idle_timeout_seconds).toBe(1200);
    expect(fake.admin.audit).toEqual([]);
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
