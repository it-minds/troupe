// A repository's memory, and the librarian a session's start begins on it (troupe #248
// and #516, the terminal client's Decisions 127 and 131).
//
// `memory.get` answers the brief, whether a librarian is due, and the facts with their
// status; `memory.forget` with an id forgets one. A session the client has just started
// starts the librarian as a branch of itself on a missing or stale brief, once onboarding
// is answered, where `memory_auto_refresh` is on, in a git repository, with a model to
// ask. Every call here is a real request to the fake daemon.

import assert from "node:assert/strict";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";
import {
  DaemonClient,
  LIBRARIAN_FIRST_PROMPT,
  LIBRARIAN_PROMPT,
  LIBRARIAN_REWRITING,
  LIBRARIAN_WRITING,
  StartQuestions,
  TroupeRpcError,
  factStatusLine,
  factsByKind,
  learnedBy,
  librarianBarred,
  librarianDone,
  mayNoLongerBeTrue,
  refreshNow,
  refreshStep,
} from "../src/index.js";
import type { MemoryFact, StartState } from "../src/index.js";
import { FakeDaemon, exampleFacts, exampleOnboarding } from "./support/daemon.js";

const REPO = "/home/ada/repo";

describe("a repository's memory, over the daemon", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  beforeEach(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  afterEach(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("reads the facts with their status, and forgets one by its id", async () => {
    daemon.memory[REPO] = { status: "fresh", built_at: "2026-10-08T09:00:00Z", facts: exampleFacts() };
    const brief = await client.memory(REPO);
    assert.equal(brief.generated, true);
    assert.deepEqual(
      brief.facts?.map((f) => [f.id, f.kind, f.status]),
      [
        ["f-check", "command", "current"],
        ["f-style", "convention", "moved"],
        ["f-layout", "overview", "missing"],
        ["f-note", "note", "unanchored"],
      ],
    );

    await client.forgetFact(REPO, "f-style");
    const forget = daemon.calls.find((c) => c.method === "memory.forget");
    assert.deepEqual({ workspace: forget?.params["workspace"], id: forget?.params["id"] }, { workspace: REPO, id: "f-style" });
    assert.match(String(forget?.params["command_id"]), /^c-/, "a command, so the daemon can tell a resend");
    assert.deepEqual(
      (await client.memory(REPO)).facts?.map((f) => f.id),
      ["f-check", "f-layout", "f-note"],
    );

    await assert.rejects(client.forgetFact(REPO, "f-gone"), (e: unknown) => e instanceof TroupeRpcError);

    // Without an id, the whole brief.
    await client.forgetBrief(REPO);
    const whole = daemon.calls.filter((c) => c.method === "memory.forget").at(-1);
    assert.equal("id" in (whole?.params ?? {}), false);
    const gone = await client.memory(REPO);
    assert.equal(gone.status, "absent");
    assert.deepEqual(gone.facts, []);
  });

  it("refreshes when asked: the librarian as a branch, with the first prompt where there is no brief, whatever memory_auto_refresh says", async () => {
    const parent = daemon.seed(REPO);
    daemon.memoryAutoRefresh = false;
    daemon.memory[REPO] = { status: "absent", refresh_held_until: "2026-10-17T09:00:00Z" };
    const first = await refreshNow(client, REPO, parent.id);
    assert.equal(first.said, LIBRARIAN_WRITING);
    assert.equal(first.librarian, daemon.librarians[0]?.sessionId);
    assert.deepEqual(
      daemon.librarians.map((l) => [l.parent, l.prompt, l.worktree]),
      [[parent.id, LIBRARIAN_FIRST_PROMPT, "never"]],
    );

    const again = await refreshNow(client, REPO, parent.id);
    assert.equal(again.said, LIBRARIAN_REWRITING);
    assert.equal(daemon.librarians[1]?.prompt, LIBRARIAN_PROMPT);

    const notes = daemon.seed("/home/ada/notes");
    const refused = await refreshNow(client, "/home/ada/notes", notes.id);
    assert.equal(refused.librarian, null);
    assert.equal(refused.said, "No librarian for the project brief: this is not a git repository, which is what a brief describes.");
    daemon.memoryOn = false;
    assert.equal((await refreshNow(client, REPO, parent.id)).said, "No librarian for the project brief: memory is off (memory: false in the workspace's config).");
    assert.equal(daemon.librarians.length, 2);
  });

  it("knows a librarian is done by its root's agent_done or its turn ending, not a subagent's", () => {
    assert.equal(librarianDone({ type: "agent_done", agent: ["root"] }), true);
    assert.equal(librarianDone({ type: "turn_ended", agent: ["root"] }), true);
    assert.equal(librarianDone({ type: "agent_done", agent: ["root", "explore#1"] }), false);
    assert.equal(librarianDone({ type: "llm_response", agent: ["root"] }), false);
  });

  it("answers a daemon from before facts with the brief's text and no facts", async () => {
    daemon.memory[REPO] = { status: "fresh", text: "# Project brief\n\n## Commands\n- make test" };
    const brief = await client.memory(REPO);
    assert.equal(brief.facts, undefined);
    assert.equal(brief.generated, undefined);
    assert.equal(brief.text, "# Project brief\n\n## Commands\n- make test");
  });
});

describe("the facts as a person reads them", () => {
  const fact = (id: string, kind: string, status: string): MemoryFact => ({
    id,
    kind,
    claim: id,
    scope: null,
    anchors: [],
    evidence: { session: null, seq: null, head: null, by: "librarian" },
    created_at: "2026-10-08T09:00:00Z",
    verified_at: "2026-10-08T09:00:00Z",
    status,
  });

  it("groups by kind in the terminal client's order, any other kind after, and no empty group", () => {
    const groups = factsByKind([fact("a", "note", "current"), fact("b", "command", "current"), fact("c", "flaky", "current"), fact("d", "negative", "moved")]);
    assert.deepEqual(
      groups.map((g) => [g.title, g.facts.map((f) => f.id)]),
      [
        ["Commands", ["b"]],
        ["What does not work", ["d"]],
        ["Notes", ["a"]],
        ["flaky", ["c"]],
      ],
    );
  });

  it("says moved and missing may no longer be true, and who learned a fact", () => {
    assert.equal(mayNoLongerBeTrue({ status: "moved" }), true);
    assert.equal(mayNoLongerBeTrue({ status: "missing" }), true);
    assert.equal(mayNoLongerBeTrue({ status: "current" }), false);
    assert.equal(mayNoLongerBeTrue({ status: "unanchored" }), false);
    assert.match(factStatusLine({ status: "moved" }), /^May no longer be true: a file it rests on has changed/);
    assert.match(factStatusLine({ status: "missing" }), /^May no longer be true: a file it rests on is gone/);
    assert.equal(learnedBy("agent:build"), "the build agent");
    assert.equal(learnedBy("librarian"), "the librarian");
    assert.equal(learnedBy("person"), "a person, in .troupe/memory.md");
  });
});

describe("whether the librarian may start by itself", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  beforeEach(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  afterEach(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("may in a git repository with the refresh on and a model", async () => {
    assert.equal(await librarianBarred(client, REPO), null);
  });

  it("may not, quietly, with memory or its refresh off, or outside a git repository", async () => {
    assert.deepEqual(await librarianBarred(client, "/home/ada/notes"), { why: "this is not a git repository, which is what a brief describes", say: false });
    daemon.memoryAutoRefresh = false;
    assert.deepEqual(await librarianBarred(client, REPO), { why: "memory_auto_refresh is off", say: false });
    daemon.memoryOn = false;
    assert.deepEqual(await librarianBarred(client, REPO), { why: "memory is off (memory: false in the workspace's config)", say: false });
  });

  it("may, when the person asks, with memory_auto_refresh off, and says every reason it may not", async () => {
    daemon.memoryAutoRefresh = false;
    assert.equal(await librarianBarred(client, REPO, { asked: true }), null);
    assert.deepEqual(await librarianBarred(client, "/home/ada/notes", { asked: true }), {
      why: "this is not a git repository, which is what a brief describes",
      say: true,
    });
  });

  it("may not with no model to ask, and says so", async () => {
    daemon.settings = { ...daemon.settings, exists: true, provider: "anthropic", api_key: null };
    const barred = await librarianBarred(client, REPO);
    assert.equal(barred?.say, true);
    assert.match(barred?.why ?? "", /^no model can be asked/);
  });

  it("asks the daemon whether one is due: a missing brief with the first prompt, a stale one with the refresh, a held one with its day", async () => {
    daemon.memory[REPO] = { status: "absent" };
    assert.deepEqual(await refreshStep(client, REPO), { start: LIBRARIAN_FIRST_PROMPT, status: "absent" });
    daemon.memory[REPO] = { status: "stale" };
    assert.deepEqual(await refreshStep(client, REPO), { start: LIBRARIAN_PROMPT, status: "stale" });
    daemon.memory[REPO] = { status: "absent", refresh_held_until: "2026-10-17T09:00:00Z" };
    const held = await refreshStep(client, REPO);
    assert.equal(held.start, undefined);
    assert.equal(held.start === undefined && held.say, true);
    assert.match(held.start === undefined ? held.why : "", /waits until 2026-10-17/);
    daemon.memory[REPO] = { status: "fresh" };
    assert.deepEqual(await refreshStep(client, REPO), { why: "the brief is fresh", say: false });
  });
});

describe("the librarian at a session's start", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;
  let states: StartState[];
  let parentId: string;

  const last = (): StartState => states.at(-1)!;
  const flow = (started: boolean, workspace = REPO): StartQuestions =>
    new StartQuestions(client, { workspace, sessionId: parentId, started, onState: (s) => states.push(s) });

  before(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  beforeEach(() => {
    states = [];
    daemon.calls.length = 0;
    daemon.librarians.length = 0;
    daemon.onboarding = {};
    daemon.onboardDeclined.clear();
    daemon.onboarded.clear();
    daemon.memory = {};
    daemon.memoryAutoRefresh = true;
    parentId = daemon.seed(REPO).id;
  });

  it("starts it as a branch of a session started here, on a missing brief, and says so", async () => {
    daemon.memory[REPO] = { status: "absent" };
    await flow(true).start();
    assert.deepEqual(daemon.librarians, [{ sessionId: daemon.librarians[0]!.sessionId, workspace: REPO, parent: parentId, prompt: LIBRARIAN_FIRST_PROMPT, worktree: "never" }]);
    assert.deepEqual(last().said, [LIBRARIAN_WRITING]);
    assert.equal(last().asking, null);
    assert.equal(last().librarian, daemon.librarians[0]!.sessionId, "the session a screen watches to read the brief again");
  });

  it("starts it on a stale brief with the refresh prompt", async () => {
    daemon.memory[REPO] = { status: "stale" };
    await flow(true).start();
    assert.deepEqual(
      daemon.librarians.map((l) => l.prompt),
      [LIBRARIAN_PROMPT],
    );
    assert.deepEqual(last().said, [LIBRARIAN_REWRITING]);
  });

  it("starts none for a session opened again", async () => {
    daemon.memory[REPO] = { status: "absent" };
    await flow(false).start();
    assert.equal(daemon.librarians.length, 0);
    assert.deepEqual(last().said, []);
  });

  it("starts it only once onboarding is answered", async () => {
    daemon.onboarding[REPO] = exampleOnboarding();
    daemon.memory[REPO] = { status: "absent" };
    const questions = flow(true);
    await questions.start();
    assert.equal(last().asking?.kind, "onboard");
    assert.equal(daemon.librarians.length, 0, "no librarian while onboarding is unanswered");
    await questions.answer("decline");
    assert.equal(daemon.librarians.length, 1);
    assert.deepEqual(
      daemon.calls.map((c) => c.method).filter((m) => m.startsWith("onboard.") || m === "session.create"),
      ["onboard.plan", "onboard.decline", "session.create"],
    );
    assert.equal(last().said.at(-1), LIBRARIAN_WRITING);
  });

  it("starts it with a daemon from before the start's questions, as the terminal client does", async () => {
    const old = new FakeDaemon({ osUser: "ada", onboard: false });
    await old.start();
    const oldClient = new DaemonClient({ transport: "ws", port: old.port, token: old.token });
    try {
      old.memory[REPO] = { status: "absent" };
      const parent = old.seed(REPO);
      const seen: StartState[] = [];
      await new StartQuestions(oldClient, { workspace: REPO, sessionId: parent.id, started: true, onState: (s) => seen.push(s) }).start();
      assert.equal(old.librarians.length, 1);
      assert.deepEqual(seen.at(-1)?.said, [LIBRARIAN_WRITING]);
    } finally {
      oldClient.disconnect();
      await old.stop();
    }
  });

  it("starts none while a try that built nothing is waited out, and says until when", async () => {
    daemon.memory[REPO] = { status: "absent", refresh_held_until: "2026-10-17T09:00:00Z" };
    await flow(true).start();
    assert.equal(daemon.librarians.length, 0);
    assert.match(last().said[0] ?? "", /^No librarian for the project brief: the last one built none, so the next waits until 2026-10-17/);
  });

  it("starts none, quietly, with memory_auto_refresh off or outside a git repository, and none on a fresh brief", async () => {
    daemon.memory[REPO] = { status: "absent" };
    daemon.memoryAutoRefresh = false;
    await flow(true).start();
    daemon.memoryAutoRefresh = true;
    daemon.memory["/home/ada/notes"] = { status: "absent" };
    await flow(true, "/home/ada/notes").start();
    daemon.memory[REPO] = { status: "fresh" };
    await flow(true).start();
    assert.equal(daemon.librarians.length, 0);
    assert.deepEqual(
      states.flatMap((s) => s.said),
      [],
    );
  });

  it("the start's own Re-run on an outdated brief is asked only where the librarian may start", async () => {
    daemon.onboarding[REPO] = { ...exampleOnboarding({ briefOutdated: true }), recorded: 2 };
    daemon.memoryAutoRefresh = false;
    await flow(false).start();
    assert.equal(last().asking, null);
    daemon.memoryAutoRefresh = true;
    await flow(false).start();
    assert.equal(last().asking?.kind, "brief");
  });
});
