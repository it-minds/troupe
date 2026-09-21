// A fake worker pod: the protocol as a session speaks it, over a real WebSocket.
//
// It is not a simulation of the agent — it is a simulation of the *server*, which is
// what a client is written against. It keeps a hash-chained log, replays from a cursor
// with no gap and no duplicate, enforces the token's expiry, warns before it, refreshes
// on the open socket, stores blobs for anything past 16 KiB, and resolves an approval
// exactly once no matter how many clients answer it.
//
// The "agent" is a script chosen by the prompt's prefix, so a test can ask for the
// behaviour it needs — an approval, a large tool result, a silent turn — without any
// model anywhere.

import { createHash } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import { SessionLog, type LoggedEvent } from "./log.js";

export const BLOB_THRESHOLD = 16 * 1024;

export interface PodToken {
  sub: string;
  name?: string;
  session_id?: string;
  role: "owner" | "collaborator" | "viewer";
  scopes: string[];
  aud: string;
  /** Unix seconds. */
  exp: number;
}

export function encodeToken(t: PodToken): string {
  return Buffer.from(JSON.stringify(t)).toString("base64url");
}

function decodeToken(s: string): PodToken | null {
  try {
    return JSON.parse(Buffer.from(s, "base64url").toString()) as PodToken;
  } catch {
    return null;
  }
}

interface Session {
  id: string;
  log: SessionLog;
  workspace: string;
  profile: string;
  agent: string;
  status: string;
  /** call_id → whether it has been answered, and by whom. First answer wins. */
  approvals: Map<string, { tool: string; args: unknown; resolvedBy: string | null; decision: string | null }>;
  blobs: Map<string, Buffer>;
  files: Map<string, string>;
  pendingApprovalCount: number;
  costMicros: number;
}

interface Client {
  ws: WebSocket;
  token: PodToken;
  /** subscription_id → what it is on and how much of it to send. */
  subs: Map<string, { sessionId: string; level: "detail" | "summary"; off: () => void }>;
  expiryTimers: NodeJS.Timeout[];
}

/**
 * `sendAuthExpiring` is what the fifth done item turns off: with the warning suppressed
 * the client never gets to refresh, the token runs out, the socket closes, and the view
 * has to come back from its own cursor.
 */
export interface WorkerOptions {
  workerId?: string;
  sendAuthExpiring?: boolean;
  /** How long before `exp` the warning goes out, in milliseconds. */
  expiringLeadMs?: number;
  /** Milliseconds between streamed deltas. */
  deltaDelayMs?: number;
}

export class FakeWorker {
  readonly sessions = new Map<string, Session>();
  readonly server: Server;
  readonly wss: WebSocketServer;
  readonly workerId: string;
  /** Every method call the worker has answered, for the "never on load" assertions. */
  readonly calls: Array<{ method: string; params: Record<string, unknown> }> = [];

  private readonly clients = new Set<Client>();
  private readonly opts: Required<WorkerOptions>;
  private port = 0;
  private subCounter = 0;

  private constructor(opts: WorkerOptions) {
    this.opts = {
      workerId: opts.workerId ?? "w-0",
      sendAuthExpiring: opts.sendAuthExpiring ?? true,
      expiringLeadMs: opts.expiringLeadMs ?? 120_000,
      deltaDelayMs: opts.deltaDelayMs ?? 1,
    };
    this.workerId = this.opts.workerId;
    this.server = createServer();
    this.wss = new WebSocketServer({ server: this.server, path: "/v1/socket" });
    this.wss.on("connection", (ws) => this.onConnection(ws));
  }

  static async start(opts: WorkerOptions = {}): Promise<FakeWorker> {
    const w = new FakeWorker(opts);
    await new Promise<void>((r) => w.server.listen(0, "127.0.0.1", r));
    w.port = (w.server.address() as AddressInfo).port;
    return w;
  }

  get endpoint(): string {
    return `ws://127.0.0.1:${this.port}/v1/socket`;
  }

