// A fake daemon: the protocol as the machine in front of you speaks it.
//
// Not a second copy of the fake worker. A daemon differs from a pod in exactly the ways
// a client has to cope with, and those differences are what this exists to exercise:
//
//   one token for everything     not a pod token minted per session, so there is no
//                                audience to check and nothing to expire
//   one socket for everything    several sessions are live on the same connection, and
//                                an event has to reach the right view
//   it owns directories          `session.create` takes a workspace, `worktree.list`
//                                and `workspace.recent` answer about this machine
//   it can be told who you are   `identity.link` changes the actor on everything after
//   it keeps the model settings  `config.set` writes them, `config.get` reads them back
//                                without the key, and `config.models` asks a provider
//
// It implements the protocol rather than imitating a screen, for the same reason the
// fake worker does: a test that passes against a fake that agrees with the client by
// construction has proved nothing.

import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import { SessionLog, type LoggedEvent } from "./log.js";

interface Session {
  id: string;
  log: SessionLog;
  workspace: string;
  branch: string | null;
  profile: string;
  state: string;
  status: string;
  createdAt: string;
  lastActiveAt: string;
  watch: boolean;
  /** Approvals still open, which the daemon's row counts (and says `waiting` for). */
  pendingApprovals: number;
}

interface Client {
  ws: WebSocket;
  subs: Map<string, { id: string; topic: string; off: () => void }>;
}

export interface FakeDaemonOptions {
  token?: string;
  /** What `initialize` reports. A daemon that cannot seal says so by leaving it out. */
  capabilities?: Record<string, unknown>;
  osUser?: string;
  /**
   * False is a daemon from before `config.*` existed, which answers `method_not_found`
   * the way an old one does — the case a client has to say something useful about.
   */
  modelSettings?: boolean;
  /** Things with a stronger claim than the file, as `config.get` reports them. */
  overrides?: Array<{ source: "project" | "env" | "opencode"; detail: string }>;
}

/** What the fake daemon's settings file holds. The key is here and nowhere in an answer. */
export interface FakeModelSettings {
  exists: boolean;
  provider: string | null;
  base_url: string | null;
  auth: "api_key" | "bearer" | null;
  api_key: string | null;
  models: { default: string | null; cheap: string | null; expensive: string | null };
}

/**
 * What each provider offers. Anthropic says what everything costs; a gateway in front of
 * open-weight models usually says nothing, so those come back null — which is the case
 * a client has to render without inventing a price.
 */
const OFFERS: Record<string, Array<Record<string, unknown>>> = {
  anthropic: [
    { id: "claude-opus-5", context: 200_000, max_output: 64_000, input: 5.0, output: 25.0 },
    { id: "claude-haiku-4-5", context: 200_000, max_output: 64_000, input: 1.0, output: 5.0 },
  ],
  openai: [
    { id: "glm-5.2", context: 128_000, max_output: null, input: null, output: null },
    { id: "qwen3.6-35b", context: 32_768, max_output: 8_192, input: null, output: null },
  ],
};

function reply(ws: WebSocket, id: unknown, result: unknown, error?: unknown): void {
  ws.send(JSON.stringify(error ? { jsonrpc: "2.0", id, error } : { jsonrpc: "2.0", id, result }));
}

function notify(ws: WebSocket, method: string, params: unknown): void {
  ws.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
}

export class FakeDaemon {
  readonly token: string;
  readonly sessions = new Map<string, Session>();
  readonly calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  /** Who the daemon says its user is. `null` until somebody links an identity. */
  linked: { subject: string; display_name?: string; plane_url?: string } | null = null;
  /** The settings file, as `config.set` last wrote it. Nothing is saved until then. */
  settings: FakeModelSettings = {
    exists: false,
    provider: null,
    base_url: null,
    auth: null,
    api_key: null,
    models: { default: null, cheap: null, expensive: null },
  };

  private server: Server | null = null;
  private wss: WebSocketServer | null = null;
  private readonly clients = new Set<Client>();
  private readonly capabilities: Record<string, unknown>;
  private readonly osUser: string;
  private readonly modelSettings: boolean;
  private readonly overrides: NonNullable<FakeDaemonOptions["overrides"]>;
  private nextId = 1;

