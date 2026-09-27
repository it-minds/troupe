// The command palette (issue #124): one list behind the protocol, drawn over the session.
// The app is rendered against the fake daemon, which answers `commands.list` with the
// fakes' table, and the palette is driven the way a person drives it: `/` in the empty
// composer opens it with its sections and a description per row, typing narrows it,
// Enter runs the row, Esc closes it, and Ctrl-K opens it from anywhere.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { COMMANDS } from "../../../packages/client/test/support/commands.js";
import { button, render, says, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

function key(target: EventTarget, key: string, init: KeyboardEventInit = {}): void {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
}

function palette(): HTMLElement | null {
  return document.querySelector<HTMLElement>('[role="dialog"][aria-label="Commands"]');
}

function rowNames(): string[] {
  return [...document.querySelectorAll(".palette .row .name")].map((el) => el.textContent ?? "");
}

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  daemon.seed("/home/ada/notes");
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

async function openSession(): Promise<HTMLTextAreaElement> {
  unmount = render(<App />).unmount;
  await waitFor(() => says("/home/ada/notes"), "the daemon's session in the list");
  button("Start a session")!.click();
  const start = await waitFor(() => document.querySelector<HTMLElement>(".start"), "the start screen");
  type(start.querySelector<HTMLInputElement>("input")!, "/home/ada/project");
  button("Start", start)!.click();
  return waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the session");
}

describe("the command palette", () => {
  it("opens on / in the empty composer, sectioned, with a description per command, from the daemon's list", async () => {
    const composer = await openSession();
    expect(palette()).toBeNull();

    key(composer, "/");
    const dialog = await waitFor(palette, "the palette");
    await waitFor(() => rowNames().length === COMMANDS.length, "every command the daemon listed");
    expect(daemon.calls.some((c) => c.method === "commands.list")).toBe(true);

    // Sections in the table's order, and a summary beside each name.
    const sections = [...dialog.querySelectorAll(".section")].map((el) => el.textContent);
    expect(sections).toEqual(["Session", "Navigate", "Workspace", "Setup", "Agents", "Quit"]);
    expect(rowNames()).toContain("/merge");
    expect(says("Land a worktree branch on the checkout")).toBe(true);
    expect(says("Set, show or clear the session's goal")).toBe(true);

    // What this app cannot run is greyed with the reason, not hidden.
    const merge = [...dialog.querySelectorAll<HTMLElement>(".row")].find((r) => r.textContent?.startsWith("/merge"))!;
    expect(merge.classList.contains("unavailable")).toBe(true);
    expect(merge.textContent).toContain("terminal client");
    const goal = [...dialog.querySelectorAll<HTMLElement>(".row")].find((r) => r.textContent?.startsWith("/goal"))!;
    expect(goal.classList.contains("unavailable")).toBe(false);

    // The composer did not get the slash.
    expect(composer.value).toBe("");

    key(dialog.querySelector("input")!, "Escape");
    await waitFor(() => palette() === null, "the palette to close");
  });

  it("narrows as you type, by name, alias and summary, and Enter runs the row", async () => {
    await openSession();
    key(window, "k", { ctrlKey: true });
    const dialog = await waitFor(palette, "the palette, from Ctrl-K");
    await waitFor(() => rowNames().length === COMMANDS.length, "the list");
    const input = dialog.querySelector<HTMLInputElement>("input")!;

    type(input, "mer");
    await waitFor(() => rowNames().length === 1, "one row");
    expect(rowNames()).toEqual(["/merge"]);

    // An alias finds its command and the cursor lands on it.
    type(input, "q");
    await waitFor(() => rowNames().includes("/quit"), "quit by its alias");
    expect(dialog.querySelector('.row[aria-selected="true"] .name')?.textContent).toBe("/quit");

    // A word from a summary.
    type(input, "worktree");
    await waitFor(() => rowNames().join() === "/merge", "merge by its summary");

    // Enter on a command this app cannot run says why, and the palette stays.
    type(input, "upload");
    await waitFor(() => rowNames().join() === "/upload", "upload");
    key(input, "Enter");
    await waitFor(() => document.querySelector(".palette .notice")?.textContent === "not in the desktop app yet", "the reason");
    expect(palette()).not.toBeNull();

    // Enter on /settings leaves for This computer.
    type(input, "settings");
    await waitFor(() => rowNames().join() === "/settings", "settings");
    key(input, "Enter");
    await waitFor(() => palette() === null, "the palette to close");
    await waitFor(() => says("Settings file"), "the This computer screen");
  });

  it("runs /goal against the session and shows the answer", async () => {
    const composer = await openSession();
    key(composer, "/");
    const dialog = await waitFor(palette, "the palette");
    await waitFor(() => rowNames().length === COMMANDS.length, "the list");
    const input = dialog.querySelector<HTMLInputElement>("input")!;

    type(input, "goal make the suite green");
    await waitFor(() => rowNames().join() === "/goal", "the goal row, the rest being its argument");
    key(input, "Enter");
    await waitFor(() => daemon.calls.some((c) => c.method === "session.goal.set" && c.params["text"] === "make the suite green"), "the goal to reach the daemon");
    await waitFor(() => says("goal set: make the suite green"), "the palette's notice");
  });
});
