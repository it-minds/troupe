// The session's goal and its loop in the desktop app (issue #59): the goal in the
// session's head, set and cleared from there, clipped with the whole of it on hover and a
// click away, and following the `goal_*` events whoever sent them; and the loop beside
// the status — started with a cap, "iteration n/N" as its events arrive, stopped
// mid-iteration, the input box usable throughout, and a loop with no goal refused in
// words. Driven against the fake daemon, which keeps the goal and reads the loop from
// the log the way the daemon does.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, says, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

const head = (): HTMLElement => document.querySelector<HTMLElement>(".session-head")!;
const goalText = (): HTMLButtonElement | null => document.querySelector<HTMLButtonElement>(".session-head .goal .text");
const loopPill = (): string | null => [...head().querySelectorAll(".controls .pill")].map((p) => p.textContent ?? "").find((t) => t.startsWith("Loop")) ?? null;

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

/**
 * Open a session from the list. What a test appends to its log comes after, live: the
 * fake answers `subscribe` and sends the replay in one write, which Node's `ws` hands
 * over in one go, before the screen has started listening — a browser delivers each
 * message as a task of its own, so the replay is not lost there.
 */
async function open(workspace: string): Promise<void> {
  unmount = render(<App />).unmount;
  const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(workspace)), "the session in the list");
  row.click();
  await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session");
  await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");
}

describe("the goal in the session's head", () => {
  it("is set and cleared from the head, clipped with the whole of it on hover and a click, and follows the events", async () => {
    const session = daemon.seed("/home/ada/release");
    await open("/home/ada/release");

    // No goal: one link, and nothing pretending to be a goal.
    expect(goalText()).toBeNull();
    button("Set a goal", head())!.click();
    const field = await waitFor(() => head().querySelector<HTMLInputElement>('input[aria-label="Goal"]'), "the goal field");
    const long = "The release notes build on Windows from a clean checkout, with the changelog generated from the merged pull requests";
    type(field, long);
    button("Set", head())!.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.goal.set" && c.params["text"] === long), "session.goal.set");

    // Drawn from the event, not from what was typed: the whole goal is its title, and a
    // click opens it and closes it again.
    const text = await waitFor(goalText, "the goal in the head");
    expect(text.textContent).toBe(long);
    expect(text.title).toBe(long);
    expect(text.getAttribute("aria-expanded")).toBe("false");
    text.click();
    await waitFor(() => goalText()?.getAttribute("aria-expanded") === "true", "the goal opened");
    expect(head().querySelector(".goal.open")).not.toBeNull();
    goalText()!.click();
    await waitFor(() => goalText()?.getAttribute("aria-expanded") === "false", "the goal closed");
    // The transcript says it once, where it happened.
    expect(says(`goal: ${long}`)).toBe(true);

    // Another client changes it: the head follows the event.
    session.goal = "Only the changelog";
    session.log.append("goal_set", { text: "Only the changelog", command_id: "c-other" }, { kind: "user", subject: "jonas@example.com" });
    await waitFor(() => goalText()?.textContent === "Only the changelog", "the other client's goal");

    // Changed from the head.
    button("Change", head())!.click();
    const again = await waitFor(() => head().querySelector<HTMLInputElement>('input[aria-label="Goal"]'), "the goal field again");
    expect(again.value).toBe("Only the changelog");
    type(again, "The changelog and the notes");
    button("Change", head())!.click();
    await waitFor(() => goalText()?.textContent === "The changelog and the notes", "the changed goal");

    // Cleared from the head: back to the one link.
    button("Clear", head())!.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.goal.clear"), "session.goal.clear");
    await waitFor(() => goalText() === null && button("Set a goal", head()) !== null, "the goal gone from the head");
    expect(says("goal cleared")).toBe(true);
  });
});

