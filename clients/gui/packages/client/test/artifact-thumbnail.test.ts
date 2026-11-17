// A gallery card's picture (troupe #977), as the fake plane the GUI's tests run against
// keeps it: a publish sends it with the version (`thumbnail: {content_type, bytes}`), the
// row carries where it is (`thumbnail_url`), that address answers the image and nothing
// else, and a version sent without one has none.

import assert from "node:assert/strict";
import { after, before, beforeEach, describe, it } from "node:test";
import { ArtifactApi, textBytes } from "../src/index.js";
import type { AuthSession } from "../src/index.js";
import { startHarness, type Harness } from "./support/harness.js";
import { TINY_PNG } from "./support/plane.js";

function apiOf(auth: AuthSession): ArtifactApi {
  return new ArtifactApi((m, p) => auth.rpc(m, p));
}

describe("a card's picture, on the fake plane", () => {
  let h: Harness;

  before(async () => {
    h = await startHarness({});
  });
  after(() => h.stop());
  beforeEach(() => h.plane.artifacts.clear());

  it("goes with the version, is on its row, and is served as an image", async () => {
    const api = apiOf(await h.signIn({ subject: "ada@example.com" }));
    const page = [{ path: "index.html", bytes: textBytes("<h1>Weekly</h1>") }];

    const published = await api.publish({ title: "Weekly", kind: "html", files: page, thumbnail: { content_type: "image/png", bytes: TINY_PNG } });
    assert.match(published.thumbnail_url ?? "", /\/t\/art-\d+\/1$/);
    const listed = (await api.list()).artifacts.find((a) => a.id === published.id);
    assert.equal(listed?.thumbnail_url, published.thumbnail_url);

    const response = await fetch(published.thumbnail_url!);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "image/png");
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), Buffer.from(TINY_PNG, "base64"));

    // The next version sent no picture, so its card has none.
    const next = await api.publish({ id: published.id, title: "Weekly", kind: "html", files: page });
    assert.equal(next.thumbnail_url, null);
    const plain = await api.publish({ title: "Plain", kind: "html", files: page });
    assert.equal(plain.thumbnail_url, null);
  });
});
