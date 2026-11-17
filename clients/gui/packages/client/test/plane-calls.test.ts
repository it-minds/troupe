// The plane calls the apps make through `AuthSession.withToken` and a `PlaneClient` method,
// as the fakes answer them: a session on the plane opened and its token renewed by the one
// helper both apps use (`planeOpener`), and the person's own clients, memory and relayed
// sessions asked by name.

import assert from "node:assert/strict";
import { test } from "node:test";
import { SessionAttachment, TroupeRpcError, planeOpener } from "../src/index.js";
import { startHarness } from "./support/harness.js";

/** A `fetch` that notes each plane method it sends, with its params. */
function noting(): { fetchImpl: typeof fetch; sent: Array<{ method: string; params: unknown }> } {
  const sent: Array<{ method: string; params: unknown }> = [];
  const fetchImpl: typeof fetch = async (input, init) => {
    if (String(input).endsWith("/rpc") && typeof init?.body === "string") {
      const body = JSON.parse(init.body) as { method: string; params: unknown };
      sent.push({ method: body.method, params: body.params });
    }
    return fetch(input, init);
  };
  return { fetchImpl, sent };
}

test("a pod session opens in the mode asked and renews with token.mint; a relayed one opens and renews with remote.open", async (t) => {
  const h = await startHarness();
  t.after(() => h.stop());
  const { fetchImpl, sent } = noting();
  const auth = await h.signIn({ fetchImpl });

  const created = await auth.withToken((plane, token) => plane.createSession(token, { profile: "dev" }));
  const pod = planeOpener(auth, created.session_id);
  sent.length = 0;
  const opened = await pod.open("read");
  assert.ok(opened.token, "the pod token");
  assert.ok(opened.endpoint);
  const minted = await pod.mint();
  assert.ok(minted.token, "a fresh pod token");
  assert.deepEqual(sent, [
    { method: "session.open", params: { session_id: created.session_id, mode: "read" } },
    { method: "token.mint", params: { session_id: created.session_id } },
  ]);

  // The same pair is what an attachment dials with.
  const attachment = await SessionAttachment.open({ sessionId: created.session_id, mode: "activate", backoffMs: [10], ...pod });
  attachment.close();

  const offer = h.plane.relay("bob@example.com", { shares: [{ subject: "alice@example.com", role: "control" }] });
  const relayed = planeOpener(auth, offer.id, true);
  sent.length = 0;
  const reached = await relayed.open("activate");
  assert.ok(reached.token);
  assert.ok(reached.endpoint.startsWith("ws"), "an endpoint to dial");
  await relayed.mint();
  assert.deepEqual(sent, [
    { method: "remote.open", params: { session_id: offer.id } },
    { method: "remote.open", params: { session_id: offer.id } },
  ]);
});

test("the person's own clients, memory and relayed sessions are asked by name", async (t) => {
  const h = await startHarness();
  t.after(() => h.stop());
  const { fetchImpl, sent } = noting();
  const auth = await h.signIn({ fetchImpl });
  const offer = h.plane.relay("bob@example.com", { shares: [{ subject: "alice@example.com", role: "observe" }] });
  sent.length = 0;

  const { clients } = await auth.withToken((plane, token) => plane.clientsSeen(token));
  assert.ok(Array.isArray(clients));

  const { sessions } = await auth.withToken((plane, token) => plane.remoteSessions(token));
  assert.deepEqual(
    sessions.map((s) => s["id"]),
    [offer.id],
  );

  const memory = await auth.withToken((plane, token) => plane.ownMemory(token));
  const own = memory.user!;
  const preview = await auth.withToken((plane, token) => plane.previewOwnMemory(token, "Prefer small commits."));
  assert.equal(preview.unchanged, false);
  const saved = await auth.withToken((plane, token) => plane.putOwnMemory(token, "Prefer small commits.", own.version));
  assert.equal(saved.changed, true);
  assert.equal(saved.user.version, own.version + 1);
  // Saved over a version since replaced, it is refused rather than written.
  await assert.rejects(
    auth.withToken((plane, token) => plane.putOwnMemory(token, "Something else.", own.version)),
    (e: unknown) => e instanceof TroupeRpcError && e.message.includes("conflict"),
  );

  assert.deepEqual(
    sent.map((s) => [s.method, s.params]),
    [
      ["me.clients", {}],
      ["remote.list", {}],
      ["me.memory", {}],
      ["me.memory.preview", { text: "Prefer small commits." }],
      ["me.memory.put", { text: "Prefer small commits.", version: own.version }],
      ["me.memory.put", { text: "Something else.", version: own.version }],
    ],
  );
});