  constructor(opts: FakeDaemonOptions = {}) {
    this.token = opts.token ?? "daemon-token";
    this.capabilities = opts.capabilities ?? { blobs: true, tools: true };
    this.osUser = opts.osUser ?? "ada";
    this.modelSettings = opts.modelSettings ?? true;
    this.overrides = opts.overrides ?? [];
  }

  get principal(): { subject: string; display_name: string; kind: string } {
    return this.linked
      ? { subject: this.linked.subject, display_name: this.linked.display_name ?? this.linked.subject, kind: "user" }
      : { subject: `local:${this.osUser}`, display_name: this.osUser, kind: "user" };
  }

  async start(): Promise<string> {
    this.server = createServer();
    this.wss = new WebSocketServer({ server: this.server, path: "/v1/socket" });
    this.wss.on("connection", (ws) => this.onConnection(ws));
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const { port } = this.server!.address() as AddressInfo;
    return String(port);
  }

  async stop(): Promise<void> {
    for (const c of this.clients) c.ws.close();
    this.clients.clear();
    await new Promise<void>((resolve) => this.wss?.close(() => resolve()));
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
  }

  get port(): number {
    return (this.server!.address() as AddressInfo).port;
  }

  /** Seed a session, as one started before the client connected. */
  seed(workspace: string, opts: Partial<Session> = {}): Session {
    const id = `s-${this.nextId++}`;
    const now = new Date().toISOString();
    const session: Session = {
      id,
      log: new SessionLog(),
      workspace,
      branch: null,
      profile: "build",
      state: "active",
      status: "idle",
      createdAt: now,
      lastActiveAt: now,
      watch: false,
      pendingApprovals: 0,
      ...opts,
    };
    session.log.append("session_created", {
      workspace,
      profile: session.profile,
      visibility: "private",
      kind: "local",
      ...(this.linked ? { owner: this.linked.subject } : {}),
    });
    this.sessions.set(id, session);
    return session;
  }

  /** Make a session ask something — the agent's `ask_user`, or the harness's budget question under a `budget-<n>` id. */
  ask(sessionId: string, question: Record<string, unknown>): LoggedEvent {
    const session = this.sessions.get(sessionId)!;
    return session.log.append("question_asked", { agent_path: ["root"], options: [], multiple: false, ...question });
  }

  /** Make a session say something, so a test can watch it arrive on the right view. */
  say(sessionId: string, text: string): LoggedEvent {
    const session = this.sessions.get(sessionId)!;
    return session.log.append("llm_response", { message: { role: "assistant", content: [{ type: "text", text }] } });
  }

  private onConnection(ws: WebSocket): void {
    let client: Client | null = null;

    ws.on("message", (raw) => {
      let msg: { id?: number | string; method?: string; params?: Record<string, unknown> };
      try {
        msg = JSON.parse(String(raw)) as typeof msg;
      } catch {
        return;
      }
      if (!msg.method) return;
      const params = msg.params ?? {};
      this.calls.push({ method: msg.method, params });

      if (msg.method === "initialize") {
        const auth = params["auth"] as { token?: string } | undefined;
        // The whole of a daemon's authentication: a token out of a file only this user
        // can read. There is no audience and no expiry, because there is no third party.
        if (auth?.token !== this.token) {
          return reply(ws, msg.id, null, { code: -32003, message: "unauthenticated" });
        }
        client = { ws, subs: new Map() };
        this.clients.add(client);
        return reply(ws, msg.id, {
          protocol_version: "1",
          server_info: { name: "fake-daemon", version: "0.0.1", instance_id: "daemon-1" },
          capabilities: this.capabilities,
          principal: this.principal,
          scopes: ["observe", "control", "admin"],
          limits: { max_message_bytes: 1_048_576 },
        });
      }

      if (!client) return reply(ws, msg.id, null, { code: -32001, message: "not_initialized" });
      this.handle(client, msg.id, msg.method, params);
    });

    ws.on("close", () => {
      if (!client) return;
      for (const s of client.subs.values()) s.off();
      this.clients.delete(client);
    });
  }

