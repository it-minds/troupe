// The palette offers a command of one side only where the install has that side (issue
// #1202), as the rail does: This computer's settings, models, servers and the like need a
// daemon. Choosing one on an install without it could only land on Sessions with no word,
// so it is not listed. A plane-only command that opens a dialog of its own (publish) stays,
// since it says its refusal; no palette command opens a plane screen yet, and the rail's
// `onAbsentSide` would leave one out the same way. The app rendered, the fakes on real
// sockets.

import { afterEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { render, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const LOCAL_COMMANDS = ["settings", "models", "mcp", "skills", "unlink"];
const PLANE_COMMANDS = ["publish"];

let unmount: (() => void) | null = null;
let harness: Harness | null = null;
let daemon: FakeDaemon | null = null;

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await harness?.stop();
  harness = null;
  await daemon?.stop();
  daemon = null;
});

function key(target: EventTarget, name: string): void {
  target.dispatchEvent(new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
}

/** The names the palette lists, from a session opened out of the list and the palette opened over it. */
async function listed(title: string): Promise<string[]> {
  const row = await waitFor(
    () => [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === title)?.querySelector<HTMLButtonElement>("button.row"),
    `the row for ${title}`,
  );
  row.click();
  const composer = await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the composer");
  key(composer, "/");
  await waitFor(() => document.querySelector('[role="dialog"][aria-label="Commands"] .palette .row') ?? document.querySelector(".palette .row"), "the palette's rows");
  // Sessions is a command of neither side: when it is listed the list has come.
  await waitFor(() => names().includes("/sessions"), "the list");
  return names();
}

const names = (): string[] => [...document.querySelectorAll(".palette .row .name")].map((el) => el.textContent ?? "");

async function signedInToAPlane(): Promise<void> {
  localStorage.clear();
  startOnTheList();
  harness = await startHarness();
  await harness.signIn({ store: webTokenStore() });
  localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
}

describe("the palette's commands by side", () => {
  it("lists none of This computer's in a remote-only install, and the plane's still", async () => {
    await signedInToAPlane();
    harness!.plane.seed("alice@example.com", { title: "Weekly licence audit" });
    unmount = render(<App />).unmount;
    const at = await listed("Weekly licence audit");
    for (const name of LOCAL_COMMANDS) expect(at, name).not.toContain(`/${name}`);
    for (const name of PLANE_COMMANDS) expect(at, name).toContain(`/${name}`);
  });

  it("lists This computer's with a daemon, in a local-only install", async () => {
    localStorage.clear();
    localStorage.setItem("troupe.pref.localOnly", "yes");
    startOnTheList();
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    daemon.seed("/home/ada/notes");
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    const at = await listed("/home/ada/notes");
    for (const name of LOCAL_COMMANDS) expect(at, name).toContain(`/${name}`);
    // The plane's publish is no page of a side: it opens its own dialog, which says the refusal.
    for (const name of PLANE_COMMANDS) expect(at, name).toContain(`/${name}`);
  });

  it("lists both sides' where the install has both", async () => {
    await signedInToAPlane();
    harness!.plane.seed("alice@example.com", { title: "Weekly licence audit" });
    daemon = new FakeDaemon({ osUser: "alice" });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    const at = await listed("Weekly licence audit");
    for (const name of [...LOCAL_COMMANDS, ...PLANE_COMMANDS]) expect(at, name).toContain(`/${name}`);
  });
});