describe("the loop in the session's head", () => {
  it("starts with a cap, shows iteration n/N as it runs, stops mid-iteration, and never takes the input box", async () => {
    const session = daemon.seed("/home/ada/release");
    await open("/home/ada/release");
    session.goal = "The notes build";
    session.log.append("goal_set", { text: "The notes build", command_id: "c-0" }, { kind: "user", subject: "local:ada" });
    await waitFor(goalText, "the goal");
    expect(loopPill()).toBeNull();

    button("Loop", head())!.click();
    const cap = await waitFor(() => head().querySelector<HTMLInputElement>('input[aria-label="Iterations at most"]'), "the cap");
    type(cap, "3");
    button("Start the loop", head())!.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.start" && c.params["max_iterations"] === 3), "session.loop.start with the cap");

    // The loop is what its events say: starting, then each iteration as it begins.
    await waitFor(() => loopPill() === "Loop · starting", "the loop starting");
    session.log.append("loop_iteration_started", { loop_id: "loop-1", iteration: 1, command_id: "loop-1-1" });
    session.log.append("user_input", { source: "loop", text: "Work towards the goal.", command_id: "loop-1-1" });
    await waitFor(() => loopPill() === "Loop · iteration 1/3", "iteration 1/3");
    session.log.append("loop_iteration_finished", { loop_id: "loop-1", iteration: 1, outcome: "continue", detail: null });
    session.log.append("loop_iteration_started", { loop_id: "loop-1", iteration: 2, command_id: "loop-1-2" });
    await waitFor(() => loopPill() === "Loop · iteration 2/3", "iteration 2/3");
    // The transcript says which iteration it is, not the words the loop gave the model.
    expect(says("loop iteration 2/3")).toBe(true);
    expect(says("Work towards the goal.")).toBe(false);
    // While it runs, the goal line offers no second loop.
    expect(button("Loop", head())).toBeNull();

    // The input box is the person's throughout: it types, says where it goes, and sends.
    const composer = document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]')!;
    expect(says("A loop is working towards the goal")).toBe(true);
    type(composer, "also check the macOS path");
    button("Send")!.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "input.send" && c.params["text"] === "also check the macOS path"), "the person's input sent mid-loop");

    // Stopped mid-iteration: the loop's state goes, and the head says how it ended.
    button("Stop loop", head())!.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.stop"), "session.loop.stop");
    await waitFor(() => loopPill() === null, "the loop pill gone");
    await waitFor(() => head().querySelector(".goal-note")?.textContent === "loop stopped after 2 iterations: stopped on request", "how the loop ended");
    expect(button("Loop", head())).not.toBeNull();
  });

  it("says plainly that a loop needs a goal, and what a cap has to be", async () => {
    // The head has a goal from the log that the session no longer has: another client
    // cleared it a moment ago, and the refusal is what this client hears first.
    const session = daemon.seed("/home/ada/release");
    await open("/home/ada/release");
    session.log.append("goal_set", { text: "The notes build", command_id: "c-0" }, { kind: "user", subject: "local:ada" });
    await waitFor(goalText, "the goal");

    button("Loop", head())!.click();
    await waitFor(() => button("Start the loop", head()), "the loop form");
    button("Start the loop", head())!.click();
    const plain = "A loop works towards the session's goal, and this session has none. Set a goal first.";
    await waitFor(() => head().querySelector(".note.error")?.textContent === plain, "the refusal in words");
    expect(says("conflict")).toBe(false);

    // A cap that is not a whole number is caught before anything is sent.
    const cap = head().querySelector<HTMLInputElement>('input[aria-label="Iterations at most"]')!;
    type(cap, "two");
    const before = daemon.calls.filter((c) => c.method === "session.loop.start").length;
    button("Start the loop", head())!.click();
    await waitFor(() => head().querySelector(".note.error")?.textContent === "The number of iterations is a whole number, one or more.", "the cap refused");
    expect(daemon.calls.filter((c) => c.method === "session.loop.start").length).toBe(before);
  });
});
