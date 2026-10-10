// The daemon on this computer going away and coming back while the app is open (defects.md
// D41). A daemon that restarts publishes a new port and a new token — the kernel picks the
// one and the other is random — so the app reads where it is again before it dials, as the
// Find button does, and says it is connected once a dial works, rather than "not answering"
// until somebody presses Find.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, says, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

/** Long enough for the list's poll, every four seconds, to dial again. */
const REDIAL_MS = 15_000;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  delete window.troupe;
  await daemon.stop();
});

/** The desktop shell's half: `daemon.json` read where the daemon publishes itself. */
function shellReading(read: () => { transport: "ws"; port: number; token: string }): void {
  window.troupe = {
    name: "Test shell",
    version: "0",
    findDaemon: async () => read(),
    readDaemon: async () => read(),
  };
}

describe("a daemon that restarts while the app is open", () => {
  it("is connected again once a dial to it works, rather than not answering until Find is pressed", async () => {
    // A browser build, told where the daemon is; it comes back where it was.
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    daemon.seed("/home/ada/notes");
    unmount = render(<App />).unmount;
    await waitFor(() => says("daemon connected"), "the launcher, connected");

    const port = daemon.port;
    await daemon.stop();
    await waitFor(() => says("daemon not answering"), "the socket closing");
    await daemon.start(port);

    await waitFor(() => says("daemon connected"), "connected again after the next poll", REDIAL_MS);
  });

  it("is found at the port and token it publishes now, and the session open across it carries on", async () => {
    shellReading(() => daemon.published);
    const session = daemon.seed("/home/ada/notes");
    unmount = render(<App />).unmount;
    await waitFor(() => says("daemon connected"), "the launcher, connected");

    // The session open on screen, reading its history.
    daemon.say(session.id, "before the restart");
    // "Connected" comes before the list's first answer; the row is there once it lands.
    const row = await waitFor(() => document.querySelector<HTMLButtonElement>(".recent button"), "the session's row");
    row.click();
    await waitFor(() => says("before the restart"), "the session on screen");

    const before = daemon.published;
    await daemon.restart();
    expect(daemon.token).not.toBe(before.token);
    daemon.say(session.id, "while it was down");

    // The list's poll dials again, at the new pair, and the view follows the socket.
    await waitFor(() => says("while it was down"), "what was said while it was down", REDIAL_MS);
    daemon.say(session.id, "after the restart");
    await waitFor(() => says("after the restart"), "what was said after it");

    // And the machine's screen says where it is now, connected.
    button("← Sessions")!.click();
    await waitFor(() => document.querySelector(".rail"), "the list");
    const settings = [...document.querySelectorAll<HTMLButtonElement>(".rail button")].find((b) => b.textContent?.includes("This computer"));
    settings!.click();
    await waitFor(() => says(`ws://127.0.0.1:${daemon.port}/v1/socket`), "the new address on This computer");
    expect(says("Not answering")).toBe(false);
    expect(says("Connected")).toBe(true);
  });
});
