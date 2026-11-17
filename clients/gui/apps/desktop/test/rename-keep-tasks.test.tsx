// Renaming a session, keeping it at the top of the list and changing its task list
// (troupe #1032). The owner renames a session and keeps it at the top from its row's ⋯ in
// the list, from the session's ⋯ and from the palette (/rename, /keep); the head and the
// list show the new name at once, since neither the daemon nor the plane pushes it; a kept
// session is listed first with its mark. The Tasks pane completes, cancels and adds a task
// with `todo.edit`. The app rendered, the fakes on real sockets.

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

const entry = (text: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === text);
const titles = (): string[] => [...document.querySelectorAll(".rows .title")].map((t) => t.textContent ?? "");
const palette = (): HTMLElement | null => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Commands"]');
const headTitle = (): string | null | undefined => document.querySelector(".session-head h1.title")?.textContent;
const nameField = (): HTMLInputElement | null => document.querySelector<HTMLInputElement>('input[aria-label="Session name"]');
const onTheList = (): boolean => Boolean(document.querySelector(".toolbar input.search"));

function key(target: EventTarget, key: string): void {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
}

async function open(text: string): Promise<HTMLElement> {
  (await waitFor(() => entry(text)?.querySelector<HTMLButtonElement>("button.row"), `the row for ${text}`)).click();
  return waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
}

/** A row's ⋯ in the list, open. */
async function rowMenu(text: string): Promise<HTMLElement> {
  (await waitFor(() => entry(text)?.querySelector<HTMLButtonElement>(".row-menu button.ib"), `the ⋯ beside ${text}`)).click();
  return waitFor(() => {
    const pop = entry(text)?.querySelector<HTMLElement>(".row-menu .menu-pop");
    return pop && !pop.hidden && pop;
  }, `the menu beside ${text}`);
}

/** The head's ⋯, open. */
async function menu(): Promise<HTMLElement> {
  (await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="More session actions"]'), "the ⋯")).click();
  return waitFor(() => {
    const pop = document.querySelector<HTMLElement>(".session-menu .menu-pop");
    return pop && !pop.hidden && pop;
  }, "the ⋯ menu");
}

async function run(command: string): Promise<void> {
  const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the composer");
  key(composer, "/");
  const dialog = await waitFor(palette, "the palette");
  await waitFor(() => dialog.querySelector(".palette .row"), "the palette's rows");
  const input = dialog.querySelector<HTMLInputElement>("input")!;
  type(input, command);
  const name = command.split(" ")[0];
  await waitFor(() => document.querySelector('.palette .row[aria-selected="true"] .name')?.textContent === `/${name}`, `the cursor on /${name}`);
  key(input, "Enter");
}

/** Type a name into the field and press Enter, or Escape. */
async function rename(name: string, end: "Enter" | "Escape" = "Enter"): Promise<void> {
  const field = await waitFor(nameField, "the name as a field");
  type(field, name);
  key(field, end);
}

