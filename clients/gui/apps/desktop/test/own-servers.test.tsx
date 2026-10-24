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
import { button, render, says, sees, startOnTheList, waitFor } from "./support";

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

  // troupe #592: everyone watching the session is told when somebody's own tools are offered,
  // and when they go: whose, how many and why.
  it("are said in the session when they are offered and when somebody's leave", async () => {
    harness.plane.seed("alice@example.com", { id: "team-4", title: "Watch the tools", profile: "dev" });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
    startOnTheList();

    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Watch the tools")), "the team session's row");
    row.click();

    const panel = await waitFor(() => document.querySelector<HTMLElement>('section[aria-label="Offer your servers"]'), "the session's question about your servers");
    button("Offer them", panel)!.click();
    await sees("Alice offered tools that run on their own machine: client.notes.search");

    // A teammate's client, whose two tools the session had, leaves.
    harness.worker.sessions.get("team-4")!.log.append(
      "tools_unregistered",
      { tools: ["client.mail.read", "client.mail.send"], connection: "a socket", reason: "disconnected", actor: "bob@example.com" },
      { kind: "user", subject: "bob@example.com" },
    );
    await sees("bob@example.com's 2 tools are no longer offered to the session, because their client left: client.mail.read, client.mail.send");
  });

  // D50: a server signed in to while the session is open was offered only at the next
  // attachment, and every signed-in server went or none did.
  it("asks again about a server signed in to while the session is open, and offers only the ones you tick", async () => {
    harness.plane.seed("alice@example.com", { id: "team-5", title: "Two servers", profile: "dev" });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
    startOnTheList();

    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Two servers")), "the team session's row");
    row.click();

    // One server: nothing to pick, as before.
    const first = await waitFor(() => document.querySelector<HTMLElement>('section[aria-label="Offer your servers"]'), "the session's question about your servers");
    expect(first.querySelector('fieldset[aria-label="Which servers to offer"]')).toBeNull();
    button("Offer them", first)!.click();
    await waitFor(() => says("Your servers are offered to this session: notes, 1 tool."), "the line saying what is offered");

    // Signed in to another while the session is open; the window comes back to the front.
    daemon.servers.push({ name: "wiki", layer: "user", source: "/home/ada/.config/troupe/mcp.json", url: "https://mcp.example.test/wiki", oauth: { client_id: "troupe-test-client" } });
    daemon.finishSignIn("wiki");
    window.dispatchEvent(new Event("focus"));

    const again = await waitFor(() => document.querySelector<HTMLElement>('section[aria-label="Offer your servers"]'), "the question about both servers");
    const boxes = await waitFor(() => {
      const found = [...again.querySelectorAll<HTMLInputElement>('fieldset[aria-label="Which servers to offer"] input[type="checkbox"]')];
      return found.length === 2 ? found : null;
    }, "a box for each server");
    expect(boxes.map((b) => b.checked)).toEqual([true, true]);
    expect(again.textContent).toContain("notes · 1 tool");

    boxes[0]!.click();
    (await waitFor(() => button("Offer wiki", again), "the button naming what is ticked")).click();
    await waitFor(() => says("Your servers are offered to this session: wiki, 1 tool."), "the line saying what is offered now");
    await waitFor(() => harness.worker.tools.size === 1, "notes taken back");
    expect([...harness.worker.tools.keys()]).toEqual(["team-5/client.wiki.search"]);
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

  // troupe Decision 862: the team's worker profile forbids a person's own tools on its pods.
  // Nobody is asked; the line says they are unavailable here, and why.
  it("are shown as unavailable, with the profile's reason, where the profile forbids them", async () => {
    harness.worker.personalToolsForbiddenBy = "dev";
    harness.plane.seed("alice@example.com", { id: "team-3", title: "Locked down", profile: "dev" });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
    startOnTheList();

    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Locked down")), "the team session's row");
    row.click();

    await waitFor(() => says("Your servers could not be offered here: the worker profile dev does not take a person's own tools"), "the line saying why");
    await sees("(personalTools: forbid)");
    expect(document.querySelector('section[aria-label="Offer your servers"]')).toBeNull();
    expect(harness.worker.tools.size).toBe(0);
  });
});
