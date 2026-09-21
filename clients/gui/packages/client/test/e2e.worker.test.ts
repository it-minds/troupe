// End to end against a real worker pod.
//
// The other half of "the server's half". `test/support/worker.ts` is a real WebSocket
// server speaking this protocol, but it is one written here: it agrees with the client
// by construction. A real worker does not, and the things it can disagree about are the
// ones that matter — event shapes, what a replay actually sends, and whether the
// idempotency ledger really collapses a command sent twice.
//
// A worker verifies session tokens offline against a JWKS on disk, so a JWKS whose
// private half we hold is accepted exactly as the plane's would be. For testing only; a
// client never signs its own token against a deployment. docs/e2e.md has the commands.

import assert from "node:assert/strict";
import { createHash, createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { SessionAttachment, TroupeConnection, createLocalSession, emptyTranscript, fold, isDurable, normalizeEndpoint } from "../src/index.js";
import type { Attachment, TroupeEvent } from "../src/index.js";

const WS = process.env["TROUPE_E2E_WS"];
const KEY_PATH = process.env["TROUPE_E2E_KEY"];
const POD = process.env["TROUPE_E2E_POD"] ?? "e2e-0";
const WORKSPACE = process.env["TROUPE_E2E_WORKSPACE"] ?? "/workspace/e2e";
const skip = WS && KEY_PATH ? false : "set TROUPE_E2E_WS and TROUPE_E2E_KEY to run against a real worker (docs/e2e.md)";

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

function mint(sub = "e2e@example.test"): string {
  const jwk = JSON.parse(readFileSync(KEY_PATH!, "utf8")) as Record<string, string>;
  const canonical = JSON.stringify({ crv: jwk["crv"], kty: jwk["kty"], x: jwk["x"], y: jwk["y"] });
  const kid = jwk["kid"] ?? createHash("sha256").update(canonical).digest("base64url");
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", typ: "JWT", kid };
  const payload = { sub, name: sub, aud: POD, role: "owner", iat: now, nbf: now - 5, exp: now + 900, jti: `e2e-${now}-${Math.random()}` };
  const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const signature = sign("sha256", Buffer.from(input), {
    key: createPrivateKey({ key: jwk as never, format: "jwk" }),
    dsaEncoding: "ieee-p1363",
  });
  return `${input}.${b64url(signature)}`;
}

/** What the plane would answer, for a worker we are dialling ourselves. */
const attachment = (sessionId: string, sub?: string): Attachment => ({
  session_id: sessionId,
  endpoint: normalizeEndpoint(WS!),
  worker_id: POD,
  role: "owner",
  token: mint(sub),
});

describe("against a real worker", { skip }, () => {
  /**
   * Attach the way the app does — through `SessionAttachment`, so the reconnection and
   * token-renewal policy is the one that ships — but with `open`/`mint` pointed at the
   * worker rather than at a plane.
   */
  async function attach(sessionId: string, onEvent?: (e: TroupeEvent) => void) {
    return SessionAttachment.open({
      sessionId,
      open: async () => attachment(sessionId),
      mint: async () => attachment(sessionId),
      mode: "activate",
      backoffMs: [50, 100, 200, 400],
      ...(onEvent ? { hooks: { onEvent } } : {}),
    });
  }

  /**
   * A session of this worker's own making, so each test is independent.
   *
   * `session.create` needs a connection but not a session, so this is a plain socket
   * rather than an attachment — an attachment subscribes, and there is nothing to
   * subscribe to until the session exists.
   */
  async function createSession(): Promise<string> {
    const conn = await TroupeConnection.open({
      url: normalizeEndpoint(WS!),
      token: mint(),
      clientInfo: { name: "troupe-client-e2e", version: "0.1.0" },
    });
    try {
      const created = await createLocalSession(conn, { workspace: WORKSPACE, worktree: "never" });
      return created.session_id;
    } finally {
      conn.close();
    }
  }

  /** `attachment.conn` is null while it is reconnecting; these tests only ask when it is not. */
  function live(a: SessionAttachment): TroupeConnection {
    const conn = a.conn;
    assert.ok(conn, "the attachment has a connection");
    return conn;
  }

  async function until(pred: () => boolean, what: string, ms = 30_000) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      if (pred()) return;
      await new Promise((r) => setTimeout(r, 25));
    }
    assert.fail(`timed out waiting for ${what}`);
  }

  it("negotiates the protocol this client speaks", async () => {
    const id = await createSession();
    const a = await attach(id);
    assert.equal(live(a).hello.protocol_version, "1");
    assert.ok(live(a).hello.server_info.name, "the server named itself");
    assert.ok(live(a).scopes.size > 0, `scopes were granted: ${[...live(a).scopes].join(", ")}`);
    await a.close();
  });

  it("folds a real turn into a transcript", async () => {
    const id = await createSession();
    let state = emptyTranscript;
    const a = await attach(id, (e) => (state = fold(state, e)));

    await a.view.send("Say something.");
    await until(() => state.entries.some((e) => e.kind === "user"), "the input to come back durably");
    await until(() => state.entries.some((e) => e.kind === "assistant"), "the model to answer");

    const user = state.entries.find((e) => e.kind === "user")!;
    assert.equal("text" in user && user.text, "Say something.");
    const assistant = state.entries.find((e) => e.kind === "assistant")!;
    assert.ok("text" in assistant && assistant.text.length > 0, "the answer had text");
    await a.close();
  });

  it("times a real turn, and returns when it ends", async () => {
    const id = await createSession();
    const a = await attach(id);

    const started = Date.now();
    const turn = await a.view.prompt("Answer briefly.", 30_000);

    assert.ok(turn.text.length > 0, "the turn carried the answer");
    assert.ok(turn.marks.accepted !== undefined, "input_accepted was seen");
    assert.ok(turn.marks.response !== undefined, "llm_response was seen");
    // The regression this guards: a turn used to wait out its whole timeout when no
    // delta arrived. Against a real model, anything near 30s means that is back.
    assert.ok(Date.now() - started < 20_000, `returned promptly (${Date.now() - started}ms)`);
    await a.close();
  });

  it("collapses a command id sent twice, so a retry after a drop is safe", async () => {
    // `SessionAttachment` reconnects, and a send that raced a dying socket is retried
    // with the same command id. That is only safe because the ledger is real; this is
    // the assertion that it is.
    const id = await createSession();
    let state = emptyTranscript;
    const a = await attach(id, (e) => (state = fold(state, e)));

    const commandId = live(a).nextCommandId();
    await a.view.send("Exactly once, please.", commandId);
    await until(() => state.entries.some((e) => e.kind === "user"), "the input");

    await a.view.send("Exactly once, please.", commandId);
    await new Promise((r) => setTimeout(r, 1_000));

    const mine = state.entries.filter((e) => e.kind === "user" && "text" in e && e.text === "Exactly once, please.");
    assert.equal(mine.length, 1, `the ledger collapsed the retry (saw ${mine.length})`);
    await a.close();
  });

  it("resumes from the cursor after the socket dies, with no gap and no duplicate", async () => {
    const id = await createSession();
    let state = emptyTranscript;
    const seen: number[] = [];
    const a = await attach(id, (e) => {
      state = fold(state, e);
      if (isDurable(e)) seen.push(e.seq);
    });

    await a.view.prompt("First.", 30_000);
    const before = a.view.lastSeq;
    // The socket that is about to die. Waiting on `status` alone is not enough: a close
    // event arrives a turn of the loop after the socket stops working, so it still reads
    // "live" for a moment — and "connecting" has already been seen once, on the way in.
    // The attachment replaces this object when it reconnects, which is unambiguous.
    const doomed = live(a);

    // Kill the socket under the client. 1006 is what a real drop reports, but an
    // application may not send it; what matters is that the close is not one the
    // attachment asked for.
    (doomed as unknown as { ws: { close(code: number, reason: string): void } })["ws"].close(4000, "e2e drop");

    // Wait for the drop to be *noticed* before waiting for the recovery: a close event
    // arrives a turn of the loop after the socket stops working, so `status` still reads
    // "live" for a moment and a naive wait would sail straight through it and write into
    // a socket that is going away.
    await until(() => a.conn !== doomed && a.status === "live", "the attachment to reconnect on a new socket");

    await a.view.prompt("Second, after the drop.", 30_000);

    assert.ok(a.view.lastSeq > before, "the stream continued rather than restarting");
    assert.equal(new Set(seen).size, seen.length, "every event folded exactly once");
    const inputs = state.entries.filter((e) => e.kind === "user").map((e) => ("text" in e ? e.text : ""));
    assert.deepEqual(inputs, ["First.", "Second, after the drop."], "both, once each, in order");
    await a.close();
  });

  it("lists and reads the session's real workspace", async () => {
    const id = await createSession();
    const a = await attach(id);

    const listing = await a.view.fsList(".");
    assert.ok(Array.isArray(listing.entries), "a listing came back");
    for (const e of listing.entries) assert.ok(typeof e.path === "string" && e.path.length > 0, "every entry has a path");

    const file = listing.entries.find((e) => e.kind === "file");
    if (file) {
      const read = await a.view.fsRead(file.path);
      assert.equal(typeof read.content, "string");
      assert.match(read.hash, /^sha256:/, "and the hash the fs_changed feed carries");
    }
    await a.close();
  });
});
