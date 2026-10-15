// A `daemon.json` left behind by a daemon that did not exit cleanly (issue #706): killed,
// crashed, or ended with the console that started it. The file names a port nothing
// listens on, and the desktop app has to start a daemon over it rather than dial the dead
// port, at launch and when somebody presses Find.
//
// The shell here is the real one, `shell-tauri.ts`, with the three Tauri commands it
// calls answered the way `src-tauri/src/daemon.rs` answers them: `daemon_endpoint` reads
// the file and probes nothing, and `daemon_start` returns what the file names if it
// answers, and otherwise starts a daemon, which rewrites the file.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { installShell } from "../src/shell-tauri";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, says, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

type Endpoint = { transport: "ws"; port: number; token: string };

/** This computer, as the shell's commands see it: the file, and whether a daemon runs. */
const machine = vi.hoisted(() => ({
  file: null as { transport: "ws"; port: number; token: string } | null,
  running: false,
  start: async (): Promise<void> => undefined,
  calls: [] as string[],
}));

/** The shell's commands, reached through `@tauri-apps/api/core` and through what the plugins call. */
const invoke = vi.hoisted(() => async (command: string): Promise<unknown> => {
  machine.calls.push(command);
  if (command === "daemon_endpoint") return machine.file;
  if (command === "daemon_start") {
    if (machine.file && machine.running) return machine.file;
    await machine.start();
    return machine.file;
  }
  if (command === "update_check") return { state: "current", version: "0.0.0-test", current: "0.0.0-test" };
  throw new Error(`no command ${command} in this test`);
});

vi.mock("@tauri-apps/api/core", () => ({ invoke }));
vi.mock("@tauri-apps/api/app", () => ({ getVersion: async () => "0.0.0-test" }));
vi.mock("@tauri-apps/plugin-http", () => ({ fetch: (...args: Parameters<typeof fetch>) => fetch(...args) }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: async () => undefined }));

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

/** A daemon that dies without removing its file: the file still names its port. */
async function kill(): Promise<Endpoint> {
  const left = daemon.published;
  await daemon.stop();
  machine.running = false;
  return left;
}

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  history.replaceState(null, "", "/");
  machine.calls = [];
  daemon = new FakeDaemon({ osUser: "ada" });
  // `troupe-daemon run`: a daemon on a port the kernel picks, published in the file.
  machine.start = async () => {
    await daemon.start();
    machine.running = true;
    machine.file = daemon.published;
  };
  await machine.start();
  (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = { invoke };
  await installShell();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  delete window.troupe;
  delete (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__;
  machine.file = null;
  if (machine.running) await daemon.stop();
  machine.running = false;
});

describe("a daemon.json naming a port nothing listens on", () => {
  it("is not what findDaemon returns: it starts a daemon over it, and returns where that one is", async () => {
    const stale = await kill();
    expect(machine.file).toEqual(stale);

    const found = await window.troupe!.findDaemon!();

    expect(found).not.toEqual(stale);
    expect(found).toEqual(daemon.published);
    expect(machine.calls).toContain("daemon_start");
  });

  it("is still what readDaemon returns, which starts nothing: a daemon somebody stopped stays stopped", async () => {
    const stale = await kill();

    expect(await window.troupe!.readDaemon!()).toEqual(stale);
    expect(machine.calls).toEqual(["daemon_endpoint"]);
    expect(machine.running).toBe(false);
  });

  it("leaves the app connected when it opens over one, with no step by the person", async () => {
    await kill();

    unmount = render(<App />).unmount;

    await waitFor(() => says("daemon connected"), "the launcher, connected to a daemon started over the stale file");
  });

  it("is passed over by Find, which reaches a daemon it started, once the one the app had died", async () => {
    unmount = render(<App />).unmount;
    await waitFor(() => says("daemon connected"), "the launcher, connected");

    // The daemon dies and leaves its file; the client's dials follow the file to nothing.
    await kill();
    await waitFor(() => says("daemon not answering"), "the socket closing");

    (await waitFor(() => button("Settings"), "the launcher's Settings")).click();
    (await waitFor(() => button("Find it, and start it if it is not running"), "the Find control")).click();

    await waitFor(() => machine.running && says(`ws://127.0.0.1:${daemon.port}/v1/socket`), "connected to the daemon Find started");
  });
});