  async stop(): Promise<void> {
    for (const c of this.clients) {
      for (const t of c.expiryTimers) clearTimeout(t);
      c.ws.terminate();
    }
    await new Promise<void>((r) => this.wss.close(() => r()));
    await new Promise<void>((r) => this.server.close(() => r()));
  }

  /** How many sockets are attached right now. */
  get connectionCount(): number {
    return this.clients.size;
  }

  createSession(id: string, params: { workspace?: string; profile?: string; agent?: string; title?: string } = {}): Session {
    const session: Session = {
      id,
      log: new SessionLog(),
      workspace: params.workspace ?? "/workspace",
      profile: params.profile ?? "dev",
      agent: params.agent ?? "build",
      status: "idle",
      approvals: new Map(),
      blobs: new Map(),
      files: new Map([
        ["README.md", "# a workspace\n"],
        ["lib/a.ex", "defmodule A do\nend\n"],
      ]),
      pendingApprovalCount: 0,
      costMicros: 0,
    };
    this.sessions.set(id, session);
    session.log.append("session_created", {
      workspace: session.workspace,
      profile: session.profile,
      visibility: "team",
      bundle_version: "3",
      kind: "team",
      origin: { kind: "user" },
    });
    session.log.append("agent_started", { profile: session.profile, mode: session.agent, bundle_version: "3" });
    return session;
  }

  // -- the socket -------------------------------------------------------------

  private onConnection(ws: WebSocket): void {
    let client: Client | null = null;

    ws.on("message", (raw) => {
      let msg: { id?: number | string; method?: string; params?: Record<string, unknown> };
      try {
        msg = JSON.parse(String(raw));
      } catch {
        return;
      }
      if (!msg.method) return;
      const params = msg.params ?? {};
      this.calls.push({ method: msg.method, params });

      if (msg.method === "initialize") {
        const auth = params["auth"] as { token?: string } | undefined;
        const token = auth?.token ? decodeToken(auth.token) : null;
        if (!token) return reply(ws, msg.id, null, { code: -32003, message: "unauthenticated" });
        if (token.aud !== this.workerId) {
          return reply(ws, msg.id, null, { code: -32003, message: "unauthenticated", data: { reason: "wrong_audience" } });
        }
        if (token.exp * 1000 <= Date.now()) {
          return reply(ws, msg.id, null, { code: -32003, message: "unauthenticated", data: { reason: "expired" } });
        }
        client = { ws, token, subs: new Map(), expiryTimers: [] };
        this.clients.add(client);
        this.armExpiry(client);
        return reply(ws, msg.id, {
          protocol_version: "1",
          server_info: { name: "fake-worker", version: "0.0.1", instance_id: this.workerId },
          capabilities: { blobs: true, tools: true },
          principal: { subject: token.sub, display_name: token.name, kind: "user" },
          scopes: token.scopes,
          limits: { max_message_bytes: 1_048_576 },
          auth: { expires_at: token.exp },
        });
      }

      if (!client) return reply(ws, msg.id, null, { code: -32001, message: "not_initialized" });
      if (client.token.exp * 1000 <= Date.now()) {
        reply(ws, msg.id, null, { code: -32003, message: "unauthenticated", data: { reason: "expired" } });
        ws.close(4401, "expired");
        return;
      }
      void this.command(client, msg.id, msg.method, params);
    });

    ws.on("close", () => {
      if (!client) return;
      for (const t of client.expiryTimers) clearTimeout(t);
      for (const s of client.subs.values()) s.off();
      this.clients.delete(client);
    });
  }

  /** Warn before `exp`, and close on it. Both are what a real pod does. */
  private armExpiry(client: Client): void {
    for (const t of client.expiryTimers) clearTimeout(t);
    client.expiryTimers = [];
    const msLeft = client.token.exp * 1000 - Date.now();
    if (this.opts.sendAuthExpiring) {
      const warnIn = Math.max(0, msLeft - this.opts.expiringLeadMs);
      client.expiryTimers.push(
        setTimeout(() => notify(client.ws, "auth.expiring", { expires_at: client.token.exp }), warnIn),
      );
    }
    client.expiryTimers.push(
      setTimeout(() => {
        // Nothing is streamed on a token that has run out.
        if (client.ws.readyState === client.ws.OPEN) client.ws.close(4401, "expired");
      }, Math.max(0, msLeft)),
    );
  }

