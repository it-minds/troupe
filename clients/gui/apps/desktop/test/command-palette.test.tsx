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
import { button, render, says, sees, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

/** The rows this app lists: the table less the terminal client's own. */
const SHOWN = COMMANDS.filter((c) => c.availability !== "tui").length;

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

function selected(): string | null {
  return document.querySelector('.palette .row[aria-selected="true"] .name')?.textContent ?? null;
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
    await waitFor(() => rowNames().length === SHOWN, "every command the daemon listed");
    expect(daemon.calls.some((c) => c.method === "commands.list")).toBe(true);

    // Sections in the table's order, and a summary beside each name.
    const sections = [...dialog.querySelectorAll(".section")].map((el) => el.textContent);
    // No Quit: leaving is the terminal client's, and its rows are not listed here.
    expect(sections).toEqual(["Session", "Navigate", "Workspace", "Setup", "Agents", "Custom"]);
    expect(rowNames()).toContain("/merge");
    await sees("Land a worktree branch on the checkout");
    await sees("Set, show or clear the session's goal");

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
    await waitFor(() => rowNames().length === SHOWN, "the list");
    const input = dialog.querySelector<HTMLInputElement>("input")!;

    type(input, "mer");
    await waitFor(() => rowNames().length === 1, "one row");
    expect(rowNames()).toEqual(["/merge"]);

    // An alias finds its command and the cursor lands on it.
    type(input, "resume");
    await waitFor(() => rowNames().includes("/sessions"), "sessions by its alias");
    await waitFor(() => selected() === "/sessions", "the cursor on /sessions");

    // A word from a summary.
    type(input, "worktree");
    await waitFor(() => rowNames().join() === "/merge", "merge by its summary");

    // Enter on a command this app cannot run says why, and the palette stays.
    type(input, "merge");
    await waitFor(() => rowNames().join() === "/merge", "merge");
    key(input, "Enter");
    await waitFor(() => document.querySelector(".palette .notice")?.textContent?.startsWith("branches and worktrees are the terminal client's"), "the reason");
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
    await waitFor(() => rowNames().length === SHOWN, "the list");
    const input = dialog.querySelector<HTMLInputElement>("input")!;

    type(input, "goal make the suite green");
    // The first word filters and the rest is the argument. `/loop` works towards the goal,
    // and says so, so it stays in the list; the cursor is on the command named exactly.
    await waitFor(() => selected() === "/goal", "the cursor on the goal row, the rest being its argument");
    expect(rowNames()).toContain("/goal");
    expect(rowNames()).not.toContain("/merge");
    key(input, "Enter");
    await waitFor(() => daemon.calls.some((c) => c.method === "session.goal.set" && c.params["text"] === "make the suite green"), "the goal to reach the daemon");
    await waitFor(() => says("goal set: make the suite green"), "the palette's notice");
  });

  // A command the repository's `.troupe/commands/review.md` defines (Decision 763): a row
  // of its own section with its file's description, which runs through the client's
  // `commands.run`, and whose prompt comes back as the session's input.
  it("lists a command a file defines in its own section, and runs it through the daemon", async () => {
    const composer = await openSession();
    key(composer, "/");
    const dialog = await waitFor(palette, "the palette");
    await waitFor(() => rowNames().length === SHOWN, "the list");
    const input = dialog.querySelector<HTMLInputElement>("input")!;

    type(input, "review the parser");
    await waitFor(() => selected() === "/review", "the cursor on /review, the rest being its argument");
    expect([...dialog.querySelectorAll(".section")].map((el) => el.textContent)).toEqual(["Custom"]);
    const row = [...dialog.querySelectorAll<HTMLElement>(".row")].find((r) => r.textContent?.startsWith("/review"))!;
    expect(row.classList.contains("unavailable")).toBe(false);
    expect(row.textContent).toContain("Review the change on this branch");
    await sees("/review <what to look at>");

    key(input, "Enter");
    await waitFor(
      () => daemon.calls.some((c) => c.method === "commands.run" && c.params["name"] === "review" && c.params["arguments"] === "the parser"),
      "the command to reach the daemon",
    );
    await waitFor(() => palette() === null, "the palette to close");
    await waitFor(() => says("Review the change on this branch. Look hardest at the parser."), "its prompt in the transcript");
  });

  // What a command a file defines sends is in its detail (Decision 814): the description is
  // only what the file says of itself.
  it("shows what a command a file defines sends: its first lines, and how many more", async () => {
    const composer = await openSession();
    key(composer, "/");
    const dialog = await waitFor(palette, "the palette");
    await waitFor(() => rowNames().length === SHOWN, "the list");
    const input = dialog.querySelector<HTMLInputElement>("input")!;
    const sends = (): string | null => dialog.querySelector(".detail .sends pre")?.textContent ?? null;

    type(input, "review");
    await waitFor(() => selected() === "/review", "/review selected");
    expect(sends()).toBe("Review the change on this branch. Look hardest at $ARGUMENTS.");

    // Twelve lines: eight shown, and the rest counted.
    type(input, "audit");
    await waitFor(() => selected() === "/audit", "/audit selected");
    expect(sends()?.split("\n")).toEqual(["Audit the dependencies, one at a time:", ...[1, 2, 3, 4, 5, 6, 7].map((n) => `${n}. check package ${n}`)]);
    expect(dialog.querySelector(".detail .sends")?.textContent).toContain("… 4 more lines in the file");

    // A built-in sends no prompt of its own, and says nothing of one.
    type(input, "goal");
    await waitFor(() => selected() === "/goal", "/goal selected");
    expect(dialog.querySelector(".detail .sends")).toBeNull();
  });

  // With auto_approve on, nothing asks before the tools a prompt leads to, so a workspace's
  // command asks once before it is first sent, its prompt in view (Decision 814).
  it("with auto_approve on, asks before a workspace's command is first sent, and allow is not asked again", async () => {
    daemon.autoApprove = true;
    const composer = await openSession();
    const inputs = (): string[] =>
      [...daemon.sessions.values()].flatMap((s) => s.log.from(0)).filter((e) => e.type === "user_input").map((e) => String(e.data["text"]));
    const run = async (line: string): Promise<void> => {
      key(composer, "/");
      const dialog = await waitFor(palette, "the palette");
      await waitFor(() => rowNames().length === SHOWN, "the list");
      type(dialog.querySelector<HTMLInputElement>("input")!, line);
      await waitFor(() => selected() === `/${line.split(" ")[0]}`, "the command selected");
      key(dialog.querySelector("input")!, "Enter");
      await waitFor(() => palette() === null, "the palette to close");
    };

    await run("review the parser");
    const panel = await waitFor(() => document.querySelector<HTMLElement>(".approval.question"), "the question");
    expect(panel.querySelector(".consequence")?.textContent).toContain("/review comes with this workspace");
    expect(panel.querySelector("pre.evidence")?.textContent).toBe("Review the change on this branch. Look hardest at the parser.");
    expect(inputs()).toEqual([]);

    button("allow", panel)!.click();
    await waitFor(() => inputs().length === 1, "the prompt sent");
    expect(inputs()).toEqual(["Review the change on this branch. Look hardest at the parser."]);
    await waitFor(() => document.querySelector(".approval.question") === null, "the question answered");

    // Allowed: the next run is sent, and nothing asks.
    await run("review the lexer");
    await waitFor(() => inputs().length === 2, "the second run sent");
    expect(document.querySelector(".approval.question")).toBeNull();

    // Another of the workspace's commands asks for itself; deny sends nothing and says how.
    await run("audit");
    const audit = await waitFor(() => document.querySelector<HTMLElement>(".approval.question"), "the audit question");
    expect(audit.querySelector("pre.evidence")?.textContent).toContain("11. check package 11");
    button("deny", audit)!.click();
    await waitFor(() => says("/audit was not sent. Run /audit again to be asked again"), "the reason in the transcript");
    expect(inputs()).toHaveLength(2);
  });
});

