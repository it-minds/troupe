// One agent picker on the start screen and in a session's head (troupe #594), driven the
// way a person drives it against the fake daemon over a real socket: its rows are the
// daemon's `agents.list`, grouped by where each agent comes from in the four words, and the
// same three actions are on it in both places. Start makes a session on the agent, Switch
// changes the agent of the session open, and Edit opens a person's or a repository's agent
// file in their editor through the shell, and is refused, in the daemon's words, for one
// Troupe ships and one an organisation's bundle carries.
//
// On the chunk's tip the start screen on this computer had no agent to choose at all, the
// head's switch was a drop-down that only switched, and nothing opened an agent's file.

import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, sees, startButton, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const REPO = "/home/ada/repo";
const CAREFUL = "---\ndescription: Reads and reports, never writes.\nmode: primary\ntools:\n  - read_file\n  - grep\n  - finish\n---\nYou read and report.\n";

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;
let opened: string[] = [];

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  opened = [];
  window.troupe = {
    name: "Test shell",
    version: "0",
    openAgentFile: async (path: string) => {
      opened.push(path);
    },
  };
});

afterEach(async () => {
  delete window.troupe;
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

/** A button of the picker's, once it is drawn and not busy. */
function enabled(picker: ParentNode, label: string): Promise<HTMLButtonElement> {
  return waitFor(() => {
    const b = button(label, picker);
    return b && !b.disabled ? b : null;
  }, label);
}
function option(picker: ParentNode, name: string): HTMLButtonElement | undefined {
  return [...picker.querySelectorAll<HTMLButtonElement>('[role="option"]')].find((o) => o.querySelector(".name")?.textContent?.replace(" ●", "") === name);
}

function groupOf(picker: ParentNode, name: string): string | null {
  return option(picker, name)?.closest('[role="group"]')?.getAttribute("aria-label") ?? null;
}

async function alertIn(picker: ParentNode, text: string): Promise<void> {
  await waitFor(() => picker.querySelector('[role="alert"]')?.textContent?.includes(text), `"${text}" said`);
}

describe("the agent picker", () => {
  it("on the start screen is a plain pick: each agent with what it does, the default marked, nothing to switch or edit", async () => {
    daemon.seed("/home/ada/notes");
    daemon.agents.files.push({ name: "careful", layer: "project", workspace: REPO, text: CAREFUL });
    unmount = render(<App />).unmount;
    await sees("/home/ada/notes");
    button("Start a session")!.click();
    const start = await waitFor(() => document.querySelector<HTMLElement>(".start"), "the start screen");
    type(start.querySelector<HTMLInputElement>('input[aria-label="Which directory"]')!, REPO);

    const chip = (): HTMLButtonElement | null => start.querySelector<HTMLButtonElement>('button.ns-chip[aria-label^="Which agent"]');
    (await waitFor(chip, "the agent chip")).click();
    const pick = (name: string): HTMLButtonElement | undefined =>
      [...start.querySelectorAll<HTMLButtonElement>(".ns-picker button.ns-opt")].find((o) => o.querySelector(".ns-opt-label")?.textContent === name);
    const careful = await waitFor(() => pick("careful"), "the repository's agent");
    expect(careful.textContent).toContain("Reads and reports, never writes.");
    expect(pick("build")!.textContent).toContain("DEFAULT");
    expect(pick("build")!.getAttribute("aria-pressed")).toBe("true");
    // Before a session exists there is nothing to start on, switch or edit from here.
    const picker = start.querySelector<HTMLElement>(".ns-picker")!;
    for (const word of ["Start a session on", "Switch to", "Edit "]) expect(button(word, picker)).toBeNull();
    expect(picker.textContent).not.toContain("change it in the console");

    // A click picks it and closes the picker; Start starts on it.
    careful.click();
    await waitFor(() => chip()?.textContent?.startsWith("careful") && start.querySelector(".ns-picker") === null, "careful chosen, the picker closed");
    (await startButton(start)).click();
    await waitFor(() => document.querySelector('textarea[aria-label="Message"]'), "the session");
    const created = daemon.calls.find((c) => c.method === "session.create" && c.params["workspace"] === REPO);
    expect(created?.params).toMatchObject({ workspace: REPO, profile: "careful" });
  });

  it("in a session's head starts another session on an agent, and refuses an organisation's agent's edit", async () => {
    daemon.seed(REPO);
    daemon.agents.files.push({ name: "deploy", layer: "bundle", text: "---\ndescription: Ships it.\nmode: primary\n---\nYou deploy.\n" });
    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(REPO)), "the session in the list");
    row.click();
    const head = await waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
    (await waitFor(() => document.querySelector<HTMLButtonElement>('.composer button[aria-label="Agent"]'), "the agent switch")).click();
    // It opens in a dialog over the screen, so the head keeps its height.
    const box = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"][aria-label="The agent this session runs"]'), "the agent's dialog");
    expect(head.contains(box)).toBe(false);
    const picker = await waitFor(() => box.querySelector<HTMLElement>('[role="group"][aria-label="Agents"]'), "the picker");

    // The line a refusal is said on is there before anything is said, a line high, so the
    // dialog does not move when one is. jsdom lays nothing out, so the rule is read.
    expect(picker.querySelector(".agent-picker-said")).not.toBeNull();
    const sheet = "../src/styles.css";
    const css = readFileSync(new URL(sheet, import.meta.url), "utf8");
    const at = css.indexOf(".agent-picker-said {");
    expect(css.slice(at, css.indexOf("}", at))).toContain("min-height: 1.3em");

    // An agent whose file is not this computer's to change says why, with no Edit to refuse.
    (await waitFor(() => option(picker, "deploy"), "the bundle's agent")).click();
    expect(groupOf(picker, "deploy")).toBe("Your organisation's");
    await waitFor(() => picker.querySelector(".agent-picker-detail")?.textContent?.includes("deploy comes from the profile's bundle; change it in the console."), "why it is not edited here");
    expect(button("Edit deploy's file", picker)).toBeNull();
    await waitFor(() => button("Switch to deploy", picker), "deploy offered as a switch");
    expect(opened).toEqual([]);

    // The agent it runs is marked as running, not offered as a switch.
    option(picker, "build")!.click();
    await waitFor(() => picker.querySelector(".agent-picker-detail .actions")?.textContent?.includes("build runs now"), "build marked as running");
    expect(button("Switch to build", picker)).toBeNull();
    expect(daemon.calls.some((c) => c.method === "profile.switch")).toBe(false);

    option(picker, "plan")!.click();
    (await enabled(picker, "Start a session on plan")).click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.create" && c.params["profile"] === "plan"), "a session started on plan");
    expect(daemon.calls.find((c) => c.method === "session.create" && c.params["profile"] === "plan")?.params).toMatchObject({ workspace: REPO });
    await waitFor(() => document.querySelector('.composer button[aria-label="Agent"] .mono')?.textContent === "plan", "the new session open, on plan");
  });
});