  private async command(client: Client, id: unknown, method: string, params: Record<string, unknown>): Promise<void> {
    const ws = client.ws;
    const sessionId = String(params["session_id"] ?? "");
    const session = this.sessions.get(sessionId);

    switch (method) {
      case "auth.refresh": {
        const auth = params["auth"] as { token?: string } | undefined;
        const token = auth?.token ? decodeToken(auth.token) : null;
        if (!token || token.aud !== this.workerId) {
          return reply(ws, id, null, { code: -32003, message: "unauthenticated", data: { reason: "wrong_audience" } });
        }
        client.token = token;
        this.armExpiry(client);
        return reply(ws, id, {
          principal: { subject: token.sub, kind: "user" },
          scopes: token.scopes,
          auth: { expires_at: token.exp },
        });
      }

      case "subscribe": {
        const topic = String(params["topic"] ?? "");
        const target = topic.startsWith("session:") ? this.sessions.get(topic.slice("session:".length)) : undefined;
        if (!target) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const level = (params["level"] as "detail" | "summary") ?? "detail";
        const subId = `sub-${++this.subCounter}`;
        const from = typeof params["from_seq"] === "number" ? (params["from_seq"] as number) : target.log.headSeq;

        // Replay first, then live, with the boundary closed: events appended while the
        // replay is being written are queued and flushed after it, so the client sees
        // exactly one event per seq.
        let replaying = true;
        const queued: LoggedEvent[] = [];
        const off = target.log.listen((e) => {
          if (replaying) queued.push(e);
          else this.deliver(client, subId, target.id, level, e);
        });
        client.subs.set(subId, { sessionId: target.id, level, off });
        reply(ws, id, { subscription_id: subId, head_seq: target.log.headSeq });
        for (const e of target.log.from(from)) this.deliver(client, subId, target.id, level, e);
        replaying = false;
        for (const e of queued) if (e.seq > from) this.deliver(client, subId, target.id, level, e);
        return;
      }

      case "unsubscribe": {
        const subId = String(params["subscription_id"] ?? "");
        client.subs.get(subId)?.off();
        client.subs.delete(subId);
        return reply(ws, id, { unsubscribed: subId });
      }

      case "session.get": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        return reply(ws, id, {
          id: session.id,
          workspace: session.workspace,
          profile: session.profile,
          state: "active",
          status: session.status,
          head_seq: session.log.headSeq,
          pending_approvals: session.pendingApprovalCount,
          cost_micros: session.costMicros,
        });
      }

      case "input.send": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        if (!client.token.scopes.includes("control")) {
          return reply(ws, id, null, { code: -32004, message: "forbidden", data: { required_scope: "control" } });
        }
        reply(ws, id, { accepted: true });
        await this.turn(session, String(params["text"] ?? ""), String(params["command_id"] ?? ""), client.token);
        return;
      }