// The palette speaks for this app (troupe #898): a row in the table's words for it where
// they differ from the terminal's, none of the terminal client's own rows, and an agent's
// row switching the session as the head's switch does.
describe("the palette in this app's words", () => {
  function paletteRow(name: string): HTMLElement | undefined {
    return [...document.querySelectorAll<HTMLElement>(".palette .row")].find((r) => r.querySelector(".name")?.textContent === `/${name}`);
  }

  it("leaves out /quit and /upload, and says /cancel and /sessions as this app runs them", async () => {
    const composer = await openSession();
    key(composer, "/");
    const dialog = await waitFor(palette, "the palette");
    await waitFor(() => rowNames().length === SHOWN, "the list");

    expect(rowNames()).not.toContain("/quit");
    expect(rowNames()).not.toContain("/upload");
    const input = dialog.querySelector<HTMLInputElement>("input")!;
    type(input, "exit");
    await waitFor(() => !rowNames().includes("/quit"), "no quit by its alias either");

    type(input, "cancel");
    await waitFor(() => selected() === "/cancel", "/cancel");
    expect(paletteRow("cancel")!.textContent).toContain("Stop the agent mid-turn");
    // No window in its usage either: this app has none.
    expect(dialog.querySelector(".palette .detail")!.textContent).not.toMatch(/window/);
    expect(paletteRow("cancel")!.textContent).not.toMatch(/window/);

    type(input, "sessions");
    await waitFor(() => selected() === "/sessions", "/sessions");
    expect(paletteRow("sessions")!.textContent).toContain("Your sessions, newest first");
    expect(dialog.querySelector(".palette .detail")!.textContent).not.toMatch(/window|directory/);
  });

  it("switches the session to an agent from its row, and sends what follows the name", async () => {
    const composer = await openSession();
    key(composer, "/");
    const dialog = await waitFor(palette, "the palette");
    await waitFor(() => rowNames().length === SHOWN, "the list");
    await waitFor(() => daemon.calls.some((c) => c.method === "agents.list" && typeof c.params["session_id"] === "string"), "the session's own listing");

    const input = dialog.querySelector<HTMLInputElement>("input")!;
    type(input, "plan look at the parser");
    await waitFor(() => selected() === "/plan", "/plan selected");
    await waitFor(() => paletteRow("plan")?.classList.contains("unavailable") === false, "/plan enabled");
    expect(dialog.querySelector(".palette .detail")!.textContent).toContain("Enter switches this session to plan");
    key(input, "Enter");
    await waitFor(() => palette() === null, "the palette to close");
    await waitFor(() => daemon.calls.some((c) => c.method === "profile.switch" && c.params["profile"] === "plan"), "profile.switch");
    await waitFor(() => daemon.calls.some((c) => c.method === "input.send" && c.params["text"] === "look at the parser"), "the rest sent as the next message");
    // Switched first, so the message is the new agent's first turn.
    const order = daemon.calls.map((c) => c.method).filter((m) => m === "profile.switch" || m === "input.send");
    expect(order).toEqual(["profile.switch", "input.send"]);
  });
});