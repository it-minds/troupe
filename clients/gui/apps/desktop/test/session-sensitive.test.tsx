// troupe #1239: a sensitive session. Its row and its head are marked `sensitive`, with since
// when and by what in the title, and under the head a line says it; the ⋯ offers its owner
// Make it sensitive, asked once more since nothing clears it, and nobody else; the new-session
// screen has a Sensitive switch; the transcript draws the mark's line and a refused call as
// a refusal; giving it to the team or inviting somebody says the profile's refusal in place,
// or under `ask` that it waits on a team administrator. A plane that does not know sensitive
// sessions shows none of it. The app rendered, the fakes on real sockets.

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

const ME = "alice@example.com";
let harness: Harness | null = null;
let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

type PlaneOpts = NonNullable<NonNullable<Parameters<typeof startHarness>[0]>["plane"]>;

async function signedIn(plane: PlaneOpts = {}): Promise<Harness> {
  harness = await startHarness({ plane: { profiles: ["dev"], ...plane } });
  harness.plane.people = [{ subject: "bea@example.com", display_name: "Bea", email: "bea@example.com" }];
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem(`troupe.pref.appearance.chosen.${ME}`, "yes");
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

const BY_CALL = { at: "2026-11-28T10:14:00Z", by: "mcp.records.lookup", how: "call" as const };
const entry = (title: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === title);
const headTag = (): HTMLElement | null => document.querySelector<HTMLElement>(".session-head .crumbs .tag.sensitive");
const banner = (): HTMLElement | null => document.querySelector<HTMLElement>(".banner.sensitive");
const confirm = (): HTMLElement | null => document.querySelector<HTMLElement>('[role="alertdialog"][aria-label="Make it sensitive"]');

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

describe("a sensitive session's marks", () => {
  it("is marked in the list beside its other marks, with since when and by what, and an unmarked one is not", async () => {
    const h = await signedIn();
    h.plane.seed(ME, { title: "Ann's record", sensitive: BY_CALL });
    h.plane.seed(ME, { title: "Usual" });
    unmount = render(<App />).unmount;
    const mark = await waitFor(() => entry("Ann's record")?.querySelector<HTMLElement>(".meta .sensitive"), "the row's mark");
    expect(mark.textContent).toBe("sensitive");
    expect(mark.title).toMatch(/^Sensitive since \d\d:\d\d: mcp\.records\.lookup read from it; nothing clears it$/);
    await waitFor(() => entry("Usual"), "the other row");
    expect(entry("Usual")!.querySelector(".sensitive")).toBeNull();
  });

  it("is a tag in the head with a line under it, and the transcript says when it became so", async () => {
    const h = await signedIn();
    h.plane.seed(ME, { title: "Ann's record", sensitive: BY_CALL });
    await openSession("Ann's record");
    await waitFor(() => headTag()?.textContent === "sensitive", "the head's tag");
    // A tag the head cuts ends in an ellipsis, so its title carries its whole word (troupe #1231).
    expect(document.querySelector(".session-head .crumbs .tag[title^='dev: ']")).not.toBeNull();
    await waitFor(() => banner()?.textContent?.includes("mcp.records.lookup read from it. Nothing clears it"), "the line under the head");
    await waitFor(() => says("This session became sensitive at"), "the transcript's line");
    expect(document.querySelector(".note.sensitive")?.textContent).toMatch(/mcp\.records\.lookup read from it\. Nothing clears it; the profile's rules refuse/);
    expect(banner()?.textContent).toContain("Nothing clears it: the profile's rules refuse");
  });

  it("draws a call its rule refused as a refusal with the harness's sentence, not as a failure", async () => {
    const h = await signedIn();
    const row = h.plane.seed(ME, { title: "Ann's record", sensitive: BY_CALL });
    await openSession("Ann's record");
    await waitFor(() => headTag(), "the head's tag");
    const log = h.worker.sessions.get(row.id)!.log;
    log.append("tool_call_started", { call_id: "call_9", name: "publish_artifact", args: { title: "Ann" } });
    const sentence = "This session is sensitive since mcp.records.lookup read from it at 10:14 UTC: publish_artifact is refused in a sensitive session by the profile dev (deny publish_artifact). It did not run.";
    log.append("tool_call_completed", { call_id: "call_9", name: "publish_artifact", ok: false, refused: "sensitive", content: sentence });
    const frame = await waitFor(() => document.querySelector<HTMLElement>(".tool-frame.refused"), "the refused call");
    expect(frame.querySelector("summary")?.textContent).toContain("refused: the session is sensitive");
    expect(frame.textContent).toContain(sentence);
    expect(document.querySelector(".tool-frame.failed")).toBeNull();
  });

  it("shows nothing new where the plane does not know sensitive sessions", async () => {
    const h = await signedIn({ beforeSensitive: true });
    h.plane.seed(ME, { title: "Ann's record" });
    await openSession("Ann's record");
    const pop = await menu();
    await waitFor(() => button("Keep at the top", pop), "the ⋯'s items");
    expect(button("Make it sensitive", pop)).toBeNull();
    expect(headTag()).toBeNull();
    expect(banner()).toBeNull();
  });
});

describe("making it sensitive", () => {
  it("is its owner's from the ⋯, asked once more, then the plane told and the item gone", async () => {
    const h = await signedIn();
    const report = h.plane.seed(ME, { title: "Quarterly report" });
    await openSession("Quarterly report");
    let pop = await menu();
    const item = await waitFor(() => button("Make it sensitive", pop), "the ⋯'s item");
    expect(item.textContent).toContain("One-way: nothing clears it");
    item.click();
    const sheet = await waitFor(confirm, "the confirm sheet");
    expect(sheet.textContent).toContain("Nothing clears it");
    expect(report.sensitive).toBeNull();
    button("Cancel", sheet)!.click();
    await waitFor(() => !confirm(), "the sheet shut");
    expect(report.sensitive).toBeNull();

    pop = await menu();
    button("Make it sensitive", pop)!.click();
    button("Make it sensitive", (await waitFor(confirm, "the confirm sheet")))!.click();
    await waitFor(() => report.sensitive?.how === "person", "the plane told");
    await waitFor(() => headTag()?.textContent === "sensitive", "the head's tag");
    await waitFor(() => banner()?.textContent?.includes("marked by you"), "the line under the head");
    pop = await menu();
    await waitFor(() => button("Keep at the top", pop), "the ⋯'s items");
    expect(button("Make it sensitive", pop)).toBeNull();
  });

  it("is offered to nobody but the owner", async () => {
    const h = await signedIn();
    h.plane.seed("bob@example.com", { title: "Bob's question" });
    await openSession("Bob's question");
    const pop = await menu();
    await waitFor(() => pop.querySelector(".menu-facts"), "the ⋯'s facts");
    expect(button("Make it sensitive", pop)).toBeNull();
  });
});

describe("the new-session screen", () => {
  const screen = (): Promise<HTMLElement> => waitFor(() => document.querySelector<HTMLElement>("section.new-session"), "the new-session screen");
  const switchOf = (s: ParentNode): HTMLInputElement | null => s.querySelector<HTMLInputElement>(".ns-sensitive input[type=checkbox]");

  async function start(s: HTMLElement, text: string): Promise<void> {
    type(s.querySelector<HTMLTextAreaElement>("textarea#ns-ask")!, text);
    await waitFor(() => s.querySelector<HTMLButtonElement>("button.ns-start:not([disabled])")?.textContent === "Start", "Start, ready");
    s.querySelector<HTMLTextAreaElement>("textarea#ns-ask")!.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }));
    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session, opened by itself");
  }

  it("has a Sensitive switch, off by default, and sends it on", async () => {
    const h = await signedIn();
    unmount = render(<App />).unmount;
    (await seesButton("Start a session")).click();
    const s = await screen();
    const on = await waitFor(() => switchOf(s), "the Sensitive switch");
    expect(on.checked).toBe(false);
    expect(on.parentElement?.textContent).toBe("Sensitive");
    on.click();
    await waitFor(() => s.querySelector(".ns-sensitive .ns-who")?.textContent === "Sensitive from its start: nothing clears it.", "what it means");
    await start(s, "Look Ann up");
    expect(h.plane.createdSensitive).toEqual([true]);
    await waitFor(() => headTag(), "the head's tag");
  });

  it("is not there where the plane does not know sensitive sessions", async () => {
    const h = await signedIn({ beforeSensitive: true });
    unmount = render(<App />).unmount;
    (await seesButton("Start a session")).click();
    const s = await screen();
    await waitFor(() => s.querySelector(".ns-only-me label"), "the only-me tick");
    expect(switchOf(s)).toBeNull();
    await start(s, "Tidy the ledger");
    expect(h.plane.createdSensitive).toEqual([false]);
  });
});

