// What an artifact's page says of each kind of reference the artifacts host blocks (troupe
// #1081, #1092): a read of the page's own file by fetch and the like is said as a read that
// fails here, never as a connection to another site.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { blockedKindWords } from "../src/index.js";

describe("a blocked reference's kind, in words", () => {
  it("says a read fails even for the page's own file", () => {
    assert.equal(
      blockedKindWords("read"),
      "a read by fetch, XMLHttpRequest, EventSource, import(), a module or a web font, which fails even for the page's own file",
    );
    assert.doesNotMatch(blockedKindWords("read"), /another site/);
  });

  it("keeps a connection to another site as one", () => {
    assert.equal(blockedKindWords("connect"), "a connection to another site");
  });
});
