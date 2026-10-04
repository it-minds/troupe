// The plane token the daemon seals a private session with (issue #365). The daemon signs
// nobody in, so it registers and seals a private session only with a token the signed-in
// app hands it with `identity.link`, which it holds in memory: the app hands it over when
// it links, again when its token is renewed, and again when the daemon has restarted. The
// app rendered, signed in to a fake deployment whose plane tokens last a little over the
// two minutes the app renews them before, and the fake daemon on a real socket.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, says, sleep, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

/** Long enough for the list's poll, every four seconds, to renew a token or dial again. */
const POLL_MS = 15_000;

let daemon: FakeDaemon;
let harness: Harness;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  // As a daemon nobody had linked when the app connected says it: no private sessions.
  daemon = new FakeDaemon({ osUser: "ada", capabilities: { blobs: true, tools: true, private_sessions: false } });
  await daemon.start();
  daemon.seed("/home/ada/notes");
  // A plane token good for five seconds past the app's renewal margin.
  harness = await startHarness({ plane: { planeTokenLifetime: 125 } });
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  startOnTheList();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  delete window.troupe;
  await daemon.stop();
  await harness.stop();
});

/** The daemon on this computer, linked to the person signed in here, at this plane. */
function linkedToAlice(): void {
  daemon.linked = { subject: "alice@example.com", display_name: "Alice", plane_url: harness.plane.baseUrl };
}

/** Whether the plane honours a token: `me` with it, as the daemon's calls would be made. */
async function honoured(token: string | null): Promise<boolean> {
  if (!token) return false;
  const answer = await fetch(`${harness.plane.baseUrl}/rpc`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "me", params: {} }),
  });
  return answer.status === 200;
}

function goToThisComputer(): void {
  const settings = [...document.querySelectorAll<HTMLButtonElement>(".rail button")].find((b) => b.textContent?.includes("This computer"));
  settings!.click();
}

describe("a daemon linked to the person signed in here", () => {
  it("is handed the plane token when the app connects, and the renewed one when it is renewed", async () => {
    linkedToAlice();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;

    await waitFor(() => daemon.planeToken, "the plane token handed to the daemon");
    const first = daemon.planeToken;
    expect(await honoured(first)).toBe(true);
    // The link is the person's own, as it was: the token changes nothing about the label.
    expect(daemon.linked).toMatchObject({ subject: "alice@example.com", plane_url: harness.plane.baseUrl });

    // The app renews its token two minutes before it runs out, and hands the daemon the new one.
    await waitFor(() => daemon.planeToken !== first && daemon.planeToken, "the renewed token handed over", POLL_MS);
    expect(await honoured(daemon.planeToken)).toBe(true);
    expect(new Set(daemon.planeTokens).size).toBeGreaterThanOrEqual(2);
  });

  it("is handed it again once it has restarted, which leaves it with none", async () => {
    linkedToAlice();
    window.troupe = { name: "Test shell", version: "0", findDaemon: async () => daemon.published, readDaemon: async () => daemon.published };
    unmount = render(<App />).unmount;
    await waitFor(() => daemon.planeToken, "the plane token handed to the daemon");

    await daemon.restart();
    expect(daemon.planeToken).toBeNull();
    await waitFor(() => daemon.planeToken, "the token handed to the restarted daemon", POLL_MS);
    expect(await honoured(daemon.planeToken)).toBe(true);
  });

  it("is not handed anything when it is linked to somebody else", async () => {
    daemon.linked = { subject: "bob@example.com", display_name: "Bob", plane_url: harness.plane.baseUrl };
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    await waitFor(() => says("/home/ada/notes"), "the daemon's sessions in the list");
    await sleep(500);
    expect(daemon.planeTokens).toEqual([]);
    expect(daemon.linked?.subject).toBe("bob@example.com");
  });
});

// Issue #381: signing out takes the token back, where it is the person's at this plane, and
// the daemon seals nothing until somebody signs in again. The link is the person's choice
// on This computer and stays.
describe("signing out", () => {
  it("takes the plane token back from a daemon linked to the person, which stays linked", async () => {
    linkedToAlice();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    await waitFor(() => daemon.planeToken, "the plane token handed to the daemon");

    (await waitFor(() => button("Sign out"), "the sign-out control")).click();
    const told = await waitFor(() => daemon.calls.find((c) => c.method === "identity.sign_out"), "the daemon told");
    expect(told.params).toMatchObject({ plane_url: harness.plane.baseUrl, subject: "alice@example.com" });
    expect(daemon.planeToken).toBeNull();
    expect(daemon.linked).toMatchObject({ subject: "alice@example.com", plane_url: harness.plane.baseUrl });
  });

  it("leaves the token of a daemon linked to somebody else", async () => {
    daemon.linked = { subject: "bob@example.com", display_name: "Bob", plane_url: harness.plane.baseUrl };
    daemon.planeToken = "bobs-token";
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    await waitFor(() => says("/home/ada/notes"), "the daemon's sessions in the list");

    (await waitFor(() => button("Sign out"), "the sign-out control")).click();
    await waitFor(() => daemon.calls.find((c) => c.method === "identity.sign_out"), "the daemon told");
    expect(daemon.planeToken).toBe("bobs-token");
  });
});

describe("linking this computer and starting a private session", () => {
  it("hands the token with the link, and asks the daemon for a private session where it reads it", async () => {
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    await waitFor(() => says("/home/ada/notes"), "the daemon's sessions in the list");
    expect(daemon.planeTokens).toEqual([]);

    goToThisComputer();
    (await waitFor(() => button("Use my account (Alice)"), "the control that links this computer")).click();
    await waitFor(() => daemon.linked?.subject === "alice@example.com" && daemon.planeToken, "the link, with the token");
    expect(daemon.linked?.plane_url).toBe(harness.plane.baseUrl);
    expect(await honoured(daemon.planeToken)).toBe(true);

    nav("Sessions")!.click();
    (await waitFor(() => button("Start a session"), "the list's start button")).click();
    const start = await waitFor(() => document.querySelector<HTMLElement>(".start"), "the start screen");
    button("Local", start)!.click();
    type(await waitFor(() => start.querySelector<HTMLInputElement>('input[aria-label="Which directory"]'), "the local half"), "/home/ada/project");
    // Offered on the same connection: the daemon said no private sessions when the app
    // connected, before anybody had linked it.
    const keep = await waitFor(
      () => [...start.querySelectorAll<HTMLLabelElement>("label")].find((l) => l.textContent?.includes("Keep it private"))?.querySelector("input"),
      "the private checkbox",
    );
    expect(keep.disabled).toBe(false);
    keep.click();
    button("Start", start)!.click();

    const create = await waitFor(() => daemon.calls.find((c) => c.method === "session.create"), "the session asked for");
    expect(create.params["private"]).toBe(true);
    expect((create.params["config"] as Record<string, unknown>)["private"]).toBeUndefined();
    expect(daemon.privateSessions.size).toBe(1);
  });
});
