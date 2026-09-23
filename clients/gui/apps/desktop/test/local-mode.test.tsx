// Local-only mode, end to end: the app rendered, a daemon on a real socket, and every
// request the page makes written down.
//
// The claim under test is the one the mode exists for — in local mode nothing leaves
// the machine but the daemon's own call to the model provider — so the assertion is on
// the page's traffic, not on which functions were called. The daemon is the fake the
// client's own tests use (`packages/client/test/support/daemon.ts`), which speaks the
// protocol on a WebSocket; the plane, where there is one, is the fake deployment.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, externalResources, nav, recordNetwork, render, says, sleep, type, waitFor } from "./support";
import type { Recorder } from "./support";

// jsdom lays nothing out, so it has nothing to scroll; the transcript asks anyway.
Element.prototype.scrollIntoView = function scrollIntoView() {};
// The page's WebSocket. jsdom's and Node's are both undici's, which builds its events
// from the global `Event` — jsdom's, in this environment — and Node's own EventTarget
// then refuses them. `ws` brings its own events and the same browser-shaped API.
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const STORED_PLANE = "https://plane.example.test";
const STORED_TOKEN_KEY = `troupe.auth.refresh:${STORED_PLANE}`;

let daemon: FakeDaemon;
let net: Recorder | null = null;
let unmount: (() => void) | null = null;
let harness: Harness | null = null;

function daemonUrl(): string {
  return `ws://127.0.0.1:${daemon.port}/v1/socket`;
}

/** Everything the page asked for that was not the daemon. */
function notTheDaemon(): string[] {
  return (net?.requests ?? []).filter((r) => r.url !== daemonUrl()).map((r) => `${r.via} ${r.url}`);
}

function refreshTokenFor(planeUrl: string): string | null {
  return localStorage.getItem(`troupe.auth.refresh:${planeUrl}`);
}

beforeEach(async () => {
  localStorage.clear();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  daemon.seed("/home/ada/notes");
  // How a browser build is told where the daemon is: the `#daemon=` a developer pastes,
  // and what `pnpm dev:local` fills in. A desktop shell reads `daemon.json` instead.
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  net?.restore();
  net = null;
  location.hash = "";
  await daemon.stop();
  await harness?.stop();
  harness = null;
});

describe("local-only mode", () => {
  it("makes no request to any plane, with a plane sign-in stored and every screen visited", async () => {
    localStorage.setItem("troupe.pref.localOnly", "yes");
    localStorage.setItem("troupe.pref.planeUrl", STORED_PLANE);
    localStorage.setItem(STORED_TOKEN_KEY, "a-stored-refresh-token");
    net = recordNetwork();
    unmount = render(<App />).unmount;

    // Straight to the list: no sign-in, no restore, and the machine's user named.
    await waitFor(() => says("/home/ada/notes"), "the daemon's session in the list");
    expect(says("Use this computer only")).toBe(false);
    expect(document.querySelector(".me .name")?.textContent).toBe("This computer");
    await waitFor(() => document.querySelector(".me")?.textContent?.includes("ada"), "the operating system's user in the rail");
    // The plane's screens are not offered.
    expect(nav("Review")).toBeNull();

    // Start a session here, say something, and read the answer.
    button("Start a session")!.click();
    const dialog = await waitFor(() => document.querySelector<HTMLElement>(".dialog"), "the start dialog");
    expect(says("On the platform")).toBe(false);
    type(dialog.querySelector<HTMLInputElement>("input")!, "/home/ada/project");
    button("Start", dialog)!.click();
    const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the session");
    const created = [...daemon.sessions.values()].find((s) => s.workspace === "/home/ada/project")!;
    type(composer, "hello");
    button("Send")!.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "input.send" && c.params["text"] === "hello"), "the message to reach the daemon");
    daemon.say(created.id, "Hello from the model, by way of the daemon.");
    await waitFor(() => says("Hello from the model, by way of the daemon."), "the answer");
    expect(document.querySelector('select[aria-label="Profile"]')).toBeNull();

    // And every other screen, long enough for the list to poll again.
    for (const screen of ["Waiting for you", "This computer", "Appearance", "Sessions"]) {
      nav(screen)!.click();
      await sleep(150);
    }
    nav("This computer")!.click();
    await waitFor(() => says("Settings file"), "the model settings, read from the daemon");
    await waitFor(() => says("recorded as ada"), "who the daemon records");
    await sleep(4_500);

    expect(net.requests.length).toBeGreaterThan(0);
    expect(notTheDaemon()).toEqual([]);
    expect(externalResources()).toEqual([]);
    // Kept, not used and not thrown away.
    expect(localStorage.getItem(STORED_TOKEN_KEY)).toBe("a-stored-refresh-token");
  });

  it("is the third door on the sign-in screen, and the next launch remembers it", async () => {
    net = recordNetwork();
    let app = render(<App />);
    unmount = app.unmount;

    const door = await waitFor(() => button("Use this computer only"), "the third door");
    door.click();
    await waitFor(() => says("/home/ada/notes"), "the session list, with no sign-in");
    expect(localStorage.getItem("troupe.pref.localOnly")).toBe("yes");

    // A relaunch: no sign-in screen at all, not even for a moment.
    app.unmount();
    app = render(<App />);
    unmount = app.unmount;
    expect(button("Use this computer only")).toBeNull();
    await waitFor(() => says("/home/ada/notes"), "the session list again");

    expect(notTheDaemon()).toEqual([]);
  });
});

