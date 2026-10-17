// Runs and review: every run of the teams a person administers, with the repository and
// issue a GitHub run worked on, its state, its draft pull request and its CI rounds, and
// what it spent; a run's page with its record, a link to its session, and marking it read.
// Against the fake plane's `admin.runs.list` and `admin.run.review`, as both roles.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, link, render, says, sees, signedInAs, startFake, type, visit, waitFor } from "./support";
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
const rows = (): HTMLTableRowElement[] => [...document.querySelectorAll<HTMLTableRowElement>("table.runs tbody tr")];
const row = (trigger: string, fired: string): HTMLTableRowElement | null =>
  rows().find((r) => (r.cells[1]?.textContent ?? "").startsWith(trigger) && (r.cells[0]?.textContent ?? "").startsWith(fired)) ?? null;

async function open(hash: string, who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App />).unmount;
}

describe("the runs", () => {
  it("lists every team's runs for a platform admin, with the repository, issue, pull request and spend", async () => {
    await open("#/runs");
    await waitFor(() => row("nightly-deps", "2026-10-15 03:00"), "the runs");
    expect(heading()).toBe("Runs and review");
    expect(rows().length).toBe(4);

    const fix = row("nightly-deps", "2026-10-15 03:00")!;
    await sees("example-org/widgets", fix);
    expect(link("#7", fix)!.href).toBe("https://github.example.com/example-org/widgets/issues/7");
    expect(link("#21", fix)!.href).toBe("https://github.example.com/example-org/widgets/pull/21");
    await sees("2 CI rounds, 1 red", fix);
    await sees("3.40", fix);
    expect(link("nightly-deps", fix)!.getAttribute("href")).toBe("#/triggers/core/nightly-deps");

    // A run that ended and nobody has read is said to be unread; one somebody read, by whom.
    await sees("not yet", () => row("nightly-deps", "2026-10-14 03:00"));
    await sees("failed", () => row("nightly-deps", "2026-10-14 03:00"));
    await sees("by dan@example.com", () => row("nightly-deps", "2026-10-13 03:00"));
    await sees("waiting on a person", () => row("weekly-digest", "2026-10-12 08:00"));

    type(field("Showing")!, "github");
    await waitFor(() => rows().length === 1, "only the GitHub run");
    type(field("Showing")!, "unread");
    await waitFor(() => rows().length === 3, "the unread runs");
    type(field("Showing")!, "");
    type(field("Team")!, "design");
    await waitFor(() => rows().length === 1 && row("weekly-digest", "2026-10-12"), "design's run");
  });

  it("shows a team admin their own team's runs and nothing of another's", async () => {
    await open("#/runs", PEOPLE.bob);
    await waitFor(() => row("weekly-digest", "2026-10-12"), "design's run");
    expect(rows().length).toBe(1);
    expect(says("example-org/widgets")).toBe(false);

    // Nor another team's run by its address.
    visit("#/runs/run-fix-7");
    await waitFor(() => says("No such run"), "the refusal");
  });
});

describe("a run", () => {
  it("reads its record, links to its session, and is marked read", async () => {
    await open("#/runs/run-fix-7");
    await waitFor(() => says("On GitHub") && says("troupe/issue-7"), "the run's page");
    await sees("example-org/widgets");
    await sees("Widgets wobble");
    expect(link("core/nightly-deps")!.getAttribute("href")).toBe("#/triggers/core/nightly-deps");
    expect(link("#21")!.href).toBe("https://github.example.com/example-org/widgets/pull/21");
    await sees("test (ubuntu)");
    const rounds = [...document.querySelectorAll<HTMLTableRowElement>("table.rounds tbody tr")];
    expect(rounds.map((r) => (r.cells[2]?.textContent ?? "").replace(/[^a-z]/g, ""))).toEqual(["red", "green"]);

    const session = link("s-run-fix-7")!;
    expect(session.getAttribute("href")).toBe("#/sessions/s-run-fix-7");

    button("Mark it read")!.click();
    await waitFor(() => says("The run stops counting as unread"), "the preview");
    button("Mark it read")!.click();
    await waitFor(() => says("Recorded in the audit as run.review on s-run-fix-7"), "the audit's note");
    expect(fake.admin.runRows.find((r) => r.id === "run-fix-7")!.reviewed_by).toBe(PEOPLE.alice.subject);
    await waitFor(() => says(`by ${PEOPLE.alice.subject}`), "the run, read");
    expect(button("Mark it read")).toBeNull();

    // Its session link opens Sessions searched for it.
    session.click();
    await waitFor(() => heading() === "Sessions", "the sessions");
    expect((document.querySelector('input[aria-label="Search sessions"]') as HTMLInputElement).value).toBe("s-run-fix-7");
  });

  it("says a run that started no session has nothing on GitHub", async () => {
    await open("#/runs/run-nightly-13");
    await waitFor(() => says("none: it did not start one"), "the skipped run");
    await sees("the run names no repository");
    expect(button("Mark it read")).toBeNull();
  });
});