  private handle(client: Client, id: unknown, method: string, params: Record<string, unknown>): void {
    const ws = client.ws;
    const sessionId = String(params["session_id"] ?? "");
    const session = this.sessions.get(sessionId);

    switch (method) {
      case "identity.get":
        return reply(ws, id, this.identityJson());

      case "identity.link": {
        const subject = String(params["subject"] ?? "");
        if (!subject) {
          return reply(ws, id, null, { code: -32602, message: "invalid_params", data: { reason: "subject must be a non-empty string" } });
        }
        this.linked = {
          subject,
          ...(params["display_name"] ? { display_name: String(params["display_name"]) } : {}),
          ...(params["plane_url"] ? { plane_url: String(params["plane_url"]) } : {}),
        };
        return reply(ws, id, this.identityJson());
      }

      case "identity.unlink":
        this.linked = null;
        return reply(ws, id, this.identityJson());

      case "session.list": {
        const filter = (params["filter"] ?? {}) as { kind?: string; workspace?: string };
        const sessions = [...this.sessions.values()]
          .filter((s) => !filter.workspace || s.workspace === filter.workspace)
          .map((s) => this.rowOf(s));
        return reply(ws, id, { sessions });
      }

      case "session.create": {
        const workspace = String(params["workspace"] ?? "");
        if (!workspace) return reply(ws, id, null, { code: -32602, message: "invalid_params" });
        const config = (params["config"] ?? {}) as { watch?: boolean };
        const created = this.seed(workspace, { watch: Boolean(config.watch) });
        return reply(ws, id, { session_id: created.id, workspace, worktree: null, branch: null });
      }

      case "subscribe": {
        const topic = String(params["topic"] ?? "");
        const from = Number(params["from_seq"] ?? 0);
        const target = this.sessions.get(topic.replace(/^session:/, ""));
        if (!target) return reply(ws, id, null, { code: -32005, message: "not_found" });

        const subscriptionId = `sub-${this.nextId++}`;
        // The replay is closed before anything live is sent, which is what lets a client
        // resume from its cursor with no gap and no duplicate.
        const backlog = target.log.from(from);
        const off = target.log.listen((e) => notify(ws, "event", { topic, subscription_id: subscriptionId, session_id: target.id, event: e }));
        client.subs.set(subscriptionId, { id: subscriptionId, topic, off });
        reply(ws, id, { subscription_id: subscriptionId, head_seq: target.log.headSeq, replayed: backlog.length });
        for (const e of backlog) {
          notify(ws, "event", { topic, subscription_id: subscriptionId, session_id: target.id, event: e });
        }
        return;
      }

      case "unsubscribe": {
        const sub = client.subs.get(String(params["subscription_id"] ?? ""));
        sub?.off();
        if (sub) client.subs.delete(sub.id);
        return reply(ws, id, { unsubscribed: true });
      }

      case "input.send": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const commandId = String(params["command_id"] ?? "");
        const actor = { kind: "user", subject: this.principal.subject };
        session.log.append("input_queued", { command_id: commandId, author: this.principal.subject, text: params["text"] }, actor);
        session.log.append("input_accepted", { command_id: commandId, author: this.principal.subject }, actor);
        return reply(ws, id, { accepted: true });
      }

      case "question.answer": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const actor = { kind: "user", subject: this.principal.subject };
        session.log.append("question_answered", { call_id: params["call_id"], text: params["text"] ?? "" }, actor);
        return reply(ws, id, { accepted: true });
      }

      case "presence.set":
        return reply(ws, id, { ok: true });

      case "workspace.recent":
        return reply(ws, id, {
          workspaces: [...new Set([...this.sessions.values()].map((s) => s.workspace))].map((path) => ({
            path,
            last_used_at: new Date().toISOString(),
            sessions: [...this.sessions.values()].filter((s) => s.workspace === path).length,
          })),
        });

      case "worktree.list":
        return reply(ws, id, {
          worktrees: [...this.sessions.values()]
            .filter((s) => s.branch)
            .map((s) => ({ path: `${s.workspace}-troupe`, branch: s.branch, session_id: s.id, dirty: false })),
        });

