// Notifications (issue #119): a session that finishes a turn or raises an approval or a
// question while this window is not in front, or while nobody here is reading it, says
// so once — and not while the person is looking at it. Permission is asked once, on the
// first thing the person does, a refusal is kept, and the preference turns it all off.
// The page's `Notification` stands in for the OS's here, as it does in a browser.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import type { DurableEvent, FleetRow } from "@troupe/client";
import { App } from "../src/App";
import { askPermission, noticeEvent, noticeRows, resetNotifications } from "../src/notify";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, sleep, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

class FakeNotification {
  static permission: NotificationPermission = "granted";
  static answer: NotificationPermission = "granted";
  static asked = 0;
  static sent: Array<{ title: string; body: string | undefined }> = [];
  static async requestPermission(): Promise<NotificationPermission> {
    FakeNotification.asked += 1;
    FakeNotification.permission = FakeNotification.answer;
    return FakeNotification.answer;
  }
  onclick: (() => void) | null = null;
  constructor(title: string, opts: NotificationOptions = {}) {
    FakeNotification.sent.push({ title, body: opts.body });
  }
  close(): void {}
}

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;
let focused = true;

const row = (workspace: string): HTMLButtonElement | undefined =>
  [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(workspace));

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  resetNotifications();
  FakeNotification.permission = "granted";
  FakeNotification.answer = "granted";
  FakeNotification.asked = 0;
  FakeNotification.sent = [];
  (globalThis as { Notification?: unknown }).Notification = FakeNotification;
  focused = true;
  Object.defineProperty(document, "hasFocus", { configurable: true, value: () => focused });
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  delete (globalThis as { Notification?: unknown }).Notification;
  await daemon.stop();
});

/** Open a session from the list, and wait until the screen is reading it (see goal-loop.test.tsx). */
async function open(workspace: string): Promise<void> {
  unmount = render(<App />).unmount;
  (await waitFor(() => row(workspace), "the session in the list")).click();
  await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session");
  await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");
}

let nextSeq = 1;
const event = (type: string, data: Record<string, unknown> = {}): DurableEvent => ({
  seq: nextSeq++,
  prev_hash: null,
  ts: new Date().toISOString(),
  actor: { kind: "system" },
  agent: ["root"],
  type,
  v: 1,
  data,
});

