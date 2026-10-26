// The review queue and a run whose turn failed (defects.md D58): its row carries `failed`
// with the reason, and the queue sorted it with the runs that finished and said "Ended:
// Idle", since only a budget or a model error counted as gone wrong. A failed turn counts
// now, and says so.

import { describe, expect, it } from "vitest";
import { ended, wentWrong } from "../src/views/Review";

const finished = { failed: null, doneReason: null, status: "idle" };
const toolFailures = { failed: { reason: "tool_failures", detail: null }, doneReason: null, status: "idle" };

describe("a run whose turn failed, in the review queue", () => {
  it("went wrong, as a run out of budget did, and says it failed and why", () => {
    expect(wentWrong(toolFailures)).toBe(true);
    expect(wentWrong({ ...finished, doneReason: "budget_exhausted" })).toBe(true);
    expect(wentWrong(finished)).toBe(false);

    expect(ended(toolFailures)).toBe("Failed: Tool failures");
    expect(ended(finished)).toBe("Idle");
    expect(ended({ ...finished, doneReason: "budget_exhausted" })).toBe("Budget exhausted");
    expect(ended({ failed: null, doneReason: null, status: null })).toBe("still going");
  });
});
