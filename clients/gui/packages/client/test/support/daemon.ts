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
//   it tells every client        `config.changed` goes to every client attached once a
//   what changed                 settings file changed (troupe #57), whoever changed it
//   it asks the first run's      `setup.get` says where it stands and `setup.answer`
//   questions                    moves it a step, checking a key and writing the settings
//
// It implements the protocol rather than imitating a screen, for the same reason the
// fake worker does: a test that passes against a fake that agrees with the client by
// construction has proved nothing.

import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import { COMMANDS, expandDefined } from "./commands.js";
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
  /** The same for questions. */
  pendingQuestions: number;
  /** The session's goal (`session.goal.*`), once one was set. */
  goal?: string | null;
  /**
   * The head `seq` as of the last moment a client was reading the session, the daemon's
   * `seen` mark: `unseen` counts what came after it. Null for a session nobody ever read.
   */
  seen?: number | null;
  /** How many subscriptions name the session now; `unseen` is empty while any does. */
  readers?: number;
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
  /**
   * True is a machine nobody has set up: no settings, no record of a first run, so
   * `setup.get` says the questions are needed. The default is a machine whose first
   * run is done, which is what every other test wants in front of it.
   */
  firstRun?: boolean;
  /** Variables set where the daemon runs, which the key step may keep a key in. */
  env?: Record<string, string>;
  /** What the machine's opencode config holds, as the daemon detects it. */
  opencode?: { providers: string[]; default: string | null };
  /**
   * False is a daemon from before troupe #57: `config.get` answers no `keys`, and a
   * `config.set` with no `provider` is the model panel's, as an old one reads it.
   */
  servesKeys?: boolean;
}

/** The `ui` keys the fake keeps (troupe #57), with their defaults: the daemon acts on none of them. */
const UI_DEFAULTS: Record<string, unknown> = { "ui.theme": "afterglow", "ui.mode": "system", "ui.notifications": true };

/** The first run in progress, as the fake daemon holds it. The key is here and in no answer. */
interface FakeSetupFlow {
  step: string;
  answers: Record<string, Record<string, unknown>>;
  key: string | null;
  offered: Array<Record<string, unknown>>;
  suggested: { default: string | null; cheap: string | null };
  check: { state: string; reason: string | null } | null;
}

const SETUP_STEPS = ["where", "provider", "key", "models", "workspace", "daemon", "finish"] as const;

function freshSetup(): FakeSetupFlow {
  return { step: "where", answers: {}, key: null, offered: [], suggested: { default: null, cheap: null }, check: null };
}

/** One MCP server in a fake layer file (troupe-remote Decision 700). `env` values stay here, as the real daemon keeps them. */
export interface FakeServer {
  name: string;
  layer: "user" | "workspace";
  source: string;
  command?: string;
  args?: string[];
  url?: string;
  env?: Record<string, string>;
  disabled?: boolean;
  /** A server that wants the person signed in (troupe-remote Decision 741). */
  oauth?: { client_id: string; scopes?: string[] };
  /** What `mcp.tools` lists for it; one `search` tool when absent. */
  tools?: Array<{ name: string; description: string; schema: Record<string, unknown> }>;
}

/** A call the fake made to one of the person's servers for `mcp.call`, with the credential it sent. */
export interface FakeServerCall {
  server: string;
  tool: string;
  arguments: Record<string, unknown>;
  authorization: string | null;
}

/** How a person's sign-in to a server stands, as `mcp.list`'s `auth` says it. */
export interface FakeAuth {
  state: "signed_out" | "signing_in" | "signed_in" | "expired";
  account: string | null;
  error: string | null;
}

export interface FakeSkill {
  name: string;
  description: string;
  layer: "user" | "workspace";
  source: string;
  dir: string;
  linked: boolean;
}

/** What the fake finds at a path a test names: the stand-in for the daemon reading a file or a directory. */
export interface Importable {
  servers?: Record<string, Record<string, unknown>>;
  skills?: Array<{ name: string; description: string }>;
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
  /** The token it serves with now; a `restart` draws a new one, as a daemon does. */
  token: string;
  readonly sessions = new Map<string, Session>();
  readonly calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  /** Who the daemon says its user is. `null` until somebody links an identity. */
  linked: { subject: string; display_name?: string; plane_url?: string } | null = null;
  /**
   * The plane token the last link carried, as the daemon holds it: in memory, in no
   * answer, kept by a link that carries none and gone with an unlink or a restart.
   */
  planeToken: string | null = null;
  /** Every plane token a link has handed over, oldest first. */
  readonly planeTokens: string[] = [];
  /** The private sessions `session.create` was asked for, by id. */
  readonly privateSessions = new Set<string>();
  /** The settings file, as `config.set` last wrote it. Nothing is saved until then. */
  settings: FakeModelSettings = {
    exists: false,
    provider: null,
    base_url: null,
    auth: null,
    api_key: null,
    models: { default: null, cheap: null, expensive: null },
  };
  /** The `ui` keys the file sets, by name; one not here is its default. */
  ui: Record<string, unknown> = {};
  /** The two layers of `mcp.json` and `skills/`, as the seven `mcp.*`/`skills.*` methods keep them. */
  servers: FakeServer[] = [];
  /** Sign-ins by server name (troupe-remote Decision 741); a server with `oauth` and no entry is signed out. */
  signIns: Record<string, FakeAuth> = {};
  /** The access token each sign-in left in the state directory, which no answer carries. */
  readonly signInTokens: Record<string, string> = {};
  /** Every call `mcp.call` made to a server, as the server would have received it (troupe Decision 748). */
  readonly serverCalls: FakeServerCall[] = [];
  /** `mcp.call`'s answers by command id: one asked again is answered from the first. */
  private readonly answered = new Map<string, unknown>();
  skills: FakeSkill[] = [];
  /** What lies at a path a test names, for `mcp.add` and `skills.add` with `from`. */
  importable: Record<string, Importable> = {};
  /** The record of a finished first run, as `setup.get` reports it; null until `finish`. */
  setupCompleted: { completed_at: string; choice: string; subject: string | null } | null;
  /** The first run in progress. */
  setup: FakeSetupFlow = freshSetup();
  /** Whether the login entry is there (troupe Decision 762): the `daemon` step writes and removes it. */
  atLogin = false;
  /** Directories the workspace step accepts; anything else "is not a directory". */
  directories: string[] = ["/home/ada/project", "/home/ada/notes", "/home/ada/repo"];
  /** How long `subscribe` takes to answer: a busy machine, where a screen is up before its view is. */
  subscribeDelayMs = 0;

