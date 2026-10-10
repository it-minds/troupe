// The librarian at a session's start, and the memory view (troupe #516 and #248).
//
// A session this app starts in a git repository with no brief, or a stale one, starts the
// librarian as a branch of itself, as the terminal client does (its Decisions 127 and
// 131): when `memory_auto_refresh` is on, a model can be asked and the daemon says one is
// due, once onboarding is answered where it was due, once per start, and with a line in
// the transcript; never for a session opened again and never for a team session. The
// memory view is a backstage pane: the repository's facts by kind with their status,
// evidence on selection, and forgetting one; and, as the terminal client's `/memory`,
// a refresh under the start's conditions and forgetting the whole brief on a second word.
// It reads the memory again when a librarian it knows of is done. The daemon is the fake
// the client's tests use, so the assertions are on what reached it.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon, exampleFacts, exampleOnboarding } from "../../../packages/client/test/support/daemon.js";
import type { FakeFact } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, sleep, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const REPO = "/home/ada/repo";
const FIRST = "There is no project brief yet. Survey this repository and write one.";
const REFRESH = "The project brief is out of date. Revise it against the repository as it is now.";
const WRITING = "The librarian is writing the project brief, in a session of its own.";
const REWRITING = "The librarian is rewriting the project brief, in a session of its own.";

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  daemon.seed("/home/ada/notes");
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

function key(target: EventTarget, key: string, init: KeyboardEventInit = {}): void {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
}

/** Start a session in `workspace` from the start screen, as a person does. */
async function startIn(workspace: string): Promise<HTMLTextAreaElement> {
  unmount = render(<App />).unmount;
  await waitFor(() => says("/home/ada/notes"), "the daemon's session in the list");
  button("Start a session")!.click();
  const start = await waitFor(() => document.querySelector<HTMLElement>(".start"), "the start screen");
  type(start.querySelector<HTMLInputElement>("input")!, workspace);
  button("Start", start)!.click();
  return waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the session");
}

/** The session in `workspace` that is not the librarian's, from the list. */
async function openFromList(workspace: string): Promise<void> {
  const row = await waitFor(
    () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(workspace) && b.textContent.includes("build")),
    `the session in ${workspace} in the list`,
  );
  row.click();
  await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the session");
}

/** This app's lines in the transcript, in order. */
function transcriptNotes(): string[] {
  return [...document.querySelectorAll(".stream .start-note")].map((p) => p.textContent ?? "");
}

/** Until the start has asked the daemon about a model, the last thing it asks before `memory.get`. */
async function startSettled(): Promise<void> {
  await waitFor(() => daemon.calls.some((c) => c.method === "worktree.list" && c.params["workspace"]), "the start to look for a repository");
  await sleep(300);
}

function panel(): HTMLElement | null {
  return document.querySelector<HTMLElement>(".approval.start");
}

