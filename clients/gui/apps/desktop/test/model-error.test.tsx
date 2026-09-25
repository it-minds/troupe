// A session on this computer whose model cannot be asked: the transcript says where the
// model settings are, because on a first run with no key that is the one thing to do and
// the desktop app is the only client a person may have. The daemon is the fake the
// client's own tests use, with the model error written into the session's log.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { render, says, waitFor } from "./support";

// jsdom lays nothing out, so it has nothing to scroll; the transcript asks anyway.
Element.prototype.scrollIntoView = function scrollIntoView() {};
// The page's WebSocket: see local-mode.test.tsx.
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

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

async function open(reason: string): Promise<void> {
  const session = daemon.seed("/home/ada/project");
  unmount = render(<App />).unmount;
  const row = await waitFor(() => document.querySelector<HTMLButtonElement>("button.row"), "the session in the list");
  row.click();
  // The view says it is here once it listens; the error is the first request's, after that.
  await waitFor(() => daemon.calls.some((c) => c.method === "presence.set"), "the session to be open");
  session.log.append("llm_error", { reason });
  await waitFor(() => says(`model error: ${reason}`), "the model error");
}

describe("a model error in a session on this computer", () => {
  it("with no key, says where the model settings are", async () => {
    await open("no API key is configured for the provider");
    expect(says("Set up a provider on This computer, under Models.")).toBe(true);
  });

  it("with a key the provider refused, says where to check it", async () => {
    await open("the provider rejected the credentials (invalid x-api-key)");
    expect(says("Check the key on This computer, under Models.")).toBe(true);
  });

  it("of any other kind, adds nothing", async () => {
    await open("the model did not answer in time");
    expect(says("This computer, under Models")).toBe(false);
  });
});
