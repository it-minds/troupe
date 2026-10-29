// What a member sees, on the administrator's page of a profile: the plane's `profile.get`
// asked as the administrator, answered for no team, drawn as tables and nothing to change.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, freshBrowser, recordCalls, render, says, sees, signedInAs, startFake, visit, waitFor } from "./support";
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

const member = (): HTMLElement | null => document.querySelector<HTMLElement>(".member-view");

async function open(hash: string): Promise<void> {
  await signedInAs(fake, PEOPLE.alice);
  visit(hash);
  unmount = render(<App />).unmount;
}

describe("what a member sees", () => {
  it("is the plane's answer for a member's app, in tables, with whose access each server is called", async () => {
    const { calls, restore } = recordCalls();
    try {
      await open("#/profiles/dev");
      await sees("What a member sees");
      await sees("as you, once you connect it", member);
      await sees("as the profile's own identity", member);
      await sees("search_issues, get_issue", member);
      await sees("git push *", member);
      await sees("the profile", member);
      await sees("glm-5.2", member);
      await sees("profile $200.00", member);
      await sees("What the harness may run here", member);
      await sees("Answers an AI? question about the code", member);
      expect(member()!.querySelectorAll("input, select, textarea, button")).toHaveLength(0);
      expect(calls.filter((c) => c.method === "profile.get")).toHaveLength(1);
    } finally {
      restore();
    }
  });

  it("is answered for no team, so only the profile's own rule leaves an agent out", async () => {
    await open("#/profiles/ux");
    await sees("not here: the profile does not have it", member);
    // The librarian the profile's rule denies is a row not here, not among the harness's jobs.
    const caption = [...member()!.querySelectorAll("caption")].find((c) => c.textContent === "What the harness may run here");
    expect(caption?.closest("table")?.textContent).not.toContain("librarian");
    // The core team's grant leaves out plan; asked as the administrator, no grant narrows it.
    expect(says("your team's grant leaves it out")).toBe(false);
  });

  it("reads a profile the examples do not know from its spec", async () => {
    await open("#/profiles/heavy");
    await waitFor(() => member() && says("2 per pod"), "heavy's member view");
    await sees("no host outside its pod", member);
  });
});
