// A sensitive session in the words both web apps say it (troupe #1239): the mark a row and a
// head show, the log's line, a refused call apart from a failed one, the sharing refusal and
// the waiting sentence, the plane's methods, and the logs the harness recorded under
// test/fixtures/sensitive read the way the core wrote them.

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { describe, it } from "node:test";
import {
  ErrorCodes,
  PlaneClient,
  TroupeRpcError,
  clockWords,
  emptyTranscript,
  fold,
  fromCheckpoint,
  inviteRefusal,
  knowsSensitive,
  planeKnowsLifespans,
  planeKnowsSensitive,
  rowFromPlane,
  sensitiveLine,
  sensitiveMark,
  sensitiveOf,
  sensitiveRefusal,
  shareRequestLine,
  sharingRefusal,
  visibilityRefusal,
  waitingSentence,
} from "../src/index.js";
import type { DurableEvent, Entry, SessionRow, TranscriptState } from "../src/index.js";

const recordings = new URL("../../../../../test/fixtures/sensitive/", import.meta.url);
const noRecordings = existsSync(recordings) ? false : "the recorded logs are at the repository's root, outside this build";

function recorded(name: string): DurableEvent[] {
  return readFileSync(new URL(`${name}.jsonl`, recordings), "utf8")
    .split(/\r?\n/)
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line) as DurableEvent);
}

const foldAll = (events: DurableEvent[], from: TranscriptState = emptyTranscript): TranscriptState => events.reduce((s, e) => fold(s, e), from);
const tools = (s: TranscriptState) => s.entries.filter((e): e is Extract<Entry, { kind: "tool" }> => e.kind === "tool");
const lines = (s: TranscriptState) => s.entries.filter((e): e is Extract<Entry, { kind: "system" }> => e.kind === "system" && e.type === "session_marked_sensitive");

const UTC = { timeZone: "UTC", now: Date.parse("2026-11-28T12:00:00Z") };

describe("a sensitive session's words", () => {
  it("marks a row with the word and a title saying since when and by what, and an unmarked one not at all", () => {
    const call = sensitiveOf({ at: "2026-11-28T10:14:00Z", by: "mcp.ehr.lookup", how: "call" })!;
    assert.deepEqual(sensitiveMark({ sensitive: call }, UTC), { word: "sensitive", title: "Sensitive since 10:14: mcp.ehr.lookup read from it; nothing clears it" });
    const hand = sensitiveOf({ at: "2026-11-28T10:14:00Z", by: "ada@example.test", how: "person" })!;
    assert.equal(sensitiveMark({ sensitive: hand }, { ...UTC, nameOf: (s) => (s === "ada@example.test" ? "Ada" : null) })?.title, "Sensitive since 10:14: marked by Ada; nothing clears it");
    assert.equal(sensitiveMark({ sensitive: hand }, { ...UTC, self: "ada@example.test" })?.title, "Sensitive since 10:14: marked by you; nothing clears it");
    assert.equal(sensitiveMark({ sensitive: null }), null);
    assert.equal(sensitiveOf(null), null);
    assert.equal(sensitiveOf({ how: "call" }), null);
  });

  it("says another day's mark with its day", () => {
    assert.equal(clockWords("2026-11-27T22:05:00Z", UTC), "27 Nov 22:05");
  });

  it("says a refusal to mark it in words", () => {
    const refused = (code: number, data?: Record<string, unknown>) => new TroupeRpcError("session.sensitive.set", { code, message: "x", ...(data ? { data } : {}) });
    assert.equal(sensitiveRefusal(refused(ErrorCodes.method_not_found)), "It was not marked sensitive: this server does not know sensitive sessions yet.");
    assert.equal(sensitiveRefusal(refused(ErrorCodes.forbidden, { required_role: "owner" })), "It was not marked sensitive: only the session's owner marks it.");
  });
});

describe("a plane's row", () => {
  const row = { id: "s-1", owner: "ada", profile: "records", visibility: "private", state: "dormant", epoch: 1, title: null, last_active_at: null, last_seq: 0, head_hash: null, object_bytes: null, workspace_bytes: null, pinned: false, status: null, done_reason: null } as unknown as SessionRow;

  it("carries the mark, and none from an older plane", () => {
    const marked = rowFromPlane({ ...row, sensitive: { at: "2026-11-28T10:14:00Z", by: "mcp.ehr.lookup", how: "call" } });
    assert.deepEqual(marked.sensitive, { at: "2026-11-28T10:14:00Z", by: "mcp.ehr.lookup", how: "call" });
    assert.equal(rowFromPlane(row).sensitive, null);
  });
});

