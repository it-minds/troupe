// An artifact's thread and who it is shared with by name, in the console (#62's last slice):
// the thread beside the artifact's page, oldest first with who wrote each comment and when;
// a box for whoever may write (its owner, somebody given comment or edit) and none for
// whoever may only read; and, for its owner, the people it is shared with by name, each at a
// role, taken back here. Somebody it is shared with by name finds it under Shared with you.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, freshBrowser, render, sees, seesButton, signedInAs, startFake, type, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";
import { artifact } from "../../../packages/client/test/support/plane.js";

const carol = { subject: PEOPLE.carol.subject, display_name: "Carol" };

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

async function open(hash: string, who: { subject: string; name: string }): Promise<void> {
  await signedInAs(fake, who);
  visit(hash);
  unmount = render(<App openTab={() => undefined} navigate={() => undefined} />).unmount;
}

const thread = () => document.querySelector<HTMLElement>('section[aria-label="Comments"]');
const people = () => document.querySelector<HTMLElement>('section[aria-label="Shared with"]');

beforeEach(async () => {
  freshBrowser();
  fake = await startFake(exampleAdmin(), {
    artifacts: [
      artifact("art-org", carol, { title: "Roadmap", visibility: "organisation" }),
      artifact("art-plan", carol, { title: "Hiring plan", visibility: "private" }),
    ],
  });
  fake.plane.people = [{ subject: PEOPLE.bob.subject, display_name: "Bob", email: PEOPLE.bob.subject }];
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

describe("an artifact's thread", () => {
  it("is shown beside its page with names and times, and its owner writes in it", async () => {
    fake.plane.comments.set("art-org", [{ id: "c-1", author: { subject: PEOPLE.bob.subject, display_name: "Bob" }, body: "Is Q3 right?", created_at: "2026-10-25T12:00:00Z" }]);
    await open("#/artifacts/art-org", PEOPLE.carol);
    await sees("Is Q3 right?", thread);
    expect(thread()!.textContent).toContain("Bob");
    expect(thread()!.textContent).toContain("2026-10-25 12:00 UTC");

    type(thread()!.querySelector<HTMLTextAreaElement>("textarea")!, "Yes, checked.");
    (await waitFor(() => [...thread()!.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === "Comment" && !b.disabled), "Comment, enabled")).click();
    await waitFor(() => thread()!.querySelectorAll("li").length === 2, "the new comment in the thread");
    expect(thread()!.querySelector("li:last-child")?.textContent).toContain("Yes, checked.");
    expect(fake.plane.comments.get("art-org")!.map((c) => c.body)).toEqual(["Is Q3 right?", "Yes, checked."]);
  });

  it("is read without a box by somebody who sees it only because of who it is for", async () => {
    await open("#/artifacts/art-org", PEOPLE.bob);
    await sees("No comments yet.", thread);
    await sees("Its owner decides who may write them.", thread);
    expect(thread()!.querySelector("textarea")).toBeNull();
  });
});

describe("who it is shared with by name", () => {
  it("is under Shared with you for the person, who may comment at that role", async () => {
    fake.plane.named.set("art-plan", new Map([[PEOPLE.bob.subject, { role: "comment" as const, granted_by: carol.subject, granted_at: "2026-10-25T12:00:00Z" }]]));
    await open("#/artifacts/shared", PEOPLE.bob);
    await sees("Hiring plan");
    unmount?.();
    visit("#/artifacts/art-plan");
    unmount = render(<App openTab={() => undefined} navigate={() => undefined} />).unmount;
    await sees("may open it and comment on it, shared with you");
    await waitFor(() => thread()?.querySelector("textarea") ?? null, "a box to write in");
  });

  it("is listed for its owner at each role, and taken back", async () => {
    fake.plane.named.set("art-plan", new Map([[PEOPLE.bob.subject, { role: "edit" as const, granted_by: carol.subject, granted_at: "2026-10-25T12:00:00Z" }]]));
    await open("#/artifacts/art-plan", PEOPLE.carol);
    await sees("Bob", people);
    expect(people()!.textContent).toContain("may comment on it and publish new versions");
    (await waitFor(() => people()!.querySelector<HTMLButtonElement>('button[aria-label="Remove Bob"]'), "Remove Bob")).click();
    await sees("Nobody by name.", people);
    expect(fake.plane.named.get("art-plan")?.has(PEOPLE.bob.subject)).toBe(false);
  });
});
