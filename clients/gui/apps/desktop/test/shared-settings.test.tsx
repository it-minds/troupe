// troupe #57, from the desktop app's side: the default model changed in the terminal is
// on the open Models panel, and one saved here reaches the terminal; the theme, light or
// dark and notifications follow the person the same way. The daemon is the fake the
// client's own tests use, and the terminal a second client of it, setting what the
// terminal UI's settings page sets.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { DaemonClient } from "@troupe/client";
import type { ConfigChanged } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import type { FakeDaemonOptions } from "../../../packages/client/test/support/daemon.js";
import { button, nav, render, sleep, startOnTheList, type, waitFor } from "./support";

// jsdom lays nothing out, so it has nothing to scroll; the transcript asks anyway.
Element.prototype.scrollIntoView = function scrollIntoView() {};
// The page's WebSocket: see local-mode.test.tsx.
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let terminal: DaemonClient;
let unmount: (() => void) | null = null;

async function start(opts: FakeDaemonOptions = {}, before: (d: FakeDaemon) => void = () => undefined): Promise<void> {
  daemon = new FakeDaemon({ osUser: "ada", ...opts });
  before(daemon);
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  terminal = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  unmount = render(<App />).unmount;
  await waitFor(() => document.querySelector(".me"), "the shell");
}

beforeEach(() => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  terminal.disconnect();
  location.hash = "";
  await daemon.stop();
});

function mainModel(): HTMLInputElement | null {
  const label = [...document.querySelectorAll("label")].find((l) => (l.textContent ?? "").startsWith("Main model"));
  return label?.querySelector("input") ?? null;
}

function pressed(selector: string, text: string): boolean {
  const found = [...document.querySelectorAll<HTMLButtonElement>(selector)].find((b) => (b.textContent ?? "").includes(text));
  return found?.getAttribute("aria-pressed") === "true";
}

function click(selector: string, text: string): void {
  [...document.querySelectorAll<HTMLButtonElement>(selector)].find((b) => (b.textContent ?? "").includes(text))!.click();
}

function heard(client: DaemonClient): Promise<ConfigChanged> {
  return new Promise((resolve) => {
    const stop = client.onConfigChanged((changed) => {
      stop();
      resolve(changed);
    });
  });
}

async function openModels(): Promise<HTMLInputElement> {
  nav("This computer")!.click();
  return waitFor(() => mainModel(), "the Models panel");
}

describe("the default model, between the desktop app and the terminal", () => {
  it("changed in the terminal, is on the open Models panel without anything pressed", async () => {
    await start();
    const field = await openModels();
    expect(field.value).toBe("");

    await terminal.setSetting("models.default", "terminal-pick");

    await waitFor(() => mainModel()?.value === "terminal-pick", "the terminal's model on the panel");
  });

  it("saved on the Models panel, reaches the terminal", async () => {
    await start();
    const field = await openModels();
    await terminal.modelConfig();
    const news = heard(terminal);

    type(field, "desktop-pick");
    button("Save")!.click();

    expect((await news).keys).toContain("models.default");
    expect((await terminal.modelConfig()).models.default).toBe("desktop-pick");
  });

  it("changed elsewhere while somebody is typing here, says so and leaves their typing alone", async () => {
    await start();
    const field = await openModels();
    type(field, "half-typed");

    await terminal.setSetting("models.default", "terminal-pick");

    await waitFor(() => (document.body.textContent ?? "").includes("Changed in another window or the terminal"), "the note");
    expect(mainModel()?.value).toBe("half-typed");
  });
});

describe("what follows the person: the theme, light or dark, and notifications", () => {
  it("a theme picked here is kept by the daemon, and one picked in another client is applied here", async () => {
    await start();
    nav("Appearance")!.click();
    await waitFor(() => document.querySelector("button.theme"), "the theme cards");

    click("button.theme", "Signal");
    await waitFor(() => daemon.ui["ui.theme"] === "signal", "ui.theme written to the daemon");
    expect(document.documentElement.dataset["theme"]).toBe("signal");

    await terminal.setSetting("ui.theme", "footlight");
    await terminal.setSetting("ui.mode", "light");
    await waitFor(() => document.documentElement.dataset["theme"] === "footlight", "the other client's theme");
    await waitFor(() => document.documentElement.dataset["mode"] === "light", "the other client's light");
    expect(pressed("button.theme", "Footlight")).toBe(true);

    // Taken out elsewhere: the default again.
    await terminal.setSetting("ui.theme", null);
    await waitFor(() => document.documentElement.dataset["theme"] === "afterglow", "the default theme");
  });

  it("notifications turned off here are off in the daemon, and turned on elsewhere are on here", async () => {
    await start();
    nav("Appearance")!.click();
    await waitFor(() => document.querySelector(".notify"), "the notifications choice");

    click(".notify button", "Off");
    await waitFor(() => daemon.ui["ui.notifications"] === false, "ui.notifications written to the daemon");

    await terminal.setSetting("ui.notifications", true);
    await waitFor(() => pressed(".notify button", "On"), "notifications on again");
    expect(localStorage.getItem("troupe.pref.notify")).toBe("on");
  });

  it("the daemon's choice wins when the window is opened, and a default does not undo one made here", async () => {
    localStorage.setItem("troupe.pref.theme", "limelight");
    localStorage.setItem("troupe.pref.mode", "dark");
    await start({}, (d) => {
      d.ui["ui.theme"] = "signal";
    });

    await waitFor(() => document.documentElement.dataset["theme"] === "signal", "the daemon's theme");
    expect(document.documentElement.dataset["mode"]).toBe("dark");
  });

  it("a daemon from before shared settings is asked nothing, and the choice stays in this window", async () => {
    await start({ servesKeys: false });
    nav("Appearance")!.click();
    await waitFor(() => document.querySelector("button.theme"), "the theme cards");

    click("button.theme", "Signal");
    await sleep(200);
    expect(document.documentElement.dataset["theme"]).toBe("signal");
    expect(daemon.calls.some((c) => c.method === "config.set")).toBe(false);
  });
});