describe("switching local-only off and on", () => {
  it("keeps the stored plane sign-in, and goes back to it without asking", async () => {
    harness = await startHarness();
    const plane = harness.plane.baseUrl;
    // Its own id: both fakes count from s-1, and the one list joins rows that share one.
    harness.plane.seed("alice@example.com", { id: "team-1", title: "Rewrite the placement loop", profile: "dev" });
    // Signed in once, before: the refresh token is in this browser's store, where the
    // app keeps it, and the theme question has been answered.
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", plane);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
    const first = refreshTokenFor(plane);
    expect(first).toBeTruthy();

    net = recordNetwork();
    unmount = render(<App />).unmount;

    // Plane mode: signed back in from the store, both halves of the list.
    await waitFor(() => says("Rewrite the placement loop") && says("/home/ada/notes"), "the team's session and this computer's");
    expect(document.querySelector(".me .name")?.textContent).toBe("Alice");
    // The recorder sees a plane when there is one to see.
    expect(net.requests.some((r) => r.url.startsWith(plane))).toBe(true);

    nav("This computer")!.click();
    const toggle = await waitFor(
      () => [...document.querySelectorAll<HTMLInputElement>('input[type="checkbox"]')].find((i) => i.parentElement?.textContent?.includes("never contact a plane")),
      "the local-only switch",
    );
    toggle.click();
    await waitFor(() => document.querySelector(".me .name")?.textContent === "This computer", "local mode");
    const kept = refreshTokenFor(plane);
    expect(kept).toBeTruthy();

    // Local now: the team's session is gone from the list, and the plane hears nothing.
    net.clear();
    nav("Sessions")!.click();
    await waitFor(() => says("/home/ada/notes") && !says("Rewrite the placement loop"), "this computer's sessions alone");
    expect(nav("Review")).toBeNull();
    await sleep(4_500);
    expect(notTheDaemon()).toEqual([]);
    expect(refreshTokenFor(plane)).toBe(kept);

    // Off again: straight back in, with no device code and no provider page.
    nav("This computer")!.click();
    const again = await waitFor(
      () => [...document.querySelectorAll<HTMLInputElement>('input[type="checkbox"]')].find((i) => i.parentElement?.textContent?.includes("never contact a plane")),
      "the switch",
    );
    again.click();
    await waitFor(() => document.querySelector(".me .name")?.textContent === "Alice", "signed back in");
    expect(document.querySelector(".usercode")).toBeNull();
    nav("Sessions")!.click();
    await waitFor(() => says("Rewrite the placement loop") && says("/home/ada/notes"), "both halves of the list again");
    // The stored token was spent and rotated: it was the one kept, not a new sign-in.
    expect(refreshTokenFor(plane)).not.toBe(kept);
    expect(localStorage.getItem("troupe.pref.localOnly")).toBe("no");
  });
});

describe("a plane that does not answer", () => {
  it("offers this computer instead of a dead sign-in, and goes back when the plane does", async () => {
    harness = await startHarness();
    const plane = harness.plane.baseUrl;
    // Its own id: both fakes count from s-1, and the one list joins rows that share one.
    harness.plane.seed("alice@example.com", { id: "team-1", title: "Rewrite the placement loop", profile: "dev" });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", plane);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");

    let down = true;
    net = recordNetwork({ refuse: (url) => down && url.startsWith(plane) });
    unmount = render(<App />).unmount;

    const carryOn = await waitFor(() => button("Continue on this computer"), "the way out");
    expect(refreshTokenFor(plane)).toBeTruthy();
    carryOn.click();
    await waitFor(() => says("/home/ada/notes"), "this computer's sessions");
    expect(says("The platform is not answering")).toBe(true);
    // Offline is not the setting: nothing about it is remembered.
    expect(localStorage.getItem("troupe.pref.localOnly")).toBeNull();

    // The plane comes back.
    down = false;
    button("Try now")!.click();
    await waitFor(() => document.querySelector(".me .name")?.textContent === "Alice", "signed back in");
    await waitFor(() => says("Rewrite the placement loop") && says("/home/ada/notes"), "the team's sessions beside this computer's");
    expect(says("The platform is not answering")).toBe(false);
  });
});