describe("sharing a sensitive session", () => {
  const forbidden = (setting: string, reason: string) => new TroupeRpcError("session.visibility.set", { code: ErrorCodes.forbidden, message: "forbidden", data: { reason, setting } });
  const refusal = "This session is sensitive and records does not allow sharing it outside the people who already read it";

  it("says the profile's refusal in its own words, where the plane gives it, and nothing for any other", () => {
    assert.equal(sharingRefusal(forbidden("sensitive.sharing", refusal)), `${refusal}.`);
    assert.equal(sharingRefusal(forbidden("sensitive", "this session is sensitive, and records refuses publish_artifact")), "this session is sensitive, and records refuses publish_artifact.");
    assert.equal(sharingRefusal(forbidden("visibility", "no")), null);
    assert.equal(visibilityRefusal(forbidden("sensitive.sharing", refusal), true), `${refusal}.`);
    assert.equal(inviteRefusal(forbidden("sensitive.sharing", refusal)), `${refusal}.`);
  });

  it("says a share held for a team administrator waits, and how it stands", () => {
    const answer = {
      waiting: true,
      reason: "This session is sensitive, so sharing it wider is waiting on a team administrator: the people who read it now go on reading it",
      share_request: { id: "share-1", session_id: "s-1", team: "eng", kind: "visibility", params: { visibility: "team" }, requested_by: "ada", state: "pending", at: "2026-11-28T10:20:00Z" },
    };
    assert.equal(
      waitingSentence(answer),
      "This session is sensitive, so sharing it wider is waiting on a team administrator: the people who read it now go on reading it (it waits).",
    );
    assert.equal(waitingSentence({ session_id: "s-1", visibility: "team" }), null);
    assert.equal(shareRequestLine(answer.share_request, (s) => (s === "ada" ? "Ada" : null)), "Ada asks to give it to eng");
    assert.equal(shareRequestLine({ ...answer.share_request, kind: "invite", params: { subject: "bea", role: "control" } }), "ada asks to let bea steer it");
  });

  it("asks the plane's methods by their names", async () => {
    const asked: unknown[] = [];
    const fetchImpl = (async (_url: string, init: { body: string }) => {
      const body = JSON.parse(init.body) as { id: number; method: string; params: unknown };
      asked.push([body.method, body.params]);
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: body.method === "session.share_requests" ? { requests: [] } : {} }), { status: 200 });
    }) as unknown as typeof fetch;
    const plane = new PlaneClient("http://plane.test", fetchImpl);
    await plane.setSessionSensitive("t", "s-1");
    await plane.shareRequests("t");
    await plane.decideShareRequest("t", "share-1", "approve");
    assert.deepEqual(asked, [
      ["session.sensitive.set", { session_id: "s-1", sensitive: true }],
      ["session.share_requests", {}],
      ["session.share_request.decide", { id: "share-1", decision: "approve" }],
    ]);
  });
});

describe("whether a server knows sensitive sessions", () => {
  it("is what its initialize says, asked once a sign-in with the lifespans question", async () => {
    assert.equal(knowsSensitive({ sensitive: true }), true);
    assert.equal(knowsSensitive({ lifespans: true }), false);
    const asked: unknown[] = [];
    const plane = { rpc: async <T,>(method: string): Promise<T> => (asked.push(method), { capabilities: { lifespans: true, sensitive: true } } as T) };
    assert.equal(await planeKnowsSensitive(plane), true);
    assert.equal(await planeKnowsLifespans(plane), true);
    assert.deepEqual(asked, ["initialize"]);
    const older = { rpc: async <T,>(): Promise<T> => ({ capabilities: { lifespans: true } }) as T };
    assert.equal(await planeKnowsSensitive(older), false);
  });
});

describe("a sensitive session's log", { skip: noRecordings }, () => {
  it("marked: a call marks it, one durable line, and the refused publish is a refusal with the harness's sentence", () => {
    const state = foldAll(recorded("marked"));
    assert.deepEqual(state.sensitive, { at: "2026-11-28T01:01:54Z", by: "mcp.records.lookup", how: "call", rule: "mcp(records.*)" });
    const [line, ...more] = lines(state);
    assert.equal(more.length, 0);
    assert.equal(line?.text, sensitiveLine(state.sensitive!));
    assert.match(line!.text, /^This session became sensitive at \d\d:\d\d: mcp\.records\.lookup read from it\. Nothing clears it;/);
    const lookup = tools(state).find((t) => t.name === "mcp.records.lookup")!;
    assert.equal(lookup.refused, undefined);
    const publish = tools(state).find((t) => t.name === "publish_artifact")!;
    assert.equal(publish.ok, false);
    assert.equal(publish.refused, "sensitive");
    assert.match(String(publish.content), /^This session is sensitive since mcp\.records\.lookup read from it at 01:01 UTC: publish_artifact is refused/);
  });

  it("by hand: the person who marked it by name, and the refused fetch", () => {
    const state = foldAll(recorded("by_hand"));
    assert.equal(state.sensitive?.how, "person");
    assert.equal(state.sensitive?.name, "Ada");
    assert.equal(sensitiveLine(state.sensitive!, UTC), "This session became sensitive at 01:01: Ada marked it. Nothing clears it; its profile refuses what would take what it read out of it.");
    const fetchCall = tools(state).find((t) => t.name === "web_fetch")!;
    assert.equal(fetchCall.refused, "sensitive");
    assert.match(String(fetchCall.content), /^This session is sensitive since Ada marked it/);
  });

  it("a replay folds the mark once", () => {
    const log = recorded("marked");
    const twice = foldAll(log.filter((e) => e.type === "session_marked_sensitive"), foldAll(log));
    assert.equal(lines(twice).length, 1);
  });

  it("from a checkpoint: the facts' mark", () => {
    const state = fromCheckpoint({
      seq: 20,
      prev_hash: null,
      ts: "2026-11-28T01:02:00Z",
      agent: ["root"],
      type: "checkpoint",
      v: 1,
      actor: { kind: "system" },
      data: {
        shape: "session/1",
        through: 19,
        facts: { agent: ["root"], profile: "build", sensitive: { how: "call", by: "mcp.records.lookup", rule: "mcp(records.*)", at: "2026-11-28T01:01:54Z" } },
      },
    } as never);
    assert.equal(state.sensitive?.by, "mcp.records.lookup");
  });
});