      case "watch.set": {
        const workspace = String(params["workspace"] ?? "");
        const enabled = params["enabled"] !== false;
        const already = [...this.sessions.values()].find((s) => s.watch && s.workspace === workspace);
        const mine = [...this.sessions.values()].find((s) => s.workspace === workspace);
        if (enabled && already && already !== mine) {
          return reply(ws, id, null, { code: -32006, message: "conflict", data: { reason: "watch is exclusive per workspace" } });
        }
        if (mine) mine.watch = enabled;
        return reply(ws, id, { enabled, backend: "poll" });
      }

      case "config.get":
      case "config.models":
      case "config.set":
        if (!this.modelSettings) return reply(ws, id, null, { code: -32601, message: "method_not_found", data: { method } });
        return this.config(ws, id, method, params);

      default:
        return reply(ws, id, null, { code: -32601, message: "method_not_found", data: { method } });
    }
  }

  /**
   * The three model-settings methods, with the daemon's semantics for an absent field:
   * `config.models` falls back to what is saved, and `config.set` keeps the saved key
   * unless it is handed one, removing it only when handed the empty string.
   */
  private config(ws: WebSocket, id: unknown, method: string, params: Record<string, unknown>): void {
    const invalid = (reason: string) => reply(ws, id, null, { code: -32602, message: "invalid_params", data: { reason } });
    const s = this.settings;

    if (method === "config.get") return reply(ws, id, this.configJson());

    if (method === "config.models") {
      const provider = String(params["provider"] ?? s.provider ?? "anthropic");
      const offers = OFFERS[provider];
      if (!offers) return invalid(`unknown provider ${provider}`);
      const key = params["api_key"] === undefined ? s.api_key : String(params["api_key"]);
      // A provider refuses a missing or wrong key with a 401, and the daemon reports
      // that as a failure beside an empty list rather than as an error: a person trying
      // a key wants to be told it is wrong, not that the call went badly. Here a key is
      // right when it looks like one.
      if (!key || !key.startsWith("sk-")) {
        return reply(ws, id, { models: [], failures: [{ provider, reason: "401 unauthorized" }] });
      }
      return reply(ws, id, { models: offers, failures: [] });
    }

    // config.set
    if (!params["command_id"]) return invalid("command_id is required");
    const provider = String(params["provider"] ?? "");
    if (!OFFERS[provider]) return invalid(`provider must be one of ${Object.keys(OFFERS).join(", ")}`);
    const auth = params["auth"];
    if (auth !== undefined && auth !== "api_key" && auth !== "bearer") return invalid("auth must be api_key or bearer");

    s.exists = true;
    s.provider = provider;
    if ("base_url" in params) s.base_url = (params["base_url"] as string | null) || null;
    if (auth !== undefined) s.auth = auth;
    if ("api_key" in params) s.api_key = String(params["api_key"] ?? "") || null;
    const models = (params["models"] ?? {}) as Record<string, string | null | undefined>;
    for (const role of ["default", "cheap", "expensive"] as const) {
      if (role in models) s.models[role] = models[role] || null;
    }
    return reply(ws, id, this.configJson());
  }

  private configJson(): Record<string, unknown> {
    const s = this.settings;
    const dir = `/home/${this.osUser}/.config/troupe`;
    return {
      config_dir: dir,
      path: `${dir}/config.yaml`,
      exists: s.exists,
      provider: s.provider,
      base_url: s.base_url,
      auth: s.auth,
      api_key_set: s.api_key !== null,
      api_key_source: s.api_key !== null ? "file" : null,
      models: { ...s.models },
      overrides: this.overrides,
    };
  }

  private identityJson(): Record<string, unknown> {
    if (!this.linked) return { linked: false };
    return {
      linked: true,
      subject: this.linked.subject,
      display_name: this.linked.display_name ?? null,
      plane_url: this.linked.plane_url ?? null,
      linked_at: new Date().toISOString(),
    };
  }

  private rowOf(s: Session): Record<string, unknown> {
    return {
      id: s.id,
      workspace: s.workspace,
      branch: s.branch,
      profile: s.profile,
      state: s.state,
      status: s.status,
      tokens: 0,
      cost: 0.25,
      created_at: s.createdAt,
      last_active_at: s.lastActiveAt,
      pinned: false,
      kind: "local",
      ...(this.linked ? { owner: this.linked.subject } : {}),
      pending_approvals: s.pendingApprovals,
      config: { watch: s.watch },
    };
  }
}
