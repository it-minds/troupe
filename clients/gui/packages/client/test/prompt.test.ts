// `prompt()` and when it is allowed to return.
//
// A turn ends when the turn ends — not when the slowest thing the method happened to be
// waiting for gives up. Deltas are best-effort by contract, so a turn can legitimately
// produce none: a dropped ephemeral under load, a tool-only turn, or a model that simply
// answered in one piece. Before this, `prompt` still held its `llm_delta` waiter open in
// the final `allSettled`, so those turns took the full `timeoutMs` to resolve — sixty
// seconds by default, and the bench calls `prompt` for every prompt it measures.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { startHarness, type Harness } from "./support/harness.js";

describe("prompt()", () => {
  let h: Harness;
  before(async () => {
    h = await startHarness();
  });
  after(async () => {
    await h.stop();
  });

  /** A session of our own, so a slow turn in one test cannot be seen by another. */
  async function session() {
    const auth = await h.signIn();
    const created = await auth.rpc<{ session_id: string }>("session.create", { profile: "dev" });
    return h.attach(auth, created.session_id);
  }

  it("returns when a turn that streamed nothing ends, not when its delta waiter expires", async () => {
    const a = await session();
    // `quiet:` answers with no `llm_delta` at all — the case that used to hang.
    const started = Date.now();
    const turn = await a.view.prompt("quiet: answer without streaming", 30_000);
    const elapsed = Date.now() - started;

    assert.match(turn.text, /silently/, "the turn really did answer");
    assert.equal(turn.marks.firstDelta, undefined, "and it really did stream nothing");
    // The turn is over in milliseconds; anything near the timeout is the old behaviour.
    assert.ok(elapsed < 5_000, `prompt returned promptly (${elapsed}ms, timeout was 30000)`);
    assert.ok(turn.marks.done !== undefined && turn.marks.done < 5_000, "and said so in its marks");
    await a.close();
  });

  it("still times the first delta when there is one", async () => {
    const a = await session();
    const turn = await a.view.prompt("hello", 30_000);

    assert.match(turn.text, /You said: hello/);
    assert.ok(turn.marks.firstDelta !== undefined, "a streamed turn still reports its first delta");
    assert.ok(turn.marks.accepted !== undefined, "and its acknowledgement");
    assert.ok(turn.marks.response !== undefined, "and its durable response");
    await a.close();
  });

  it("leaves no waiter behind to fire into a finished turn", async () => {
    const a = await session();
    await a.view.prompt("quiet: one", 30_000);
    await a.view.prompt("quiet: two", 30_000);

    // Two turns, both quiet: if the first turn's abandoned waiters were still in the
    // list they would match the second turn's events and resolve the wrong promise.
    const third = await a.view.prompt("three", 30_000);
    assert.match(third.text, /You said: three/, "the third turn is still its own");
    await a.close();
  });
});
