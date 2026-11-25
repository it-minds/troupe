// troupe #1207: a session on the platform starts on GitHub repositories and has more
// attached while it runs. The new-session screen offers the team's listed repositories
// after the profile, on a profile that allows GitHub and on no other; several chosen are
// sent as `repositories`; a refusal is the plane's sentence. The session's Backstage lists
// each one, where its clone is and what was done there, with Attach and Take off for its
// owner and neither for anybody else. Against the fake deployment and the fake daemon.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { castingTiming } from "../src/views/StartSession";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, sees, seesButton, showBackstage, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let harness: Harness | null = null;
let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

const GITHUB = { repositories: ["example-org/widgets", "example-org/gadgets", "example-docs/*"], profiles: { dev: 3 } };

async function signedIn(): Promise<Harness> {
  harness = await startHarness({ plane: { profiles: ["dev", "ux"], github: GITHUB } });
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  return harness;
}

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  castingTiming.firstTurnMs = 200;
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  history.replaceState(null, "", location.pathname);
  await harness?.stop();
  harness = null;
  await daemon.stop();
});

const screen = (): Promise<HTMLElement> => waitFor(() => document.querySelector<HTMLElement>("section.new-session"), "the new-session screen");
const ask = (s: HTMLElement): HTMLTextAreaElement => s.querySelector<HTMLTextAreaElement>("textarea#ns-ask")!;
const sentence = (s: ParentNode): string => s.querySelector(".ns-sentence")?.textContent?.replace(/[●▾]/g, "").replace(/\s+/g, " ").trim() ?? "";
const chip = (s: ParentNode, label: string): HTMLButtonElement | null => s.querySelector<HTMLButtonElement>(`button.ns-chip[aria-label^="${label}"]`);
const option = (s: ParentNode, label: string): HTMLButtonElement | undefined =>
  [...s.querySelectorAll<HTMLButtonElement>("button.ns-opt")].find((b) => b.querySelector(".ns-opt-label")?.textContent === label);
const typed = (s: ParentNode): HTMLInputElement => s.querySelector<HTMLInputElement>('input[aria-label="Repository, as owner/name@branch"]')!;
const entry = (title: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === title);
const panel = (): HTMLElement | null => document.querySelector<HTMLElement>('.backstage section[aria-label="Repositories"]');

function ctrlEnter(el: HTMLElement): void {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
}

async function openStart(): Promise<HTMLElement> {
  unmount = render(<App />).unmount;
  (await seesButton("Start a session")).click();
  return screen();
}

async function openSession(title: string, listed?: (row: HTMLLIElement) => void): Promise<HTMLElement> {
  unmount = render(<App />).unmount;
  const rowButton = await waitFor(() => entry(title)?.querySelector<HTMLButtonElement>("button.row"), `the row for ${title}`);
  listed?.(entry(title)!);
  rowButton.click();
  await waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
  await showBackstage();
  return waitFor(panel, "the repositories in the backstage");
}

describe("a new session on the platform", () => {
  it("is offered the team's repositories after a profile that allows GitHub, and none after one that does not", async () => {
    await signedIn();
    const s = await openStart();
    await waitFor(() => chip(s, "Which repositories"), "the repository chip");
    expect(sentence(s)).toBe("Runs on the platform with dev on no repository as build · everyone on core can open it");
    chip(s, "Which repositories")!.click();
    await waitFor(() => option(s, "example-org/widgets"), "the team's repositories");
    expect(option(s, "example-org/gadgets")).toBeDefined();
    await sees("Another of example-docs/, or a branch", s);
    await sees("A session here holds up to 3; 3 more may be added.", s);

    chip(s, "Which profile")!.click();
    (await waitFor(() => option(s, "ux"), "the profiles")).click();
    await waitFor(() => chip(s, "Which repositories") === null, "no repository on a profile without GitHub");
    expect(sentence(s)).toBe("Runs on the platform with ux as designer · everyone on core can open it");
  });

  it("sends the several chosen as repositories, the first at the root", async () => {
    const h = await signedIn();
    const s = await openStart();
    (await waitFor(() => chip(s, "Which repositories"), "the repository chip")).click();
    (await waitFor(() => option(s, "example-org/widgets"), "the team's repositories")).click();
    await waitFor(() => option(s, "example-org/widgets")!.getAttribute("aria-pressed") === "true", "widgets, chosen");
    option(s, "example-org/gadgets")!.click();
    await waitFor(() => option(s, "example-org/gadgets")!.getAttribute("aria-pressed") === "true", "gadgets, chosen");
    type(typed(s), "example-docs/site@v2");
    button("Add", s)!.click();
    await waitFor(() => sentence(s).includes("on example-org/widgets +2 more as"), "the three, in the sentence");
    expect(option(s, "example-org/widgets")!.getAttribute("aria-pressed")).toBe("true");
    await sees("That is as many as a session here holds (3).", s);

    type(ask(s), "Tidy the three");
    ctrlEnter(ask(s));
    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session, opened by itself");
    const made = [...h.plane.rows.values()].find((r) => r.title === "Tidy the three")!;
    expect(made.repositories.map((r) => [`${r.owner}/${r.name}`, r.ref, r.path])).toEqual([
      ["example-org/widgets", null, "."],
      ["example-org/gadgets", null, "example-org/gadgets"],
      ["example-docs/site", "v2", "example-docs/site"],
    ]);
  });

  it("shows the plane's sentence when it refuses one", async () => {
    await signedIn();
    const s = await openStart();
    (await waitFor(() => chip(s, "Which repositories"), "the repository chip")).click();
    await waitFor(() => typed(s), "the typed repository");
    type(typed(s), "other-org/secret");
    button("Add", s)!.click();
    type(ask(s), "Look around");
    ctrlEnter(ask(s));
    await waitFor(
      () => says("other-org/secret: the team core does not list other-org/secret among the GitHub repositories its sessions may name"),
      "the plane's refusal",
    );
  });
});

