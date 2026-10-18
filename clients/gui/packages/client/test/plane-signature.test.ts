// The plane's signed answers, checked here as `Troupe.Protocol.PlaneSignature` checks them
// (#657): the vector below is the one its suite holds the Elixir verifier to
// (`apps/troupe_protocol/test/troupe/protocol/plane_signature_test.exs`), so the desktop app
// and the terminal agree on what the plane signed.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { fingerprintOf, refusalSentence, verifySigned } from "../src/index.js";
import type { PlaneKey, SignedAnswer } from "../src/index.js";

const PINNED: PlaneKey = {
  algorithm: "ed25519",
  public_key: "6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=",
  fingerprint: "SHA256:/oEsEvOrTOasXbaaw1L5BssbEe9D+zPiUu9/9VImOIk",
};

const SIGNED: SignedAnswer = {
  algorithm: "ed25519",
  fingerprint: PINNED.fingerprint,
  document:
    '{"body":{"versions":{"desktop":{"recommended":"0.22.0-beta"}}},"expires_at":"2026-10-25T12:00:00Z","kind":"client_versions","plane":"https://plane.example.test","signed_at":"2026-10-18T12:00:00Z"}',
  signature: "vvRwPMQ83kuULmIjIoq/wVj2eB4eOnmrmU9kuHHSg1t2waFkqnOuJhEL2QIV9Gnt+SahvTn37Y7NLLprK+RtDA==",
};

const NOW = new Date("2026-10-18T12:00:00Z");

describe("the plane's signature", () => {
  it("holds for the shared vector, and gives the body that was signed", async () => {
    assert.equal(await fingerprintOf(PINNED.public_key), PINNED.fingerprint);
    const checked = await verifySigned(SIGNED, PINNED, "client_versions", NOW);
    assert.deepEqual(checked, {
      ok: true,
      body: { versions: { desktop: { recommended: "0.22.0-beta" } } },
      signedAt: "2026-10-18T12:00:00Z",
      expiresAt: "2026-10-25T12:00:00Z",
    });
  });

  it("refuses an answer changed after it was signed, one past its time, and one signed as the other kind", async () => {
    const edited = { ...SIGNED, document: SIGNED.document.replace("0.22.0-beta", "0.9.0-beta") };
    assert.deepEqual(await verifySigned(edited, PINNED, "client_versions", NOW), { ok: false, reason: "forged" });
    assert.deepEqual(await verifySigned(SIGNED, PINNED, "client_versions", new Date("2026-10-25T12:00:00Z")), {
      ok: false,
      reason: "expired",
      at: "2026-10-25T12:00:00Z",
    });
    assert.deepEqual(await verifySigned(SIGNED, PINNED, "client_defaults", NOW), { ok: false, reason: "wrong_kind", kind: "client_versions" });
    assert.deepEqual(await verifySigned(null, PINNED, "client_versions", NOW), { ok: false, reason: "unsigned" });
    assert.deepEqual(await verifySigned({ ...SIGNED, signature: "AAAA" }, PINNED, "client_versions", NOW), { ok: false, reason: "malformed" });
  });

  it("names the other key where another key signed it, and says so as the terminal does", async () => {
    const other = { ...SIGNED, fingerprint: "SHA256:another" };
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const raw = Buffer.from(await crypto.subtle.exportKey("raw", pair.publicKey)).toString("base64");
    const pinnedElsewhere: PlaneKey = { algorithm: "ed25519", public_key: raw, fingerprint: "SHA256:pinned" };
    const refused = await verifySigned(other, pinnedElsewhere, "client_versions", NOW);
    assert.deepEqual(refused, { ok: false, reason: "other_key", fingerprint: "SHA256:another" });
    assert.ok(!refused.ok);
    assert.equal(
      refusalSentence(refused, "https://plane.example.test", "the version policy", "SHA256:pinned"),
      "the version policy from https://plane.example.test is signed by the key SHA256:another, not by SHA256:pinned, the key this machine pinned for that plane: it is not taken until you accept the new key",
    );
  });
});
