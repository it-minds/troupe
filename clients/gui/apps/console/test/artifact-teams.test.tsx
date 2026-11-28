// A team's artifacts and private ones (#62): the gallery's Teams tab lists the teams' own,
// the team named on each card, from the plane's `teams: true`; a private one is under its
// owner's Mine and nobody else's; and an administrator's Artifacts opens on Every artifact,
// their table, every one for a platform admin and a team admin's teams' own, each opened on
// its page as its administrator reads it, audited, and taken down by typing its id. Against
// the fake plane, whose people are all in team core.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { PEOPLE, button, field, freshBrowser, link, opener, says, sees, seesLink, startFake, type, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";

const ada = { subject: "ada@example.com", display_name: "Ada" };
const carol = { subject: PEOPLE.carol.subject, display_name: "Carol" };

let fake: FakeDeployment;

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
  close();
  await fake.stop();
});

const { open, close } = opener(() => fake, { openTab: () => undefined });

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
    await sees("for only you, and whoever you share it with", cards);
    expect(document.body.textContent).not.toContain("Ada's diary");
  });
});

describe("every artifact, for administrators", () => {
  const whose = (): HTMLElement => document.querySelector<HTMLElement>('nav[aria-label="Whose artifacts"]')!;

  it("is a platform admin's first tab, a person's private ones too, with Mine a filter beside it", async () => {
    await open("#/artifacts", PEOPLE.alice);
    await waitFor(() => row("Ada's diary"), "a private one");
    expect(link("Every artifact", whose())!.getAttribute("aria-current")).toBe("page");
    await sees("its owner alone", () => row("Ada's diary"));
    await sees("the design team", () => row("Design board"));
    await waitFor(() => row("Core's plan"), "a team's");
    expect(document.querySelector("iframe")).toBeNull();

    // Mine narrows it to what is the administrator's own, as anybody's Mine is.
    link("Mine", whose())!.click();
    await sees("You have published nothing yet");
    expect(document.body.textContent).not.toContain("Ada's diary");
    expect(globalThis.location.hash).toBe("#/artifacts/mine");
  });

  it("opens another person's private one on its page as its administrator reads it, each read audited, and offers its takedown", async () => {
    await open("#/artifacts", PEOPLE.alice);
    (await waitFor(() => row("Ada's diary")?.querySelector("a"), "its title, a link")).click();
    await sees("You read this page as an administrator");
    await sees("it does not open here");
    await waitFor(() => document.querySelector('section[aria-label="Versions"]'), "its versions");
    await waitFor(() => document.querySelector('section[aria-label="Links"]'), "its links, to read");
    expect([...document.querySelectorAll("button")].some((b) => b.textContent === "Open")).toBe(false);
    await waitFor(() => button("Take down"), "its takedown");
    expect(fake.admin.audit.filter((e) => e.action === "artifact.read").map((e) => [e.actor, e.subject_id])).toEqual([[PEOPLE.alice.subject, "art-ada-diary"]]);
    expect(fake.plane.asked).toContain("admin.artifact.get");
  });

  it("was Published artifacts: a link kept from then opens every artifact", async () => {
    await open("#/published", PEOPLE.alice);
    await waitFor(() => row("Ada's diary"), "every artifact");
    await waitFor(() => globalThis.location.hash === "#/artifacts", "its new address");
  });

  it("is a team admin's teams' own, read on its page as their administrator, and taken down once its id is typed", async () => {
    await open("#/artifacts", PEOPLE.bob);
    (await waitFor(() => row("Design board")?.querySelector("a"), "the design team's")).click();
    await waitFor(() => document.querySelector('section[aria-label="Versions"]'), "its page");
    await waitFor(() => fake.admin.audit.some((e) => e.action === "artifact.read" && e.actor === PEOPLE.bob.subject && e.subject_id === "art-design-board"), "the read in the audit");

    close();
    await open("#/artifacts", PEOPLE.bob);
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