  private server: Server | null = null;
  private wss: WebSocketServer | null = null;
  private readonly clients = new Set<Client>();
  private readonly capabilities: Record<string, unknown>;
  private readonly osUser: string;
  private readonly modelSettings: boolean;
  private readonly overrides: NonNullable<FakeDaemonOptions["overrides"]>;
  private readonly env: Record<string, string>;
  private readonly opencode: { providers: string[]; default: string | null };
  private readonly servesKeys: boolean;
  private nextId = 1;
  private restarts = 0;

  constructor(opts: FakeDaemonOptions = {}) {
    this.token = opts.token ?? "daemon-token";
    this.capabilities = opts.capabilities ?? { blobs: true, tools: true };
    this.osUser = opts.osUser ?? "ada";
    this.modelSettings = opts.modelSettings ?? true;
    this.overrides = opts.overrides ?? [];
    this.env = opts.env ?? {};
    this.opencode = opts.opencode ?? { providers: [], default: null };
    this.servesKeys = opts.servesKeys ?? true;
    this.setupCompleted = opts.firstRun ? null : { completed_at: "2026-09-01T08:00:00Z", choice: "local", subject: null };
  }

  /**
   * What the daemon does after a settings file changed (troupe #57): `config.changed` to
   * every client attached, the one that changed it too. Public, so a test can play the
   * terminal changing the file.
   */
  announce(keys: string[]): void {
    if (keys.length === 0 || !this.servesKeys) return;
    const changed = { scope: "user", path: String(this.configJson()["path"]), keys };
    for (const c of this.clients) notify(c.ws, "config.changed", changed);
  }

  get principal(): { subject: string; display_name: string; kind: string } {
    return this.linked
      ? { subject: this.linked.subject, display_name: this.linked.display_name ?? this.linked.subject, kind: "user" }
      : { subject: `local:${this.osUser}`, display_name: this.osUser, kind: "user" };
  }

  /**
   * Listen. `port` starts it again where it was after a `stop`, with its sessions: a
   * daemon that went away and came back, as far as a client already holding its port and
   * token can tell.
   */
  async start(port = 0): Promise<string> {
    this.server = createServer();
    this.wss = new WebSocketServer({ server: this.server, path: "/v1/socket" });
    this.wss.on("connection", (ws) => this.onConnection(ws));
    await new Promise<void>((resolve) => this.server!.listen(port, "127.0.0.1", resolve));
    return String(this.port);
  }

  async stop(): Promise<void> {
    for (const c of this.clients) c.ws.close();
    this.clients.clear();
    await new Promise<void>((resolve) => this.wss?.close(() => resolve()));
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
  }

  /**
   * Go away and come back as a daemon that restarted does (`loopback.ex`): on a port the
   * kernel picks and with a new random token, its sessions kept. A client still holding
   * the old port and token reaches nothing; what the daemon publishes now is `published`.
   */
  async restart(): Promise<void> {
    await this.stop();
    this.restarts += 1;
    this.token = `daemon-token-${this.restarts}`;
    // The label is in `identity.json` and survives; the plane token was in memory.
    this.planeToken = null;
    await this.start();
  }

  /** What `daemon.json` says while it runs: the port and token a client finds it by. */
  get published(): { transport: "ws"; port: number; token: string } {
    return { transport: "ws", port: this.port, token: this.token };
  }

  get port(): number {
    return (this.server!.address() as AddressInfo).port;
  }

