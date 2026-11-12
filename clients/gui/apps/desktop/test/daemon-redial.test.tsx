// A daemon the app failed to reach at its first dial is dialled again by itself: the first
// `identity.get` loses its answer (the socket closes in its place, as a daemon still
// starting or restarting does), the status says the daemon is not answering, and the next
// try, with nobody pressing Find, connects. A daemon the person disconnected is not dialled again.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { redialTiming } from "../src/hooks";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { nav, render, sees, sleep, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const timing = { ...redialTiming };
let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  // On this computer alone, so nothing waits on a plane.
  localStorage.setItem("troupe.pref.localOnly", "yes");
  Object.assign(redialTiming, { firstMs: 300, firstForMs: 60_000, thenMs: 300 });
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  Object.assign(redialTiming, timing);
  await daemon.stop();
});

const identityAsked = (): number => daemon.calls.filter((c) => c.method === "identity.get").length;

describe("a daemon not reached at the first dial", () => {
  it("is dialled again by itself, and the status goes from not answering to connected", async () => {
    daemon.loseReply["identity.get"] = "drop";
    unmount = render(<App />).unmount;
    (await waitFor(() => nav("This computer"), "the rail")).click();
    await sees("Not answering");
    await sees("Connected");
    expect(identityAsked()).toBeGreaterThanOrEqual(2);
  });

  it("is not dialled again once the person disconnected it", async () => {
    unmount = render(<App />).unmount;
    (await waitFor(() => nav("This computer"), "the rail")).click();
    await sees("Connected");
    const forget = await waitFor(() => [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === "Disconnect") ?? null, "Disconnect");
    forget.click();
    const asked = identityAsked();
    await sleep(1_000);
    expect(identityAsked()).toBe(asked);
  });
});
