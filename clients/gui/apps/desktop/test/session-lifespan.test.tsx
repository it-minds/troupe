// troupe #1209: a session has a lifespan. The new-session screen offers Throwaway, Normal
// and Persistent beside "Only me, until I invite people" where the plane says it knows
// them, and nothing where it does not; the create sends the word. A throwaway session's row
// and head say when it goes, and its head offers Erase now and Keep it; the session's ⋯ and
// the row's ⋯ change it, to its owner alone, and the log's line follows. The app rendered,
// the fakes on real sockets.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { castingTiming } from "../src/views/StartSession";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, seesButton, startOnTheList, type, waitFor } from "./support";

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
const lifespans = (s: ParentNode): HTMLElement | null => s.querySelector<HTMLElement>('[role="radiogroup"][aria-label="How long it lasts"]');
const choice = (s: ParentNode, word: string): HTMLInputElement | null =>
  [...(lifespans(s)?.querySelectorAll<HTMLLabelElement>("label") ?? [])].find((l) => l.textContent === word)?.querySelector("input") ?? null;
const entry = (title: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === title);
const headMark = (): string | null | undefined => document.querySelector(".session-head .crumbs .tag.lasts")?.textContent;
const strip = (): HTMLElement | null => document.querySelector<HTMLElement>(".banner.throwaway");

function ctrlEnter(el: HTMLElement): void {
  el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
}

/** Type the message and start, once the profiles are read and Start may be pressed. */
async function startWith(s: HTMLElement, text: string): Promise<void> {
  type(ask(s), text);
  await waitFor(() => s.querySelector<HTMLButtonElement>("button.ns-start:not([disabled])")?.textContent === "Start", "Start, ready");
  ctrlEnter(ask(s));
  await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session, opened by itself");
}

async function openStart(): Promise<HTMLElement> {
  unmount = render(<App />).unmount;
  (await seesButton("Start a session")).click();
  return screen();
}

async function openSession(title: string): Promise<HTMLElement> {
  unmount = render(<App />).unmount;
  (await waitFor(() => entry(title)?.querySelector<HTMLButtonElement>("button.row"), `the row for ${title}`)).click();
  return waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
}

async function menu(): Promise<HTMLElement> {
  (await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="More session actions"]'), "the ⋯")).click();
  return waitFor(() => {
    const pop = document.querySelector<HTMLElement>(".session-menu .menu-pop");
    return pop && !pop.hidden && pop;
  }, "the ⋯ menu");
}

describe("the new-session screen", () => {
  it("offers how long it lasts beside only me, normal by default, and sends the word chosen", async () => {
    const h = await signedIn();
    const s = await openStart();
    await waitFor(() => lifespans(s), "the lifespan choice");
    expect([...lifespans(s)!.querySelectorAll("label")].map((l) => l.textContent)).toEqual(["Throwaway", "Normal", "Persistent"]);
    expect(choice(s, "Normal")!.checked).toBe(true);
    expect(lifespans(s)!.querySelector(".ns-who")?.textContent).toBe("Sleeps when idle and stays until you erase it.");

    choice(s, "Throwaway")!.click();
    await waitFor(() => lifespans(s)!.querySelector(".ns-who")?.textContent === "Erased a day after it goes quiet.", "the throwaway sentence");
    await startWith(s, "Which port does the gateway listen on?");
    expect(h.plane.createdLifespan).toEqual(["throwaway"]);
    expect([...h.plane.rows.values()].find((r) => r.title?.startsWith("Which port"))?.lifespan).toBe("throwaway");
  });

  it("sends nothing of it for a normal session", async () => {
    const h = await signedIn();
    const s = await openStart();
    await waitFor(() => lifespans(s), "the lifespan choice");
    await startWith(s, "Tidy the ledger");
    expect(h.plane.createdLifespan).toEqual([null]);
  });

  it("offers no choice on a plane that does not know lifespans", async () => {
    const h = await signedIn({ beforeLifespans: true });
    const s = await openStart();
    await waitFor(() => s.querySelector(".ns-only-me label"), "the only-me tick");
    expect(lifespans(s)).toBeNull();
    await startWith(s, "Tidy the ledger");
    expect(h.plane.createdLifespan).toEqual([null]);
  });
});

