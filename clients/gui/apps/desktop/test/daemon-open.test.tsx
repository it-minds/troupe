// The address `troupe-daemon open` opens (issue #449, Decision 797): the web app with
// `#daemon=<port>:<token>` after it. The page connects to the daemon it names, takes the
// token off the address bar, and keeps the pair in this browser, so a reload or a new tab
// connects again. A page whose socket will not open says which origin the daemon has to
// admit, since a browser shows it no 403.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, says, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

/** Load the app, the way a reload, or a new tab at the same address, does. */
function load(): void {
  unmount?.();
  unmount = render(<App />).unmount;
}

/** Arrive at the address `troupe-daemon open` hands the browser. */
function arrive(port: number, token: string): void {
  history.replaceState(null, "", `/#daemon=${port}:${token}`);
  load();
}

async function thisComputer(): Promise<void> {
  (await waitFor(() => button("Settings"), "the launcher's Settings")).click();
  await waitFor(() => says("The daemon"), "This computer");
}

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  history.replaceState(null, "", "/");
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  history.replaceState(null, "", "/");
  await daemon.stop();
});

describe("the address troupe-daemon open opens", () => {
  it("shows the sessions on this computer, with the token gone from the address bar, and a reload connects again", async () => {
    daemon.seed("/home/ada/notes");
    arrive(daemon.port, daemon.token);

    await waitFor(() => says("daemon connected"), "the launcher, connected");
    await waitFor(() => says("/home/ada/notes"), "the session on this computer");
    expect(location.hash).toBe("");
    expect(location.href).not.toContain(daemon.token);

    // A reload, or a new tab at the address as it is now: nothing after it.
    load();
    await waitFor(() => says("daemon connected"), "connected again with nothing on the address");
    await waitFor(() => says("/home/ada/notes"), "the session again");
  });

  it("is forgotten by Disconnect, and stays forgotten after a reload", async () => {
    arrive(daemon.port, daemon.token);
    await waitFor(() => says("daemon connected"), "connected");

    await thisComputer();
    button("Disconnect")!.click();
    await waitFor(() => says("troupe-daemon open"), "the way to connect again");

    load();
    await waitFor(() => says("no daemon from a browser"), "nothing to connect to after a reload");
  });

  it("names this page's origin, and troupe-daemon open, when the socket will not open", async () => {
    // A daemon that has restarted since serves somewhere else; one that refuses this page's
    // origin fails the same way in a browser.
    const { port, token } = daemon;
    await daemon.stop();
    arrive(port, token);

    await waitFor(() => says("daemon not answering"), "the launcher, not answering");
    expect(location.hash).toBe("");

    await thisComputer();
    await waitFor(() => says(`does not admit pages from ${location.origin}`), "the origin the daemon has to admit");
    expect(says("troupe-daemon open")).toBe(true);
    await daemon.start();
  });
});
