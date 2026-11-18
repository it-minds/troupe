// Archiving a session (troupe #1005): its owner hides it from the session list, for
// everyone who sees it, and it is kept whole. The list's Archived filter lists the archived
// ones, from the plane and the daemon both, each with Unarchive for its owner; an archived
// one still opens; and the session's ⋯ and the palette's /archive and /unarchive do it from
// the session. The app rendered, the fakes on real sockets.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, sees, seesButton, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let unmount: (() => void) | null = null;

/** The list's entry for a title or a workspace: its row and anything beside it. */
const entry = (text: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === text);
const titles = (): string[] => [...document.querySelectorAll(".rows .title")].map((t) => t.textContent ?? "");
const archivedFilter = (): HTMLSelectElement | null => document.querySelector<HTMLSelectElement>('select[aria-label="Archived"]');
const palette = (): HTMLElement | null => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Commands"]');

function choose(select: HTMLSelectElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(select, value);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function key(target: EventTarget, key: string): void {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
}

/** Open the session whose row says `text`, from the list. */
// Its own open, not support's: a row of the list already drawn, by its entry, answering the head.
async function open(text: string): Promise<HTMLElement> {
  (await waitFor(() => entry(text)?.querySelector<HTMLButtonElement>("button.row"), `the row for ${text}`)).click();
  return waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
}

/** The head's ⋯, open. */
async function menu(): Promise<HTMLElement> {
  (await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="More session actions"]'), "the ⋯")).click();
  return waitFor(() => {
    const pop = document.querySelector<HTMLElement>(".menu-pop");
    return pop && !pop.hidden && pop;
  }, "the ⋯ menu");
}

/** Run a command from the palette, typed as a person types it. */
async function run(command: string): Promise<void> {
  const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the composer");
  key(composer, "/");
  const dialog = await waitFor(palette, "the palette");
  await waitFor(() => dialog.querySelector(".palette .row"), "the palette's rows");
  const input = dialog.querySelector<HTMLInputElement>("input")!;
  type(input, command);
  await waitFor(() => document.querySelector('.palette .row[aria-selected="true"] .name')?.textContent === `/${command}`, `the cursor on /${command}`);
  key(input, "Enter");
}

const onTheList = (): boolean => Boolean(document.querySelector(".toolbar input.search"));

describe("archiving a session on this computer", () => {
  let daemon: FakeDaemon;

  beforeEach(async () => {
    localStorage.clear();
    localStorage.setItem("troupe.pref.localOnly", "yes");
    startOnTheList();
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  });

  afterEach(async () => {
    unmount?.();
    unmount = null;
    location.hash = "";
    await daemon.stop();
  });

  it("archives from the ⋯, back to a list without it, and lists it under Archived until it is unarchived", async () => {
    const notes = daemon.seed("/home/ada/notes");
    daemon.seed("/home/ada/plans");

    unmount = render(<App />).unmount;
    await open("/home/ada/notes");
    const pop = await menu();
    expect(pop.textContent).toContain("Hide it from the session list, for everyone who sees it");
    (await seesButton("Archive session", pop)).click();

    await waitFor(() => daemon.calls.some((c) => c.method === "session.archive" && c.params["session_id"] === notes.id), "the archive sent to the daemon");
    await waitFor(onTheList, "the session list");
    await waitFor(() => titles().join(",") === "/home/ada/plans", "the list without the archived session");

    choose(await waitFor(archivedFilter, "the Archived filter"), "archived");
    await waitFor(() => titles().join(",") === "/home/ada/notes", "the archived session under Archived");
    const unarchive = await seesButton("Unarchive", entry("/home/ada/notes")!);
    unarchive.click();

    await waitFor(() => daemon.calls.some((c) => c.method === "session.unarchive" && c.params["session_id"] === notes.id), "the unarchive sent to the daemon");
    await sees("Nothing archived");
    choose(archivedFilter()!, "");
    await waitFor(() => titles().sort().join(",") === "/home/ada/notes,/home/ada/plans", "the session back in the list");
  });

  it("opens an archived session from Archived, says so, and unarchives it from the ⋯", async () => {
    const notes = daemon.seed("/home/ada/notes");
    unmount = render(<App />).unmount;
    await open("/home/ada/notes");
    (await seesButton("Archive session", await menu())).click();
    await waitFor(onTheList, "the session list");

    choose(await waitFor(archivedFilter, "the Archived filter"), "archived");
    await open("/home/ada/notes");
    await sees("This session is archived: it is kept whole, and not in the session list.");
    // At once: the ⋯ was drawn with the session, and an archived one offers the other.
    const pop = await menu();
    expect(button("Archive session", pop)).toBeNull();
    (await seesButton("Unarchive session", pop)).click();

    await waitFor(() => daemon.calls.some((c) => c.method === "session.unarchive" && c.params["session_id"] === notes.id), "the unarchive sent to the daemon");
    await waitFor(() => !says("This session is archived"), "the archived line gone");
    // Still on the session, which is in the list again.
    expect(document.querySelector(".session-head")).not.toBeNull(); // at once: the waitFor above saw the session redrawn
    await seesButton("Archive session", await menu());
  });

  it("archives with /archive from the palette, and /unarchive on one that is not archived says so", async () => {
    const notes = daemon.seed("/home/ada/notes");
    unmount = render(<App />).unmount;
    await open("/home/ada/notes");

    await run("unarchive");
    await waitFor(() => document.querySelector(".palette .notice")?.textContent === "this session is not archived", "the palette's notice");
    expect(daemon.calls.some((c) => c.method === "session.unarchive")).toBe(false);
    key(document.querySelector<HTMLInputElement>(".palette input")!, "Escape");
    await waitFor(() => palette() === null, "the palette to close");

    await run("archive");
    await waitFor(() => daemon.calls.some((c) => c.method === "session.archive" && c.params["session_id"] === notes.id), "the archive sent to the daemon");
    await waitFor(onTheList, "the session list");
    await sees("No sessions yet");
  });
});

describe("archiving a team session", () => {
  let harness: Harness;

  beforeEach(async () => {
    localStorage.clear();
    startOnTheList();
    harness = await startHarness();
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  });

  afterEach(async () => {
    unmount?.();
    unmount = null;
    location.hash = "";
    delete window.troupe;
    await harness.stop();
  });

  async function signIn(): Promise<void> {
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
    await waitFor(() => document.querySelector(".usercode"), "the code to enter");
    harness.idp.approve("ada@example.com", "Ada");
    await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
    button("Continue")!.click();
    await waitFor(onTheList, "the session list");
  }

  it("is archived by its owner for everyone, put to sleep, and listed under Archived from the plane", async () => {
    const audit = harness.plane.seed("ada@example.com", { title: "Weekly licence audit" });
    harness.plane.seed("ada@example.com", { title: "Nightly dependency sweep" });
    await signIn();

    await open("Weekly licence audit");
    (await seesButton("Archive session", await menu())).click();
    await waitFor(onTheList, "the session list");
    await waitFor(() => titles().join(",") === "Nightly dependency sweep", "the list without the archived session");
    // Asleep, and out of the plane's default list for anybody who asks it.
    expect(audit.archived).toBe(true);
    expect(audit.state).toBe("dormant");

    choose(await waitFor(archivedFilter, "the Archived filter"), "archived");
    await waitFor(() => titles().join(",") === "Weekly licence audit", "the archived session under Archived");
    (await seesButton("Unarchive", entry("Weekly licence audit")!)).click();
    await sees("Nothing archived");
    expect(audit.archived).toBe(false);
  });

  it("offers no archive to somebody who is not its owner, and says a refusal in words", async () => {
    harness.plane.seed("bob@example.com", { title: "Bob's migration" });
    await signIn();

    await open("Bob's migration");
    const pop = await menu();
    await sees("you are a collaborator");
    expect(button("Archive session", pop)).toBeNull();
    key(document, "Escape");

    // The palette lists /archive for everyone; the plane refuses anybody but the owner.
    await run("archive");
    await waitFor(() => document.querySelector(".palette .notice")?.textContent === "Only its owner can archive this session", "the refusal in the palette");
    await sees("It was not archived. Only its owner can archive this session.");
    expect(document.querySelector(".session-head")).not.toBeNull(); // at once: a refusal leaves the person where they were
  });
});