describe("a throwaway session", () => {
  it("says when it goes in a line under the head, and Keep it makes it normal", async () => {
    const h = await signedIn();
    const quick = h.plane.seed("alice@example.com", { title: "Which port?", lifespan: "throwaway" });
    await openSession("Which port?");
    await waitFor(() => strip()?.textContent?.includes("This session is throwaway: it is erased in"), "the throwaway line");
    expect(headMark()).toBeUndefined();

    (await seesButton("Keep it", strip()!)).click();
    await waitFor(() => quick.lifespan === "normal", "the plane told");
    await waitFor(() => !strip(), "the line gone");
    await waitFor(() => says("This session is normal now: it stays until its owner erases it"), "the log's line");
  });

  it("is erased by Erase now, asked once more, and leaves the list", async () => {
    const h = await signedIn();
    const quick = h.plane.seed("alice@example.com", { title: "Which port?", lifespan: "throwaway" });
    await openSession("Which port?");
    (await waitFor(() => strip() && button("Erase now", strip()!), "Erase now")).click();
    await waitFor(() => strip()?.textContent?.includes("cannot be undone"), "the question");
    expect(h.plane.erased).toEqual([]);
    button("Erase it", strip()!)!.click();
    await waitFor(() => h.plane.erased.includes(quick.id), "the plane told to erase it");
    await waitFor(() => document.querySelector(".toolbar input.search") && !entry("Which port?"), "back on the list, without it");
  });

  it("is marked in the list with when it goes, and a persistent one by its word", async () => {
    const h = await signedIn();
    h.plane.seed("alice@example.com", { title: "Which port?", lifespan: "throwaway" });
    h.plane.seed("alice@example.com", { title: "Quarterly report", lifespan: "persistent" });
    h.plane.seed("alice@example.com", { title: "Usual" });
    unmount = render(<App />).unmount;
    await waitFor(() => entry("Which port?") && entry("Quarterly report") && entry("Usual"), "the rows");
    await waitFor(() => entry("Which port?")!.querySelector(".lasts")?.textContent?.startsWith("throwaway · goes in"), "the throwaway mark");
    expect(entry("Quarterly report")!.querySelector(".lasts")?.textContent).toBe("persistent");
    expect(entry("Usual")!.querySelector(".lasts")).toBeNull();
  });
});

describe("changing how long it lasts", () => {
  it("is the owner's from the session's ⋯, the head following", async () => {
    const h = await signedIn();
    const report = h.plane.seed("alice@example.com", { title: "Quarterly report" });
    await openSession("Quarterly report");
    const pop = await menu();
    await waitFor(() => button("Make it persistent", pop), "the ⋯'s items");
    expect(button("Make it normal", pop)).toBeNull();
    await waitFor(() => button("Make it throwaway", pop)?.textContent?.includes("Erased a day after it goes quiet"), "what throwaway means");
    button("Make it persistent", pop)!.click();
    await waitFor(() => report.lifespan === "persistent", "the plane told");
    await waitFor(() => headMark() === "persistent", "the head's mark");
    await waitFor(() => says("This session is persistent now: it is kept until its owner erases it"), "the log's line");
  });

  it("is the owner's from the row's ⋯", async () => {
    const h = await signedIn();
    const report = h.plane.seed("alice@example.com", { title: "Quarterly report" });
    unmount = render(<App />).unmount;
    const row = await waitFor(() => entry("Quarterly report"), "the row");
    (await waitFor(() => row.querySelector<HTMLButtonElement>('button[aria-label="More actions for Quarterly report"]'), "the row's ⋯")).click();
    (await seesButton("Make it throwaway", row)).click();
    await waitFor(() => report.lifespan === "throwaway", "the plane told");
    await waitFor(() => entry("Quarterly report")!.querySelector(".lasts")?.textContent?.startsWith("throwaway"), "the row's mark");
  });

  it("is offered to nobody but the owner, who alone sees Erase now and Keep it", async () => {
    const h = await signedIn();
    h.plane.seed("bob@example.com", { title: "Bob's question", lifespan: "throwaway" });
    await openSession("Bob's question");
    await waitFor(() => strip(), "the throwaway line");
    expect(button("Erase now", strip()!)).toBeNull();
    expect(button("Keep it", strip()!)).toBeNull();
    const pop = await menu();
    expect(button("Make it normal", pop)).toBeNull();
    expect(button("Make it persistent", pop)).toBeNull();
  });

  it("is not offered where the plane does not know lifespans", async () => {
    const h = await signedIn({ beforeLifespans: true });
    h.plane.seed("alice@example.com", { title: "Quarterly report" });
    await openSession("Quarterly report");
    const pop = await menu();
    await waitFor(() => button("Keep at the top", pop), "the ⋯'s items");
    expect(button("Make it persistent", pop)).toBeNull();
    expect(button("Make it throwaway", pop)).toBeNull();
  });
});
