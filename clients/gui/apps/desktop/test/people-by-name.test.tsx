// People by name in the transcript (troupe #931): another person's words carry their
// initials and their name where the event's actor names them, and their subject where an
// older server sent no name; your own stay unnamed.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { render, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;

const WORKSPACE = "/home/ada/people";
const me = { kind: "user", subject: "alice@example.com" };

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  delete (window as { troupe?: unknown }).troupe;
  await harness?.stop();
  harness = null;
  await daemon.stop();
});

async function open(): Promise<ReturnType<FakeDaemon["seed"]>> {
  const session = daemon.seed(WORKSPACE);
  harness = await startHarness();
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  unmount = render(<App />).unmount;
  const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(WORKSPACE)), "the session in the list");
  row.click();
  await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session");
  await waitFor(() => daemon.calls.some((c) => c.method === "session.loop.get"), "the screen attached");
  return session;
}

/** Each person's line as drawn: its ring, its name, and its words. */
function lines(): Array<{ ring: string | null; name: string | null; body: string | null; self: boolean }> {
  return [...document.querySelectorAll<HTMLElement>(".turn.person")].map((t) => ({
    ring: t.querySelector(".byline .ring")?.textContent ?? null,
    name: t.querySelector(".byline .name")?.textContent ?? null,
    body: t.querySelector(".body")?.textContent ?? null,
    self: t.classList.contains("self"),
  }));
}

describe("a person's line in the transcript", () => {
  it("carries the initials and the name the actor names, the subject without one, and nothing for your own", async () => {
    const session = await open();
    session.log.append("user_input", { source: "user", text: "mine" }, me);
    session.log.append("user_input", { source: "user", text: "named" }, { kind: "user", subject: "idp|7f3a", display_name: "Bob Example" });
    session.log.append("user_input", { source: "user", text: "unnamed" }, { kind: "user", subject: "carol@example.com" });

    await waitFor(() => lines().length === 3, "the three lines");
    expect(lines()).toEqual([
      { ring: null, name: null, body: "mine", self: true },
      { ring: "BE", name: "Bob Example", body: "named", self: false },
      { ring: "CA", name: "carol@example.com", body: "unnamed", self: false },
    ]);
  });
});
