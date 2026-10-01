// A turn the root agent failed (defects.md D42; Decision 727). A root that crashes as
// often as it may be restarted ends its turn with `turn_ended`, `reason: agent_failed` and
// what it raised, and its session stops. That is a failure, and the app says so wherever it
// says how a session is: the transcript's end of the turn, the session's status, the
// launcher's row and the list's, and a notification — with what the agent raised.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { resetNotifications } from "../src/notify";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

/** The first line of what the root raised, as the harness writes it into `detail`. */
const RAISED = '** (Protocol.UndefinedError) protocol Enumerable not implemented for "not a list"';

/** Long enough for the list's poll, every four seconds, to bring the row. */
const POLL_MS = 15_000;

class FakeNotification {
  static permission: NotificationPermission = "granted";
  static sent: Array<{ title: string; body: string | undefined }> = [];
  static async requestPermission(): Promise<NotificationPermission> {
    return "granted";
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

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  resetNotifications();
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

describe("a turn the root agent failed", () => {
  it("on screen, ends the turn saying what it raised, the session's status says it failed, and a notification says so", async () => {
    startOnTheList();
    const session = daemon.seed("/home/ada/crashing");
    unmount = render(<App />).unmount;
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/ada/crashing")),
      "the session in the list",
    );
    row.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");

    focused = false;
    daemon.fail(session.id, RAISED);

    const note = await waitFor(
      () => [...document.querySelectorAll(".stream .note")].find((p) => p.textContent?.startsWith("the agent kept crashing")),
      "the end of the turn in the transcript",
    );
    expect(note.textContent).toBe(`the agent kept crashing and the session stopped: ${RAISED}`);
    expect(note.classList.contains("error")).toBe(true);

    const status = document.querySelector(".session-head .controls .pill");
    expect(status?.textContent).toBe("Failed");
    expect(status?.classList.contains("error")).toBe(true);
    expect(status?.getAttribute("title")).toBe(RAISED);

    await waitFor(() => FakeNotification.sent.length === 1, "the notification");
    expect(FakeNotification.sent[0]).toEqual({ title: "/home/ada/crashing", body: `The turn failed: ${RAISED}` });
  });

  it("away from it, the launcher's row and the list's say it failed, and a notification says so", async () => {
    const session = daemon.seed("/home/ada/crashing");
    // Read once and left: what happens from here is news.
    daemon.markSeen(session.id);
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".launcher .recent button"), "the launcher's recent row");
    expect(document.querySelector(".recent .is-error")).toBeNull();

    daemon.fail(session.id, RAISED);

    const recent = await waitFor(() => document.querySelector<HTMLButtonElement>(".recent .is-error"), "the row, failed", POLL_MS);
    expect(recent.textContent).toContain("/home/ada/crashing");
    expect(recent.getAttribute("title")).toBe(`The agent kept crashing and the session stopped: ${RAISED}`);
    await waitFor(() => FakeNotification.sent.length === 1, "the notification");
    expect(FakeNotification.sent[0]).toEqual({ title: "/home/ada/crashing", body: `The turn failed: ${RAISED}` });

    // The list says it in a word, and what was raised on hover.
    button("02")!.click();
    const pill = await waitFor(() => document.querySelector("button.row .pill.error"), "the list's row, failed");
    expect(pill.textContent).toBe("Failed");
    expect(pill.getAttribute("title")).toBe(`The agent kept crashing and the session stopped: ${RAISED}`);
  });
});
