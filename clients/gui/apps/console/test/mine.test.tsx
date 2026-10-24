// Mine: what a person who signs in to the console has of their own, whether they administer
// anything or not. Their sessions on the plane and nobody else's, which version of each of
// their clients the plane last saw against its policy, and the memory their machines read,
// to read and not to change. Every call is one any client of theirs makes, never `admin.*`.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, freshBrowser, recordCalls, render, sees, signedInAs, startFake, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";
import { exampleAdmin } from "../../../packages/client/test/support/admin.js";

let fake: FakeDeployment;
let unmount: (() => void) | null = null;
let restore: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake(exampleAdmin(), {
    clientsSeen: [
      { component: "desktop", version: "0.25.0-beta", platform: "windows/x86_64", since: "2026-10-20T09:00:00Z", seen_at: "2026-10-24T08:00:00Z", standing: "current", recommended: "0.25.0-beta" },
      { component: "tui", version: "0.23.0-beta", platform: null, since: "2026-10-10T09:00:00Z", seen_at: "2026-10-23T08:00:00Z", standing: "behind", recommended: "0.25.0-beta" },
    ],
    memory: [
      { scope: "organisation", name: null, version: 3, hash: "sha256:a", updated_at: "2026-10-22T10:00:00Z", text: "We write British English." },
      { scope: "team", name: "design", version: 1, hash: "sha256:b", updated_at: "2026-10-21T10:00:00Z", text: "Figma links go in the PR." },
    ],
  });
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  restore?.();
  restore = null;
  await fake.stop();
});

describe("Mine", () => {
  it("shows a member their own sessions, their clients' versions and their memory, read-only, through no administrative call", async () => {
    fake.plane.seed(PEOPLE.carol.subject, { id: "s-carol-1", title: "Tidy the icons", profile: "ux" });
    fake.plane.seed(PEOPLE.alice.subject, { id: "s-alice-1", title: "Somebody else's", profile: "dev" });
    const recorded = recordCalls();
    restore = recorded.restore;
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;

    const sessions = () => document.querySelector('[aria-label="Your sessions"]');
    await sees("Tidy the icons", sessions);
    expect(sessions()!.textContent).not.toContain("Somebody else's");

    const clients = () => document.querySelector('[aria-label="Your clients"]');
    await sees("desktop app 0.25.0-beta on windows/x86_64", clients);
    await sees("current", clients);
    await sees("terminal 0.23.0-beta", clients);
    await sees("behind · the plane recommends 0.25.0-beta", clients);

    const memory = () => document.querySelector('[aria-label="Your memory"]');
    await sees("We write British English.", memory);
    await sees("The design team's", memory);
    expect(memory()!.querySelector("textarea, input, button"), "a member's memory is to read").toBeNull();
    expect(button("Save")).toBeNull();

    const methods = recorded.calls.filter((c) => c.url.startsWith(fake.plane.baseUrl)).map((c) => c.method).filter((m): m is string => m !== null);
    expect(methods).toEqual(expect.arrayContaining(["me", "sessions.list", "me.clients", "me.memory"]));
    // `admin.teams.list` is how the console finds a member administers nothing; nothing after it is administrative.
    expect(methods.filter((m) => m.startsWith("admin.") && m !== "admin.teams.list")).toEqual([]);
  });

  it("says so where the plane has seen no client of theirs and keeps no memory for them", async () => {
    await fake.stop();
    fake = await startFake();
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector('[aria-label="Your clients"]')?.textContent?.includes("No client of yours"), "no clients");
    await sees("Your organisation keeps no memory for you");
    await sees("No session of yours on the plane");
  });
});
