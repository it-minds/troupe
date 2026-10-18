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

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, sees, startOnTheList, type, waitFor } from "./support";

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
  it("on the start screen lists the workspace's agents by where they come from, and starts one", async () => {
    daemon.seed("/home/ada/notes");
    daemon.agents.files.push({ name: "careful", layer: "project", workspace: REPO, text: CAREFUL });
    daemon.agents.files.push({ name: "mine", layer: "user", text: "---\ndescription: Mine.\nmode: primary\n---\nYou are mine.\n" });
    unmount = render(<App />).unmount;
    await sees("/home/ada/notes");
    button("Start a session")!.click();
    const start = await waitFor(() => document.querySelector<HTMLElement>(".start"), "the start screen");
    type(start.querySelector<HTMLInputElement>("input")!, REPO);

    const picker = await waitFor(() => start.querySelector<HTMLElement>('[role="group"][aria-label="The agent it starts as"]'), "the picker");
    await waitFor(() => option(picker, "careful"), "the repository's agent");
    expect(groupOf(picker, "careful")).toBe("This repository's");
    expect(groupOf(picker, "mine")).toBe("Yours");
    expect(groupOf(picker, "build")).toBe("Shipped");
    expect(option(picker, "careful")!.textContent).toContain("read only");

    // A built-in's file is Troupe's: refused, with how it is changed instead.
    option(picker, "plan")!.click();
    (await enabled(picker, "Edit plan's file")).click();
    await alertIn(picker, "plan is built in: a copy of it in your agents or the repository's");
    expect(opened).toEqual([]);

    // There is no session yet to switch.
    (await enabled(picker, "Switch to plan")).click();
    await alertIn(picker, "There is no session to switch yet");

    // The repository's opens in the editor, by its file.
    option(picker, "careful")!.click();
    (await enabled(picker, "Edit careful's file")).click();
    await waitFor(() => opened.length === 1, "the file opened");
    expect(opened).toEqual([`${REPO}/.troupe/agents/careful.md`]);

    // Start, from the picker: a session on careful in that workspace.
    (await enabled(picker, "Start a session on careful")).click();
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
    (await waitFor(() => head.querySelector<HTMLButtonElement>('button[aria-label="Agent"]'), "the agent switch")).click();
    const picker = await waitFor(() => head.querySelector<HTMLElement>('[role="group"][aria-label="Agents"]'), "the picker");

    (await waitFor(() => option(picker, "deploy"), "the bundle's agent")).click();
    expect(groupOf(picker, "deploy")).toBe("Your organisation's");
    (await enabled(picker, "Edit deploy's file")).click();
    await alertIn(picker, "deploy comes from the profile's bundle; change it in the console");
    expect(opened).toEqual([]);

    // Switching to the agent it runs says so, and asks nothing of the daemon.
    option(picker, "build")!.click();
    (await enabled(picker, "Switch to build")).click();
    await alertIn(picker, "This session runs build already.");
    expect(daemon.calls.some((c) => c.method === "profile.switch")).toBe(false);

    option(picker, "plan")!.click();
    (await enabled(picker, "Start a session on plan")).click();
    await waitFor(() => daemon.calls.some((c) => c.method === "session.create" && c.params["profile"] === "plan"), "a session started on plan");
    expect(daemon.calls.find((c) => c.method === "session.create" && c.params["profile"] === "plan")?.params).toMatchObject({ workspace: REPO });
    await waitFor(() => document.querySelector(".session-head button[aria-label=\"Agent\"]")?.textContent === "Agent plan", "the new session open, on plan");
  });
});