  /** Seed a session, as one started before the client connected. `opts.id` names it. */
  seed(workspace: string, opts: Partial<Session> = {}): Session {
    const id = opts.id ?? `s-${this.nextId++}`;
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
      pendingQuestions: 0,
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

  /**
   * As a root agent that kept crashing ends its turn (Decision 727): `turn_ended` with
   * `agent_failed` and what it raised, and the session stops, to be listed dormant.
   */
  fail(sessionId: string, detail: string): LoggedEvent {
    const session = this.sessions.get(sessionId)!;
    const ended = session.log.append("turn_ended", { reason: "agent_failed", detail });
    session.state = "dormant";
    session.status = "idle";
    return ended;
  }

  /**
   * How the root agent's last turn failed, as the daemon's row says it for a dormant
   * session: its last `turn_ended` ended `agent_failed`, and no turn has started since.
   */
  failedOf(s: Session): { reason: string; detail: string | null } | null {
    if (s.state !== "dormant") return null;
    const last = s.log.events.filter((e) => e.agent.length === 1 && ["turn_ended", "user_input", "cancelled", "agent_done"].includes(e.type)).at(-1);
    if (last?.type !== "turn_ended" || last.data["reason"] !== "agent_failed") return null;
    return { reason: "agent_failed", detail: typeof last.data["detail"] === "string" ? last.data["detail"] : null };
  }

  /** As if a client had read the session up to now and left: what follows is `unseen`. */
  markSeen(sessionId: string): void {
    const session = this.sessions.get(sessionId)!;
    session.seen = session.log.headSeq;
  }

  /**
   * What happened since the last reader left (PROTOCOL.md §6, `session.list`): the root
   * agent's `turn_ended`s and its distinct approvals and questions, with the first one's
   * time. Empty while somebody reads it, and for a session nobody ever read.
   */
  unseenOf(s: Session): { turns: number; approvals: number; questions: number; since: string | null } {
    const empty = { turns: 0, approvals: 0, questions: 0, since: null };
    if ((s.readers ?? 0) > 0 || s.seen === null || s.seen === undefined) return empty;
    const root = s.log.from(s.seen).filter((e) => e.agent.length === 1);
    const turns = root.filter((e) => e.type === "turn_ended");
    const calls = (type: string) => root.filter((e, i, all) => e.type === type && all.findIndex((o) => o.type === type && o.data["call_id"] === e.data["call_id"]) === i);
    const approvals = calls("approval_requested");
    const questions = calls("question_asked");
    const counted = [...turns, ...approvals, ...questions].sort((a, b) => a.seq - b.seq);
    return { turns: turns.length, approvals: approvals.length, questions: questions.length, since: counted[0]?.ts ?? null };
  }

  /** The latest loop as the log has it, the way `session.loop.get` reads it. */
  loopOf(s: Session): Record<string, unknown> | null {
    const started = s.log.events.filter((e) => e.type === "loop_started").at(-1);
    if (!started) return null;
    const id = started.data["loop_id"];
    const mine = s.log.from(started.seq).filter((e) => e.data["loop_id"] === id);
    const stopped = mine.find((e) => e.type === "loop_stopped");
    const iteration = mine.filter((e) => e.type === "loop_iteration_started").length;
    return {
      loop_id: id,
      state: stopped ? "stopped" : "running",
      iteration,
      max_iterations: started.data["max_iterations"],
      failures: 0,
      reason: stopped?.data["reason"] ?? null,
      detail: stopped?.data["detail"] ?? null,
      summary: stopped?.data["summary"] ?? null,
      goal: started.data["goal"],
      started_by: started.actor.subject ?? null,
      started_at: started.ts,
    };
  }

  /** A subscription that names a session is a reader of it: it clears `unseen` on arrival and marks where it left. */
  private reading(topic: string, delta: 1 | -1): void {
    const session = this.sessions.get(topic.replace(/^(session|presence):/, ""));
    if (!session || !/^(session|presence):/.test(topic)) return;
    session.readers = Math.max(0, (session.readers ?? 0) + delta);
    if (delta === 1 || session.readers === 0) session.seen = session.log.headSeq;
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
      for (const s of client.subs.values()) {
        s.off();
        this.reading(s.topic, -1);
      }
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
        if (typeof params["plane_token"] === "string" && params["plane_token"]) {
          this.planeToken = params["plane_token"];
          this.planeTokens.push(params["plane_token"]);
        }
        return reply(ws, id, this.identityJson());
      }

      case "identity.unlink":
        this.linked = null;
        this.planeToken = null;
        return reply(ws, id, this.identityJson());

      // The token goes where it is that person's at that plane; the label stays (#381).
      case "identity.sign_out": {
        const plane = String(params["plane_url"] ?? "").replace(/\/+$/, "");
        const subject = params["subject"];
        const theirs =
          this.planeToken !== null &&
          (this.linked?.plane_url ?? "").replace(/\/+$/, "") === plane &&
          (subject === undefined || subject === this.linked?.subject);
        if (theirs) this.planeToken = null;
        return reply(ws, id, { signed_out: theirs });
      }

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
        // `private` beside `workspace`, as the daemon reads it; one inside `config` is a
        // setting no client may choose, and is not asked for.
        const asked = params["private"] === true;
        if (asked) this.privateSessions.add(created.id);
        return reply(ws, id, {
          session_id: created.id,
          workspace,
          worktree: null,
          branch: null,
          syncing: asked && this.planeToken !== null,
        });
      }

      case "subscribe": {
        if (this.subscribeDelayMs > 0 && !params["__delayed"]) {
          const later = { ...params, __delayed: true };
          setTimeout(() => this.handle(client, id, method, later), this.subscribeDelayMs);
          return;
        }
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
        this.reading(topic, 1);
        reply(ws, id, { subscription_id: subscriptionId, head_seq: target.log.headSeq, replayed: backlog.length });
        for (const e of backlog) {
          notify(ws, "event", { topic, subscription_id: subscriptionId, session_id: target.id, event: e });
        }
        return;
      }

      case "unsubscribe": {
        const sub = client.subs.get(String(params["subscription_id"] ?? ""));
        sub?.off();
        if (sub) {
          client.subs.delete(sub.id);
          this.reading(sub.topic, -1);
        }
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

      // The goal and the loop, as the daemon keeps them (PROTOCOL.md §6): the answer is
      // the acknowledgement and the event is the effect.
      case "session.goal.set": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const text = String(params["text"] ?? "").trim();
        if (!text) return reply(ws, id, null, { code: -32602, message: "invalid_params", data: { field: "text" } });
        session.goal = text;
        session.log.append("goal_set", { text, command_id: params["command_id"] }, { kind: "user", subject: this.principal.subject });
        return reply(ws, id, { accepted: true });
      }

