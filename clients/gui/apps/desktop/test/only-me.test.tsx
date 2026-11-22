// troupe #1168: a session on a team's profile may start as its owner's alone and be shared
// later. On the platform path the tick is off by default, the line under it says who can
// open the session either way, the create sends the visibility, and the list and the head
// mark such a session "only you". Against the fake deployment and the fake daemon.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { castingTiming } from "../src/views/StartSession";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { hereIn, render, seesButton, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let harness: Harness | null = null;
let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

type PlaneOpts = NonNullable<NonNullable<Parameters<typeof startHarness>[0]>["plane"]>;

async function signedIn(plane: PlaneOpts = {}): Promise<Harness> {
  harness = await startHarness({ plane: { profiles: ["dev"], ...plane } });
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
const tick = (s: ParentNode): HTMLInputElement | null =>
  [...s.querySelectorAll<HTMLLabelElement>(".ns-only-me label")].find((l) => l.textContent === "Only me, until I invite people")?.querySelector("input") ?? null;
const who = (s: ParentNode): string => s.querySelector(".ns-who")?.textContent ?? "";
const entry = (title: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === title);
const marks = (el: Element | null | undefined): string[] => [...(el?.querySelectorAll(".pill") ?? [])].map((p) => p.textContent ?? "");

function ctrlEnter(el: HTMLElement): void {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
}

async function openStart(): Promise<HTMLElement> {
  unmount = render(<App />).unmount;
  (await seesButton("Start a session")).click();
  return screen();
}

async function startWith(s: HTMLElement, text: string): Promise<void> {
  type(ask(s), text);
  ctrlEnter(ask(s));
  await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session, opened by itself");
}

describe("only me, until I invite people", () => {
  it("sends the team's visibility unticked, and says everyone on the team can open it", async () => {
    const h = await signedIn();
    const s = await openStart();
    await waitFor(() => tick(s), "the tick");
    expect(tick(s)!.checked).toBe(false);
    expect(sentence(s)).toBe("Runs on the platform with dev as build · everyone on core can open it");
    expect(who(s)).toBe("Everyone on core can open it.");
    await startWith(s, "Tidy the ledger");
    expect(h.plane.createdVisibility).toEqual(["team"]);
  });

  it("sends private ticked, on the same profile, and says only you can open it until you invite people", async () => {
    const h = await signedIn();
    const s = await openStart();
    (await waitFor(() => tick(s), "the tick")).click();
    await waitFor(() => tick(s)!.checked, "the tick, ticked");
    expect(sentence(s)).toBe("Runs on the platform with dev as build · only you can open it until you invite people");
    expect(who(s)).toBe("Only you can open it until you invite people; administrators oversee it as any session.");
    await startWith(s, "Draft the memo");
    expect(h.plane.createdVisibility).toEqual(["private"]);
    const made = [...h.plane.rows.values()].find((r) => r.title === "Draft the memo");
    expect(made).toMatchObject({ profile: "dev", visibility: "private" });
  });

  it("keeps the team chip where it is a choice, since its budget is still a team's", async () => {
    await signedIn({ teams: ["core", "design"] });
    const s = await openStart();
    (await waitFor(() => tick(s), "the tick")).click();
    await waitFor(() => tick(s)!.checked, "the tick, ticked");
    expect(sentence(s)).toBe("Runs on the platform with dev as build · for which team? · only you can open it until you invite people");
    expect(who(s)).toBe("Only you can open it until you invite people; administrators oversee it as any session.");
  });

  it("is not on the screen for a session on this computer, whose own words stay", async () => {
    await signedIn();
    const s = await openStart();
    (await waitFor(() => tick(s), "the tick")).click();
    await hereIn(s, "/home/alice/project");
    await waitFor(() => tick(s) === null, "the tick, gone");
    await waitFor(() => sentence(s).startsWith("Runs on this computer"), "the local sentence");
    expect(sentence(s)).toMatch(/· only you can open it$/);
  });

  it("marks a pod session of the person's own that the team cannot open, in the list and the head, and no other", async () => {
    const h = await signedIn();
    h.plane.seed("alice@example.com", { title: "Mine alone", visibility: "private" });
    h.plane.seed("alice@example.com", { title: "The team's" });
    h.plane.seed("bob@example.com", { title: "Bob's alone", visibility: "private" });
    unmount = render(<App />).unmount;
    await waitFor(() => entry("Mine alone") && entry("The team's"), "the sessions, listed");
    // In the place of "Team", which would say everyone on it can open it.
    expect(marks(entry("Mine alone"))).toContain("only you");
    expect(marks(entry("Mine alone"))).not.toContain("Team");
    expect(marks(entry("The team's"))).toContain("Team");
    expect(marks(entry("The team's"))).not.toContain("only you");
    expect(entry("Bob's alone")).toBeUndefined();

    entry("Mine alone")!.querySelector<HTMLButtonElement>("button.row")!.click();
    await waitFor(() => marks(document.querySelector(".session-head .crumbs")).includes("only you"), "the mark on the session's head");
  });
});
