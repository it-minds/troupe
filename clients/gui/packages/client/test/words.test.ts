// What the desktop app and the console both say, from one helper each (troupe #1028): an
// error, a size, money, a length of time, how long ago, a session's state and an answered
// approval. The durations and the money are the terminal's, where it shows the same thing.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { TroupeRpcError, ago, bytes, decisionWords, durationWords, errorText, moneyWords, sessionStateWords } from "../src/index.js";

describe("the words both apps say", () => {
  it("an error is the server's reason, else its message, else the value", () => {
    const refused = new TroupeRpcError("session.create", { code: -32003, message: "forbidden", data: { reason: "This profile is not one of your teams'." } });
    assert.equal(errorText(refused), "This profile is not one of your teams'.");
    const unsaid = new TroupeRpcError("session.create", { code: -32003, message: "forbidden", data: { reason: "" } });
    assert.equal(errorText(unsaid), unsaid.message);
    assert.equal(errorText({ data: { reason: "said by a plain object" } }), "said by a plain object");
    assert.equal(errorText(new Error("socket closed")), "socket closed");
    assert.equal(errorText("no daemon"), "no daemon");
    assert.equal(errorText(42), "42");
    assert.equal(errorText(undefined, "Mermaid could not read it"), "Mermaid could not read it");
  });

  it("a size is in binary units, one decimal place, the nought left out", () => {
    assert.equal(bytes(0), "0 bytes");
    assert.equal(bytes(1), "1 byte");
    assert.equal(bytes(1023), "1023 bytes");
    assert.equal(bytes(1024), "1 KiB");
    assert.equal(bytes(1536), "1.5 KiB");
    assert.equal(bytes(1024 * 1024 - 1), "1 MiB");
    assert.equal(bytes(3 * 1024 ** 3), "3 GiB");
    assert.equal(bytes(null), "—");
  });

  it("money is to the cent, half up, and anything less than one is under a cent", () => {
    assert.equal(moneyWords(0), "$0.00");
    assert.equal(moneyWords(4000), "under a cent");
    assert.equal(moneyWords(9_999), "under a cent");
    assert.equal(moneyWords(10_000), "$0.01");
    assert.equal(moneyWords(1_000_000), "$1.00");
    assert.equal(moneyWords(1_234_999), "$1.23");
    assert.equal(moneyWords(1_235_000), "$1.24");
    assert.equal(moneyWords(1_473_500_000), "$1,473.50");
    assert.equal(moneyWords(-2_500_000), "−$2.50");
    assert.equal(moneyWords(null), "—");
  });

  it("a length of time reads as the terminal says it, and a limit's size as an adjective", () => {
    assert.equal(durationWords(0), "0 s");
    assert.equal(durationWords(1500), "1.5 s");
    assert.equal(durationWords(59_000), "59 s");
    assert.equal(durationWords(59_960), "1 min");
    assert.equal(durationWords(61_000), "1 min 1 s");
    assert.equal(durationWords(3_660_000), "1 h 1 min");
    assert.equal(durationWords(undefined), "—");
    assert.equal(durationWords(45_000, "adjective"), "45-second");
    assert.equal(durationWords(1_800_000, "adjective"), "30-minute");
    assert.equal(durationWords(5_400_000, "adjective"), "90-minute");
    assert.equal(durationWords(7_200_000, "adjective"), "2-hour");
  });

  it("how long ago is the coarsest unit that still says something, and a date from thirty days", () => {
    const now = Date.parse("2026-11-17T12:00:00Z");
    assert.equal(ago(now, now), "just now");
    assert.equal(ago(now - 59_000, now), "just now");
    assert.equal(ago(now - 3 * 60_000 - 30_000, now), "3 min ago");
    assert.equal(ago("2026-11-17T10:00:00Z", now), "2 h ago");
    assert.equal(ago(now - 30 * 3_600_000, now), "yesterday");
    assert.equal(ago(now - 4 * 86_400_000, now), "4 days ago");
    assert.equal(ago("2026-10-01T09:00:00Z", now), "2026-10-01");
    assert.equal(ago("not a time", now), "—");
  });

  it("a session's state is one word in both apps, never the protocol's key", () => {
    assert.deepEqual(
      ["active", "working", "waiting", "idle", "failed", "dormant", "read_only", "erasure_pending", "something_new"].map(sessionStateWords),
      ["Active", "Working", "Waiting for you", "Idle", "Failed", "Asleep", "Read only", "Erasure pending", "Something new"],
    );
  });

  it("an answered approval starts with one word for its answer", () => {
    assert.deepEqual(["allow", "allow_session", "allow_always", "deny", undefined].map(decisionWords), ["Allowed", "Allowed for this session", "Always allowed", "Denied", "Allowed"]);
  });
});
