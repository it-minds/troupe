// The review queue and a run whose turn failed: its row carries `failed`
// with the reason, and the queue sorted it with the runs that finished and said "Ended:
// Idle", since only a budget or a model error counted as gone wrong. A failed turn counts
// now, and says so.
//
// A card says only what is true of its session (troupe #896): it read "Fired never" for a
// session a trigger had started, where the runs were not the reader's to see, and "Ended
// Idle" for one that had not ended. Fired is said only of a session a trigger started, and
// an open session's Ended says it is still open.

import { afterEach, describe, expect, it } from "vitest";
import { webTokenStore } from "@troupe/client";
import { ended, firedAt, Review, wentWrong } from "../src/views/Review";
import { startHarness } from "../../../packages/client/test/support/harness.js";
import type { Harness } from "../../../packages/client/test/support/harness.js";
import { render, waitFor } from "./support";

const finished = { failed: null, doneReason: null, status: "idle" };
const toolFailures = { failed: { reason: "tool_failures", detail: null }, doneReason: null, status: "idle" };

describe("a run whose turn failed, in the review queue", () => {
  it("went wrong, as a run out of budget did, and says it failed and why", () => {
    expect(wentWrong(toolFailures)).toBe(true);
    expect(wentWrong({ ...finished, doneReason: "budget_exhausted" })).toBe(true);
    expect(wentWrong(finished)).toBe(false);

    expect(ended(toolFailures)).toBe("Failed: Tool failures");
    expect(ended({ ...finished, doneReason: "budget_exhausted" })).toBe("Budget exhausted");
  });
});

describe("a review card", () => {
  let harness: Harness | null = null;
  let unmount: (() => void) | null = null;

  afterEach(async () => {
    unmount?.();
    unmount = null;
    await harness?.stop();
    harness = null;
  });

  it("says an open session is still open, not its status", () => {
    expect(ended(finished)).toBe("still open");
    expect(ended({ ...finished, status: "waiting" })).toBe("still open");
    expect(ended({ failed: null, doneReason: null, status: null })).toBe("still open");
    expect(ended({ ...finished, status: "done" })).toBe("Done");
  });

  it("says when a trigger fired it, from the run or else from the session's making, and nothing of one no trigger started", () => {
    const made = { kind: "trigger", trigger: "nightly-deps" };
    expect(firedAt({ origin: made, raw: { created_at: "2026-11-14T02:00:00Z" } }, { fired_at: "2026-11-14T01:59:58Z" })).toBe("2026-11-14T01:59:58Z");
    expect(firedAt({ origin: made, raw: { created_at: "2026-11-14T02:00:00Z" } }, undefined)).toBe("2026-11-14T02:00:00Z");
    expect(firedAt({ origin: made, raw: {} }, undefined)).toBeNull();
    expect(firedAt({ origin: { kind: "a2a" }, raw: { created_at: "2026-11-14T02:00:00Z" } }, undefined)).toBeUndefined();
    expect(firedAt({ origin: null, raw: null }, undefined)).toBeUndefined();
  });

  it("on a trigger's idle session the reader cannot see the runs of, reads a time for Fired and still open for Ended", async () => {
    harness = await startHarness();
    const auth = await harness.signIn({ store: webTokenStore() });
    harness.plane.seed("alice@example.com", { title: "Nightly dependency sweep", origin: { kind: "trigger", trigger: "nightly-deps" } });
    unmount = render(<Review auth={auth} admin={null} daemon={null} teams={[]} onOpen={() => {}} />).unmount;

    const card = await waitFor(
      () => [...document.querySelectorAll<HTMLElement>(".inbox > li")].find((li) => li.textContent?.includes("Nightly dependency sweep")),
      "the trigger's card",
    );
    const facts = Object.fromEntries([...card.querySelectorAll("dl.facts dt")].map((dt) => [dt.textContent, dt.nextElementSibling?.textContent ?? ""]));
    expect(facts["Fired"]).not.toBe("never");
    expect(facts["Fired"]).toMatch(/now|ago/);
    expect(card.querySelector("dl.facts dt + dd time")).not.toBeNull();
    expect(facts["Ended"]).toBe("still open");
  });
});