describe("a session's start and the librarian", () => {
  it("starts the librarian on a repository with no brief, as a branch of the session, and says so in the transcript", async () => {
    daemon.memory[REPO] = { status: "absent" };
    await startIn(REPO);

    await waitFor(() => daemon.librarians.length > 0, "the librarian");
    const parent = [...daemon.sessions.values()].find((s) => s.workspace === REPO && s.profile === "build")!;
    expect(daemon.librarians).toEqual([{ sessionId: expect.any(String), workspace: REPO, parent: parent.id, prompt: FIRST, worktree: "never" }]);
    const line = await waitFor(() => [...document.querySelectorAll(".stream .note")].find((p) => p.textContent === WRITING), "the line in the transcript");
    // After the session's own first line, where the start said it.
    expect(line.previousElementSibling?.textContent).toBe("session created on build");
  });

  it("starts it on a stale brief with the terminal client's refresh prompt", async () => {
    daemon.memory[REPO] = { status: "stale" };
    await startIn(REPO);
    await waitFor(() => transcriptNotes().includes(REWRITING), "the line");
    expect(daemon.librarians.map((l) => l.prompt)).toEqual([REFRESH]);
  });

  it("starts none while onboarding is asked, and starts it once onboarding is answered", async () => {
    daemon.onboarding[REPO] = exampleOnboarding();
    daemon.memory[REPO] = { status: "absent" };
    await startIn(REPO);
    await waitFor(() => panel()?.querySelector("h2")?.textContent === "Onboard 4 files from Claude Code and Cursor into Troupe's own?", "the onboarding question");
    await sleep(200);
    expect(daemon.librarians).toEqual([]);

    button("Not now", panel()!)!.click();
    await waitFor(() => daemon.librarians.length === 1, "the librarian, once onboarding is answered");
    await waitFor(() => transcriptNotes().length === 2, "both lines");
    expect(transcriptNotes()[0]).toMatch(/^Onboarding: not now\./);
    expect(transcriptNotes()[1]).toBe(WRITING);
    expect(
      daemon.calls.filter((c) => c.method.startsWith("onboard.") || (c.method === "session.create" && c.params["profile"] === "librarian")).map((c) => c.method),
    ).toEqual(["onboard.plan", "onboard.decline", "session.create"]);
  });

  it("starts it once per start: not again when the session is left and opened again, nor for one opened from the list", async () => {
    daemon.memory[REPO] = { status: "absent" };
    await startIn(REPO);
    await waitFor(() => daemon.librarians.length === 1, "the librarian");
    // The brief is missing again, as if that librarian had built nothing.
    daemon.memory[REPO] = { status: "absent" };

    button("← Sessions")!.click();
    await openFromList(REPO);
    const line = await waitFor(() => [...document.querySelectorAll(".stream .start-note")].find((p) => p.textContent === WRITING), "the start's line, still there");
    await waitFor(() => line.previousElementSibling?.textContent === "session created on build", "the line where it was said");
    await sleep(300);
    expect(daemon.librarians.length).toBe(1);

    // The app started again: the session is one that was there, and starts nothing.
    unmount?.();
    daemon.calls.length = 0;
    unmount = render(<App />).unmount;
    await openFromList(REPO);
    await sleep(300);
    expect(daemon.librarians.length).toBe(1);
    expect(daemon.calls.some((c) => c.method === "memory.get")).toBe(false);
  });

  it("says why none starts when no model can be asked", async () => {
    daemon.settings = { ...daemon.settings, exists: true, provider: "anthropic", api_key: null };
    daemon.memory[REPO] = { status: "absent" };
    await startIn(REPO);
    await waitFor(
      () => transcriptNotes().includes("No librarian for the project brief: no model can be asked with this computer's settings; This computer > Models sets one up."),
      "why none started",
    );
    expect(daemon.librarians).toEqual([]);
  });

  it("says until when a try that built nothing holds the next one off", async () => {
    daemon.memory[REPO] = { status: "absent", refresh_held_until: "2026-10-17T09:00:00Z" };
    await startIn(REPO);
    await waitFor(() => transcriptNotes().some((n) => n.startsWith("No librarian for the project brief: the last one built none, so the next waits until 2026-10-17")), "the hold");
    expect(daemon.librarians).toEqual([]);
  });

  it("starts none and says nothing outside a git repository, or with memory_auto_refresh off", async () => {
    daemon.memory["/home/ada/notes"] = { status: "absent" };
    await startIn("/home/ada/notes");
    await startSettled();
    expect(daemon.librarians).toEqual([]);
    expect(transcriptNotes()).toEqual([]);

    unmount?.();
    daemon.calls.length = 0;
    daemon.memoryAutoRefresh = false;
    daemon.memory[REPO] = { status: "absent" };
    await startIn(REPO);
    await waitFor(() => daemon.calls.some((c) => c.method === "config.get" && c.params["workspace"] === REPO), "the start to read the config");
    await sleep(300);
    expect(daemon.librarians).toEqual([]);
    expect(transcriptNotes()).toEqual([]);
  });
});

