// How long an artifact is kept, in the words both apps use (#981): nothing at all where the
// plane gives no date, a card's line and a page's sentences where it does.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { goesDate, goesLine, goesSentence, versionGoes, versionsSentence } from "../src/index.js";
import type { ArtifactVersion } from "../src/index.js";

const now = new Date("2026-11-16T12:00:00Z");
const v = (n: number, goes_at: string | null): ArtifactVersion => ({ n, goes_at }) as ArtifactVersion;

describe("retention words", () => {
  it("say nothing where no period is set", () => {
    assert.equal(goesLine({ goes_at: null }, now), null);
    assert.equal(goesLine({}, now), null);
    assert.equal(goesSentence({ goes_at: null, retention: { versions_days: null, unopened_days: null } }, now), null);
    assert.equal(versionsSentence({ retention: { versions_days: null, unopened_days: 30 }, versions: [] }), null);
    assert.equal(versionsSentence({ versions: [] }), null);
    assert.equal(versionGoes({ goes_at: null }, now), null);
  });

  it("give the day in UTC, with the year only when it is not this one", () => {
    assert.equal(goesDate("2026-12-03T23:30:00Z", now), "3 Dec");
    assert.equal(goesDate("2027-01-22T00:30:00Z", now), "22 Jan 2027");
  });

  it("say when it goes and that opening it keeps it", () => {
    assert.equal(goesLine({ goes_at: "2026-12-03T10:00:00Z" }, now), "Goes 3 Dec unless opened");
    assert.equal(
      goesSentence({ goes_at: "2026-12-03T10:00:00Z", retention: { versions_days: null, unopened_days: 30 } }, now),
      "It goes on 3 Dec, every version with it, unless somebody opens it. Artifacts nobody opens for 30 days are removed, and opening it starts the 30 days again.",
    );
  });

  it("say which versions go", () => {
    assert.equal(
      versionsSentence({ retention: { versions_days: 1, unopened_days: null }, versions: [v(2, null)] }),
      "Versions older than the newest are removed 1 day after they were published; the newest, and a pinned one, are kept. None of these is old enough to go yet.",
    );
    assert.match(versionsSentence({ retention: { versions_days: 90, unopened_days: null }, versions: [v(2, null), v(1, "2027-01-22T00:00:00Z")] }) ?? "", /One of these goes on the day it shows\.$/);
    assert.equal(versionGoes({ goes_at: "2027-01-22T00:00:00Z" }, now), "goes 22 Jan 2027");
  });
});
