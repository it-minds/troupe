// A pod session's owner raises it to its channel's current bundle version (troupe #1177).
// The session panel says "v3 · v4 is current" for a session behind its channel, with Update
// for its owner; the version follows the log's `config_upgraded`, whose transcript line says
// who raised it. A raise asked while the agent works is kept, and the panel says it moves when
// the agent is done; a refusal shows in the view's banner. The app rendered, the fakes on
// real sockets.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, showBackstage, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let unmount: (() => void) | null = null;

const entry = (text: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === text);
const onTheList = (): boolean => Boolean(document.querySelector(".toolbar input.search"));

/** The backstage's Configuration fact, its text and its Update button. */
function configuration(): { text: string; update: HTMLButtonElement | null } | null {
  const dt = [...document.querySelectorAll(".backstage dt")].find((d) => d.textContent === "Configuration");
  const dd = dt?.nextElementSibling;
  return dd ? { text: dd.textContent ?? "", update: dd.querySelector("button") } : null;
}

describe("a pod session behind its channel", () => {
  let harness: Harness;

  beforeEach(async () => {
    localStorage.clear();
    startOnTheList();
    harness = await startHarness();
    window.troupe = { name: "Test shell", version: "0", signInFlow: "device" };
    localStorage.setItem("troupe.pref.planeUrl", harness.plane.baseUrl);
  });

  afterEach(async () => {
    unmount?.();
    unmount = null;
    location.hash = "";
    delete window.troupe;
    await harness.stop();
  });

  async function signIn(): Promise<void> {
    unmount = render(<App />).unmount;
    (await waitFor(() => button("Sign in"), "the sign-in screen")).click();
    await waitFor(() => document.querySelector(".usercode"), "the code to enter");
    harness.idp.approve("ada@example.com", "Ada");
    await waitFor(() => says("Welcome, Ada."), "the first sign-in's theme");
    button("Continue")!.click();
    await waitFor(onTheList, "the session list");
  }

  async function open(text: string): Promise<void> {
    (await waitFor(() => entry(text)?.querySelector<HTMLButtonElement>("button.row"), `the row for ${text}`)).click();
    await waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
    await showBackstage();
  }

  it("says both versions to its owner, and Update raises it, the version following the log", async () => {
    harness.plane.seed("ada@example.com", { title: "Tune the retry budget" });
    harness.plane.bundleCurrent.set("dev", 4);
    await signIn();
    await open("Tune the retry budget");

    const behind = await waitFor(() => (configuration()?.text.startsWith("v3 · v4 is current") ? configuration() : null), "the two versions");
    expect(behind.update?.textContent).toBe("Update");
    expect(behind.update?.title).toBe("Moves to v4 now; the conversation stays");
    behind.update!.click();

    await waitFor(() => says("Configuration raised from v3 to v4 by Ada"), "the transcript's line");
    await waitFor(() => configuration()?.text === "v4", "the version following the log");
    expect(configuration()?.update).toBeNull();
  });

  it("says only the version when it is current", async () => {
    harness.plane.seed("ada@example.com", { title: "Current already" });
    await signIn();
    await open("Current already");
    await waitFor(() => configuration()?.text === "v3", "the one version");
    expect(configuration()?.update).toBeNull();
  });

  it("offers nobody but its owner Update", async () => {
    harness.plane.seed("bob@example.com", { title: "Bob's sweep" });
    harness.plane.bundleCurrent.set("dev", 4);
    await signIn();
    await open("Bob's sweep");
    await waitFor(() => configuration()?.text.startsWith("v3 · v4 is current"), "the two versions");
    expect(configuration()?.update).toBeNull();
  });

  it("keeps a raise asked while the agent works, and moves when it is done", async () => {
    const busy = harness.plane.seed("ada@example.com", { title: "Long refactor" });
    harness.plane.bundleCurrent.set("dev", 4);
    await signIn();
    await open("Long refactor");
    const behind = await waitFor(() => configuration()?.update ?? null, "Update");

    harness.worker.sessions.get(busy.id)!.status = "acting";
    behind.click();
    await waitFor(() => configuration()?.text.includes("Moves to v4 when the agent is done"), "the raise kept");
    expect(document.querySelector(".banner.error")).toBeNull();

    harness.worker.sessions.get(busy.id)!.status = "idle";
    harness.plane.landRaise(busy.id);
    await waitFor(() => configuration()?.text === "v4", "the version once it landed");
  });

  it("shows a refusal in the view's banner", async () => {
    harness.plane.seed("ada@example.com", { title: "Refused" });
    harness.plane.bundleCurrent.set("dev", 4);
    await signIn();
    await open("Refused");
    const update = await waitFor(() => configuration()?.update ?? null, "Update");

    harness.plane.refuseNext("session.bundle.raise", {
      code: -32602,
      message: "invalid_params",
      data: { field: "agent", agent: "build", agents: ["review"], reason: "v4 of stable does not offer build, which this session runs as" },
    });
    update.click();
    const banner = await waitFor(() => document.querySelector(".banner.error")?.textContent, "the banner");
    expect(banner).toContain("Its configuration was not updated");
    expect(banner).toContain("v4 of stable does not offer build");
    expect(configuration()?.text.startsWith("v3 · v4 is current")).toBe(true);
  });
});
