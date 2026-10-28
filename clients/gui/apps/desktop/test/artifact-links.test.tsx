// The artifact panel's Copy link and Open in browser in the shell. The link is put on the
// clipboard by the shell, never by the page: a webview writes its own clipboard only inside
// the click that asked, and the owner's link is minted by the daemon first. Open in browser
// hands the artifact's address to the shell, and a shell that refuses says why on the
// panel's error line rather than nothing. Against the fake daemon and a fake plane.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { nav, render, sees, seesButton, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;
const copied: string[] = [];
const opened: string[] = [];
const pageWrote: string[] = [];
let refuse: string | null = null;

const row = (over: Record<string, unknown>): Record<string, unknown> => ({
  kind: "html",
  visibility: "organisation",
  owner: { subject: "bo@example.test", display_name: "Bo" },
  mine: false,
  origin: { session_id: "s-weekly", profile: "dev", agent: "agent:writer", where: "laptop" },
  team: "core",
  version: 1,
  current: 1,
  pinned: null,
  bytes: 1229,
  url: `https://artifacts.example.test/a/${String(over["id"])}/`,
  created_at: "2026-01-02T10:00:00Z",
  published_at: new Date().toISOString(),
  may_delete: false,
  ...over,
});

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  copied.length = 0;
  opened.length = 0;
  pageWrote.length = 0;
  refuse = null;
  window.troupe = {
    name: "Test shell",
    version: "0",
    signInFlow: "device",
    copyText: async (text: string) => void copied.push(text),
    openExternal: async (url: string) => {
      if (refuse) throw new Error(refuse);
      opened.push(url);
    },
  };
  // The page's own clipboard, which a shell's build must leave alone.
  Object.defineProperty(navigator, "clipboard", { value: { writeText: async (t: string) => void pageWrote.push(t) }, configurable: true });
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  daemon.artifacts = [
    row({ id: "art-weekly", title: "Weekly figures", scope: "organisation" }),
    row({ id: "art-mine", title: "My notes", scope: "mine", mine: true, role: "owner", owner: { subject: "alice@example.com", display_name: "Alice" }, version: 2, current: 2, may_delete: true }),
  ];
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  harness = await startHarness();
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
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

/** The gallery open and the named card's aside. */
async function panelOf(title: string): Promise<HTMLElement> {
  unmount = render(<App />).unmount;
  (await waitFor(() => nav("Artifacts"), "the Artifacts entry in the rail")).click();
  (await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>(".repertoire .card")].find((c) => c.textContent?.includes(title)), "the card")).click();
  return waitFor(() => document.querySelector<HTMLElement>('[aria-label="Artifact details"]'), "the aside");
}

describe("the artifact panel in the shell", () => {
  it("copies its owner a view link minted now, through the shell's clipboard", async () => {
    const panel = await panelOf("My notes");
    (await seesButton("Copy link", panel)).click();
    await waitFor(() => copied.length === 1, "the link copied by the shell");
    expect(copied[0]).toBe("https://artifacts.example.test/s/tok-sh-1");
    expect(daemon.artifactCalls.map((c) => [c.method, c.params["role"]])).toContainEqual(["artifact.share", "view"]);
    await seesButton("Link copied", panel);
    expect(pageWrote).toEqual([]);
  });

  it("copies anybody else its address, through the shell's clipboard", async () => {
    const panel = await panelOf("Weekly figures");
    (await seesButton("Copy link", panel)).click();
    await waitFor(() => copied.length === 1, "the address copied by the shell");
    expect(copied[0]).toBe("https://artifacts.example.test/a/art-weekly/");
    expect(daemon.artifactCalls.map((c) => c.method)).not.toContain("artifact.share");
    expect(pageWrote).toEqual([]);
  });

  it("opens its address in the person's browser through the shell", async () => {
    const panel = await panelOf("Weekly figures");
    (await seesButton("Open in browser", panel)).click();
    await waitFor(() => opened.length === 1, "the address handed to the shell");
    expect(opened[0]).toBe("https://artifacts.example.test/a/art-weekly/");
    expect(panel.querySelector(".note.error")).toBeNull();
  });

  it("says why when the shell refuses to open the browser", async () => {
    refuse = "Not allowed to open url https://artifacts.example.test/a/art-weekly/";
    const panel = await panelOf("Weekly figures");
    (await seesButton("Open in browser", panel)).click();
    await sees("Not opened: Not allowed to open url https://artifacts.example.test/a/art-weekly/");
    expect(opened).toEqual([]);
  });
});