describe("sharing a sensitive session", () => {
  it("says the profile's refusal in place where it denies giving it to the team", async () => {
    const h = await signedIn({ sensitiveSharing: "deny" });
    const row = h.plane.seed(ME, { title: "Ann's record", visibility: "private", sensitive: BY_CALL });
    await openSession("Ann's record");
    const pop = await menu();
    (await waitFor(() => [...pop.querySelectorAll<HTMLButtonElement>("button.item")].find((b) => b.textContent?.startsWith("Give it to")), "Give it to the team")).click();
    await waitFor(
      () => document.querySelector(".banner.error")?.textContent === "This session is sensitive and dev does not allow sharing it outside the people who already read it.",
      "the refusal in place",
    );
    expect(row.visibility).toBe("private");
  });

  it("says it waits on a team administrator where the profile asks, and nothing changes yet", async () => {
    const h = await signedIn({ sensitiveSharing: "ask" });
    const row = h.plane.seed(ME, { title: "Ann's record", visibility: "private", sensitive: BY_CALL });
    await openSession("Ann's record");
    const pop = await menu();
    (await waitFor(() => [...pop.querySelectorAll<HTMLButtonElement>("button.item")].find((b) => b.textContent?.startsWith("Give it to")), "Give it to the team")).click();
    await waitFor(() => [...document.querySelectorAll(".banner.sensitive")].some((b) => b.textContent?.includes("waiting on a team administrator") && b.textContent.includes("(it waits)")), "the waiting sentence");
    expect(row.visibility).toBe("private");
    expect(h.plane.shareRequests.map((r) => [r.kind, r.state])).toEqual([["visibility", "pending"]]);
  });

  it("an invitation waits on a team administrator too, and nobody is invited yet", async () => {
    const h = await signedIn({ sensitiveSharing: "ask" });
    const row = h.plane.seed(ME, { title: "Ann's record", visibility: "private", sensitive: BY_CALL });
    await openSession("Ann's record");
    const group = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Shared with"]'), "the invitations");
    (await waitFor(() => button("Invite", group), "Invite")).click();
    const box = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Invite somebody"]'), "the dialog");
    type(box.querySelector<HTMLInputElement>(".invite-form input")!, "Be");
    (await waitFor(() => [...box.querySelectorAll<HTMLButtonElement>(".people button")].find((b) => b.textContent?.startsWith("Bea")), "Bea")).click();
    (await waitFor(() => box.querySelector<HTMLButtonElement>('.invite-form button[type="submit"]:not([disabled])'), "the form's Invite")).click();
    await waitFor(() => [...document.querySelectorAll(".banner.sensitive")].some((b) => b.textContent?.includes("waiting on a team administrator")), "the waiting sentence");
    expect(h.plane.invitations.get(row.id)?.get("bea@example.com")).toBeUndefined();
    expect(h.plane.shareRequests.map((r) => r.kind)).toEqual(["invite"]);
  });
});
