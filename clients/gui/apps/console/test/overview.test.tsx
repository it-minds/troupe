// The overview: what needs attention first, worst first and each with where it is fixed;
// then each profile's fleet and each team's spend. From `admin.overview`, with the runs
// nobody has read from `admin.sessions.list`, scoped by the plane to what the person
// administers.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, freshBrowser, link, render, says, sees, signedInAs, startFake, visit, waitFor } from "./support";
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

const items = (): HTMLElement[] => [...document.querySelectorAll<HTMLElement>("ul.attention li")];
const metric = (label: string): HTMLElement | null => [...document.querySelectorAll<HTMLElement>(".metric")].find((m) => says(label, m)) ?? null;

describe("the overview", () => {
  it("is where the console opens, and says what needs attention first, worst first, each with where it is fixed", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => items().length > 0, "what needs attention");
    expect(document.querySelector("h1")?.textContent).toBe("Overview");

    const said = items().map((i) => i.textContent ?? "");
    // design is over its ceiling; build-box-0 never reported; heavy has one pod of two;
    // dev-1 drains; one trigger run waits to be read.
    expect(said[0]).toContain("design is at its monthly ceiling");
    expect(said.some((s) => s.includes("troupe-w-dev-1 on dev is draining: 1 session still on it."))).toBe(true);
    expect(said.some((s) => s.includes("build-box-0 on build-box has never reported"))).toBe(true);
    expect(said.some((s) => s.includes("heavy asked for 2 pods and has 1."))).toBe(true);
    expect(said.some((s) => s.includes("1 session an unattended run started is waiting for a person"))).toBe(true);
    expect(link("design's limits")!.getAttribute("href")).toBe("#/teams/design/limits");
    // Each is fixed in this console: a pod where the pods are, the runs where runs are read.
    expect(link("Look at heavy")!.getAttribute("href")).toBe("#/pods");
    expect(link("Runs and review")!.getAttribute("href")).toBe("#/runs");
    expect([...document.querySelectorAll("a")].filter((a) => a.href.includes("/admin"))).toEqual([]);

    await sees("4", () => metric("Active sessions"));
    await sees("5 dormant, 1 read-only", () => metric("Active sessions"));
    await sees("3 / 5", () => metric("Pods"));
    await sees("473.50", () => metric("Spent"));
  });

  it("shows each profile's fleet and each team's spend against its budget", async () => {
    await signedInAs(fake, PEOPLE.alice);
    visit("#/overview");
    unmount = render(<App />).unmount;
    await waitFor(() => says("Fleet · per profile") && link("build-box"), "the fleet");
    // A profile is linked to its own page in this console.
    expect(link("build-box")!.getAttribute("href")).toBe("#/profiles/build-box");
    await sees("over budget");
    expect(link("core")!.getAttribute("href")).toBe("#/teams/core/limits");
  });

  it("shows a team admin their own team's part and nothing of another's", async () => {
    await signedInAs(fake, PEOPLE.bob);
    unmount = render(<App />).unmount;
    await waitFor(() => says("Spend · per team") && link("design"), "the overview, as the design team's admin");
    expect(link("core")).toBeNull();
    expect(link("dev")).toBeNull();
    await sees("2 dormant, 0 read-only", () => metric("Active sessions"));
  });

  it("says so when nothing needs attention", async () => {
    for (const p of fake.admin.profiles) p.pods = Array.from({ length: p.replicas }, (_, i) => ({ ...p.pods[0]!, pod: `${p.name}-${i}`, healthy: true, draining: false, last_seen_at: "2026-10-13T09:00:00Z" }));
    for (const t of fake.admin.teams.values()) t.budget_micros = 0;
    for (const s of fake.admin.sessions) s.reviewed = true;
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => says("Nothing needs attention"), "the empty list");
    await sees("Nothing is unhealthy, at its ceiling or waiting on a person.");
  });
});
