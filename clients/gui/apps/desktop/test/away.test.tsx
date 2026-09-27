// "While you were away" (issue #119): a session's row says what happened while nobody
// was reading it (`unseen`, PROTOCOL.md §6), the list marks it, and opening the session
// says it in a line at the top — once, since opening it is what clears it at the daemon.
// A row from a daemon that does not count says nothing, and nothing is made up for it.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, says, sleep, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

const row = (workspace: string): HTMLButtonElement | undefined =>
  [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(workspace));
const marker = (workspace: string): HTMLElement | null => row(workspace)?.querySelector<HTMLElement>(".pill.new") ?? null;
const clock = (iso: string): string => {
  const at = new Date(iso);
  return `${String(at.getHours()).padStart(2, "0")}:${String(at.getMinutes()).padStart(2, "0")}`;
};

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
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

describe("while you were away", () => {
  it("marks the row, says it once on opening the session, and clears the marker", async () => {
    // Read once, then left: two turns and a question since.
    const away = daemon.seed("/home/ada/tilbud", { status: "waiting", pendingQuestions: 1 });
    daemon.markSeen(away.id);
    const first = away.log.append("turn_ended", {});
    away.log.append("turn_ended", {});
    daemon.ask(away.id, { call_id: "q-1", question: "Formal or casual?" });
    // Read, and nothing since; and one nobody ever read, which has nothing to say either.
    const quiet = daemon.seed("/home/ada/notes");
    daemon.markSeen(quiet.id);
    const never = daemon.seed("/home/ada/never");
    never.log.append("turn_ended", {});

    unmount = render(<App />).unmount;
    const sentence = `2 turns finished, 1 question waiting since ${clock(first.ts)}`;
    const mark = await waitFor(() => marker("/home/ada/tilbud"), "the marker on the row");
    expect(mark.textContent).toBe("3 new");
    expect(mark.title).toBe(`While you were away: ${sentence}`);
    expect(marker("/home/ada/notes")).toBeNull();
    expect(marker("/home/ada/never")).toBeNull();

    // Opening it says what happened, in a line at the top.
    row("/home/ada/tilbud")!.click();
    const line = await waitFor(() => document.querySelector<HTMLElement>(".banner.away"), "the line at the top");
    expect(line.textContent).toContain(`While you were away: ${sentence}.`);
    // Reading it is what cleared it at the daemon, so it will not be said again.
    expect(daemon.unseenOf(away)).toEqual({ turns: 0, approvals: 0, questions: 0, since: null });

    // Seen: it goes, and the session carries on.
    button("Seen", line)!.click();
    await waitFor(() => document.querySelector(".banner.away") === null, "the line gone once seen");

    // Back on the list, the marker is gone at once and stays gone after the next poll.
    button("Sessions", document.querySelector(".rail nav")!)!.click();
    await waitFor(() => row("/home/ada/tilbud"), "the list again");
    expect(marker("/home/ada/tilbud")).toBeNull();
    await sleep(4_500);
    expect(marker("/home/ada/tilbud")).toBeNull();

    // Something new while nobody reads it again: marked again.
    away.log.append("turn_ended", {});
    await waitFor(() => marker("/home/ada/tilbud")?.textContent === "1 new", "a new marker", 10_000);
  });

  it("goes when the person answers by sending something", async () => {
    const away = daemon.seed("/home/ada/kunder");
    daemon.markSeen(away.id);
    away.log.append("turn_ended", {});

    unmount = render(<App />).unmount;
    (await waitFor(() => marker("/home/ada/kunder") && row("/home/ada/kunder"), "the marked row")).click();
    await waitFor(() => says("While you were away: 1 turn finished"), "the line at the top");

    const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the composer");
    type(composer, "thanks, carry on");
    button("Send")!.click();
    await waitFor(() => document.querySelector(".banner.away") === null, "the line gone once answered");
  });
});
