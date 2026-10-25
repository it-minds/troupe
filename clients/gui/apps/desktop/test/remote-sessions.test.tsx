// Steering a laptop's session from another device, through the plane (troupe #58). On this computer: a local session's head offers it to the plane, shared
// with the people named, says it is offered and takes it back. From another computer: the
// list has it as Remote, says since when one whose laptop is away has been, and opening
// an online one steers it like any session: a prompt goes, and the head says whose laptop.
// The fake plane's worker stands in for the laptop, as the plane's relay would.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { RESTART_SENTENCE, webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, sees, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  harness = await startHarness();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
  await harness.stop();
});

async function signedIn(): Promise<void> {
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  startOnTheList();
}

const row = (text: string): HTMLButtonElement | undefined =>
  [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(text));

describe("a laptop's session, from another computer", () => {
  it("is listed as Remote, an away laptop's says since when, and an online one is steered", async () => {
    harness.plane.relay("ada@example.com", { id: "s-laptop-on", ownerName: "Ada", workspace: "billing", shares: [{ subject: "alice@example.com", role: "control" }] });
    const away = harness.plane.relay("ada@example.com", { id: "s-laptop-away", ownerName: "Ada", workspace: "archive", shares: [{ subject: "alice@example.com", role: "control" }] });
    harness.plane.offline(away.id, "2026-10-18T07:30:00Z");
    await signedIn();

    unmount = render(<App />).unmount;
    const online = await waitFor(() => row("billing"), "the relayed session's row");
    await waitFor(() => online.querySelector(".pill")?.textContent === "Remote", "the Remote pill");
    await waitFor(() => row("archive")?.textContent?.includes("Offline since"), "the away laptop's line");

    online.click();
    await sees("On Ada's laptop · Online");
    const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the composer");
    type(composer, "ship the invoice fix");
    button("Send")!.click();

    const sent = await waitFor(
      () => harness.worker.calls.find((c) => c.method === "input.send" && c.params["session_id"] === "s-laptop-on"),
      "the prompt at the laptop",
    );
    expect(sent.params["text"]).toBe("ship the invoice fix");

    // An approval from here is for the one call: allowing for the session is the laptop's.
    await sees("You said: ship the invoice fix");
    const again = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the composer");
    type(again, "approve: rm -rf build");
    (await waitFor(() => button("Send"), "the send button")).click();
    const panel = await waitFor(() => document.querySelector<HTMLElement>("section.approval:not(.answered)"), "the approval");
    const allow = await waitFor(() => button("Allow", panel), "the allow button");
    // at once: drawn with its buttons, the scoped one is not among them
    expect(panel.querySelector("button.scoped")).toBeNull();
    // As the console and the terminal say it: once.
    expect(allow.textContent).toBe("Allow once");
    allow.click();
    const decided = await waitFor(() => harness.worker.calls.find((c) => c.method === "approval.respond"), "the answer at the laptop");
    expect(decided.params["decision"]).toBe("allow");
  });

  it("says the laptop is offline, and since when, when it is opened while away", async () => {
    const away = harness.plane.relay("ada@example.com", { id: "s-laptop-gone", ownerName: "Ada", workspace: "drafts", shares: [{ subject: "alice@example.com", role: "observe" }] });
    harness.plane.offline(away.id, new Date().toISOString());
    await signedIn();

    unmount = render(<App />).unmount;
    (await waitFor(() => row("drafts"), "the away laptop's row")).click();
    await sees("The laptop is offline since");
  });
});

/** How long news may take to show: a push's, nowhere near the fleet's poll. */
// Well under the 4 s a poll would take, and wide enough for a loaded runner: the proof that
// a change was pushed is that `remote.list` was not asked again, not the clock.
const PUSHED_MS = 3_000;