describe("notifications", () => {
  it("takes nothing in a session's replay for news, and reads it only for whether a loop runs", async () => {
    expect(await askPermission()).toBe("granted");
    noticeRows([{ id: "s-9", title: "/home/ada/replayed" } as FleetRow], null);
    focused = false;
    noticeEvent("s-9", event("turn_ended"), false);
    noticeEvent("s-9", event("question_asked", { call_id: "q-1", question: "Formal?" }), false);
    noticeEvent("s-9", event("loop_started", { loop_id: "loop-1" }), false);
    // Live, but the loop's own turn: the loop ending is the news.
    noticeEvent("s-9", event("turn_ended"), true);
    expect(FakeNotification.sent).toEqual([]);
    noticeEvent("s-9", event("loop_stopped", { loop_id: "loop-1", reason: "max_iterations" }), true);
    noticeEvent("s-9", event("turn_ended"), true);
    expect(FakeNotification.sent).toEqual([
      { title: "/home/ada/replayed", body: "The loop stopped" },
      { title: "/home/ada/replayed", body: "1 turn finished" },
    ]);
  });

  it("says what the session on screen did while the window was not in front, once per event, and nothing while it is", async () => {
    const session = daemon.seed("/home/ada/release");
    await open("/home/ada/release");
    await sleep(200);
    expect(FakeNotification.sent).toEqual([]);

    focused = false;
    session.log.append("turn_ended", {});
    await waitFor(() => FakeNotification.sent.length === 1, "the turn said");
    expect(FakeNotification.sent[0]).toEqual({ title: "/home/ada/release", body: "1 turn finished" });

    session.log.append("approval_requested", { call_id: "call-7", tool: "shell", args: { command: "rm -rf build" }, agent_path: ["root"] });
    await waitFor(() => FakeNotification.sent.length === 2, "the approval said");
    expect(FakeNotification.sent[1]!.body).toBe("Waiting for you: run shell?");

    // The same approval asked again, as a session that wakes asks it: said once.
    session.log.append("approval_requested", { call_id: "call-7", tool: "shell", args: { command: "rm -rf build" }, agent_path: ["root"] });
    daemon.ask(session.id, { call_id: "q-1", question: "Formal or casual?" });
    await waitFor(() => FakeNotification.sent.length === 3, "the question said");
    expect(FakeNotification.sent[2]!.body).toBe("Waiting for you: Formal or casual?");

    // A loop's turns are its own business; the loop ending is the news.
    session.log.append("loop_started", { loop_id: "loop-1", max_iterations: 3, max_failures: 3, goal: "g" });
    session.log.append("turn_ended", {});
    session.log.append("loop_stopped", { loop_id: "loop-1", reason: "goal_complete", iterations: 1, summary: "done" });
    await waitFor(() => FakeNotification.sent.length === 4, "the loop's end said");
    expect(FakeNotification.sent[3]!.body).toBe("The loop is done: the goal is met");

    // Looking at it again: nothing, however much happens.
    focused = true;
    session.log.append("turn_ended", {});
    daemon.ask(session.id, { call_id: "q-2", question: "And now?" });
    await sleep(300);
    expect(FakeNotification.sent).toHaveLength(4);
  });

  it("says what a session nobody here is reading did, from the list, once", async () => {
    const other = daemon.seed("/home/ada/kunder");
    daemon.markSeen(other.id);
    other.log.append("turn_ended", {}); // there already when the list first came: its marker says it
    unmount = render(<App />).unmount;
    await waitFor(() => row("/home/ada/kunder")?.querySelector(".pill.new"), "the list with its marker");
    await sleep(300);
    expect(FakeNotification.sent).toEqual([]);

    // With the window in front too: nothing on screen is reading this session.
    other.log.append("turn_ended", {});
    other.pendingQuestions = 1;
    daemon.ask(other.id, { call_id: "q-1", question: "Formal or casual?" });
    await waitFor(() => FakeNotification.sent.length === 1, "the news from the list", 10_000);
    expect(FakeNotification.sent[0]).toEqual({ title: "/home/ada/kunder", body: "1 turn finished, 1 question waiting" });

    // The next polls say the same counts: nothing more.
    await sleep(4_500);
    expect(FakeNotification.sent).toHaveLength(1);
  });

  it("asks once, on the first thing the person does, keeps a refusal, and stays quiet when turned off", async () => {
    FakeNotification.permission = "default";
    FakeNotification.answer = "denied";
    const session = daemon.seed("/home/ada/release");
    unmount = render(<App />).unmount;
    await waitFor(() => row("/home/ada/release"), "the list");
    expect(FakeNotification.asked).toBe(0);

    window.dispatchEvent(new Event("pointerdown"));
    await waitFor(() => FakeNotification.asked === 1, "the one question");
    window.dispatchEvent(new Event("pointerdown"));
    window.dispatchEvent(new Event("keydown"));
    await sleep(100);
    expect(FakeNotification.asked).toBe(1);
    expect(localStorage.getItem("troupe.pref.notify.asked")).toBe("yes");

    // Refused: nothing is shown, and the settings say why.
    row("/home/ada/release")!.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the session on screen");
    focused = false;
    session.log.append("turn_ended", {});
    await sleep(300);
    expect(FakeNotification.sent).toEqual([]);
    button("Appearance", document.querySelector(".rail nav")!)!.click();
    await waitFor(() => document.body.textContent?.includes("Troupe will not ask again"), "the refusal, said on the settings screen");

    // Allowed, but turned off here: still nothing.
    FakeNotification.permission = "granted";
    unmount!();
    resetNotifications();
    localStorage.setItem("troupe.pref.notify", "off");
    await open("/home/ada/release");
    focused = false;
    session.log.append("turn_ended", {});
    await sleep(300);
    expect(FakeNotification.sent).toEqual([]);
    expect(FakeNotification.asked).toBe(1);
  });
});
