// Onboarding, then the librarian, at a session's start (troupe #516, Decision 835).
//
// A session that starts in a workspace with other tools' files and nothing onboarded has
// `onboarding_suggested` in its log; the app asks the daemon for the plan and asks the
// person, where the approval panel sits: one question for the lot, each file's diff under
// Review, a new AGENTS.md asked on its own, and only after that the brief and the
// librarian. The daemon is the fake the client's tests use, which keeps what was answered
// as the contract says, so the assertions are on what reached it.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { LIBRARIAN_PROMPT, webTokenStore } from "@troupe/client";
import { App } from "../src/App";
import { FakeDaemon, exampleOnboarding } from "../../../packages/client/test/support/daemon.js";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { button, render, says, startOnTheList, type, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

const REPO = "/home/ada/repo";
const QUESTION = "Onboard 4 files from Claude Code and Cursor into Troupe's own?";
const CREATE = "AGENTS.md is not there. Create it? Every coding tool reads AGENTS.md, not only Troupe.";
const BRIEF = "The librarian's survey changed (v1 to v2): rewrite the brief now?";

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

/** Start a session in `workspace` from the start screen, as a person does. */
async function startIn(workspace: string): Promise<void> {
  unmount = render(<App />).unmount;
  await waitFor(() => says("/home/ada/notes"), "the daemon's session in the list");
  button("Start a session")!.click();
  const start = await waitFor(() => document.querySelector<HTMLElement>(".start"), "the start screen");
  type(start.querySelector<HTMLInputElement>("input")!, workspace);
  button("Start", start)!.click();
  await waitFor(() => document.querySelector<HTMLTextAreaElement>('textarea[aria-label="Message"]'), "the session");
}

function panel(): HTMLElement | null {
  return document.querySelector<HTMLElement>(".approval.start");
}

/** The panel once it asks `text`. */
function asking(text: string): Promise<HTMLElement> {
  return waitFor(() => {
    const p = panel();
    return p?.querySelector("h2")?.textContent === text && p;
  }, `the question "${text}"`);
}

/** Press the panel's button once it is there and not busy. */
async function press(label: string): Promise<void> {
  const b = await waitFor(() => {
    const found = panel() && button(label, panel()!);
    return found && !found.disabled && found;
  }, `the ${label} button`);
  b.click();
}

/** What the start's methods were called with, in order. */
function calls(): Array<[string, unknown]> {
  return daemon.calls
    .filter((c) => c.method.startsWith("onboard.") || c.method === "memory.decline" || (c.method === "session.create" && c.params["profile"] === "librarian"))
    .map((c) => [c.method, c.method === "onboard.plan" ? c.params["workspace"] : (c.params["ids"] ?? (c.params["all"] ? "all" : c.params["profile"] ?? c.params["workspace"]))]);
}

describe("a session's start in a workspace onboarding is due in", () => {
  it("asks the one question, writes all with Onboard, asks the new AGENTS.md on its own, and starts the librarian only after", async () => {
    daemon.onboarding[REPO] = exampleOnboarding({ briefOutdated: true });
    await startIn(REPO);

    const question = await asking(QUESTION);
    // The harness's own line is in the stream too, as it was before anything asked.
    expect(says("Other tools' files are here")).toBe(true);
    // The files it is about, and what it passed over.
    expect([...question.querySelectorAll(".onboard-files li")].map((li) => li.textContent)).toEqual([
      "AGENTS.md new, and not there yet, from CLAUDE.md",
      "web/AGENTS.md adds to the one that is there, from web/CLAUDE.md",
      ".troupe/rules/style.md new, from .cursor/rules/style.mdc",
      ".troupe/rules/legacy.md new, from .cursorrules",
    ]);
    expect(question.textContent).toContain("Not proposed: CLAUDE.local.md");
    expect([...question.querySelectorAll(".answers button")].map((b) => [b.textContent, b.className])).toEqual([
      ["Onboard", "allow"],
      ["Review", "deny"],
      ["Not now", "deny"],
    ]);

    await press("Onboard");
    const create = await asking(CREATE);
    expect(create.querySelector(".diff-lines .add")?.textContent).toBe("+ # AGENTS.md");
    // Onboarding is not answered yet, so no librarian and no brief question.
    expect(daemon.librarians).toEqual([]);
    expect(says(BRIEF)).toBe(false);

    await press("Create AGENTS.md");
    await asking(BRIEF);
    await waitFor(() => says("Onboarding: wrote web/AGENTS.md, .troupe/rules/style.md, .troupe/rules/legacy.md and AGENTS.md."), "what onboarding did");
    // Re-run is the default: first, and the one filled.
    expect(panel()!.querySelector(".answers button")?.textContent).toBe("Re-run");
    expect(panel()!.querySelector(".answers button")?.className).toBe("allow");

    await press("Re-run");
    await waitFor(() => says("The librarian is rewriting the project brief, in a session of its own."), "the librarian started");
    await waitFor(() => panel() === null, "no question left");
    expect(calls()).toEqual([
      ["onboard.plan", REPO],
      ["onboard.apply", "all"],
      ["onboard.apply", ["p1"]],
      ["session.create", "librarian"],
    ]);
    const parent = [...daemon.sessions.values()].find((s) => s.workspace === REPO && s.profile === "build")!;
    expect(daemon.librarians).toEqual([{ sessionId: expect.any(String), workspace: REPO, parent: parent.id, prompt: LIBRARIAN_PROMPT, worktree: "never" }]);
    expect(daemon.planOf(REPO).onboarding.due).toBe("none");
  });

  it("shows each file's diff under Review, with Write and Skip, and the new AGENTS.md in its own words", async () => {
    daemon.onboarding[REPO] = exampleOnboarding();
    await startIn(REPO);
    await asking(QUESTION);
    await press("Review");

    await asking(CREATE);
    await press("Don't create");

    const web = await asking("Write web/AGENTS.md?");
    expect(web.querySelector(".consequence")?.textContent).toBe("adds to the one that is there, from web/CLAUDE.md · file 2 of 4");
    const lines = [...web.querySelectorAll(".diff-lines > span")].map((s) => [s.className, s.textContent]);
    expect(lines).toEqual([
      ["ctx", "  # web"],
      ["ctx", "  "],
      ["add", "+ Components live in src/components, one per file."],
    ]);
    expect([...web.querySelectorAll(".answers button")].map((b) => b.textContent)).toEqual(["Write", "Skip"]);
    await press("Write");

    const style = await asking("Write .troupe/rules/style.md?");
    expect(style.textContent).toContain("file 3 of 4");
    await press("Skip");

    const legacy = await asking("Write .troupe/rules/legacy.md?");
    expect(legacy.querySelector(".onboard-notes")?.textContent).toBe("the legacy file is always applied");
    await press("Write");

    await waitFor(() => says("Onboarding: wrote web/AGENTS.md and .troupe/rules/legacy.md; did not write AGENTS.md and .troupe/rules/style.md."), "what onboarding did");
    await waitFor(() => panel() === null, "no question left: the brief is not due");
    expect(calls()).toEqual([
      ["onboard.plan", REPO],
      ["onboard.decline", ["p1"]],
      ["onboard.apply", ["p2"]],
      ["onboard.decline", ["p3"]],
      ["onboard.apply", ["p4"]],
    ]);
  });

  it("says no to all with Not now, and asks nothing when the session is opened again", async () => {
    daemon.onboarding[REPO] = exampleOnboarding();
    await startIn(REPO);
    await asking(QUESTION);
    await press("Not now");
    await waitFor(() => says("Onboarding: not now."), "the no, said");
    expect(panel()).toBeNull();
    expect(calls()).toEqual([
      ["onboard.plan", REPO],
      ["onboard.decline", "all"],
    ]);

    // Opened again: the event is in the log still, the plan says nothing is due.
    unmount?.();
    daemon.calls.length = 0;
    unmount = render(<App />).unmount;
    const row = await waitFor(
      () => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(REPO)),
      "the session in the list",
    );
    row.click();
    await waitFor(() => daemon.calls.some((c) => c.method === "onboard.plan"), "the plan asked again");
    await waitFor(() => says("Other tools' files are here"), "the harness's line, replayed");
    expect(panel()).toBeNull();
    expect(calls()).toEqual([["onboard.plan", REPO]]);
  });

  it("asks the re-run, Re-run first, when the workspace was onboarded under older rules", async () => {
    daemon.onboarding[REPO] = { ...exampleOnboarding({ briefOutdated: true }), recorded: 1 };
    await startIn(REPO);
    const question = await asking("Onboarding rules changed since this repository was onboarded (v1 to v2). Re-run now?");
    expect([...question.querySelectorAll(".answers button")].map((b) => [b.textContent, b.className])).toEqual([
      ["Re-run", "allow"],
      ["Review", "deny"],
      ["Not now", "deny"],
    ]);
    await press("Not now");
    await asking(BRIEF);
    await press("Not now");
    await waitFor(() => says("The brief stays as it is"), "the brief's no, said");
    expect(calls()).toEqual([
      ["onboard.plan", REPO],
      ["onboard.decline", "all"],
      ["memory.decline", REPO],
    ]);
    expect(daemon.librarians).toEqual([]);
  });

  it("shows the refusal and asks nothing where onboarding may not run", async () => {
    const refusal = "Onboarding runs on your own machine, not on a pod: run `troupe onboard` in your checkout, commit what it writes, and sessions here read it from the repository.";
    daemon.onboarding[REPO] = { ...exampleOnboarding({ briefOutdated: true }), refusal };
    await startIn(REPO);
    await waitFor(() => says(refusal), "the refusal");
    expect(panel()).toBeNull();
    expect(calls()).toEqual([["onboard.plan", REPO]]);
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

  it("asks nothing and asks this computer's daemon nothing: its pod is not this computer's to onboard", async () => {
    localStorage.removeItem("troupe.pref.localOnly");
    const plane = harness.plane;
    plane.seed("alice@example.com", { id: "team-1", title: "Plan the release", profile: "dev" });
    harness.worker.sessions.get("team-1")!.log.append("onboarding_suggested", {
      workspace: "/workspace",
      reasons: ["first"],
      due: "first",
      brief_due: "none",
      message: "Other tools' files are here: `troupe onboard` would bring in 2 rules as Troupe's own files.",
    });
    await harness.signIn({ store: webTokenStore() });
    localStorage.setItem("troupe.pref.planeUrl", plane.baseUrl);
    localStorage.setItem("troupe.pref.appearance.chosen.alice@example.com", "yes");
    daemon.onboarding["/workspace"] = exampleOnboarding();

    unmount = render(<App />).unmount;
    const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes("Plan the release")), "the team session's row");
    row.click();
    await waitFor(() => says("would bring in 2 rules"), "the harness's line");
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(panel()).toBeNull();
    expect(calls()).toEqual([]);
  });
});
