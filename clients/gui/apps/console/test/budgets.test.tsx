// Budgets and connections: every team's spend against its ceiling, which ceiling would
// refuse a person first, a person's own cap set behind a preview; and who has connected a
// personal credential to which server. Against the fake plane's `admin.budget.explain`,
// `admin.person.budget` and `admin.connections.list`.

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

async function open(hash: string, who: { subject: string; name: string } = PEOPLE.alice): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App />).unmount;
}

const go = (verb: string) => [...document.querySelectorAll<HTMLButtonElement>(".preview button")].find((b) => (b.textContent ?? "").startsWith(verb) && !b.disabled);

describe("budgets", () => {
  it("names the ceiling that refuses a person first, with what each rung has left", async () => {
    await open("#/budgets");
    type(await waitFor(() => field("Person"), "the form"), "dan@example.com");
    type(field("In team")!, "core");
    button("Explain")!.click();
    // Dan's own cap is 150 and he has spent 120: tighter than core's ceiling.
    await waitFor(() => says("This person's own cap is what refuses first: 30.00 left."), "the answer");
    await sees("the team's ceiling");
    await sees("the platform's, or the deployment's");
  });

  it("sets a person's own cap behind a preview, and shows the audit's record", async () => {
    await open("#/budgets");
    (await waitFor(() => button("Set a person's cap"), "the cap")).click();
    const people = await waitFor(() => document.querySelectorAll<HTMLSelectElement>('form[aria-label="A person\'s own cap"] select')[0], "the form");
    type(people, "erin@example.com");
    type(field("Cap, in dollars a month")!, "40");
    button("Preview")!.click();
    await waitFor(() => says("may spend 40.00 a month across every team"), "the preview");
    (await waitFor(() => go("Apply"), "the confirm")).click();
    await waitFor(() => says("Recorded in the audit as person.budget on erin@example.com"), "the audit's note");
    expect(fake.admin.teams.get("core")!.members.find((m) => m.subject === "erin@example.com")!.budget_micros).toBe(40_000_000);
  });

  it("shows a team admin their teams' ceilings and nothing a platform admin decides", async () => {
    await open("#/budgets", PEOPLE.bob);
    await waitFor(() => says("Every team") && says("design"), "design's ceiling");
    expect(says("core")).toBe(false);
    expect(button("Explain")).toBeNull();
    expect(button("Set a person's cap")).toBeNull();
  });
});

describe("connections", () => {
  it("says who has connected to each person-mode server and whose identity a session carries, and that nothing reads a credential", async () => {
    await open("#/connections");
    await waitFor(() => says("calendar · slot calendar"), "the server");
    await sees("1 of 3 people have connected");
    const dan = [...document.querySelectorAll("tr")].find((r) => (r.textContent ?? "").includes("dan@example.com") && (r.textContent ?? "").includes("connected"));
    expect(dan?.textContent).toContain("connected");
    await sees("s-7f3a9c21");
    await sees("Nobody here can read or remove a person's credential");
  });
});
