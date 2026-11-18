// A session whose log its agent cannot read (troupe #1053). A message cannot wake it:
// the daemon answers what the agent raised, marked `repairable`. The composer gives way to
// the offer to wake it anyway, which skips the event, sends the message, and the
// transcript says where the event was skipped.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, sessionOpener, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const RAISED = '** (Protocol.UndefinedError) protocol Enumerable not implemented for "not a list"';

let daemon: FakeDaemon;
const page = sessionOpener(() => daemon);

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  page.close();
  location.hash = "";
  await daemon.stop();
});

describe("a session whose log its agent cannot read", () => {
  it("offers to wake it anyway, which skips the event, sends the message, and says where", async () => {
    startOnTheList();
    const session = daemon.seed("/home/ada/ledger");
    daemon.say(session.id, "Copied the ledger table.");
    daemon.unreadable(session.id, RAISED);

    const composer = await page.open("/home/ada/ledger");
    type(composer, "check the counts");
    composer.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    const offer = await waitFor(() => document.querySelector(".instead.stopped"), "the offer in the composer's place");
    expect(offer.textContent).toContain(`The agent could not start from this session's log: ${RAISED}`);
    expect(document.querySelector('textarea[aria-label="Message"]')).toBeNull();

    button("Wake it anyway")!.click();

    await waitFor(() => daemon.calls.some((c) => c.method === "session.repair"), "the wake past the event");
    const note = await waitFor(
      () => [...document.querySelectorAll(".stream .note")].find((p) => p.textContent?.includes("could not be read and was skipped")),
      "the line where the event was",
    );
    expect(note.textContent).toMatch(/^An event from .+ could not be read and was skipped$/);
    await waitFor(
      () => daemon.calls.filter((c) => c.method === "input.send" && c.params["text"] === "check the counts").length === 2,
      "the message sent again once the session is awake",
    );
    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the composer back");
  });
});