      case "approval.respond": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const callId = String(params["call_id"] ?? "");
        const approval = session.approvals.get(callId);
        if (!approval) return reply(ws, id, null, { code: -32005, message: "not_found" });
        if (approval.resolvedBy) {
          // First response wins. The later one is told who resolved it and changes
          // nothing — no second decision, and no second continuation of the turn.
          session.log.append("approval_resolved", { call_id: callId, resolved_by: approval.resolvedBy });
          return reply(ws, id, { resolved_by: approval.resolvedBy });
        }
        approval.resolvedBy = client.token.sub;
        approval.decision = String(params["decision"] ?? "deny");
        session.pendingApprovalCount = Math.max(0, session.pendingApprovalCount - 1);
        session.log.append(
          "approval_decided",
          { call_id: callId, tool: approval.tool, decision: approval.decision, actor: client.token.sub },
          { kind: "user", subject: client.token.sub },
        );
        reply(ws, id, { decision: approval.decision });
        await this.afterApproval(session, callId, approval.decision, approval.tool, approval.args);
        return;
      }

      case "turn.cancel": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        session.log.append("cancelled", {}, { kind: "user", subject: client.token.sub });
        this.setStatus(session, "idle");
        return reply(ws, id, { cancelled: true });
      }

      case "profile.switch": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const to = String(params["profile"] ?? "");
        session.log.append("profile_switched", { from: session.profile, to }, { kind: "user", subject: client.token.sub });
        session.profile = to;
        return reply(ws, id, { profile: to });
      }

      case "presence.set":
        return reply(ws, id, { ok: true });

      case "blob.get": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const key = String(params["blob"] ?? "");
        const blob = session.blobs.get(key);
        if (!blob) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const asked = params["range"] as [number, number] | undefined;
        const start = asked ? Math.max(0, asked[0]) : 0;
        // A server may cap a single response and says so with a shorter range than
        // asked for; 64 KiB here, so a client that ignores the answer's range loops.
        const cap = 65_536;
        const end = Math.min(blob.length - 1, asked ? Math.min(asked[1], start + cap - 1) : start + cap - 1);
        return reply(ws, id, {
          blob: key,
          size: blob.length,
          range: [start, end],
          encoding: "base64",
          data: blob.subarray(start, end + 1).toString("base64"),
        });
      }

      case "fs.list": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const at = String(params["path"] ?? ".").replace(/^\.\/?/, "");
        if (at.includes("..")) return reply(ws, id, null, { code: -32004, message: "forbidden" });
        const names = new Set<string>();
        for (const path of session.files.keys()) {
          if (at && !path.startsWith(`${at}/`)) continue;
          const rest = at ? path.slice(at.length + 1) : path;
          const head = rest.split("/")[0]!;
          names.add(head);
        }
        const entries = [...names].map((name) => {
          const full = at ? `${at}/${name}` : name;
          const file = session.files.get(full);
          return { path: full, name, kind: file === undefined ? "directory" : "file", size: file?.length ?? 0 };
        });
        return reply(ws, id, { path: at || ".", entries });
      }

      case "fs.read": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const path = String(params["path"] ?? "");
        if (path.includes("..")) return reply(ws, id, null, { code: -32004, message: "forbidden" });
        const content = session.files.get(path);
        if (content === undefined) return reply(ws, id, null, { code: -32005, message: "not_found" });
        return reply(ws, id, {
          path,
          content,
          size: Buffer.byteLength(content),
          hash: `sha256:${createHash("sha256").update(content).digest("hex")}`,
        });
      }

      default:
        return reply(ws, id, null, { code: -32601, message: "method_not_found", data: { method } });
    }
  }

  private deliver(client: Client, subId: string, sessionId: string, level: "detail" | "summary", e: LoggedEvent): void {
    if (level === "summary" && !SUMMARY_TYPES.has(e.type)) return;
    notify(client.ws, "event", { topic: `session:${sessionId}`, session_id: sessionId, subscription_id: subId, event: e });
  }

  private ephemeral(session: Session, type: string, data: Record<string, unknown>, agent: string[] = ["root"]): void {
    for (const client of this.clients) {
      for (const [subId, sub] of client.subs) {
        if (sub.sessionId !== session.id) continue;
        if (sub.level === "summary" && type !== "summary_diff") continue;
        notify(client.ws, "event", {
          topic: `session:${session.id}`,
          session_id: session.id,
          subscription_id: subId,
          event: { ephemeral: true, type, agent, data },
        });
      }
    }
  }

  private setStatus(session: Session, status: string): void {
    session.status = status;
    this.ephemeral(session, "agent_state", { state: status });
  }

  // -- the "agent" ------------------------------------------------------------

  /**
   * One turn. The prefix of the prompt picks the script, so a test asks for the
   * behaviour it needs rather than for a model.
   */
  private async turn(session: Session, text: string, commandId: string, token: PodToken): Promise<void> {
    const actor = { kind: "user", subject: token.sub };
    session.log.append("input_accepted", { command_id: commandId, author: token.sub }, actor);
    session.log.append("user_input", { source: "user", text }, actor);
    this.setStatus(session, "thinking");
    session.log.append("llm_request", { model: "fake", message_count: session.log.headSeq, tools: [], profile: session.profile });

    if (text.startsWith("approve:")) return this.askApproval(session, text.slice("approve:".length).trim());
    if (text.startsWith("big:")) return this.bigResult(session, text.slice("big:".length).trim());
    const quiet = text.startsWith("quiet:");

    const answer = quiet ? `(silently) ${text.slice("quiet:".length)}` : `You said: ${text}`;
    if (!quiet) {
      for (const word of answer.split(/(?<= )/)) {
        await sleep(this.opts.deltaDelayMs);
        this.ephemeral(session, "llm_delta", { kind: "text", text: word });
      }
    }
    this.respond(session, answer);
    this.setStatus(session, "idle");
  }

  private respond(session: Session, text: string, stop = "end_turn"): void {
    session.costMicros += 100;
    session.log.append("llm_response", {
      message: { role: "assistant", content: [{ type: "text", text }] },
      usage: { input_tokens: 10, output_tokens: text.length },
      stop_reason: stop,
      model: "fake",
      gateway: { request_id: `r-${session.log.headSeq}`, cost_micros: 100 },
    });
  }

  private askApproval(session: Session, what: string): void {
    const callId = `call-${session.log.headSeq}`;
    const args = { command: what };
    session.approvals.set(callId, { tool: "shell", args, resolvedBy: null, decision: null });
    session.pendingApprovalCount += 1;
    session.log.append("approval_requested", { call_id: callId, tool: "shell", args, agent_path: ["root"] });
    this.setStatus(session, "waiting");
  }

  private async afterApproval(session: Session, callId: string, decision: string, tool: string, args: unknown): Promise<void> {
    this.setStatus(session, "acting");
    if (decision === "deny") {
      this.respond(session, `I was not allowed to run ${tool}.`);
    } else {
      session.log.append("tool_call_started", { call_id: callId, name: tool, args });
      await sleep(1);
      session.log.append("tool_call_completed", { call_id: callId, name: tool, ok: true, content: "done\n" });
      this.respond(session, `Ran ${tool}.`);
    }
    this.setStatus(session, "idle");
  }

  /**
   * A tool result past 16 KiB, which the server replaces with a reference. The bytes
   * stay here until somebody asks for them, which is the point of the last done item:
   * loading a transcript must not fetch them.
   */
  private async bigResult(session: Session, label: string): Promise<void> {
    const callId = `call-${session.log.headSeq}`;
    const body = Buffer.from(`${label}\n`.repeat(40_000));
    const key = `sha256:${createHash("sha256").update(body).digest("hex")}`;
    session.blobs.set(key, body);
    session.log.append("tool_call_started", { call_id: callId, name: "read", args: { path: "big.txt" } });
    await sleep(1);
    session.log.append("tool_call_completed", {
      call_id: callId,
      name: "read",
      ok: true,
      content: { blob: key, size: body.length, preview: body.subarray(0, 4096).toString(), truncated: true },
    });
    this.respond(session, `read ${body.length} bytes`);
    this.setStatus(session, "idle");
  }
}

/** What a `summary` subscription carries: lifecycle, and nothing that is content. */
const SUMMARY_TYPES = new Set([
  "session_created",
  "session_dormant",
  "session_activated",
  "session_resumed",
  "agent_done",
  "cancelled",
  "budget_exhausted",
  "llm_error",
  "approval_requested",
  "approval_decided",
  "approval_resolved",
]);

function reply(ws: WebSocket, id: unknown, result: unknown, error?: { code: number; message: string; data?: unknown }): void {
  ws.send(JSON.stringify(error ? { jsonrpc: "2.0", id, error } : { jsonrpc: "2.0", id, result }));
}

function notify(ws: WebSocket, method: string, params: unknown): void {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