describe("the list follows the plane as it changes", () => {
  it("an offer made on a laptop shows within a second, from the plane's push and not a poll, and its withdrawal too", async () => {
    await signedIn();
    unmount = render(<App />).unmount;
    await waitFor(() => harness.plane.watches.size === 1, "the desktop's watch on the plane");
    const asked = (): number => harness.plane.asked.filter((m) => m === "remote.list").length;
    const before = asked();

    const at = Date.now();
    harness.plane.relay("ada@example.com", { id: "s-laptop-new", ownerName: "Ada", workspace: "ledger", shares: [{ subject: "alice@example.com", role: "control" }] });
    await waitFor(() => row("ledger"), "the new offer, pushed", PUSHED_MS);
    expect(Date.now() - at).toBeLessThan(PUSHED_MS);

    harness.plane.offline("s-laptop-new");
    await waitFor(() => row("ledger")?.textContent?.includes("Offline since"), "the laptop gone, pushed", PUSHED_MS);

    harness.plane.withdraw("s-laptop-new");
    await waitFor(() => !row("ledger"), "the withdrawal, pushed", PUSHED_MS);
    expect(asked(), "remote.list was asked again rather than told").toBe(before);
  });
});

describe("this computer's own session", () => {
  it("names who is steering it from another device as they come and go, from its presence", async () => {
    const shop = daemon.seed("/home/alice/shop");
    await signedIn();
    unmount = render(<App />).unmount;
    (await waitFor(() => row("/home/alice/shop"), "the local session's row")).click();
    (await waitFor(() => button("Steer from elsewhere"), "the offer in the head")).click();
    type(await waitFor(() => document.querySelector<HTMLInputElement>(".remote-share input"), "the share field"), "bea@example.com");
    button("Offer it")!.click();
    await sees("Offered · Online");
    await waitFor(() => daemon.calls.some((c) => c.method === "subscribe" && c.params["topic"] === `presence:${shop.id}`), "the session's presence followed");

    const at = Date.now();
    daemon.present(shop.id, { subject: "bea@example.com", display_name: "Bea", state: "joined", via: "plane" });
    await waitFor(() => document.querySelector(".remote-offer .steering")?.textContent === "Bea is steering from another device", "Bea, steering", PUSHED_MS);
    expect(Date.now() - at).toBeLessThan(PUSHED_MS);

    daemon.present(shop.id, { subject: "bea@example.com", display_name: "Bea", state: "left", via: "plane" });
    await waitFor(() => !document.querySelector(".remote-offer .steering"), "Bea gone", PUSHED_MS);
  });

  it("is offered to the plane from its head, shared with the people named, and withdrawn", async () => {
    daemon.seed("/home/alice/shop");
    await signedIn();

    unmount = render(<App />).unmount;
    (await waitFor(() => row("/home/alice/shop"), "the local session's row")).click();
    (await waitFor(() => button("Steer from elsewhere"), "the offer in the head")).click();

    const share = await waitFor(() => document.querySelector<HTMLInputElement>(".remote-share input"), "the share field");
    type(share, "bea@example.com, cy@example.com");
    button("Offer it")!.click();

    await sees("Offered · Online");
    const offered = daemon.calls.find((c) => c.method === "remote.offer")!;
    expect(offered.params["share"]).toEqual([
      { person: "bea@example.com", role: "control" },
      { person: "cy@example.com", role: "control" },
    ]);

    button("Withdraw")!.click();
    await waitFor(() => button("Steer from elsewhere"), "the offer taken back");
    expect(daemon.calls.some((c) => c.method === "remote.withdraw")).toBe(true);
  });

  it("says once that an offer lasts until this machine restarts, with the command, and says one a restart brought back", async () => {
    const shop = daemon.seed("/home/alice/shop");
    await signedIn();
    unmount = render(<App />).unmount;
    (await waitFor(() => row("/home/alice/shop"), "the local session's row")).click();
    (await waitFor(() => button("Steer from elsewhere"), "the offer in the head")).click();
    (await waitFor(() => button("Offer it"), "the offer's form")).click();

    // Nothing starts the daemon at login here: the pill says so, and the sentence the
    // terminal says once, with the command, is said as the offer is made.
    await sees("Offered · Online · until this machine restarts");
    await sees(RESTART_SENTENCE);

    // The daemon started at login and restarted: the listing says the offer came back.
    daemon.atLogin = true;
    shop.remote = { ...shop.remote!, lasts: "across_restarts", restored: true };
    await waitFor(
      () => document.querySelector(".remote-offer .pill")?.textContent === "Offered · Online · back after a restart",
      "the offer back after a restart",
      15_000,
    );
  });
});
