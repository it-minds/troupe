// Onboarding, then the librarian, at a session's start (troupe #516, Decision 835).
//
// The daemon says what a start found due (`onboarding_suggested`), plans it
// (`onboard.plan`) and takes the person's answers (`onboard.apply`, `onboard.decline`,
// `memory.decline`); the client asks. Every call here is a real request to the fake
// daemon, which answers with the contract's shapes and keeps what was answered.

import assert from "node:assert/strict";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";
import { DaemonClient, LIBRARIAN_PROMPT, StartQuestions, emptyTranscript, fold } from "../src/index.js";
import type { StartAnswer, StartState, TroupeEvent } from "../src/index.js";
import { FakeDaemon, exampleOnboarding } from "./support/daemon.js";

const REPO = "/home/ada/repo";

describe("the onboarding methods, over the daemon", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  beforeEach(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    daemon.onboarding[REPO] = exampleOnboarding({ briefOutdated: true });
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  afterEach(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("plans, writes every file that is only a write with all, and a new AGENTS.md only when named", async () => {
    const plan = await client.onboardPlan(REPO);
    assert.equal(plan.onboarding.due, "first");
    assert.equal(plan.onboarding.version, 2);
    assert.deepEqual(plan.onboarding.tools, ["Claude Code", "Cursor"]);
    assert.deepEqual(
      plan.onboarding.items.map((i) => [i.id, i.question]),
      [
        ["p1", "create_agents_md"],
        ["p2", "write"],
        ["p3", "write"],
        ["p4", "write"],
      ],
    );
    assert.equal(plan.brief.due, "outdated");
    assert.equal(plan.refusal, null);

    const all = await client.onboardApply(REPO, "all");
    assert.deepEqual(
      all.written.map((w) => [w.shown, w.action]),
      [
        ["web/AGENTS.md", "replaced"],
        [".troupe/rules/style.md", "created"],
        [".troupe/rules/legacy.md", "created"],
      ],
    );
    assert.deepEqual(all.refused, []);
    const apply = daemon.calls.find((c) => c.method === "onboard.apply");
    assert.equal(apply?.params["all"], true);
    assert.match(String(apply?.params["command_id"]), /^c-/, "a command, so the daemon can tell a resend");

    // The new AGENTS.md is left, and the plan is not answered until it is.
    const left = await client.onboardPlan(REPO);
    assert.equal(left.onboarding.due, "first");
    assert.deepEqual(
      left.onboarding.items.map((i) => i.id),
      ["p1"],
    );

    const named = await client.onboardApply(REPO, ["p1"]);
    assert.deepEqual(
      named.written.map((w) => w.shown),
      ["AGENTS.md"],
    );
    const done = await client.onboardPlan(REPO);
    assert.equal(done.onboarding.due, "none");
    assert.equal(done.onboarding.recorded, 2, "the version is recorded once every file is answered");
  });

  it("declines all for this version, declines one, and declines an outdated brief", async () => {
    const one = await client.onboardDecline(REPO, ["p3"]);
    assert.equal(one.declined, 1);
    assert.deepEqual(
      (await client.onboardPlan(REPO)).onboarding.items.map((i) => i.id),
      ["p1", "p2", "p4"],
    );

    const rest = await client.onboardDecline(REPO, "all");
    assert.equal(rest.declined, 3);
    const plan = await client.onboardPlan(REPO);
    assert.equal(plan.onboarding.due, "none");

    await client.declineBrief(REPO);
    assert.equal((await client.onboardPlan(REPO)).brief.due, "none");
    const decline = daemon.calls.find((c) => c.method === "memory.decline");
    assert.equal(decline?.params["workspace"], REPO);
    assert.match(String(decline?.params["command_id"]), /^c-/);
  });

  it("starts the librarian as a branch of the session, in the checkout, with the terminal client's prompt", async () => {
    const parent = daemon.seed(REPO);
    const created = await client.startLibrarian({ workspace: REPO, parent: parent.id, prompt: LIBRARIAN_PROMPT });
    assert.ok(created.session_id);
    const call = daemon.calls.find((c) => c.method === "session.create");
    assert.deepEqual(
      { profile: call?.params["profile"], worktree: call?.params["worktree"], parent: call?.params["parent"], prompt: call?.params["prompt"] },
      { profile: "librarian", worktree: "never", parent: parent.id, prompt: LIBRARIAN_PROMPT },
    );
    assert.equal(daemon.librarians.length, 1);
  });
});

describe("the start's questions", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;
  let states: StartState[];
  let parentId: string;

  const flow = (workspace = REPO): StartQuestions => new StartQuestions(client, { workspace, sessionId: parentId, onState: (s) => states.push(s) });
  const last = (): StartState => states.at(-1)!;
  const methods = (): string[] => daemon.calls.map((c) => c.method).filter((m) => m.startsWith("onboard.") || m === "memory.decline" || m === "session.create");
  const answer = async (questions: StartQuestions, a: StartAnswer, kind: string): Promise<void> => {
    assert.equal(last().asking?.kind, kind, `asked ${kind} before answering ${a}`);
    await questions.answer(a);
  };

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
    daemon.onboarded.clear();
    daemon.onboardDeclined.clear();
    daemon.briefDeclined.clear();
    daemon.librarians.length = 0;
    daemon.onboarding = {};
    parentId = daemon.seed(REPO).id;
  });

  it("asks the one question, writes all, asks the new AGENTS.md on its own, then the brief, and only then starts the librarian", async () => {
    daemon.onboarding[REPO] = exampleOnboarding({ briefOutdated: true });
    const questions = flow();
    await questions.start();
    const asked = last().asking;
    assert.equal(asked?.kind, "onboard");
    assert.equal(asked?.text, "Onboard 4 files from Claude Code and Cursor into Troupe's own?");
    assert.deepEqual(asked?.kind === "onboard" ? asked.skipped.map((s) => s.source) : [], ["CLAUDE.local.md"]);

    await answer(questions, "onboard", "onboard");
    const create = last().asking;
    assert.equal(create?.kind, "create");
    assert.equal(create?.text, "AGENTS.md is not there. Create it? Every coding tool reads AGENTS.md, not only Troupe.");
    assert.equal(daemon.librarians.length, 0, "no librarian while onboarding is unanswered");

    await answer(questions, "create", "create");
    assert.deepEqual(last().said, ["Onboarding: wrote web/AGENTS.md, .troupe/rules/style.md, .troupe/rules/legacy.md and AGENTS.md."]);
    assert.equal(last().asking?.kind, "brief");
    assert.equal(last().asking?.text, "The librarian's survey changed (v1 to v2): rewrite the brief now?");

    await answer(questions, "rerun", "brief");
    assert.equal(last().asking, null);
    assert.equal(last().said.at(-1), "The librarian is rewriting the project brief, in a session of its own.");
    assert.deepEqual(methods(), ["onboard.plan", "onboard.apply", "onboard.apply", "session.create"]);
    assert.deepEqual(daemon.librarians.map((l) => [l.workspace, l.parent, l.worktree]), [[REPO, parentId, "never"]]);
    assert.equal(daemon.planOf(REPO).onboarding.recorded, 2);
  });

  it("reviews each file as a diff, writing one and skipping one, and a new AGENTS.md is still its own question", async () => {
    daemon.onboarding[REPO] = exampleOnboarding();
    const questions = flow();
    await questions.start();
    await answer(questions, "review", "onboard");

    const first = last().asking;
    assert.equal(first?.kind, "create", "the plan's first file is the new AGENTS.md, asked in its own words");
    await answer(questions, "skip", "create");

    const second = last().asking;
    assert.equal(second?.kind, "review");
    if (second?.kind !== "review") return;
    assert.equal(second.text, "Write web/AGENTS.md?");
    assert.equal(second.index, 2);
    assert.equal(second.total, 4);
    assert.match(second.item.diff, /^\+ Components live/m);
    await answer(questions, "write", "review");
    await answer(questions, "skip", "review");
    await answer(questions, "write", "review");

    assert.equal(last().asking, null, "no brief question: the brief is not due");
    assert.deepEqual(last().said, ["Onboarding: wrote web/AGENTS.md and .troupe/rules/legacy.md; did not write AGENTS.md and .troupe/rules/style.md."]);
    assert.deepEqual(
      daemon.calls.filter((c) => c.method === "onboard.apply" || c.method === "onboard.decline").map((c) => [c.method, c.params["ids"]]),
      [
        ["onboard.decline", ["p1"]],
        ["onboard.apply", ["p2"]],
        ["onboard.decline", ["p3"]],
        ["onboard.apply", ["p4"]],
      ],
    );
    assert.equal(daemon.planOf(REPO).onboarding.due, "none");
  });

  it("not now declines all for this version and asks nothing more when the brief is not due", async () => {
    daemon.onboarding[REPO] = exampleOnboarding();
    const questions = flow();
    await questions.start();
    await answer(questions, "decline", "onboard");
    assert.equal(last().asking, null);
    assert.match(last().said[0]!, /^Onboarding: not now\./);
    const decline = daemon.calls.find((c) => c.method === "onboard.decline");
    assert.equal(decline?.params["all"], true);
    assert.equal(daemon.planOf(REPO).onboarding.due, "none");
  });

  it("asks the re-run when the workspace was onboarded under older rules, and a no to the brief is remembered", async () => {
    daemon.onboarding[REPO] = { ...exampleOnboarding({ briefOutdated: true }), recorded: 1 };
    const questions = flow();
    await questions.start();
    assert.equal(last().asking?.text, "Onboarding rules changed since this repository was onboarded (v1 to v2). Re-run now?");
    await answer(questions, "decline", "onboard");
    assert.match(last().said[0]!, /^Onboarding: not re-run\./);
    await answer(questions, "decline", "brief");
    assert.equal(last().asking, null);
    assert.deepEqual(methods(), ["onboard.plan", "onboard.decline", "memory.decline"]);
    assert.equal(daemon.librarians.length, 0);
    assert.equal(daemon.planOf(REPO).brief.due, "none");
  });

  it("asks the brief alone when only the brief is due", async () => {
    daemon.onboarding[REPO] = { ...exampleOnboarding({ briefOutdated: true }), recorded: 2 };
    const questions = flow();
    await questions.start();
    assert.equal(last().asking?.kind, "brief");
  });

  it("says the refusal and asks nothing where onboarding may not run", async () => {
    const refusal = "Onboarding runs on your own machine, not on a pod: run `troupe onboard` in your checkout, commit what it writes, and sessions here read it from the repository.";
    daemon.onboarding[REPO] = { ...exampleOnboarding({ briefOutdated: true }), refusal };
    const questions = flow();
    await questions.start();
    assert.equal(last().refusal, refusal);
    assert.equal(last().asking, null);
    assert.deepEqual(methods(), ["onboard.plan"]);
  });

  it("asks nothing in a workspace with nothing due", async () => {
    const questions = flow("/home/ada/notes");
    await questions.start();
    assert.equal(last().asking, null);
    assert.deepEqual(last().said, []);
    assert.equal(last().error, null);
  });

  it("asks nothing of a daemon from before the questions, and says no error", async () => {
    const old = new FakeDaemon({ osUser: "ada", onboard: false });
    await old.start();
    const oldClient = new DaemonClient({ transport: "ws", port: old.port, token: old.token });
    try {
      const seen: StartState[] = [];
      const questions = new StartQuestions(oldClient, { workspace: REPO, sessionId: "s-1", onState: (s) => seen.push(s) });
      await questions.start();
      assert.equal(seen.at(-1)?.asking, null);
      assert.equal(seen.at(-1)?.error, null);
    } finally {
      oldClient.disconnect();
      await old.stop();
    }
  });
});

describe("onboarding_suggested in the transcript", () => {
  it("is the harness's line, and keeps where and what is due for the screen that asks", () => {
    const event = {
      seq: 2,
      ts: "2026-10-10T08:00:00Z",
      type: "onboarding_suggested",
      agent: ["root"],
      actor: { kind: "system" },
      data: { workspace: REPO, due: "first", brief_due: "outdated", counts: { rules: 2 }, message: "Other tools' files are here.", reasons: ["first", "brief"] },
    } as unknown as TroupeEvent;
    const state = fold(emptyTranscript, event);
    assert.deepEqual(state.onboarding, { seq: 2, workspace: REPO, due: "first", briefDue: "outdated" });
    assert.deepEqual(
      state.entries.map((e) => (e.kind === "system" ? [e.type, e.text] : e.kind)),
      [["onboarding_suggested", "Other tools' files are here."]],
    );
  });
});
