// Mine: what a person who signs in to the console has of their own, whether they administer
// anything or not. Their sessions on the plane and nobody else's, which version of each of
// their clients the plane last saw against its policy, the memory their organisation gives
// their machines, to read and not to change, and their own memory (#55's user level), to
// change with a preview. Every call is one any client of theirs makes, never `admin.*`.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { PEOPLE, button, freshBrowser, recordCalls, render, sees, seesButton, seesField, signedInAs, startFake, type, visit, waitFor } from "./support";
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
    // Its state as every page of the console says one, a glyph and a word, never the
    // plane's state and status pasted together.
    const state = sessions()!.querySelector("tbody td .status");
    expect(state?.textContent).toBe("● Active");
    expect(sessions()!.textContent).not.toContain("Active · idle");

    const clients = () => document.querySelector('[aria-label="Your clients"]');
    await sees("desktop app 0.25.0-beta on windows/x86_64", clients);
    await sees("current", clients);
    await sees("terminal 0.23.0-beta", clients);
    await sees("behind · the plane recommends 0.25.0-beta", clients);

    const memory = () => document.querySelector('[aria-label="Your memory"]');
    await sees("We write British English.", memory);
    await sees("The design team's", memory);
    for (const read of memory()!.querySelectorAll("article.memory-read")) {
      expect(read.querySelector("textarea, input, button"), "the organisation's memory is to read").toBeNull();
    }
    expect(button("Save")).toBeNull();

    const methods = recorded.calls.filter((c) => c.url.startsWith(fake.plane.baseUrl)).map((c) => c.method).filter((m): m is string => m !== null);
    expect(methods).toEqual(expect.arrayContaining(["me", "sessions.list", "me.clients", "me.memory"]));
    // `admin.teams.list` is how the console finds a member administers nothing; nothing after it is administrative.
    expect(methods.filter((m) => m.startsWith("admin.") && m !== "admin.teams.list")).toEqual([]);
  });

  it("says where each of a member's sessions opens, and that only their own memory is theirs to change", async () => {
    await fake.stop();
    fake = await startFake(exampleAdmin(), {
      memory: [{ scope: "organisation", name: null, version: 3, hash: "sha256:a", updated_at: "2026-10-22T10:00:00Z", text: "We write British English." }],
      own: { [PEOPLE.carol.subject]: "I write British English." },
    });
    fake.plane.seed(PEOPLE.carol.subject, { id: "s-carol-1", title: "Tidy the icons", profile: "ux" });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;

    const sessions = () => document.querySelector<HTMLElement>('[aria-label="Your sessions"]');
    const row = () => [...(sessions()?.querySelectorAll("tbody tr") ?? [])].find((r) => r.textContent?.includes("Tidy the icons")) ?? null;
    await waitFor(() => row(), "carol's session");
    await sees("Open in the app, or in the terminal.", row);
    // A member has no Sessions page, so nothing links there; the one link opens the app
    // at this session (#959).
    // at once: the row was waited for above, and drawn whole
    expect([...row()!.querySelectorAll("a")].map((a) => a.getAttribute("href"))).toEqual([`troupe://session/s-carol-1?plane=${encodeURIComponent(fake.plane.baseUrl)}`]);

    const memory = () => document.querySelector<HTMLElement>('[aria-label="Your memory"]');
    await sees("Your organisation's and your teams' are read-only here", memory);
    const own = () => document.querySelector<HTMLElement>('article[aria-label="Your own memory"]');
    await sees("Yours to change.", own);
    await seesButton("Change your memory", own()!);
    // "Read-only" is said of the levels they cannot change, never of their own.
    expect(own()!.textContent).not.toContain("Read-only");
  });

  it("links a team admin's session to Sessions, where their role may see it", async () => {
    // s-4b81d003 is one of the design team's sessions, which bob administers.
    fake.plane.seed(PEOPLE.bob.subject, { id: "s-4b81d003", title: "Icons, again", profile: "ux" });
    fake.plane.seed(PEOPLE.bob.subject, { id: "s-bob-elsewhere", title: "Not on Sessions", profile: "ux" });
    await signedInAs(fake, PEOPLE.bob);
    visit("#/mine");
    unmount = render(<App />).unmount;

    const sessions = () => document.querySelector<HTMLElement>('[aria-label="Your sessions"]');
    const row = (title: string) => [...(sessions()?.querySelectorAll("tbody tr") ?? [])].find((r) => r.textContent?.includes(title)) ?? null;
    await waitFor(() => row("Icons, again")?.querySelector("a"), "the link to Sessions");
    const app = (id: string) => `troupe://session/${id}?plane=${encodeURIComponent(fake.plane.baseUrl)}`;
    expect([...row("Icons, again")!.querySelectorAll("a")].map((a) => a.getAttribute("href"))).toEqual(["#/sessions/s-4b81d003", app("s-4b81d003"), "#/sessions/s-4b81d003"]);
    await sees("Open in the app, or in the terminal.", () => row("Icons, again"));
    // at once: drawn in the same answer as the row waited for above
    expect([...row("Not on Sessions")!.querySelectorAll("a")].map((a) => a.getAttribute("href"))).toEqual([app("s-bob-elsewhere")]);
    await sees("Open in the app, or in the terminal.", () => row("Not on Sessions"));
  });

  it("lets a person change their own memory, previewed line by line and saved over the version they edited", async () => {
    await fake.stop();
    fake = await startFake(exampleAdmin(), { own: { [PEOPLE.carol.subject]: "I write British English." } });
    const recorded = recordCalls();
    restore = recorded.restore;
    await signedInAs(fake, PEOPLE.carol);
    visit("#/mine");
    unmount = render(<App />).unmount;

    const own = () => document.querySelector<HTMLElement>('article[aria-label="Your own memory"]');
    await sees("I write British English.", own);
    await sees("version 1", own);

    (await seesButton("Change your memory", own()!)).click();
    type(await seesField("Your own memory", own()!), "I write British English.\nTabs, not spaces.");
    button("Preview", own()!)!.click();

    await sees("What will happen", own);
    await sees("your memory v1 → v2", own);
    await sees("Tabs, not spaces.", own);
    await sees("Nobody else reads it", own);
    // Nothing is written until it is confirmed.
    expect(fake.plane.own.get(PEOPLE.carol.subject)!.version).toBe(1);

    (await seesButton("Save", own()!)).click();
    await sees("version 2", own);
    expect(fake.plane.own.get(PEOPLE.carol.subject)).toMatchObject({ version: 2, text: "I write British English.\nTabs, not spaces." });

    // Saved from another machine while a change is open: said, and nothing overwritten.
    (await seesButton("Change your memory", own()!)).click();
    type(await seesField("Your own memory", own()!), "Mine.");
    button("Preview", own()!)!.click();
    await sees("What will happen", own);
    fake.plane.own.set(PEOPLE.carol.subject, { version: 3, text: "From the laptop.", changed_by: PEOPLE.carol.subject, changed_at: "2026-10-25T09:00:00Z" });
    (await seesButton("Save", own()!)).click();
    await sees("version 3 is in force now", own);
    expect(fake.plane.own.get(PEOPLE.carol.subject)!.text).toBe("From the laptop.");

    const methods = recorded.calls.filter((c) => c.url.startsWith(fake.plane.baseUrl)).map((c) => c.method);
    expect(methods).toEqual(expect.arrayContaining(["me.memory.preview", "me.memory.put"]));
    expect(methods.filter((m) => m?.startsWith("admin.memory"))).toEqual([]);
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
