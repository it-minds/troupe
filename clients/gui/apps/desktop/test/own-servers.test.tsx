// Your own signed-in servers, offered to a session on your team's pod (troupe Decision
// 748): the app rendered, signed in to a fake deployment, with the daemon on this
// computer signed in to one of the person's servers. Opening the team session asks the
// person, in the session's words, before its tools are registered; a call the pod's agent
// makes goes to the daemon, which calls the server with the sign-in it keeps; and nothing
// of that sign-in reaches the pod or the plane.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  daemon.servers.push({ name: "notes", layer: "user", source: "/home/ada/.config/troupe/mcp.json", url: "https://mcp.example.test/notes", oauth: { client_id: "troupe-test-client" } });
  daemon.finishSignIn("notes");
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

describe("your own servers in a team session", () => {
  it("are offered once you say so, and the pod's call is made by the daemon with no token on the way", async () => {
    const plane = harness.plane;
    plane.seed("alice@example.com", { id: "team-1", title: "Plan the release", profile: "dev" });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
    startOnTheList();

    // Everything the page asks the plane.
    const asked: unknown[] = [];
    const fake = plane as unknown as { rpc: (...args: [string, string, string, Record<string, unknown>]) => unknown };
    const rpc = fake.rpc.bind(plane);
    fake.rpc = (subject, name, method, params) => {
      asked.push({ method, params });
      return rpc(subject, name, method, params);
    };

    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Plan the release")), "the team session's row");
    row.click();

    // The session asks first, and nothing is registered until the person answers.
    const panel = await waitFor(() => document.querySelector<HTMLElement>('section[aria-label="Offer your servers"]'), "the session's question about your servers");
    expect(panel.textContent).toContain("Let this session run notes.search on your machine?");
    expect(panel.textContent).toContain("your sign-in to notes");
    expect(harness.worker.tools.size).toBe(0);

    button("Offer them", panel)!.click();
    await waitFor(() => says("Your servers are offered to this session: notes, 1 tool."), "the line saying what is offered");
    expect(document.querySelector('section[aria-label="Offer your servers"]')).toBeNull();
    expect([...harness.worker.tools.keys()]).toEqual(["team-1/client.notes.search"]);
    const registration = harness.worker.calls.filter((c) => c.method === "tools.register").at(-1)!;
    expect(registration.params["consent"]).toMatchObject({ confirmed_by: "alice@example.com" });

    // The pod's agent calls the tool; the daemon makes the call with the person's sign-in.
    const answer = await harness.worker.invokeTool("team-1", "client.notes.search", { topic: "the release" }, "call-1");
    expect(answer).toEqual({ content: 'search on notes for ada@example.test: {"topic":"the release"}' });
    const token = daemon.signInTokens["notes"]!;
    expect(daemon.serverCalls).toEqual([{ server: "notes", tool: "search", arguments: { topic: "the release" }, authorization: `Bearer ${token}` }]);

    // Nothing of the sign-in went to the pod or to the plane.
    expect(harness.worker.frames.length).toBeGreaterThan(0);
    for (const frame of harness.worker.frames) expect(frame).not.toContain(token);
    expect(JSON.stringify(asked)).not.toContain(token);
  });

  it("are not registered when you say not now", async () => {
    harness.plane.seed("alice@example.com", { id: "team-2", title: "Not this one", profile: "dev" });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
    startOnTheList();

    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Not this one")), "the team session's row");
    row.click();

    const panel = await waitFor(() => document.querySelector<HTMLElement>('section[aria-label="Offer your servers"]'), "the session's question about your servers");
    button("Not now", panel)!.click();
    await waitFor(() => document.querySelector('section[aria-label="Offer your servers"]') === null, "the question gone");
    expect(harness.worker.tools.size).toBe(0);
    expect(says("Your servers are offered")).toBe(false);
  });
});
