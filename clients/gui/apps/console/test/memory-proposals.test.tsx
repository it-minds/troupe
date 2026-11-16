// What agents proposed for a team's or the organisation's memory (#55), waiting on Company
// memory for whoever may change that level: each with where it would go and where it came
// from; accepted after a preview, which writes it into the document, or declined with a
// sentence the session is told. Counted on the Overview's "Needs attention".

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, freshBrowser, render, sees, seesButton, seesField, signedInAs, startFake, type, visit, waitFor } from "./support";
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

const queue = (): HTMLElement | null => document.querySelector<HTMLElement>('section.proposals[aria-label="Waiting for review"]');
const row = (text: string): HTMLElement | null => [...document.querySelectorAll<HTMLElement>("li.proposal")].find((li) => li.textContent?.includes(text)) ?? null;

describe("memory proposals", () => {
  it("lists each waiting proposal with where it would go and where it came from", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    await waitFor(queue, "the queue");
    await sees("For the core team's memory, under Releases", () => row("Tuesdays after the freeze"));
    await sees("Releases go out on Tuesdays after the freeze lifts.", queue);
    await sees("by the agent build in s-7f3a9c21, for erin@example.com, on a pod.", () => row("Tuesdays after the freeze"));
    await sees("For the organisation's memory, under Tone", () => row("present tense"));
    await sees("on dan@example.com's machine.", () => row("present tense"));
  });

  it("accepts one after a preview: the entry is in the document, audited, and the queue moves on", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => row("Tuesdays after the freeze"), "the core proposal");

    (await seesButton("Accept", row("Tuesdays after the freeze")!)).click();
    await sees("What will happen", () => row("Tuesdays after the freeze"));
    await sees("with build in s-7f3a9c21 as who wrote the line", () => row("Tuesdays after the freeze"));
    // Nothing is written until it is confirmed.
    expect(fake.admin.memory.get("team/core")).toBeUndefined();

    button("Accept", row("Tuesdays after the freeze")!)!.click();
    await sees("Recorded in the audit as memory.proposal.accept on team/core", queue);
    await waitFor(() => !row("Tuesdays after the freeze"), "the accepted proposal to leave the queue");
    expect(fake.admin.memory.get("team/core")!.at(-1)!.text).toBe("## Releases\n\n- Releases go out on Tuesdays after the freeze lifts.");
    expect(fake.admin.memoryProposals.find((p) => p.id === "p-core-1")).toMatchObject({ state: "accepted", decided_by: "alice@example.com", version: 1 });
    // The core team's document, read again, holds it.
    await sees("- Releases go out on Tuesdays after the freeze lifts.", () => document.querySelector<HTMLElement>('section.memory[aria-label="The core team\'s memory"]'));
  });

  it("declines one with a sentence, which is what the session is told", async () => {
    visit("#/memory");
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;
    await waitFor(() => row("present tense"), "the organisation's proposal");

    (await seesButton("Decline", row("present tense")!)).click();
    const why = await seesField("Why it is declined", row("present tense")!);
    expect((await seesButton("Decline", row("present tense")!)).hasAttribute("disabled")).toBe(true);
    type(why, "We write commit messages in the imperative.");
    button("Decline", row("present tense")!)!.click();

    await sees("Recorded in the audit as memory.proposal.decline on organisation", queue);
    expect(fake.admin.memoryProposals.find((p) => p.id === "p-org-1")).toMatchObject({
      state: "declined",
      reason: "We write commit messages in the imperative.",
      message: expect.stringContaining("was declined by alice@example.com: We write commit messages in the imperative."),
    });
    expect(fake.admin.memory.get("organisation")!.length).toBe(2);
  });

  it("shows a team admin only their team's, and says so when proposals are switched off", async () => {
    fake.admin.memoryProposalsOn = false;
    visit("#/memory");
    await signedInAs(fake, { subject: "dan@example.com", name: "Dan" });
    unmount = render(<App />).unmount;

    await waitFor(() => row("Tuesdays after the freeze"), "core's proposal");
    expect(row("present tense")).toBeNull();
    await sees("Agents' proposals are switched off", queue);
  });

  it("is counted on the overview, linked to Company memory", async () => {
    await signedInAs(fake, PEOPLE.alice);
    unmount = render(<App />).unmount;

    const line = (): HTMLElement | null => [...document.querySelectorAll<HTMLElement>("ul.attention li")].find((li) => li.textContent?.includes("memory proposals")) ?? null;
    await sees("2 memory proposals from agents are waiting for you to accept or decline.", line);
    expect(line()!.querySelector("a")!.getAttribute("href")).toBe("#/memory");
  });
});
