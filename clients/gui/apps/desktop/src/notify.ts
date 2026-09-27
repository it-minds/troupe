// Telling the person when they are not looking (issue #119's last box): a notification
// when a session finishes a turn or raises an approval or a question while this window
// is not in front, or while the session is not the one on screen.
//
// News arrives two ways, and each is the only one for its case:
//
//   rows     what the list polls. A session nobody is reading counts what happened since
//            the last reader left (`unseen`, PROTOCOL.md §6), and a count that goes up is
//            news — whether or not this window is in front, since nothing on screen shows
//            that session. A plane's rows count nothing, so its sessions have only the
//            second way, and only while one is open.
//   events   a session this window is reading, whose `unseen` therefore stays empty: its
//            own `turn_ended`, `approval_requested` and `question_asked` once the replay is
//            over, and only while the window is not in front. A loop's turns are its own
//            business; the loop ending is the news.
//
// Each thing is said once: a count is remembered per session, and an approval or a
// question by its call id, which a session that wakes asks again under.
//
// Where it goes is the shell's, when it has one (WebView2 refuses the page's own), and
// the page's `Notification` in a browser. Asked once, on the first thing the person does
// here rather than out of nowhere at start, and a refusal is kept: nothing asks again by
// itself. The preference beside the appearance settings turns it off.
//
// A notification leads to its session. A browser says when one is clicked, and the click
// brings the window forward and opens the session. The shell's cannot: the notification
// plugin reports a click only on a phone, since on a desktop it shows the toast and lets
// go of the handle that would hear it. So there the window coming to the front shortly
// after a notification, however it got there, is taken as the answer to it, and opens the
// session the last one was about.

import { useEffect, useState } from "react";
import { describeUnseen } from "@troupe/client";
import type { DurableEvent, FleetRow, TroupeEvent, Unseen } from "@troupe/client";
import { prefs, shell } from "./shell";
import type { NotifyPermission } from "./shell";

export type Permission = NotifyPermission | "unsupported";

interface Backend {
  permission(): Promise<Permission>;
  request(): Promise<Permission>;
  send(title: string, body: string, tag: string): void;
}

function backend(): Backend | null {
  const s = shell()?.notifications;
  if (s) {
    return {
      permission: () => s.permission(),
      request: () => s.request(),
      send: (title, body) => void s.send(title, body).catch(() => undefined),
    };
  }
  const N = (globalThis as { Notification?: typeof Notification }).Notification;
  if (!N) return null;
  return {
    permission: async () => N.permission as Permission,
    request: async () => (await N.requestPermission()) as Permission,
    // One per session: a later one replaces what is still up rather than stacking. The
    // tag is the session, which a click opens.
    send: (title, body, tag) => {
      const n = new N(title, { body, tag });
      n.onclick = () => {
        n.close();
        answered(tag);
      };
    },
  };
}

// -- state ----------------------------------------------------------------------------

/** How soon after a notification the window coming to the front counts as answering it. */
export const ANSWER_MS = 15_000;

let permission: Permission = "default";
const counts = new Map<string, Unseen>();
const titles = new Map<string, string>();
const looping = new Set<string>();
const said = new Set<string>();
const listeners = new Set<() => void>();
/** Opens a session; the app's, while it is mounted. */
let opener: ((sessionId: string) => void) | null = null;
/** The last notification said while the window was not in front, until it comes back. */
let unanswered: { sessionId: string; at: number } | null = null;

function changed(): void {
  for (const l of listeners) l();
}

export function notificationsOn(): boolean {
  return prefs.get("notify", "on") !== "off";
}

/** Whether this window is the one in front. */
function focused(): boolean {
  const d = globalThis.document;
  return Boolean(d && d.visibilityState !== "hidden" && d.hasFocus());
}

function say(sessionId: string, key: string, body: string): void {
  if (said.has(key)) return;
  said.add(key);
  if (!notificationsOn() || permission !== "granted") return;
  const b = backend();
  if (!b) return;
  b.send(titles.get(sessionId) ?? sessionId, body, sessionId);
  if (!focused()) unanswered = { sessionId, at: Date.now() };
}

/** A notification was clicked: the window to the front, and its session open. */
function answered(sessionId: string): void {
  unanswered = null;
  globalThis.focus?.();
  opener?.(sessionId);
}

/** The window came to the front: soon enough after a notification, that is its answer. */
function cameBack(): void {
  const last = unanswered;
  unanswered = null;
  if (last && Date.now() - last.at <= ANSWER_MS) opener?.(last.sessionId);
}

// -- the two ways news arrives --------------------------------------------------------

/**
 * The list's rows, each time it is polled. The first sight of a row is what was there
 * already, which its marker says; what it counts after that is news.
 */
