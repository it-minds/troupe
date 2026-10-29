// A prompt that draws nothing: the composer's hint says, from 10 s after a prompt with no
// model request, that the daemon has not sent it, and from 20 s after the request with
// nothing streaming, that the model has sent nothing back; the first byte takes the line
// away. The fake daemon holds the events back, and the clock is moved by hand.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { render, says, sees, startOnTheList, waitFor } from "./support";

type Session = ReturnType<FakeDaemon["seed"]>;

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;
const real = Date.now;
let skew = 0;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  skew = 0;
  vi.spyOn(Date, "now").mockImplementation(() => real() + skew);
});

afterEach(async () => {
  vi.restoreAllMocks();
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

async function open(session: Session): Promise<void> {
  unmount = render(<App />).unmount;
  const row = await waitFor(() => document.querySelector<HTMLButtonElement>("button.row"), "the session in the list");
  row.click();
  await waitFor(() => daemon.calls.some((c) => c.method === "presence.set"), "the session to be open");
}

const prompt = (session: Session): void => {
  session.log.append("user_input", { source: "user", text: "fix the parser" }, { kind: "user", subject: "ada" });
};

describe("a prompt that draws nothing", () => {
  it("says the daemon has not sent the request from 10 s, until the request goes", async () => {
    const session = daemon.seed("/home/ada/parser");
    await open(session);
    prompt(session);
    await sees("fix the parser");
    expect(says("has not sent the model request")).toBe(false);

    skew = 12_000;
    await sees("the daemon has not sent the model request yet (00:1");

    session.log.append("llm_request", { model: "claude" });
    daemon.ephemeral(session, "agent_state", { state: "thinking" });
    await waitFor(() => !says("has not sent the model request"), "the request to be sent");
  });

  it("says nothing is back from 20 s after the request, until the first byte", async () => {
    const session = daemon.seed("/home/ada/parser");
    await open(session);
    prompt(session);
    await sees("fix the parser");
    session.log.append("llm_request", { model: "claude" });
    daemon.ephemeral(session, "agent_state", { state: "thinking" });
    await sees("The session is working.");
    expect(says("nothing back yet")).toBe(false);

    skew = 25_000;
    await sees("waiting on the model (00:2");
    expect(says("has not sent the model request")).toBe(false);

    daemon.ephemeral(session, "llm_delta", { kind: "text", text: "On it." });
    await waitFor(() => !says("nothing back yet"), "the first byte");
    await sees("The session is working.");
  });

  it("says nothing of a turn that ended, or one waiting on a person", async () => {
    const session = daemon.seed("/home/ada/parser");
    await open(session);
    prompt(session);
    await sees("fix the parser");
    session.log.append("llm_request", { model: "claude" });
    daemon.ephemeral(session, "agent_state", { state: "thinking" });
    session.log.append("llm_error", { reason: "no key" });
    session.log.append("turn_ended", { reason: "llm_error" });
    daemon.ephemeral(session, "agent_state", { state: "idle" });
    await sees("model error: no key");

    skew = 60_000;
    await sees("Enter sends");
    expect(says("nothing back yet")).toBe(false);
    expect(says("has not sent the model request")).toBe(false);
  });
});