describe("a session on this computer", () => {
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

  it("is renamed from its row's ⋯, Enter sending the name and Esc leaving it", async () => {
    const notes = daemon.seed("/home/ada/notes");
    unmount = render(<App />).unmount;

    (await seesButton("Rename", await rowMenu("/home/ada/notes"))).click();
    await rename("Ledger notes", "Escape");
    await waitFor(() => nameField() === null, "the field gone");
    expect(daemon.calls.some((c) => c.method === "session.title.set")).toBe(false);
    expect(titles()).toEqual(["/home/ada/notes"]);

    (await seesButton("Rename", await rowMenu("/home/ada/notes"))).click();
    await rename("Ledger notes");
    await waitFor(() => titles().join(",") === "Ledger notes", "the row under its new name");
    expect(daemon.calls.find((c) => c.method === "session.title.set")?.params).toMatchObject({ session_id: notes.id, title: "Ledger notes" });
  });

  it("is kept at the top from its row's ⋯, listed first with its mark, and let go again", async () => {
    const notes = daemon.seed("/home/ada/notes");
    daemon.seed("/home/ada/plans");
    notes.lastActiveAt = new Date(Date.now() - 3_600_000).toISOString();
    unmount = render(<App />).unmount;
    await waitFor(() => titles().join(",") === "/home/ada/plans,/home/ada/notes", "the newest first");

    (await seesButton("Keep at the top", await rowMenu("/home/ada/notes"))).click();
    await waitFor(() => titles().join(",") === "/home/ada/notes,/home/ada/plans", "the kept one first");
    expect(entry("/home/ada/notes")!.querySelector(".kept")?.textContent).toBe("Kept");
    expect(daemon.calls.some((c) => c.method === "session.pin" && c.params["session_id"] === notes.id)).toBe(true);

    (await seesButton("Let go from the top", await rowMenu("/home/ada/notes"))).click();
    await waitFor(() => titles().join(",") === "/home/ada/plans,/home/ada/notes", "back by when it was active");
    expect(entry("/home/ada/notes")!.querySelector(".kept")).toBeNull();
    expect(daemon.calls.some((c) => c.method === "session.unpin" && c.params["session_id"] === notes.id)).toBe(true);
  });

  it("is renamed with /rename, the head showing the name at once, and with /rename alone in the head's field", async () => {
    const notes = daemon.seed("/home/ada/notes");
    unmount = render(<App />).unmount;
    await open("/home/ada/notes");

    await run("rename Ledger notes");
    await waitFor(() => headTitle() === "Ledger notes", "the head under its new name");
    expect(daemon.calls.find((c) => c.method === "session.title.set")?.params).toMatchObject({ session_id: notes.id, title: "Ledger notes" });

    await run("rename");
    await waitFor(() => palette() === null, "the palette closed");
    await rename("Ledger move");
    await waitFor(() => headTitle() === "Ledger move", "the head under the name typed");

    // An empty name takes it off: a session on this computer is called by where it works.
    (await seesButton("Rename session", await menu())).click();
    await rename("");
    await waitFor(() => headTitle() === "/home/ada/notes", "the head under its workspace");
    expect(daemon.calls.filter((c) => c.method === "session.title.set").map((c) => c.params["title"])).toEqual(["Ledger notes", "Ledger move", ""]);
  });

  it("is kept at the top with /keep and the session's ⋯, and let go with /keep off", async () => {
    const notes = daemon.seed("/home/ada/notes");
    unmount = render(<App />).unmount;
    await open("/home/ada/notes");

    await run("keep");
    await waitFor(() => daemon.calls.some((c) => c.method === "session.pin" && c.params["session_id"] === notes.id), "the pin sent");
    await waitFor(() => document.querySelector(".palette .notice")?.textContent === "kept at the top of the session list", "the palette's notice");
    key(document.querySelector<HTMLInputElement>(".palette input")!, "Escape");
    await waitFor(() => palette() === null, "the palette to close");

    (await seesButton("Let go from the top", await menu())).click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.unpin"), "the unpin sent");
    await seesButton("Keep at the top", await menu());
    key(document, "Escape");

    await run("keep off");
    await waitFor(() => document.querySelector(".palette .notice")?.textContent === "this session is not kept at the top", "the palette's notice");
    expect(daemon.calls.filter((c) => c.method === "session.unpin")).toHaveLength(1);
  });

  it("completes, cancels and adds a task from the Tasks pane", async () => {
    const notes = daemon.seed("/home/ada/notes");
    daemon.todos(notes.id, [
      { id: "t1", content: "copy the ledger table", status: "in_progress" },
      { id: "t2", content: "drop the old index", status: "pending" },
    ]);
    unmount = render(<App />).unmount;
    await open("/home/ada/notes");
    (await seesButton("Show backstage", await menu())).click();
    await sees("copy the ledger table");

    (await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="Complete: copy the ledger table"]'), "Complete")).click();
    await waitFor(() => document.querySelector(".tasks li.completed")?.textContent === "copy the ledger table", "the task completed");
    (await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="Cancel: drop the old index"]'), "Cancel")).click();
    await waitFor(() => document.querySelector(".tasks li.cancelled")?.textContent === "drop the old index", "the task cancelled");

    const add = await waitFor(() => document.querySelector<HTMLInputElement>('input[aria-label="Add a task"]'), "the field to add one");
    type(add, "check the counts");
    add.form!.requestSubmit();
    await waitFor(() => [...document.querySelectorAll(".tasks .task-text")].some((t) => t.textContent === "check the counts"), "the task added");
    expect(add.value).toBe("");

    const edits = daemon.calls.filter((c) => c.method === "todo.edit").map((c) => [c.params["action"], c.params["id"] ?? c.params["content"]]);
    expect(edits).toEqual([
      ["complete", "t1"],
      ["cancel", "t2"],
      ["add", "check the counts"],
    ]);
    // A task done or dropped is no longer offered.
    expect(document.querySelector('button[aria-label="Complete: copy the ledger table"]')).toBeNull();
  });
});

describe("a team session", () => {
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

  it("is renamed and kept at the top by its owner through the plane", async () => {
    const audit = harness.plane.seed("ada@example.com", { title: "Weekly licence audit" });
    await signIn();

    (await seesButton("Rename", await rowMenu("Weekly licence audit"))).click();
    await rename("Licence audit");
    await waitFor(() => titles().includes("Licence audit"), "the row under its new name");
    expect(audit.title).toBe("Licence audit");

    (await seesButton("Keep at the top", await rowMenu("Licence audit"))).click();
    await waitFor(() => entry("Licence audit")?.querySelector(".kept") !== null, "the kept mark");
    expect(audit.pinned).toBe(true);
  });

  it("offers neither to somebody who is not its owner, and the palette says whose it is", async () => {
    const bobs = harness.plane.seed("bob@example.com", { title: "Bob's migration" });
    await signIn();
    await waitFor(() => entry("Bob's migration"), "Bob's row");
    expect(entry("Bob's migration")!.querySelector(".row-menu")).toBeNull();

    await open("Bob's migration");
    const pop = await menu();
    expect(button("Rename session", pop)).toBeNull();
    expect(button("Keep at the top", pop)).toBeNull();
    key(document, "Escape");

    await run("rename Mine");
    await waitFor(() => document.querySelector(".palette .notice")?.textContent === "only its owner can rename this session", "the palette's notice");
    expect(bobs.title).toBe("Bob's migration");
  });
});