describe("the memory view", () => {
  async function openMemory(composer: HTMLTextAreaElement): Promise<HTMLElement> {
    key(composer, "/");
    const dialog = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Commands"]'), "the palette");
    await waitFor(() => dialog.querySelector(".row"), "the commands");
    const row = [...dialog.querySelectorAll<HTMLElement>(".row")].find((r) => r.textContent?.startsWith("/memory"))!;
    // A command this app runs now, not one it greys.
    expect(row.classList.contains("unavailable")).toBe(false);
    type(dialog.querySelector<HTMLInputElement>("input")!, "memory");
    await waitFor(() => dialog.querySelector('.row[aria-selected="true"] .name')?.textContent === "/memory", "the memory row");
    key(dialog.querySelector("input")!, "Enter");
    return waitFor(() => document.querySelector<HTMLElement>(".backstage .memory"), "the memory view");
  }

  it("opens on /memory: the facts by kind with their status, evidence on selection, and one forgotten", async () => {
    daemon.memory[REPO] = { status: "fresh", built_at: "2026-10-08T09:00:00Z", facts: exampleFacts() };
    const composer = await startIn(REPO);
    const memory = await openMemory(composer);
    await waitFor(() => memory.querySelector(".fact"), "the facts");

    expect([...memory.querySelectorAll(".fact-kind h4")].map((h) => h.textContent)).toEqual(["Commands", "Conventions", "Overview", "Notes"]);
    // Changed or gone since written: may no longer be true, in the caution colour, and the
    // pane says how many.
    const doubtful = [...memory.querySelectorAll(".fact")].filter((f) => f.querySelector(".pill.offline")).map((f) => f.querySelector(".claim .text")?.textContent);
    expect(doubtful).toEqual(["Components live in src/components, one per file", "The protocol's schema is generated from schema.ex"]);
    expect(memory.querySelector(".fact .pill.offline")?.textContent).toContain("May no longer be true");
    expect(memory.textContent).toContain("2 facts may no longer be true");
    expect(memory.querySelector(".fact.unanchored")?.textContent).toContain("not tied to a file");

    // Its evidence when it is chosen.
    const style = [...memory.querySelectorAll<HTMLButtonElement>(".fact .claim")].find((b) => b.textContent?.startsWith("Components live"))!;
    style.click();
    const evidence = await waitFor(() => memory.querySelector<HTMLElement>(".evidence-of"), "the evidence");
    expect(evidence.textContent).toContain("May no longer be true: a file it rests on has changed since it was written.");
    expect(evidence.textContent).toContain("src/components/index.ts");
    expect(evidence.textContent).toContain("aa01bb02cc03");
    expect(evidence.textContent).toContain("the build agent");
    expect(evidence.textContent).toContain("s-41 · event 433");
    expect(evidence.textContent).toContain("7f8a221");
    expect(evidence.textContent).toContain("src/**");

    // Forgotten on a second word, by its id.
    button("Forget", evidence)!.click();
    (await waitFor(() => button("Forget it", evidence), "the second word")).click();
    await waitFor(() => ![...memory.querySelectorAll(".fact .claim .text")].some((t) => t.textContent?.startsWith("Components live")), "the fact gone");
    const forget = daemon.calls.find((c) => c.method === "memory.forget");
    expect({ workspace: forget?.params["workspace"], id: forget?.params["id"] }).toEqual({ workspace: REPO, id: "f-style" });
    expect(memory.textContent).toContain("1 fact may no longer be true");

    // A command's evidence says how the command ended.
    [...memory.querySelectorAll<HTMLButtonElement>(".fact .claim")].find((b) => b.textContent?.startsWith("The gate"))!.click();
    const gate = await waitFor(() => memory.querySelector<HTMLElement>(".evidence-of"), "the gate's evidence");
    expect(gate.textContent).toContain("Exit status0");
  });

  /** A fact a librarian learned since, with a command in backticks. */
  const docsFact = (): FakeFact => ({
    ...exampleFacts()[0]!,
    id: "f-docs",
    claim: "The docs build with `mix docs`",
    anchors: [{ path: "mix.exs", hash: "3f9a6c0e2b7d41a58c9e0f1d2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d" }],
  });

  function memoryPane(): HTMLElement {
    return document.querySelector<HTMLElement>(".backstage .memory")!;
  }

  it("refreshes from the pane, reads the memory again when that librarian is done, and sets a command in a claim as code", async () => {
    daemon.memory[REPO] = { status: "fresh", built_at: "2026-10-08T09:00:00Z", facts: exampleFacts() };
    const composer = await startIn(REPO);
    const memory = await openMemory(composer);
    await waitFor(() => memory.querySelector(".fact"), "the facts");
    expect(memory.querySelector(".fact .claim code")?.textContent).toBe("mix check");

    button("Refresh", memory)!.click();
    await waitFor(() => memoryPane().textContent?.includes(REWRITING), "what the refresh did");
    const parent = [...daemon.sessions.values()].find((s) => s.workspace === REPO && s.profile === "build")!;
    expect(daemon.librarians.map((l) => [l.parent, l.prompt, l.worktree])).toEqual([[parent.id, REFRESH, "never"]]);

    // The librarian learns a fact; the pane shows it once the librarian is done, not before.
    daemon.memory[REPO]!.facts!.push(docsFact());
    await sleep(200);
    expect(memoryPane().textContent).not.toContain("The docs build with");
    daemon.sessions.get(daemon.librarians[0]!.sessionId)!.log.append("agent_done", { reason: "finished" });
    await waitFor(() => memoryPane().textContent?.includes("The docs build with mix docs"), "the fact the librarian wrote");
  });

  it("reads the memory again when the start's librarian is done", async () => {
    daemon.memory[REPO] = { status: "absent", facts: [] };
    await startIn(REPO);
    await waitFor(() => daemon.librarians.length === 1, "the start's librarian");
    button("Memory", document.querySelector<HTMLElement>(".backstage")!)!.click();
    await waitFor(() => memoryPane()?.textContent?.includes("No facts yet."), "the memory as it was");
    daemon.memory[REPO]!.facts!.push(docsFact());
    daemon.sessions.get(daemon.librarians[0]!.sessionId)!.log.append("agent_done", { reason: "finished" });
    await waitFor(() => memoryPane().textContent?.includes("The docs build with mix docs"), "the fact the start's librarian wrote");
  });

  it("says why /memory refresh starts no librarian outside a git repository, and starts it there with memory_auto_refresh off", async () => {
    daemon.memory["/home/ada/notes"] = { status: "fresh", facts: [] };
    const composer = await startIn("/home/ada/notes");
    key(composer, "/");
    const dialog = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Commands"]'), "the palette");
    await waitFor(() => dialog.querySelector(".row"), "the commands");
    type(dialog.querySelector<HTMLInputElement>("input")!, "memory refresh");
    await waitFor(() => dialog.querySelector('.row[aria-selected="true"] .name')?.textContent === "/memory", "the memory row");
    key(dialog.querySelector("input")!, "Enter");
    await waitFor(
      () => memoryPane()?.textContent?.includes("No librarian for the project brief: this is not a git repository, which is what a brief describes."),
      "why none started",
    );
    expect(daemon.librarians).toEqual([]);

    // A refresh asked for is not the automatic one memory_auto_refresh turns off.
    unmount?.();
    daemon.memoryAutoRefresh = false;
    daemon.memory[REPO] = { status: "fresh", facts: exampleFacts() };
    await startIn(REPO);
    button("Memory", document.querySelector<HTMLElement>(".backstage")!)!.click();
    await waitFor(() => memoryPane()?.querySelector(".fact"), "the facts");
    button("Refresh", memoryPane())!.click();
    await waitFor(() => daemon.librarians.length === 1, "the librarian, asked for");
  });

  it("forgets the whole brief on a second word, from the pane or /memory forget", async () => {
    daemon.memory[REPO] = { status: "fresh", built_at: "2026-10-08T09:00:00Z", facts: exampleFacts() };
    const composer = await startIn(REPO);
    key(composer, "/");
    const dialog = await waitFor(() => document.querySelector<HTMLElement>('[role="dialog"][aria-label="Commands"]'), "the palette");
    await waitFor(() => dialog.querySelector(".row"), "the commands");
    type(dialog.querySelector<HTMLInputElement>("input")!, "memory forget");
    await waitFor(() => dialog.querySelector('.row[aria-selected="true"] .name')?.textContent === "/memory", "the memory row");
    key(dialog.querySelector("input")!, "Enter");

    // Asked, not done: the second word first.
    const ask = await waitFor(() => document.querySelector<HTMLElement>('.backstage .memory [aria-label="Forget the brief"]'), "the second word");
    expect(daemon.calls.some((c) => c.method === "memory.forget")).toBe(false);
    button("Keep it", ask)!.click();
    await waitFor(() => !document.querySelector('.backstage .memory [aria-label="Forget the brief"]'), "kept");

    button("Forget the brief", memoryPane())!.click();
    const again = await waitFor(() => document.querySelector<HTMLElement>('.backstage .memory [aria-label="Forget the brief"]'), "the second word again");
    button("Forget all of it", again)!.click();
    await waitFor(() => memoryPane().textContent?.includes("There is no project brief yet."), "the brief gone");
    expect(memoryPane().querySelector(".fact")).toBeNull();
    const forget = daemon.calls.filter((c) => c.method === "memory.forget");
    expect(forget.map((c) => [c.params["workspace"], "id" in c.params])).toEqual([[REPO, false]]);
  });

  it("shows the brief's text from a daemon whose memory.get has no facts", async () => {
    daemon.memory[REPO] = { status: "fresh", text: "# Project brief\n\n## Commands\n- make test" };
    await startIn(REPO);
    button("Memory", document.querySelector<HTMLElement>(".backstage")!)!.click();
    const text = await waitFor(() => document.querySelector(".backstage .memory .brief-text"), "the brief's text");
    expect(text.textContent).toBe("# Project brief\n\n## Commands\n- make test");
    expect(document.querySelector(".backstage .memory .fact")).toBeNull();
  });
});

describe("a team session", () => {
  let harness: Harness;

  beforeEach(async () => {
    harness = await startHarness();
  });

  afterEach(async () => {
    await harness.stop();
  });

  it("starts no librarian, asks this computer's daemon nothing about memory, and has no memory pane", async () => {
    localStorage.removeItem("troupe.pref.localOnly");
    const plane = harness.plane;
    plane.seed("alice@example.com", { id: "team-1", title: "Plan the release", profile: "dev" });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
    daemon.memory["/workspace"] = { status: "absent" };

    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Plan the release")), "the team session's row");
    row.click();
    await waitFor(() => document.querySelector(".backstage"), "the session");
    await sleep(300);
    expect(daemon.librarians).toEqual([]);
    expect(daemon.calls.filter((c) => c.method.startsWith("memory.") || c.method === "worktree.list")).toEqual([]);
    expect(button("Memory", document.querySelector<HTMLElement>(".backstage")!)).toBeNull();
  });
});
