// An artifact a team owns, in the console: its page says the team is whose it is and that
// every member is an owner, a member has the owner's controls, an admin of the owning
// team takes it back, and the owning person gives one of theirs to a team, the plane's
// refusal said on the page; its card says whose it is. Against the fake plane, whose
// people's teams are named per person here.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, field, freshBrowser, render, sees, seesButton, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";

const ada = { subject: "ada@example.com", display_name: "Ada" };
const dan = { subject: "dan@example.com", name: "Dan" };

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  // Carol and Dan are in core, Dan its admin; Ada is in no team, though the plane's `me`
  // still offers her core, so the plane's refusal of a team she is not in is what the page says.
  fake = await startFake(exampleAdmin(), {
    memberOf: { "carol@example.com": ["core"], "dan@example.com": ["core"], "ada@example.com": [] },
    artifacts: [
      artifact("art-team", ada, { title: "Core's figures", visibility: "private", owner_team: "core", team: "core" }),
      artifact("art-own", ada, { title: "Ada's draft", visibility: "private", team: "core" }),
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
const whose = (): HTMLElement | null => document.querySelector<HTMLElement>('[aria-label="Whose it is"]');

describe("an artifact a team owns", () => {
  it("is every member's, whose page says the team is its owner, and is under Mine", async () => {
    await open("#/artifacts/art-team", PEOPLE.carol);
    await sees("the core team (you are a member); Ada (ada@example.com) first published it");
    await sees("an owner, as every member of core is");
    await sees("the core team, whose it is, and whoever you give a link");
    await seesButton("Pin version 1");
    expect(button("Take back")).toBeNull();

    visit("#/artifacts");
    await sees("Core's figures", cards);
    await sees("the core team's", cards);
  });

  it("is taken back by an admin of the team, who becomes its owner", async () => {
    await open("#/artifacts/art-team", dan);
    (await seesButton("Take back")).click();
    await sees("Core's figures is yours now, not the core team's.");
    await waitFor(() => fake.plane.artifacts.get("art-team")?.owner_team === null, "the plane's row");
    await sees("you, Dan (dan@example.com)");
    await sees("its owner");
    await waitFor(() => button("Take back") === null, "nothing to take back");
  });

  it("is given to a team by its owner, and the plane's refusal is said on the page", async () => {
    await open("#/artifacts/art-own", { subject: ada.subject, name: "Ada" });
    await sees("you, Ada (ada@example.com)");
    const to = await waitFor(() => field("Give to team", whose() ?? document), "the team chooser");
    type(to, "core");
    (await seesButton("Give it to the team")).click();
    await sees("Could not give it to the team: you are not in team core");

    // Now in core, the same click gives it to the team.
    fake.plane.join("ada@example.com", ["core"]);
    button("Give it to the team")!.click();
    await sees("Ada's draft is the core team's now: every member of it is its owner.");
    await waitFor(() => fake.plane.artifacts.get("art-own")?.owner_team === "core", "the plane's row");
    await sees("the core team (you are a member)");
  });
});
