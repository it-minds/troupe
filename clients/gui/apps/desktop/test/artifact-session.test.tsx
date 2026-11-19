// An artifact leads to the session that published it (troupe #1099): its Info's Overview
// says "Published from a session" with Open session, which opens it in the app as its
// troupe://session link would. Where the plane answers that there is no such session for
// this person (gone, or not shared with them, which it answers alike), the line says so
// and the app stays where it is: the button grants nothing. Against a fake plane whose
// artifacts the fake daemon keeps.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { SESSION_NOT_OPEN } from "../src/links";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import { keptBy } from "../../../packages/client/test/support/kept.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { artifactInfo, infoDialog, infoTab, nav, render, sees, seesButton, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;

const artifact = (id: string, title: string, session: string): Record<string, unknown> => ({
  id,
  title,
  kind: "html",
  visibility: "organisation",
  scope: "organisation",
  owner: { subject: "bo@example.test", display_name: "Bo" },
  mine: false,
  origin: { session_id: session, profile: "dev", agent: "agent:writer", where: "pod" },
  version: 1,
  current: 1,
  pinned: null,
  bytes: 1229,
  url: `https://artifacts.example.test/a/${id}/`,
  created_at: new Date().toISOString(),
  published_at: new Date().toISOString(),
  may_delete: false,
});

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
  daemon.artifacts = [
    artifact("art-figures", "Weekly figures", "s-figures"),
    artifact("art-gone", "Old notes", "s-gone"),
    artifact("art-bobs", "Bob's plan", "s-bobs"),
    { ...artifact("art-hand", "By hand", "x"), origin: { where: "person" } },
  ];
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  harness = await startHarness({ plane: { keeper: keptBy(daemon) } });
  harness.plane.seed("alice@example.com", { id: "s-figures", title: "Weekly figures run" });
  // Bob's, not shared with Alice: the plane answers it as it answers one that is gone.
  harness.plane.seed("bob@example.com", { id: "s-bobs", title: "Bob's planning" });
  harness.plane.unseen.add("s-bobs");
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

const aside = infoDialog;

/** The named artifact's Info, on its Overview, where it came from. */
async function choose(title: string): Promise<HTMLElement> {
  return infoTab(await artifactInfo(title), "Overview");
}

async function openGallery(): Promise<void> {
  unmount = render(<App />).unmount;
  (await waitFor(() => nav("Artifacts"), "the Artifacts entry in the rail")).click();
}

describe("an artifact's session", () => {
  it("is opened from the artifact, in the app, as its link opens it", async () => {
    await openGallery();
    const details = await choose("Weekly figures");
    await sees("Published from a session.");
    (await seesButton("Open session", details)).click();
    await waitFor(() => document.querySelector(".session-head"), "the session's view");
    await sees("Weekly figures run");
  });

  it("says so where the session is gone, and stays on the artifact", async () => {
    await openGallery();
    const details = await choose("Old notes");
    (await seesButton("Open session", details)).click();
    await sees(SESSION_NOT_OPEN);
    expect(document.querySelector(".session-head")).toBeNull();
    expect(aside()).not.toBeNull();
  });

  it("grants nothing to somebody the session is not shared with: the plane's refusal is the end of it", async () => {
    await openGallery();
    const details = await choose("Bob's plan");
    const before = harness!.plane.asked.length;
    (await seesButton("Open session", details)).click();
    await sees(SESSION_NOT_OPEN);
    expect(document.querySelector(".session-head")).toBeNull();
    // Asked once at the click, and never opened: no `session.open` reached the plane.
    const since = harness!.plane.asked.slice(before);
    expect(since.filter((m) => m === "session.get")).toHaveLength(1);
    expect(since.filter((m) => m === "session.open")).toEqual([]);
  });

  it("offers nothing for an artifact no session published", async () => {
    await openGallery();
    const details = await choose("By hand");
    expect(details.textContent).not.toContain("Published from a session");
  });
});
