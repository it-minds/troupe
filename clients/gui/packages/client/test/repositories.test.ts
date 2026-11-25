// A pod session's GitHub repositories (troupe #1207): what a row says it holds, in the words
// both web apps say it, the plane calls that attach one and take one off, and the line a
// transcript shows when one moves.

import assert from "node:assert/strict";
import { describe, it, test } from "node:test";
import {
  ErrorCodes,
  TroupeRpcError,
  emptyTranscript,
  fold,
  listedRepositories,
  readRepository,
  repositoriesLeft,
  repositoriesOf,
  repositoriesSummary,
  repositoryChangedText,
  repositoryParam,
  repositoryRefusal,
  repositoryWhere,
  repositoryWork,
  rowFromPlane,
} from "../src/index.js";
import type { DurableEvent, Entry, SessionRow } from "../src/index.js";
import { startHarness } from "./support/harness.js";

describe("a session's repositories", () => {
  it("are the row's list, or an older plane's one repository at the root", () => {
    const listed = { repositories: [{ owner: "o", name: "a", path: "." }, { owner: "o", name: "b", path: "o/b" }] };
    assert.deepEqual(repositoriesOf(listed).map((r) => r.name), ["a", "b"]);
    assert.deepEqual(repositoriesOf({ repository: { owner: "o", name: "a" }, github: { branch: "troupe/x" } }), [
      { owner: "o", name: "a", path: ".", github: { branch: "troupe/x" } },
    ]);
    assert.deepEqual(repositoriesOf({}), []);
    assert.deepEqual(rowFromPlane({ id: "s", ...listed } as unknown as SessionRow).repositories, ["o/a", "o/b"]);
  });

  it("are summed up as the first and how many more", () => {
    assert.equal(repositoriesSummary([]), "");
    assert.equal(repositoriesSummary(["o/a"]), "o/a");
    assert.equal(repositoriesSummary(["o/a", "o/b", "o/c"]), "o/a +2 more");
  });

  it("say where each clone is and what the session did there", () => {
    assert.equal(repositoryWhere({ path: "." }), "at the workspace's root");
    assert.equal(repositoryWhere({ path: "o/b" }), "in o/b/");
    assert.equal(repositoryWork({ github: null }), "nothing pushed yet");
    assert.equal(repositoryWork({ github: { branch: "troupe/x", commit: "abcdef1234" } }), "troupe/x at abcdef1");
    assert.equal(repositoryWork({ github: { branch: "troupe/x", pull_request: { number: 4, url: "u" } } }), "draft #4 from troupe/x");
  });

  it("are read as a person types one, and sent as the plane takes one", () => {
    assert.deepEqual(readRepository("example-org/widgets"), { owner: "example-org", name: "widgets", ref: null });
    assert.deepEqual(readRepository(" example-org/widgets@release-2 "), { owner: "example-org", name: "widgets", ref: "release-2" });
    assert.equal(readRepository("widgets"), null);
    assert.equal(readRepository("o/.."), null);
    assert.equal(repositoryParam({ owner: "o", name: "a", ref: null }), "o/a");
    assert.deepEqual(repositoryParam({ owner: "o", name: "a", ref: "main" }), { owner: "o", name: "a", ref: "main" });
    assert.deepEqual(listedRepositories(["o/a", "p/*", "bad"]), { named: ["o/a"], owners: ["p"] });
    assert.equal(repositoriesLeft(1, 3), "A session here holds up to 3; 2 more may be added.");
    assert.equal(repositoriesLeft(3, 3), "That is as many as a session here holds (3).");
  });

  it("say why the plane would not attach one or take one off", () => {
    const refused = (code: number, data?: Record<string, unknown>) => new TroupeRpcError("session.repository.add", { code, message: "x", ...(data ? { data } : {}) });
    assert.equal(repositoryRefusal(refused(ErrorCodes.forbidden, { required_role: "owner" }), true), "It was not attached: only the session's owner attaches a repository or takes one off.");
    assert.equal(
      repositoryRefusal(refused(ErrorCodes.conflict, { reason: "busy", detail: "o/b has a push going" }), false),
      "It was not taken off: o/b has a push going.",
    );
    assert.equal(
      repositoryRefusal(refused(ErrorCodes.invalid_params, { field: "repository", reason: "a session on the profile dev holds at most 3 repositories (spec.github.maxRepositories)" }), true),
      "It was not attached: a session on the profile dev holds at most 3 repositories (spec.github.maxRepositories).",
    );
  });

  it("move in the transcript as one line each", () => {
    let seq = 0;
    const durable = (data: Record<string, unknown>): DurableEvent =>
      ({ seq: ++seq, prev_hash: null, ts: "2026-11-26T10:00:00Z", actor: { kind: "system" }, agent: ["root"], type: "session_repository_changed", v: 1, data }) as DurableEvent;
    const state = [
      durable({ action: "attached", repository: "o/b", path: "o/b", by_name: "Ada", repositories: [] }),
      durable({ action: "detached", repository: "o/b", path: "o/b", by_name: "Ada", repositories: [] }),
      durable({ action: "failed", repository: "o/c", path: "o/c", reason: "git said: not found", repositories: [] }),
    ].reduce((s, e) => fold(s, e), emptyTranscript);
    const lines = state.entries.filter((e): e is Extract<Entry, { kind: "system" }> => e.kind === "system").map((e) => e.text);
    assert.deepEqual(lines, ["o/b attached by Ada, cloned in o/b/", "o/b taken off by Ada; its directory is gone", "o/c could not be cloned: git said: not found"]);
    assert.equal(repositoryChangedText({ action: "attached", repository: "o/a", path: "." }), "o/a attached, cloned at the workspace's root");
  });
});

test("a session is created on repositories, has one attached and one taken off, as the plane is asked", async (t) => {
  const h = await startHarness({ plane: { github: { repositories: ["example-org/widgets", "example-org/gadgets"], profiles: { dev: 3 } } } });
  t.after(() => h.stop());
  const auth = await h.signIn();

  const created = await auth.withToken((plane, token) =>
    plane.createSession(token, { profile: "dev", repositories: ["example-org/widgets", { owner: "example-org", name: "gadgets", ref: "main" }] }),
  );
  const row = await auth.withToken((plane, token) => plane.addSessionRepository(token, created.session_id, "example-org/docs").catch((e: unknown) => e));
  assert.ok(row instanceof TroupeRpcError);
  assert.match(repositoryRefusal(row, true), /does not list example-org\/docs/);

  const removed = await auth.withToken((plane, token) => plane.removeSessionRepository(token, created.session_id, "example-org/gadgets"));
  assert.deepEqual(repositoriesOf(removed).map((r) => r.name), ["widgets"]);
  const added = await auth.withToken((plane, token) => plane.addSessionRepository(token, created.session_id, "example-org/gadgets"));
  assert.deepEqual(repositoriesOf(added).map((r) => [r.name, r.path]), [["widgets", "."], ["gadgets", "example-org/gadgets"]]);
});