describe("a running session's repositories", () => {
  it("are listed for its owner, who attaches one from the team's list and takes it off again", async () => {
    const h = await signedIn();
    const row = h.plane.seed("alice@example.com", { title: "Fix the widgets" });
    row.repositories = [{ owner: "example-org", name: "widgets", ref: null, path: ".", attached_by: "alice@example.com", attached_at: "2026-11-26T09:00:00Z", github: null }];
    const p = await openSession("Fix the widgets");
    await waitFor(() => says("example-org/widgets", p) && says("at the workspace's root", p), "the one it was created on");
    // The one it was created on is taken off only beside another.
    expect(button("Take off", p)).toBeNull();

    button("Attach a repository", p)!.click();
    expect(option(p, "example-org/widgets")).toBeUndefined();
    (await waitFor(() => option(p, "example-org/gadgets"), "the team's other repository")).click();
    (await waitFor(() => (button("Attach", p)?.disabled === false ? button("Attach", p) : null), "Attach, with one chosen")).click();
    await waitFor(() => says("in example-org/gadgets/", panel()!), "the attached one, in its own directory");
    await waitFor(() => says("example-org/gadgets attached by"), "the transcript's line");
    expect(row.repositories.map((r) => r.name)).toEqual(["widgets", "gadgets"]);

    const takeOff = await waitFor(() => [...panel()!.querySelectorAll<HTMLButtonElement>("button")].filter((b) => b.textContent === "Take off"), "Take off");
    expect(takeOff).toHaveLength(2);
    takeOff[1]!.click();
    await waitFor(() => !says("example-org/gadgets", panel()!), "the one taken off, gone");
    expect(row.repositories.map((r) => r.name)).toEqual(["widgets"]);
  });

  it("say the plane's refusal when it will not attach one", async () => {
    const h = await signedIn();
    const row = h.plane.seed("alice@example.com", { title: "Fix the widgets" });
    row.repositories = [{ owner: "example-org", name: "widgets", ref: null, path: ".", attached_by: "alice@example.com", attached_at: "2026-11-26T09:00:00Z", github: null }];
    const p = await openSession("Fix the widgets");
    button("Attach a repository", p)!.click();
    type(await waitFor(() => p.querySelector<HTMLInputElement>('input[aria-label="Repository, as owner/name@branch"]'), "the typed repository"), "other-org/secret");
    button("Add", p)!.click();
    (await waitFor(() => (button("Attach", p)?.disabled === false ? button("Attach", p) : null), "Attach, with one chosen")).click();
    await waitFor(
      () => says("It was not attached: the team core does not list other-org/secret among the GitHub repositories its sessions may name", p),
      "the refusal",
    );
  });

  it("offer neither Attach nor Take off to somebody who is not its owner", async () => {
    const h = await signedIn();
    const row = h.plane.seed("bob@example.com", { title: "Bob's widgets" });
    row.repositories = [
      { owner: "example-org", name: "widgets", ref: null, path: ".", attached_by: "bob@example.com", attached_at: "2026-11-26T09:00:00Z", github: null },
      { owner: "example-org", name: "gadgets", ref: "main", path: "example-org/gadgets", attached_by: "bob@example.com", attached_at: "2026-11-26T09:05:00Z", github: null },
    ];
    // The list's row says the first and how many more.
    const p = await openSession("Bob's widgets", (listed) => expect(listed.textContent).toContain("example-org/widgets +1 more"));
    await waitFor(() => says("example-org/gadgets", p), "both repositories");
    await sees("in example-org/gadgets/, branch main", p);
    expect(button("Attach a repository", p)).toBeNull();
    expect(button("Take off", p)).toBeNull();
  });
});
