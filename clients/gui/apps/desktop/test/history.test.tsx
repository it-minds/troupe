// A session opened from the list shows what it said before: the replay `subscribe` sends.
// The fake daemon answers `subscribe` and replays the log in one go, and Node's `ws`
// hands both to the page in the same turn, before `DaemonClient.open` has resolved; the
// screen takes the stream from the start, so it sees the history either way.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { render, says, startOnTheList, waitFor } from "./support";

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

describe("a session with a history", () => {
  it("shows what was said before it was opened", async () => {
    const session = daemon.seed("/home/ada/kunder");
    session.log.append("user_input", { source: "user", text: "What changed in the invoices?" }, { kind: "user", subject: "local:ada" });
    daemon.say(session.id, "Two templates, and the VAT line moved.");
    session.log.append("turn_ended", {});

    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/ada/kunder")), "the row");
    row.click();

    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session");
    await waitFor(() => says("Two templates, and the VAT line moved."), "the replayed answer");
    expect(says("What changed in the invoices?")).toBe(true);
    // Once each: the replay is folded by one listener, not by a late one as well.
    expect(document.body.textContent!.split("Two templates, and the VAT line moved.").length).toBe(2);
  });
});