      case "session.goal.clear": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        session.goal = null;
        session.log.append("goal_cleared", { command_id: params["command_id"] }, { kind: "user", subject: this.principal.subject });
        return reply(ws, id, { accepted: true });
      }

      case "session.goal.get":
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        return reply(ws, id, session.goal ? { goal: session.goal, set_by: this.principal.subject, set_at: new Date().toISOString() } : { goal: null, set_by: null, set_at: null });

      // A loop is read from the log, as the daemon reads it: its iterations are whatever a
      // test appends (`loop_iteration_started`, …), and stopping writes `loop_stopped`.
      case "session.loop.start": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        if (!session.goal) return reply(ws, id, null, { code: -32006, message: "conflict", data: { needs: "goal", reason: "the session has no goal to loop towards: set one with session.goal.set" } });
        const running = this.loopOf(session);
        if (running?.["state"] === "running") {
          return reply(ws, id, null, { code: -32006, message: "conflict", data: { loop_id: running["loop_id"], reason: "a loop is already running: session.loop.stop stops it" } });
        }
        const max = params["max_iterations"] === undefined ? 10 : Number(params["max_iterations"]);
        if (!(Number.isInteger(max) && max > 0)) return reply(ws, id, null, { code: -32602, message: "invalid_params", data: { field: "max_iterations" } });
        const loopId = `loop-${session.log.events.filter((e) => e.type === "loop_started").length + 1}`;
        session.log.append("loop_started", { loop_id: loopId, max_iterations: max, max_failures: 3, goal: session.goal, command_id: params["command_id"] }, { kind: "user", subject: this.principal.subject });
        return reply(ws, id, { accepted: true, loop_id: loopId, max_iterations: max });
      }

      case "session.loop.stop": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const loop = this.loopOf(session);
        if (loop?.["state"] === "running") {
          session.log.append(
            "loop_stopped",
            { loop_id: loop["loop_id"], reason: "requested", iterations: loop["iteration"], detail: null, summary: null, command_id: params["command_id"] },
            { kind: "user", subject: this.principal.subject },
          );
        }
        return reply(ws, id, { accepted: true });
      }

      case "session.loop.get":
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        return reply(ws, id, { loop: this.loopOf(session) });

      case "presence.set":
        return reply(ws, id, { ok: true });

      case "commands.list":
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "session", id: sessionId } });
        return reply(ws, id, { commands: COMMANDS });

      // A command a file defines, as the daemon runs it (Decision 763): its prompt, with
      // `arguments` for `$ARGUMENTS`, goes in as input under the call's `command_id`.
      case "commands.run": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "session", id: sessionId } });
        const name = String(params["name"] ?? "");
        const text = expandDefined(name, String(params["arguments"] ?? ""));
        if (text === null) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "command", name } });
        const commandId = String(params["command_id"] ?? "");
        const actor = { kind: "user", subject: this.principal.subject };
        session.log.append("input_queued", { command_id: commandId, author: this.principal.subject, text }, actor);
        session.log.append("input_accepted", { command_id: commandId, author: this.principal.subject }, actor);
        session.log.append("user_input", { command_id: commandId, text, source: "user" }, actor);
        return reply(ws, id, { accepted: true, command_id: commandId });
      }

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

      case "setup.get":
      case "setup.answer":
        if (!this.modelSettings) return reply(ws, id, null, { code: -32601, message: "method_not_found", data: { method } });
        return this.setupCall(ws, id, method, params);

      case "mcp.list":
      case "mcp.add":
      case "mcp.remove":
      case "mcp.check":
      case "mcp.sign_in":
      case "mcp.sign_out":
      case "mcp.tools":
      case "mcp.call":
      case "skills.list":
      case "skills.add":
      case "skills.remove":
        return this.sources(ws, id, method, params);

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
    if (this.servesKeys && ("key" in params || "path" in params)) return this.setKey(ws, id, params);
    const before = { ...s, models: { ...s.models } };
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
    reply(ws, id, this.configJson());
    // The keys whose lines changed, as the daemon reads the file before and after.
    const fields = ["api_key", "auth", "base_url", "provider"] as const;
    const roles = ["cheap", "default", "expensive"] as const;
    this.announce([
      ...fields.filter((f) => before[f] !== s[f]),
      ...roles.filter((r) => before.models[r] !== s.models[r]).map((r) => `models.${r}`),
    ]);
  }

  /**
   * `config.set` of one key (troupe #57), as the daemon does it for the keys a client of
   * this fake sets: the model roles and the `ui` keys, into the user's file. Anything else
   * is not a setting it knows, and another scope needs a workspace it does not have.
   */
  private setKey(ws: WebSocket, id: unknown, params: Record<string, unknown>): void {
    const invalid = (reason: string) => reply(ws, id, null, { code: -32602, message: "invalid_params", data: { reason } });
    const key = Array.isArray(params["path"]) ? (params["path"] as string[]).join(".") : String(params["key"] ?? "");
    const scope = String(params["scope"] ?? "user");
    const value = params["value"] ?? null;
    if (scope !== "user") return invalid(`the ${scope} scope needs a workspace`);

    const role = /^models\.(default|cheap|expensive)$/.exec(key)?.[1] as keyof FakeModelSettings["models"] | undefined;
    let changed: boolean;
    if (role) {
      if (value !== null && typeof value !== "string") return invalid(`${key} must be a string, not ${JSON.stringify(value)}`);
      changed = this.settings.models[role] !== value;
      this.settings.models[role] = value;
    } else if (key in UI_DEFAULTS) {
      if (key === "ui.mode" && value !== null && !["system", "light", "dark"].includes(String(value))) {
        return invalid(`ui.mode must be one of system, light, dark, not ${JSON.stringify(value)}`);
      }
      if (key === "ui.notifications" && value !== null && typeof value !== "boolean") {
        return invalid(`ui.notifications must be true or false, not ${JSON.stringify(value)}`);
      }
      changed = this.ui[key] !== (value ?? undefined);
      if (value === null) delete this.ui[key];
      else this.ui[key] = value;
    } else {
      return invalid(`${key} is not a setting Troupe knows; \`troupe config --explain\` lists them all`);
    }

    this.settings.exists = true;
    const path = String(this.configJson()["path"]);
    reply(ws, id, { ...this.configJson(), written: { key, scope, path } });
    if (changed) this.announce([key]);
  }

  /**
   * The first run's questions (troupe Decision 705), with the daemon's semantics: a step
   * is the current one or one already answered (which forgets what came after), a key
   * is checked before anything is written — right when it looks like one, refused
   * otherwise — the settings are written at the models step, `auto_approve` at the
   * workspace step, the login entry (`atLogin`) at the daemon step, and `finish` records
   * the run and starts the session.
   */
  private setupCall(ws: WebSocket, id: unknown, method: string, params: Record<string, unknown>): void {
    const invalid = (reason: string) => reply(ws, id, null, { code: -32602, message: "invalid_params", data: { reason } });
    if (method === "setup.get") return reply(ws, id, this.setupJson());
    if (!params["command_id"]) return invalid("command_id is required");

    const step = String(params["step"] ?? "");
    const answer = (params["answer"] ?? {}) as Record<string, unknown>;
    const flow = this.setup;
    const index = SETUP_STEPS.indexOf(step as (typeof SETUP_STEPS)[number]);
    if (index < 0) return invalid(`${JSON.stringify(step)} is not a step; the steps are ${SETUP_STEPS.join(", ")}`);
    if (step !== flow.step && !(step in flow.answers)) return invalid(`the current step is ${flow.step}; answer it, or a step already answered`);

    // Going back forgets what came after, the key included.
    for (const later of SETUP_STEPS.slice(index)) delete flow.answers[later];
    if (index <= SETUP_STEPS.indexOf("key")) {
      flow.key = null;
      flow.offered = [];
      flow.suggested = { default: null, cheap: null };
      flow.check = null;
    }
    flow.step = step;
    if (answer["back"] === true) return reply(ws, id, this.setupJson());

    const advance = (accepted: Record<string, unknown>, next: string) => {
      flow.answers[step] = accepted;
      flow.step = next;
    };

    switch (step) {
      case "where": {
        if (answer["choice"] === "local") advance({ choice: "local" }, "provider");
        else if (answer["choice"] === "plane") advance({ choice: "plane", plane_url: (answer["plane_url"] as string) || null }, "finish");
        else return invalid("choice must be local or plane");
        break;
      }
      case "provider": {
        if (answer["reuse"] === "opencode") {
          if (this.opencode.providers.length === 0) return invalid("there are no providers in opencode's config to copy");
          this.settings.exists = true;
          advance({ reuse: "opencode", providers: this.opencode.providers }, "workspace");
          break;
        }
        if (answer["reuse"] === "config") {
          if (!this.settings.exists || !this.settings.api_key) return invalid("there is no config.yaml through which a model can be asked; set a provider up instead");
          advance({ reuse: "config", path: this.configJson()["path"] }, "workspace");
          break;
        }
        const provider = String(answer["provider"] ?? "");
        if (!OFFERS[provider]) return invalid(`provider must be one of anthropic, openai, fake, not ${JSON.stringify(provider)}`);
        const kind = String(answer["kind"] ?? provider);
        const baseUrl = ((answer["base_url"] as string | null) ?? "").trim() || null;
        if ((kind === "gateway" || kind === "litellm") && !baseUrl) return invalid(`a ${kind} needs its base URL, ending in /v1`);
        advance({ provider, kind, base_url: baseUrl, auth: (answer["auth"] as string) ?? "api_key" }, "key");
        break;
      }
      case "key": {
        const provider = flow.answers["provider"]!;
        let key: string | null;
        let source: Record<string, unknown>;
        if (typeof answer["api_key"] === "string") {
          key = answer["api_key"].trim();
          if (!key) return invalid("api_key is empty; paste the key, or name the variable it is in");
          source = { source: "typed" };
        } else if (typeof answer["env"] === "string") {
          const value = this.env[answer["env"]];
          if (!value) return invalid(`${answer["env"]} is not set where the daemon runs; paste the key, or set it and start the daemon again`);
          key = value;
          source = { source: "env", var: answer["env"] };
        } else if (provider["base_url"]) {
          key = null;
          source = { source: "none" };
        } else {
          return invalid(`${provider["provider"]} needs a key; paste one, or keep it in ${provider["provider"] === "anthropic" ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"}`);
        }
        // The real daemon lists the provider's models with the key; here a key is right
        // when it looks like one, and a gateway given none cannot be asked.
        if (key && !key.startsWith("sk-")) {
          flow.check = { state: "refused", reason: "401 unauthorized: the key was refused" };
          break;
        }
        flow.key = typeof answer["env"] === "string" ? `{env:${answer["env"]}}` : key;
        flow.offered = key ? OFFERS[String(provider["provider"])]! : [];
        const ids = flow.offered.map((m) => String(m["id"]));
        flow.suggested = { default: ids[0] ?? null, cheap: ids[1] ?? ids[0] ?? null };
        flow.check = key ? { state: "ok", reason: null } : { state: "unknown", reason: "no key was given, so nothing was asked" };
        advance(source, "models");
        break;
      }
      case "models": {
        const def = String(answer["default"] ?? "").trim();
        if (!def) return invalid("default must be a model id");
        const cheap = ((answer["cheap"] as string | null) ?? "").trim() || null;
        const provider = flow.answers["provider"]!;
        this.settings = {
          exists: true,
          provider: String(provider["provider"]),
          base_url: (provider["base_url"] as string | null) ?? null,
          auth: (provider["auth"] as "api_key" | "bearer") ?? "api_key",
          api_key: flow.key,
          models: { default: def, cheap, expensive: null },
        };
        advance({ default: def, cheap }, "workspace");
        this.announce(["provider", "models.default", "models.cheap"]);
        break;
      }
      case "workspace": {
        const workspace = String(answer["workspace"] ?? "").trim();
        if (!workspace) return invalid("workspace must be a directory");
        if (!this.directories.includes(workspace)) return invalid(`${workspace} is not a directory`);
        const approvals = answer["approvals"] ?? "ask";
        if (approvals !== "ask" && approvals !== "auto") return invalid(`approvals must be ask or auto, not ${JSON.stringify(approvals)}`);
        advance({ workspace, approvals }, "daemon");
        break;
      }
      case "daemon": {
        if (typeof answer["at_login"] !== "boolean") return invalid("at_login must be true or false");
        this.atLogin = answer["at_login"];
        advance({ at_login: this.atLogin }, "finish");
        break;
      }
      case "finish": {
        const choice = String(flow.answers["where"]?.["choice"] ?? "local");
        this.setupCompleted = { completed_at: new Date().toISOString(), choice, subject: this.principal.subject };
        const workspace = flow.answers["workspace"]?.["workspace"] as string | undefined;
        let session: Record<string, unknown> | null = null;
        if (choice === "local" && workspace && answer["start"] !== false) {
          const prompt = String(answer["prompt"] ?? "").trim() || this.suggestedPrompt(workspace);
          const created = this.seed(workspace);
          // As a session created with a prompt starts: the prompt is its first input.
          created.log.append("user_input", { text: prompt, source: "user", author: this.principal.subject }, { kind: "user", subject: this.principal.subject });
          session = { workspace, prompt, session_id: created.id, worktree: null, branch: null };
        }
        advance({ start: session !== null }, "done");
        const finished = { ...this.setupJson(), step: "done", session };
        this.setup = freshSetup();
        return reply(ws, id, finished);
      }
    }
    return reply(ws, id, this.setupJson());
  }

  private suggestedPrompt(workspace: string | null | undefined): string | null {
    if (!workspace) return null;
    return workspace.endsWith("repo")
      ? "Tell me what this project does, how it is built and tested, and where you would start reading."
      : "Look around this directory and tell me what you find.";
  }

  private setupJson(): Record<string, unknown> {
    const flow = this.setup;
    const path =
      flow.answers["where"]?.["choice"] === "plane"
        ? ["where", "finish"]
        : typeof flow.answers["provider"]?.["reuse"] === "string"
          ? ["where", "provider", "workspace", "daemon", "finish"]
          : [...SETUP_STEPS];
    const config = this.configJson();
    return {
      needed: this.setupCompleted === null && !this.settings.exists,
      completed: this.setupCompleted,
      step: flow.step,
      steps: path.map((name) => ({ name, done: name in flow.answers })),
      answers: flow.answers,
      detected: {
        env: Object.keys(this.env).filter((v) => v === "ANTHROPIC_API_KEY" || v === "OPENAI_API_KEY"),
        opencode: { path: `/home/${this.osUser}/.config/opencode/opencode.jsonc`, ...this.opencode },
        config: { ...config, usable: this.settings.exists && this.settings.api_key !== null },
        plane: { url: this.linked?.plane_url ?? null, linked: this.linked !== null },
      },
      key_storage: { kind: "file", path: config["path"], keychain: false },
      offered: flow.offered,
      suggested: flow.suggested,
      check: flow.check,
      suggested_prompt: this.suggestedPrompt(flow.answers["workspace"]?.["workspace"] as string | undefined),
      daemon: {
        at_login: this.atLogin,
        kind: "systemd",
        path: `/home/${this.osUser}/.config/systemd/user/troupe-daemon.service`,
        command: `/home/${this.osUser}/.local/bin/troupe-daemon`,
      },
      session: null,
    };
  }

  /** The person came back from the browser: a sign-in started with `mcp.sign_in` lands. */
  finishSignIn(name: string, account: string | null = "ada@example.test"): void {
    this.signIns[name] = { state: "signed_in", account, error: null };
    this.signInTokens[name] = `at-${name}-${Math.random().toString(36).slice(2)}`;
  }

  /**
   * The person's own servers and skills (troupe-remote Decision 700), with the daemon's
   * shapes: a layer's file written by scope, an import reading what `importable` says
   * is at the path, `env` answered as names, a check answering `ready` with one tool
   * for anything but a command that does not exist.
   */
  private sources(ws: WebSocket, id: unknown, method: string, params: Record<string, unknown>): void {
    const invalid = (reason: string) => reply(ws, id, null, { code: -32602, message: "invalid_params", data: { reason } });
    const scope = (params["scope"] as "user" | "workspace" | undefined) ?? "user";
    const workspace = typeof params["workspace"] === "string" ? params["workspace"] : null;
    const dir = `/home/${this.osUser}/.config/troupe`;
    const layerPath = (what: "mcp.json" | "skills") => (scope === "workspace" ? `${workspace}/.troupe/${what}` : `${dir}/${what}`);
    if (scope === "workspace" && !workspace) return invalid("the workspace scope needs a workspace");

    const visible = <T extends { layer: string }>(rows: T[]): T[] => rows.filter((r) => r.layer === "user" || Boolean(workspace));
    const authOf = (s: FakeServer): FakeAuth | null => (s.oauth ? (this.signIns[s.name] ?? { state: "signed_out", account: null, error: null }) : null);
    const liveOf = (s: FakeServer) =>
      s.disabled
        ? { state: "disabled", tools: [], error: null }
        : s.oauth && authOf(s)?.state !== "signed_in"
          ? { state: "sign_in", tools: [], error: `sign in to ${s.name}: /mcp sign-in ${s.name}, or Sign in on the desktop app's Servers and skills` }
          : { state: "ready", tools: ["greet"], error: null };
    const serverJson = (s: FakeServer, live: boolean) => ({
      name: s.name,
      layer: s.layer,
      source: s.source,
      transport: s.url ? "http" : "stdio",
      command: s.command ?? null,
      args: s.args ?? [],
      url: s.url ?? null,
      cd: null,
      env: Object.keys(s.env ?? {}).sort(),
      permission: "ask",
      disabled: Boolean(s.disabled),
      refused: null,
      trust: s.layer === "workspace" ? "trusted" : null,
      oauth: s.oauth ?? null,
      auth: authOf(s),
      ...(live ? liveOf(s) : { state: null, tools: [], error: null }),
    });

    switch (method) {
      case "mcp.list":
        return reply(ws, id, { servers: visible(this.servers).map((s) => serverJson(s, typeof params["session_id"] === "string")), warnings: [] });

      case "mcp.add": {
        if (!params["command_id"]) return invalid("command_id is required");
        const from = params["from"];
        if (typeof from === "string") {
          const found = this.importable[from];
          if (!found?.servers) return invalid(`could not read ${from}: no such file or directory`);
          const path = layerPath("mcp.json");
          const added: string[] = [];
          const skipped: Array<{ name: string; reason: string }> = [];
          for (const [name, raw] of Object.entries(found.servers)) {
            if (!raw["command"] && !raw["url"]) {
              skipped.push({ name, reason: "has neither a command nor a url" });
              continue;
            }
            this.servers = this.servers.filter((s) => !(s.name === name && s.layer === scope));
            this.servers.push({ name, layer: scope, source: params["link"] ? from : path, ...(raw as Omit<FakeServer, "name" | "layer" | "source">) });
            added.push(name);
          }
          return reply(ws, id, { path, from, added: added.sort(), skipped, warnings: [], linked: Boolean(params["link"]) });
        }
        const name = params["name"];
        const raw = params["server"];
        if (typeof name !== "string" || typeof raw !== "object" || raw === null) return invalid("mcp.add takes a file to import (from) or a server to write (name and server)");
        if (!/^[a-z0-9][a-z0-9_-]*$/.test(name)) return invalid(`${JSON.stringify(name)} is not a server name: lower-case letters, digits, - and _, and no dot`);
        const existing = this.servers.find((s) => s.name === name && s.layer === scope);
        const merged: FakeServer = { ...(existing ?? { name, layer: scope, source: layerPath("mcp.json") }), ...(raw as Partial<FakeServer>), name, layer: scope };
        this.servers = [...this.servers.filter((s) => s !== existing), merged];
        const { name: _n, layer: _l, source: _s, env, ...entry } = merged;
        return reply(ws, id, { name, path: merged.source, entry: { ...entry, ...(env ? { env: Object.keys(env).sort() } : {}) }, warnings: [] });
      }

      case "mcp.remove": {
        if (!params["command_id"]) return invalid("command_id is required");
        const path = layerPath("mcp.json");
        if (typeof params["include"] === "string") {
          const gone = this.servers.filter((s) => s.layer === scope && s.source === params["include"]);
          if (gone.length === 0) return invalid(`${path} does not include ${params["include"]}`);
          this.servers = this.servers.filter((s) => !gone.includes(s));
          return reply(ws, id, { path, removed: gone.map((s) => s.name).sort() });
        }
        const name = String(params["name"] ?? "");
        const own = this.servers.find((s) => s.name === name && s.layer === scope);
        if (!own) return invalid(`${path} has no server named ${name}`);
        if (own.source !== path) return invalid(`${name} comes from ${own.source}, which ${path} links; edit that file, or unlink it with include: ${JSON.stringify(own.source)}`);
        this.servers = this.servers.filter((s) => s !== own);
        return reply(ws, id, { path, removed: [name] });
      }

      case "mcp.check": {
        const name = String(params["name"] ?? "");
        const given = params["server"] as Record<string, unknown> | undefined;
        const known = this.servers.find((s) => s.name === name);
        if (!given && !known) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "mcp_server", name } });
        const command = given ? String(given["command"] ?? "") : (known?.command ?? "");
        const base = known ? serverJson(known, false) : { name, layer: "request", source: "request" };
        if (command.startsWith("no-such")) return reply(ws, id, { server: { ...base, state: "error", tools: [], error: `could not start: {:not_found, "${command}"}` } });
        if (known?.disabled) return reply(ws, id, { server: { ...base, state: "disabled", tools: [], error: null } });
        if (known) return reply(ws, id, { server: { ...base, ...liveOf(known) } });
        return reply(ws, id, { server: { ...base, state: "ready", tools: ["greet"], error: null } });
      }

      // The daemon runs the sign-in and listens for the browser; here the browser is a
      // test calling `finishSignIn`.
      case "mcp.sign_in":
      case "mcp.sign_out": {
        if (!params["command_id"]) return invalid("command_id is required");
        const name = String(params["name"] ?? "");
        const known = this.servers.find((s) => s.name === name);
        if (!known) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "mcp_server", name } });
        if (!known.oauth) return invalid(`${name} takes no sign-in: give its entry an oauth.client_id to sign in to it`);
        if (method === "mcp.sign_out") {
          delete this.signIns[name];
          return reply(ws, id, { server: name, auth: authOf(known) });
        }
        this.signIns[name] = { state: "signing_in", account: this.signIns[name]?.account ?? null, error: null };
        const query = new URLSearchParams({ client_id: known.oauth.client_id, response_type: "code", redirect_uri: "http://127.0.0.1:53682/callback" });
        return reply(ws, id, {
          server: name,
          url: `https://login.example.test/tenant/authorize?${query.toString()}`,
          redirect_uri: "http://127.0.0.1:53682/callback",
          expires_at: new Date(Date.now() + 5 * 60_000).toISOString(),
        });
      }

      // A server listed and called outside any session, with the person's sign-in (troupe
      // Decision 748): the token goes to the server and into no answer.
      case "mcp.tools":
      case "mcp.call": {
        const name = String(params["name"] ?? "");
        const known = this.servers.find((s) => s.name === name);
        if (!known) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "mcp_server", name } });
        if (!known.url) return invalid(`${name} runs a command on this computer; only a server with a url is called outside a session`);
        const live = liveOf(known);
        const tools = known.tools ?? [{ name: "search", description: "Search my notes.", schema: { type: "object", properties: { topic: { type: "string" } } } }];
        if (method === "mcp.tools") return reply(ws, id, { server: name, state: live.state, error: live.error, tools: live.state === "ready" ? tools : [] });

        if (!params["command_id"]) return invalid("command_id is required");
        const commandId = String(params["command_id"]);
        if (this.answered.has(commandId)) return reply(ws, id, this.answered.get(commandId));
        const tool = String(params["tool"] ?? "");
        const args = (params["arguments"] as Record<string, unknown> | undefined) ?? {};
        let content: string;
        if (live.state === "ready") {
          const token = this.signInTokens[name] ?? null;
          this.serverCalls.push({ server: name, tool, arguments: args, authorization: token ? `Bearer ${token}` : null });
          content = `${tool} on ${name} for ${this.signIns[name]?.account ?? "nobody"}: ${JSON.stringify(args)}`;
        } else {
          content = JSON.stringify({ error: "sign_in_required", server: name, hint: `sign in to ${name} on the desktop app's Servers and skills panel, then ask again` });
        }
        const answer = { server: name, tool, content };
        this.answered.set(commandId, answer);
        return reply(ws, id, answer);
      }

      case "skills.list":
        return reply(ws, id, { skills: visible(this.skills) });

      case "skills.add": {
        if (!params["command_id"]) return invalid("command_id is required");
        const from = String(params["from"] ?? "");
        const found = this.importable[from];
        if (!found?.skills) return invalid(`${from} is not a directory`);
        const link = Boolean(params["link"]);
        const path = link ? `${scope === "workspace" ? `${workspace}/.troupe` : dir}/skills.json` : layerPath("skills");
        const added: string[] = [];
        for (const skill of found.skills) {
          this.skills = this.skills.filter((s) => !(s.name === skill.name && s.layer === scope));
          this.skills.push({ ...skill, layer: scope, source: link ? from : layerPath("skills"), dir: `${link ? from : layerPath("skills")}/${skill.name}`, linked: link });
          added.push(skill.name);
        }
        return reply(ws, id, { path, from, added: added.sort(), skipped: [], linked: link });
      }

      case "skills.remove": {
        if (!params["command_id"]) return invalid("command_id is required");
        if (typeof params["include"] === "string") {
          const gone = this.skills.filter((s) => s.layer === scope && s.linked && s.source === params["include"]);
          this.skills = this.skills.filter((s) => !gone.includes(s));
          return reply(ws, id, { path: `${dir}/skills.json`, removed: gone.map((s) => s.name).sort() });
        }
        const name = String(params["name"] ?? "");
        const own = this.skills.find((s) => s.name === name && s.layer === scope);
        if (!own) return invalid(`${layerPath("skills")} has no skill named ${name}`);
        if (own.linked) return invalid(`${name} comes from ${own.source}, which links it; unlink it with include: ${JSON.stringify(own.source)}`);
        this.skills = this.skills.filter((s) => s !== own);
        return reply(ws, id, { path: layerPath("skills"), removed: [name] });
      }

      default:
        return reply(ws, id, null, { code: -32601, message: "method_not_found", data: { method } });
    }
  }

  private configJson(): Record<string, unknown> {
    const s = this.settings;
    const dir = `/home/${this.osUser}/.config/troupe`;
    const path = `${dir}/config.yaml`;
    const answer: Record<string, unknown> = {
      config_dir: dir,
      path,
      exists: s.exists,
      provider: s.provider,
      base_url: s.base_url,
      auth: s.auth,
      api_key_set: s.api_key !== null,
      api_key_source: s.api_key !== null ? "file" : null,
      models: { ...s.models },
      overrides: this.overrides,
    };
    if (!this.servesKeys) return answer;

    // Every key the fake keeps, with where it came from (troupe #57): the file, or the default.
    const key = (name: string, value: unknown, fallback: unknown, label: string) => ({
      key: name,
      value: value ?? fallback,
      layer: value === undefined || value === null ? "default" : "user",
      source: value === undefined || value === null ? null : path,
      default: fallback,
      scopes: ["user"],
      secret: false,
      label,
      doc: null,
    });
    return {
      ...answer,
      workspace: null,
      trusted: false,
      files: [{ scope: "user", path, exists: s.exists }],
      keys: [
        key("models.default", s.models.default, "claude-sonnet-5", "model"),
        key("models.cheap", s.models.cheap, null, "cheap model"),
        key("models.expensive", s.models.expensive, null, "expensive model"),
        key("ui.theme", this.ui["ui.theme"], UI_DEFAULTS["ui.theme"], "theme"),
        key("ui.mode", this.ui["ui.mode"], UI_DEFAULTS["ui.mode"], "light or dark"),
        key("ui.notifications", this.ui["ui.notifications"], UI_DEFAULTS["ui.notifications"], "notifications"),
      ],
      warnings: [],
      errors: [],
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
      pending_questions: s.pendingQuestions,
      unseen: this.unseenOf(s),
      failed: this.failedOf(s),
      config: { watch: s.watch },
    };
  }
}
