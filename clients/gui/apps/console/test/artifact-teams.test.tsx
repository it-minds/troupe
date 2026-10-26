// A team's artifacts and private ones (#62): the gallery's Teams tab lists the teams' own,
// the team named on each card, from the plane's `teams: true`; a private one is under its
// owner's Mine and nobody else's; and Operate's Published artifacts is the administrators'
// table, every one for a platform admin and a team admin's teams' own, each taken down by
// typing its id. Against the fake plane, whose people are all in team core.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, says, sees, seesLink, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";

const ada = { subject: "ada@example.com", display_name: "Ada" };
const carol = { subject: PEOPLE.carol.subject, display_name: "Carol" };

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake(exampleAdmin(), {
    artifacts: [
      artifact("art-core-plan", ada, { title: "Core's plan", visibility: "team:core", team: "core" }),
      artifact("art-design-board", ada, { title: "Design board", visibility: "team:design", team: "design" }),
      artifact("art-ada-diary", ada, { title: "Ada's diary", visibility: "private", team: "core" }),
      artifact("art-carol-draft", carol, { title: "Carol's draft", visibility: "private", team: "core" }),
    ],
  });
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

async function open(hash: string, who: { subject: string; name: string }): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App openTab={() => undefined} />).unmount;
}

const cards = (): HTMLElement | null => document.querySelector<HTMLElement>('ul[aria-label="Artifacts"]');
const row = (title: string): HTMLTableRowElement | null => [...document.querySelectorAll<HTMLTableRowElement>("tbody tr")].find((r) => r.cells[0]?.textContent?.startsWith(title)) ?? null;
const confirm = (verb: string) => [...document.querySelectorAll<HTMLButtonElement>(".preview button")].find((b) => (b.textContent ?? "").startsWith(verb) && !b.disabled);

describe("a team's artifacts in the gallery", () => {
  it("lists the teams' own under Teams, each card naming its team, and a private one under its owner's Mine alone", async () => {
    await open("#/artifacts/teams", PEOPLE.carol);
    await sees("Core's plan", cards);
    await sees("for the core team", cards);
    expect(cards()!.textContent).not.toContain("Design board");
    expect(document.body.textContent).not.toContain("Ada's diary");
    expect(fake.plane.asked).toContain("artifact.list");

    (await seesLink("Mine", document.querySelector('nav[aria-label="Whose artifacts"]')!)).click();
    await sees("Carol's draft", cards);
    await sees("for only you, and whoever you give a link", cards);
    expect(document.body.textContent).not.toContain("Ada's diary");
  });
});

describe("published artifacts, for administrators", () => {
  it("is every artifact for a platform admin, a person's private ones too, and nothing opens one", async () => {
    await open("#/published", PEOPLE.alice);
    await waitFor(() => row("Ada's diary"), "a private one");
    await sees("its owner alone", () => row("Ada's diary"));
    await sees("the design team", () => row("Design board"));
    await waitFor(() => row("Core's plan"), "a team's");
    expect(document.querySelector("iframe")).toBeNull();
  });

  it("is a team admin's teams' own, taken down once its id is typed", async () => {
    await open("#/published", PEOPLE.bob);
    await waitFor(() => row("Design board"), "the design team's artifact");
    expect(row("Core's plan")).toBeNull();
    expect(row("Ada's diary")).toBeNull();

    button("Take down", row("Design board")!)!.click();
    await waitFor(() => says("This is a takedown"), "the preview");
    expect(confirm("Take it down")).toBeUndefined();
    type(field("Type art-design-board to confirm")!, "art-design-board");
    (await waitFor(() => confirm("Take it down"), "the id typed")).click();
    await waitFor(() => !fake.plane.artifacts.has("art-design-board"), "taken down");
    await waitFor(() => row("Design board") === null, "gone from the table");
  });
});
