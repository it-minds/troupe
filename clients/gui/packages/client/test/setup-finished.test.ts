// What a screen goes by when the answer to a first run's `finish` never reached it (troupe
// #739): the daemon's record. A run finished since the screen last heard is one whose
// record is newer, or a first run the daemon no longer wants; and the finished flow it
// would have been answered with is built from what the person answered.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { finishedFlow, setupFinishedSince } from "../src/index.js";
import type { SetupFlow } from "../src/index.js";

const record = (at: string, choice = "plane") => ({ completed_at: at, choice, subject: "local:ada" });

function flow(extra: Partial<SetupFlow>): SetupFlow {
  return {
    needed: true,
    completed: null,
    step: "where",
    steps: [],
    answers: {},
    detected: {
      env: [],
      opencode: { path: "", providers: [], default: null },
      config: { exists: false, path: "", provider: null, base_url: null, api_key_set: false, api_key_source: null, models: {}, usable: false },
      plane: { url: null, linked: false },
    },
    key_storage: { kind: "file", path: "", keychain: false },
    offered: [],
    suggested: { default: null, cheap: null },
    check: null,
    suggested_prompt: null,
    session: null,
    ...extra,
  };
}

describe("a first run finished since a screen last heard", () => {
  it("is a newer record, or a first run no longer wanted, and nothing else", () => {
    assert.equal(setupFinishedSince(flow({}), flow({ needed: false, completed: record("2026-10-18T09:00:00Z") })), true);
    assert.equal(setupFinishedSince(flow({}), flow({ needed: false })), true, "a config written meanwhile: nothing left to ask");
    assert.equal(setupFinishedSince(flow({}), flow({})), false);
    // The rail's re-run: the record is there from the start, and only a newer one is a finish.
    const before = flow({ needed: false, completed: record("2026-09-01T08:00:00Z", "local") });
    assert.equal(setupFinishedSince(before, flow({ needed: false, completed: record("2026-09-01T08:00:00Z", "local") })), false);
    assert.equal(setupFinishedSince(before, flow({ needed: false, completed: record("2026-10-18T09:00:00Z") })), true);
  });

  it("finishes with the person's answers, no session, and the plane the record names where none was named here", () => {
    const named = flow({ step: "finish", answers: { where: { choice: "plane", plane_url: "https://troupe.example" } } });
    const now = flow({ needed: false, completed: record("2026-10-18T09:00:00Z") });
    const done = finishedFlow(named, now);
    assert.equal(done.step, "done");
    assert.deepEqual(done.answers.where, { choice: "plane", plane_url: "https://troupe.example" });
    assert.equal(done.session, null);
    assert.deepEqual(done.completed, now.completed);

    assert.deepEqual(finishedFlow(flow({}), now).answers.where, { choice: "plane", plane_url: null });
    assert.equal(finishedFlow(flow({}), flow({ needed: false, completed: record("2026-10-18T09:00:00Z", "local") })).answers.where, undefined);
  });
});
