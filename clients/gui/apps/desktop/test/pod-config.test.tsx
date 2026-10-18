// A team session says what is in force in it on its pod (troupe #655's follow-up): its
// Settings pane asks the pod `config.get` naming the session, over the session's own
// connection, and lists each key something set and each rule with where it came from — the
// worker profile, the platform, the session's terms, the repository's file — and offers
// nothing to change. A session on this computer has no such pane: its settings are the
// computer's, which the settings screens show.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, sees, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let harness: Harness;
let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  harness = await startHarness();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await harness.stop();
  await daemon.stop();
});

const backstage = (): HTMLElement => document.querySelector<HTMLElement>(".backstage")!;

describe("a team session's settings", () => {
  it("are what is in force on its pod, each with where it came from, and nothing to change", async () => {
    const plane = harness.plane;
    plane.seed("alice@example.com", { id: "team-1", title: "Plan the release", profile: "dev" });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");

    unmount = render(<App />).unmount;
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Plan the release")),
      "the team session's row",
    );
    row.click();
    (await waitFor(() => document.querySelector(".backstage") && button("Settings", backstage()), "the Settings tab")).click();

    await sees("In force in this session on its pod");
    const pane = (): HTMLElement => backstage();
    await sees("the worker profile dev (TROUPE_MODEL)");
    await sees("the session's terms");
    await sees("set by your organisation");
    await sees("this project's .troupe/config.yaml");
    await sees("shell(curl)");
    await sees("the worker profile");

    // What nobody set is the default, and not listed.
    expect(pane().textContent).not.toContain("max_depth");
    // Nothing on it changes anything.
    expect(pane().querySelectorAll("input, select, textarea")).toHaveLength(0);
  });
});

describe("a session on this computer", () => {
  it("has no settings pane: its settings are the computer's", async () => {
    daemon.seed("/home/alice/notes");
    localStorage.setItem("troupe.pref.localOnly", "yes");
    unmount = render(<App />).unmount;
    await sees("/home/alice/notes");
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/alice/notes")),
      "the session's row",
    );
    row.click();
    await waitFor(() => document.querySelector(".backstage") && button("Files", backstage()), "the session's panes");
    expect(button("Settings", backstage())).toBeNull();
  });
});
