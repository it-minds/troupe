// The divider over a session's first event (troupe #929): "CURTAIN UP" and the local time
// the session began, from the time its first event was written; the plain words where
// that event carries none.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { curtainUp } from "../src/frames";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { render, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const WORKSPACE = "/home/ada/notes";
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

describe("the curtain's divider", () => {
  it("says the local time the session began, with the day in front when it was not today", () => {
    const began = new Date(2026, 10, 15, 18, 54, 3);
    expect(curtainUp(began.getTime(), new Date(2026, 10, 15, 21, 0))).toBe("CURTAIN UP · 18:54");
    const earlier = curtainUp(new Date(2026, 10, 12, 9, 5).getTime(), new Date(2026, 10, 15, 21, 0));
    expect(earlier).toMatch(/^CURTAIN UP · .*12.* 09:05$/);
    expect(curtainUp(undefined)).toBe("CURTAIN UP");
    expect(curtainUp(Number.NaN)).toBe("CURTAIN UP");
  });

  it("is drawn over the session's first event with the time that event was written", async () => {
    const session = daemon.seed(WORKSPACE);
    const first = session.log.events[0]!;
    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(WORKSPACE)), "the session in the list");
    row.click();
    const divider = await waitFor(() => document.querySelector<HTMLElement>(".stream .divider"), "the divider");
    expect(divider.textContent).toBe(curtainUp(Date.parse(first.ts)));
    expect(divider.textContent).toMatch(/^CURTAIN UP · \d\d:\d\d$/);
  });
});
