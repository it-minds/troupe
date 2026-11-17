// A screen entered before this computer's daemon was ready. The daemon starts slowly
// beside the app, and a screen asks it once at its start: one entered while the daemon
// was reached but not yet linked to the person was refused as not signed in, and one
// entered before its socket opened again holds what the earlier daemon had. Where the
// person has typed nothing on the screen, the app remounts it by itself and says nothing;
// where they have, it says the daemon is ready now and offers a refresh, which remounts
// that one screen, and the banner goes at the refresh and at the next screen. A screen
// entered after the daemon was ready says nothing, and Memory and Artifacts, which read
// the plane when signed in, never do. Against a fake plane whose
// artifacts the fake daemon keeps (`keptBy`).

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import { keptBy } from "../../../packages/client/test/support/kept.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { nav, render, says, sees, seesButton, sleep, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const READY = "This computer's daemon is ready now";
/** Long enough for the list's poll, every four seconds, to dial again. */
const REDIAL_MS = 15_000;

let daemon: FakeDaemon;
let harness: Harness | null = null;
let unmount: (() => void) | null = null;

const weekly = {
  id: "art-weekly",
  title: "Weekly figures",
  kind: "html",
  visibility: "organisation",
  scope: "organisation",
  owner: { subject: "bo@example.test", display_name: "Bo" },
  mine: false,
  version: 1,
  current: 1,
  pinned: null,
  bytes: 1229,
  url: "https://artifacts.example.test/a/art-weekly/",
  created_at: "2026-10-20T08:00:00Z",
  published_at: "2026-10-27T08:00:00Z",
  may_delete: false,
};

beforeEach(async () => {
  localStorage.clear();
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "alice" });
  await daemon.start();
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

/** Signed in to the plane, on the list; the daemon is linked once the hand-over lands. */
// Its own open, not support's: signed in to a plane and the app drawn, no session opened.
async function open(): Promise<void> {
  harness = await startHarness({ plane: { keeper: keptBy(daemon) } });
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
  unmount = render(<App />).unmount;
}

/** The list's search box, once the list is drawn. */
function search(): Promise<HTMLInputElement> {
  return waitFor(() => document.querySelector<HTMLInputElement>('input[aria-label="Search sessions"]'), "the list's search box");
}

describe("a screen entered before this computer's daemon was ready", () => {
  // Straight after sign-in the list is entered before the hand-over lands; nothing is
  // typed on it, so nothing is lost by drawing it again, and nothing asks for a Refresh.
  it("remounts by itself once the daemon links, where nothing was typed, and says nothing", async () => {
    // The daemon is reached long before it is linked.
    daemon.delayMs["identity.link"] = 3000;
    await open();
    (await waitFor(() => nav("Tools and skills"), "the rail")).click();
    const asked = (): number => daemon.calls.filter((c) => c.method === "mcp.list").length;
    await waitFor(() => asked() > 0, "the servers asked of the daemon");
    const before = asked();
    await waitFor(() => daemon.linked !== null && daemon.linked !== undefined, "the daemon linked", 10_000);
    await waitFor(() => asked() > before, "the servers asked again, by the screen's own remount");
    await sleep(300);
    expect(says(READY)).toBe(false);
  });

  it("with a draft on the screen, says so once the daemon links, and Refresh asks again", async () => {
    daemon.delayMs["identity.link"] = 3000;
    await open();
    type(await search(), "placement");
    await sees(READY);
    // The draft is still there: the screen was not drawn again under it.
    expect((await search()).value).toBe("placement");
    (await seesButton("Refresh")).click();
    await waitFor(() => !says(READY), "the banner gone at the refresh");
  });

  // Signed in, Memory and Artifacts read the plane, so the daemon becoming ready changes
  // nothing they show: no banner there.
  it("says nothing on Memory and Artifacts, which read the plane", async () => {
    daemon.artifacts = [weekly];
    daemon.delayMs["identity.link"] = 1500;
    await open();
    (await waitFor(() => nav("Artifacts"), "the rail")).click();
    await sees("Weekly figures");
    await waitFor(() => daemon.linked !== null && daemon.linked !== undefined, "the daemon linked", 10_000);
    await sleep(300);
    expect(says(READY)).toBe(false);
  });

  it("goes at the next screen, which says nothing when it was entered after", async () => {
    daemon.artifacts = [weekly];
    daemon.delayMs["identity.link"] = 1500;
    await open();
    // The list is entered as the app opens, before the hand-over lands, and typed on.
    type(await search(), "weekly");
    await sees(READY);

    (await waitFor(() => nav("Artifacts"), "the rail")).click();
    await sees("Weekly figures");
    expect(says(READY)).toBe(false);
  });

  it("draws the screen again by itself once the daemon's socket opens again", async () => {
    daemon.artifacts = [weekly];
    await open();
    (await waitFor(() => nav("Tools and skills"), "the rail")).click();
    const asked = (): number => daemon.calls.filter((c) => c.method === "mcp.list").length;
    await waitFor(() => daemon.linked !== null && daemon.linked !== undefined, "the daemon linked", 10_000);
    await waitFor(() => asked() > 0, "the servers asked of the daemon");
    await sleep(300);
    expect(says(READY)).toBe(false);

    const before = asked();
    const port = daemon.port;
    await daemon.stop();
    await daemon.start(port);
    await waitFor(() => asked() > before, "the servers asked again after the next dial", REDIAL_MS);
    expect(says(READY)).toBe(false);
  });

  // A session's remount reads its transcript again from the top, so it is never drawn
  // again uninvited: the banner offers it.
  it("on a session, says so rather than drawing it again", async () => {
    daemon.seed("/home/alice/notes");
    daemon.delayMs["identity.link"] = 3000;
    await open();
    (await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("/home/alice/notes")), "the session in the list")).click();
    await waitFor(() => document.querySelector(".session"), "the session");
    await sees(READY);
  });
});
