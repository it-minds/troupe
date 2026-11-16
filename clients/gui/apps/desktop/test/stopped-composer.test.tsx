// A session whose agent the harness wakes no more (troupe #987): after a spent budget a
// message is dropped, so the composer gives way to the sentence that says so and what to do,
// and a message that was dropped reads as dropped, never as picked up. A session that
// finished keeps its composer, since a message resumes it; a model error leaves it too.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { render, startOnTheList, waitFor } from "./support";

type Session = ReturnType<FakeDaemon["seed"]>;

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

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

const WORKSPACE = "/home/ada/parser";
const STOPPED = "This session has stopped: its 30-minute working limit is spent. Start a new session to continue.";
const NOT_TAKEN = "Your message was not taken: the session had stopped (its 30-minute working limit is spent). Start a new session to continue.";

async function open(session: Session): Promise<void> {
  unmount = render(<App />).unmount;
  const row = await waitFor(
    () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(session.workspace)),
    "the session in the list",
  );
  row.click();
  await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the composer");
}

const composer = (): HTMLTextAreaElement | null => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]');
const retry = (): HTMLButtonElement | undefined => [...document.querySelectorAll<HTMLButtonElement>(".stream button.fbtn")].find((b) => b.textContent === "Retry");
const notes = (): HTMLElement[] => [...document.querySelectorAll<HTMLElement>(".stream .note")];

function spend(session: Session): void {
  session.log.append("budget_warning", { dimension: "wall", used: 1_440_000, limit: 1_800_000, fraction: 0.8, detail: "working time 24m/30m (80%)" });
  session.log.append("agent_done", { reason: "budget_exhausted", limit: "wall_clock" });
  session.log.append("budget_exhausted", { limit: "wall_clock" });
}

describe("a session that has stopped", () => {
  it("puts the sentence in the composer's place after a budget stop, and says a dropped message was not taken", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    session.log.append("user_input", { source: "user", text: "go on" });
    session.log.append("llm_response", { message: { role: "assistant", content: [{ type: "text", text: "Still working." }] }, stop_reason: "end_turn" });
    session.log.append("turn_ended", { turn: { calls: 1, input_tokens: 10, cache_read: 0, cache_write: 0, output_tokens: 4, cost_micros: 0, unpriced: 1 } });
    await waitFor(() => retry(), "the reply's Retry");
    spend(session);

    const instead = await waitFor(() => document.querySelector<HTMLElement>(".instead.stopped"), "the sentence in the composer's place");
    expect(instead.textContent).toBe(STOPPED);
    expect(composer()).toBeNull();
    // Retry would send the words again, only for them to be dropped: it says why it is off.
    expect(retry()?.disabled).toBe(true);
    expect(retry()?.title).toBe(STOPPED);
    expect(document.querySelector(".session-head .controls .pill")?.textContent).toContain("Stopped");

    session.log.append("input_after_done", { source: "user" });
    const note = await waitFor(() => notes().find((n) => n.textContent === NOT_TAKEN), "the not-taken note");
    expect(note.classList.contains("error")).toBe(true);
    expect(notes().some((n) => /picked/.test(n.textContent ?? ""))).toBe(false);
  });

  it("keeps the composer after the agent finished, and says it picked the conversation up when woken", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    session.log.append("agent_done", { reason: "finished" });
    await waitFor(() => document.querySelector(".session-head .controls .pill")?.textContent?.includes("Finished"), "the finished pill");
    expect(composer()).not.toBeNull();
    expect(document.querySelector(".instead.stopped")).toBeNull();

    session.log.append("agent_woken", { from: "finished", source: "user" });
    await waitFor(() => notes().find((n) => n.textContent === "the agent had finished; new input picked the conversation back up"), "the woken note");
    expect(composer()).not.toBeNull();
  });

  it("keeps the composer after a model error, which the next message retries", async () => {
    const session = daemon.seed(WORKSPACE);
    await open(session);
    session.log.append("llm_error", { reason: "the provider timed out" });
    await waitFor(() => notes().find((n) => n.textContent?.includes("the provider timed out")), "the model error");
    expect(composer()).not.toBeNull();
    expect(document.querySelector(".instead.stopped")).toBeNull();
  });
});
