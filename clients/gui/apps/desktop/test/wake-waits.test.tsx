// A session woken on a full profile waits for a place as a new one does (troupe #1149):
// its screen says so in the new-session screen's words, and once the plane has placed it
// the session is live. The app rendered, the fakes on real sockets.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let unmount: (() => void) | null = null;

const entry = (text: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === text);
const banner = (): HTMLElement | null => document.querySelector<HTMLElement>(".banner.queued");
const onTheList = (): boolean => Boolean(document.querySelector(".toolbar input.search"));

describe("a session woken on a full profile", () => {
  let harness: Harness;

  beforeEach(async () => {
    localStorage.clear();
    startOnTheList();
    harness = await startHarness();
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  });

  afterEach(async () => {
    unmount?.();
    unmount = null;
    location.hash = "";
    delete window.troupe;
    await harness.stop();
  });

  async function signIn(): Promise<void> {
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
    await waitFor(() => document.querySelector(".usercode"), "the code to enter");
    harness.idp.approve("ada@example.com", "Ada");
    await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
    button("Continue")!.click();
    await waitFor(onTheList, "the session list");
  }

  it("says it waits for a free place in its profile, asks again, and is live once placed", async () => {
    const asleep = harness.plane.seed("ada@example.com", { title: "Rewrite the placement loop", profile: "dev" });
    asleep.state = "dormant";
    harness.plane.setRoom("dev", { capacity: 1, active: 1 });
    await signIn();

    (await waitFor(() => entry("Rewrite the placement loop")?.querySelector<HTMLButtonElement>("button.row"), "the row")).click();
    const waiting = await waitFor(banner, "the wait for a place");
    expect(waiting.textContent).toContain("Waiting for a free place in dev. It wakes by itself when one frees.");
    expect(waiting.textContent).toContain("waiting for a free place on dev");
    // Not the asleep banner beside it: the session is coming up, not sleeping.
    expect(document.querySelector(".banner.dormant")).toBeNull();

    await waitFor(() => harness.plane.mints.includes(asleep.id), "a second ask while it waits");
    harness.plane.placeWaiting(asleep.id);
    await waitFor(() => banner() === null, "the wait over");
    expect(document.querySelector(".banner.error")).toBeNull();
  });
});
