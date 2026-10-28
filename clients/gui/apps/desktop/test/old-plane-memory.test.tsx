// The Memory view on a plane from before entries (0.28 and earlier), which reads a document
// as `text` alone: an edit of the person's own is saved all the same, sent again as text once
// the plane refuses the entries, and the view says so as after any save.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, nav, render, sees, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  daemon.own = { version: 2, text: "## Tone\n\nKeep answers short." };
  daemon.planeReadsOnlyText = true;
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await harness?.stop();
  harness = null;
  await daemon.stop();
});

describe("the Memory view on a plane that reads only text", () => {
  it("saves an edit of the person's own as text", async () => {
    harness = await startHarness();
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
    unmount = render(<App />).unmount;
    (await waitFor(() => nav("Memory"), "the Memory entry in the rail")).click();
    const screen = await waitFor(() => document.querySelector<HTMLElement>(".memory-screen"), "the Memory view");
    (await waitFor(() => [...screen.querySelectorAll<HTMLButtonElement>(".levels .level")].find((b) => b.textContent?.includes("Only you")), "the person's level")).click();
    const own = await waitFor(() => screen.querySelector<HTMLElement>(".entries > li"), "the person's own");
    button("Edit", own)!.click();
    const edit = await waitFor(() => screen.querySelector<HTMLElement>('[aria-label="Edit memory"]'), "the edit form");
    type(edit.querySelector<HTMLTextAreaElement>("textarea")!, "Keep answers very short.");
    button("Save", edit)!.click();
    await sees("Saved. New sessions start with the new version.");
    expect(daemon.ownPuts.map((p) => ("entries" in p ? "entries" : p["text"]))).toEqual(["entries", "## Tone\n\nKeep answers very short."]);
    expect(daemon.own).toEqual({ version: 3, text: "## Tone\n\nKeep answers very short." });
  });
});
