// Memory and Artifacts read from the plane the app is signed in to, as the console reads
// them, whatever this computer's daemon is doing: with no daemon at all, and with one that
// is connected but signed in to no plane. Neither says anything about the daemon. Not
// signed in (the plane not answering), they go through the daemon and its own sign-in; with
// neither, they say why in the daemon's own state. Under Local only the plane is asked
// nothing. Against a fake plane that keeps the person's memory and artifacts itself.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { artifact } from "../../../packages/client/test/support/plane.js";
import { button, nav, recordNetwork, render, sees, startOnTheList, waitFor } from "./support";
import type { Recorder } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const ORGANISATION = "## Tone\n\nPlain English, short sentences.\n\n## Dates\n\nISO dates everywhere.";
const TEAM = "## Prices\n\nUse the framework agreement's prices.";
const MINE = "## Tone\n\nKeep answers short.";
const ada = { subject: "ada@example.com", display_name: "Ada" };

let harness: Harness | null = null;
let daemon: FakeDaemon | null = null;
let network: Recorder | null = null;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  harness = await startHarness({
    plane: {
      memory: [
        { scope: "organisation", name: null, version: 4, hash: "sha256:org-4", text: ORGANISATION },
        { scope: "team", name: "core", version: 2, hash: "sha256:core-2", text: TEAM },
      ],
      own: { "alice@example.com": MINE },
      artifacts: [artifact("art-weekly", ada, { title: "Weekly figures", visibility: "organisation" })],
    },
  });
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  network?.restore();
  network = null;
  location.hash = "";
  await harness?.stop();
  harness = null;
  await daemon?.stop();
  daemon = null;
});

/** A daemon on this computer that answers, connected, and is signed in to no plane. */
async function aDaemonSignedInNowhere(): Promise<FakeDaemon> {
  const d = new FakeDaemon({ osUser: "alice" });
  await d.start();
  location.hash = `#daemon=${d.port}:${d.token}`;
  return d;
}

const memoryScreen = (): Promise<HTMLElement> => waitFor(() => document.querySelector<HTMLElement>(".memory-screen"), "the Memory view");
const gallery = (): Promise<HTMLElement> => waitFor(() => document.querySelector<HTMLElement>(".repertoire"), "the gallery");
const entries = (screen: HTMLElement): string[] => [...screen.querySelectorAll(".entries > li")].map((li) => (li.textContent ?? "").replace(/\s+/g, " ").trim());

async function seesTheMemory(): Promise<void> {
  (await waitFor(() => nav("Memory"), "the Memory entry in the rail")).click();
  const screen = await memoryScreen();
  await waitFor(() => entries(screen).length === 3, "three topics in effect");
  expect(entries(screen)[0]).toContain("Tone○ FROM YOU");
  expect(entries(screen)[0]).toContain("REPLACES EVERYONE");
  expect(entries(screen)[2]).toContain("Prices◎ FROM CORE");
  expect(screen.textContent).not.toMatch(/daemon/i);
}

async function seesTheGallery(): Promise<void> {
  (await waitFor(() => nav("Artifacts"), "the Artifacts entry in the rail")).click();
  const screen = await gallery();
  await waitFor(() => screen.textContent?.includes("Weekly figures"), "the plane's artifact");
  expect(screen.textContent).not.toMatch(/daemon/i);
}

describe("signed in to a plane", () => {
  it("reads memory and artifacts from the plane with no daemon on this computer", async () => {
    unmount = render(<App />).unmount;
    await seesTheMemory();
    expect(harness!.plane.asked).toContain("me.memory");
    expect(harness!.plane.asked).toContain("memory.in_effect");
    await seesTheGallery();
    expect(harness!.plane.asked).toContain("artifact.list");
  });

  it("reads them from the plane while the daemon is connected, whatever the daemon is signed in to", async () => {
    daemon = await aDaemonSignedInNowhere();
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".rail")?.textContent?.includes("Sessions"), "the rail");
    await seesTheMemory();
    // The daemon is asked where this computer's copy stands, and nothing of the person's own.
    await waitFor(() => daemon!.calls.some((c) => c.method === "me.memory.status"), "this computer's copy asked");
    expect(daemon.calls.filter((c) => c.method === "me.memory" || c.method === "memory.in_effect")).toEqual([]);
    await seesTheGallery();
    expect(daemon.calls.filter((c) => c.method.startsWith("artifact."))).toEqual([]);
  });

  it("asks the plane nothing under Local only, and says so", async () => {
    daemon = await aDaemonSignedInNowhere();
    daemon.own = { version: 2, text: MINE };
    localStorage.setItem("troupe.pref.localOnly", "yes");
    unmount = render(<App />).unmount;
    (await waitFor(() => nav("Memory"), "the Memory entry")).click();
    await sees("Local only: the plane is not asked.");
    await sees("This computer holds version 2 of your memory");
    (await waitFor(() => nav("Artifacts"), "the Artifacts entry")).click();
    await sees("Local only: the plane is not asked. Artifacts are kept on your organisation's plane");
    expect(harness!.plane.asked.filter((m) => m.startsWith("me.memory") || m === "memory.in_effect" || m.startsWith("artifact."))).toEqual([]);
    expect(daemon.calls.filter((c) => c.method === "me.memory" || c.method.startsWith("artifact."))).toEqual([]);
  });
});

describe("not signed in, the plane not answering", () => {
  const offline = async (): Promise<void> => {
    const plane = harness!.plane.baseUrl;
    network = recordNetwork({ refuse: (url) => url.startsWith(plane) });
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Continue on this computer"), "the way out")).click();
    await sees("The platform is not answering");
  };

  it("reads memory through the daemon and its own sign-in", async () => {
    daemon = await aDaemonSignedInNowhere();
    daemon.own = { version: 2, text: MINE };
    await offline();
    (await waitFor(() => nav("Memory"), "the Memory entry")).click();
    const screen = await memoryScreen();
    await waitFor(() => screen.querySelector(".levels"), "the levels");
    await waitFor(() => daemon!.calls.some((c) => c.method === "me.memory"), "the daemon asked");
  });

  it("says why there is nothing to read them through in the daemon's own state", async () => {
    // A shell that looked for the daemon and found none running.
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device", findDaemon: async () => null };
    try {
      await offline();
      (await waitFor(() => nav("Memory"), "the Memory entry")).click();
      await sees("You are not signed in here, and this computer's daemon is not running, so your memory cannot be read.");
      (await waitFor(() => nav("Artifacts"), "the Artifacts entry")).click();
      await sees("You are not signed in here, and this computer's daemon is not running, so your artifacts cannot be read.");
    } finally {
      delete window.troupe;
    }
  });
});