export function noticeRows(rows: FleetRow[], onScreen: string | null): void {
  for (const row of rows) {
    if (row.title) titles.set(row.id, row.title);
    const now = row.unseen;
    if (!now) continue;
    const before = counts.get(row.id);
    counts.set(row.id, now);
    if (!before || row.id === onScreen || now.since === null) continue;
    // A new `since` is a new stretch of nobody reading: everything in it is news.
    const fresh = before.since !== now.since;
    const news = {
      turns: Math.max(0, now.turns - (fresh ? 0 : before.turns)),
      approvals: Math.max(0, now.approvals - (fresh ? 0 : before.approvals)),
      questions: Math.max(0, now.questions - (fresh ? 0 : before.questions)),
    };
    if (news.turns + news.approvals + news.questions === 0) continue;
    say(row.id, `${row.id}:${now.since}:${now.turns}:${now.approvals}:${now.questions}`, describeUnseen(news, row));
  }
}

/**
 * One event of a session this window is reading. `live` is false for the replay, which
 * is only read for whether a loop is running.
 */
export function noticeEvent(sessionId: string, e: TroupeEvent, live: boolean): void {
  if (e.ephemeral) return;
  const d = e as DurableEvent;
  if (d.type === "loop_started") looping.add(sessionId);
  if (d.type === "loop_stopped") looping.delete(sessionId);
  if (!live || focused()) return;
  const callId = typeof d.data["call_id"] === "string" ? d.data["call_id"] : String(d.seq);
  switch (d.type) {
    case "turn_ended":
      if (d.agent.length === 1 && !looping.has(sessionId)) say(sessionId, `${sessionId}:${d.seq}`, "1 turn finished");
      return;
    case "loop_stopped":
      say(sessionId, `${sessionId}:${d.seq}`, d.data["reason"] === "goal_complete" ? "The loop is done: the goal is met" : "The loop stopped");
      return;
    case "approval_requested":
      say(sessionId, `${sessionId}:call:${callId}`, `Waiting for you: ${typeof d.data["tool"] === "string" ? `run ${d.data["tool"]}?` : "an approval"}`);
      return;
    case "question_asked":
      say(sessionId, `${sessionId}:call:${callId}`, `Waiting for you: ${typeof d.data["question"] === "string" ? d.data["question"] : "a question"}`);
      return;
    default:
      return;
  }
}

// -- asking ---------------------------------------------------------------------------

/** Ask, and keep the answer. The first time by itself; after that only when the person turns it on. */
export async function askPermission(): Promise<Permission> {
  const b = backend();
  if (!b) return (permission = "unsupported");
  prefs.set("notify.asked", "yes");
  permission = await b.request().catch((): Permission => "default");
  changed();
  return permission;
}

async function prepare(): Promise<void> {
  const b = backend();
  permission = b ? await b.permission().catch((): Permission => "default") : "unsupported";
  changed();
  if (permission !== "default" || !notificationsOn() || prefs.get("notify.asked") === "yes") return;
  const ask = (): void => {
    globalThis.removeEventListener?.("pointerdown", ask);
    globalThis.removeEventListener?.("keydown", ask);
    void askPermission();
  };
  globalThis.addEventListener?.("pointerdown", ask);
  globalThis.addEventListener?.("keydown", ask);
}

/**
 * The app's half: what the list says, every time it is polled, and the session on
 * screen, which the rows leave to its own events. `open` is where a notification that
 * was answered leads.
 */
export function useNotifications(rows: FleetRow[], onScreen: string | null, open: (sessionId: string) => void): void {
  useEffect(() => void prepare(), []);
  useEffect(() => noticeRows(rows, onScreen), [rows, onScreen]);
  useEffect(() => {
    opener = open;
    globalThis.addEventListener?.("focus", cameBack);
    return () => {
      if (opener === open) opener = null;
      globalThis.removeEventListener?.("focus", cameBack);
    };
  }, [open]);
}

/** The preference, for the settings screen: on or off, and what the OS or browser says. */
export function useNotificationSetting(): { on: boolean; permission: Permission; setOn: (on: boolean) => void } {
  const [on, setOnState] = useState(notificationsOn);
  const [, render] = useState(0);
  useEffect(() => {
    const l = (): void => render((n) => n + 1);
    listeners.add(l);
    return () => void listeners.delete(l);
  }, []);
  return {
    on,
    permission,
    setOn: (next) => {
      prefs.set("notify", next ? "on" : "off");
      setOnState(next);
      // Turning it on is the person asking, so the question is put if it has not been answered.
      if (next && permission === "default") void askPermission();
    },
  };
}

/** Forget everything, for tests. */
export function resetNotifications(): void {
  permission = "default";
  counts.clear();
  titles.clear();
  looping.clear();
  said.clear();
  unanswered = null;
}
