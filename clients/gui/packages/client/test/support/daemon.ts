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
//   it asks the first run's      `setup.get` says where it stands and `setup.answer`
//   questions                    moves it a step, checking a key and writing the settings
//
// It implements the protocol rather than imitating a screen, for the same reason the
// fake worker does: a test that passes against a fake that agrees with the client by
// construction has proved nothing.

import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import { COMMANDS } from "./commands.js";
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
}

/** The first run in progress, as the fake daemon holds it. The key is here and in no answer. */
interface FakeSetupFlow {
  step: string;
  answers: Record<string, Record<string, unknown>>;
  key: string | null;
  offered: Array<Record<string, unknown>>;
  suggested: { default: string | null; cheap: string | null };
  check: { state: string; reason: string | null } | null;
}

const SETUP_STEPS = ["where", "provider", "key", "models", "workspace", "finish"] as const;

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
  /** The two layers of `mcp.json` and `skills/`, as the seven `mcp.*`/`skills.*` methods keep them. */
  servers: FakeServer[] = [];
  skills: FakeSkill[] = [];
  /** What lies at a path a test names, for `mcp.add` and `skills.add` with `from`. */
  importable: Record<string, Importable> = {};
  /** The record of a finished first run, as `setup.get` reports it; null until `finish`. */
  setupCompleted: { completed_at: string; choice: string; subject: string | null } | null;
  /** The first run in progress. */
  setup: FakeSetupFlow = freshSetup();
  /** Directories the workspace step accepts; anything else "is not a directory". */
  directories: string[] = ["/home/ada/project", "/home/ada/notes", "/home/ada/repo"];

  private server: Server | null = null;
  private wss: WebSocketServer | null = null;
  private readonly clients = new Set<Client>();
  private readonly capabilities: Record<string, unknown>;
  private readonly osUser: string;
  private readonly modelSettings: boolean;
  private readonly overrides: NonNullable<FakeDaemonOptions["overrides"]>;
  private readonly env: Record<string, string>;
  private readonly opencode: { providers: string[]; default: string | null };
  private nextId = 1;

  constructor(opts: FakeDaemonOptions = {}) {
    this.token = opts.token ?? "daemon-token";
    this.capabilities = opts.capabilities ?? { blobs: true, tools: true };
    this.osUser = opts.osUser ?? "ada";
    this.modelSettings = opts.modelSettings ?? true;
    this.overrides = opts.overrides ?? [];
    this.env = opts.env ?? {};
    this.opencode = opts.opencode ?? { providers: [], default: null };
    this.setupCompleted = opts.firstRun ? null : { completed_at: "2026-09-01T08:00:00Z", choice: "local", subject: null };
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

      case "session.loop.start": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        if (!session.goal) return reply(ws, id, null, { code: -32006, message: "conflict", data: { needs: "goal", reason: "the session has no goal to loop towards" } });
        const max = Number(params["max_iterations"] ?? 10);
        session.log.append("loop_started", { loop_id: "loop-1", max_iterations: max, max_failures: 3, goal: session.goal, command_id: params["command_id"] }, { kind: "user", subject: this.principal.subject });
        return reply(ws, id, { accepted: true, loop_id: "loop-1", max_iterations: max });
      }

      case "session.loop.stop":
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        return reply(ws, id, { accepted: true });

      case "session.loop.get":
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        return reply(ws, id, { loop: null });

      case "presence.set":
        return reply(ws, id, { ok: true });

      case "commands.list":
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "session", id: sessionId } });
        return reply(ws, id, { commands: COMMANDS });

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

  /**
   * The first run's questions (troupe Decision 705), with the daemon's semantics: a step
   * is the current one or one already answered (which forgets what came after), a key
   * is checked before anything is written — right when it looks like one, refused
   * otherwise — the settings are written at the models step, `auto_approve` at the
   * workspace step, and `finish` records the run and starts the session.
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
        break;
      }
      case "workspace": {
        const workspace = String(answer["workspace"] ?? "").trim();
        if (!workspace) return invalid("workspace must be a directory");
        if (!this.directories.includes(workspace)) return invalid(`${workspace} is not a directory`);
        const approvals = answer["approvals"] ?? "ask";
        if (approvals !== "ask" && approvals !== "auto") return invalid(`approvals must be ask or auto, not ${JSON.stringify(approvals)}`);
        advance({ workspace, approvals }, "finish");
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
          ? ["where", "provider", "workspace", "finish"]
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
      session: null,
    };
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
    const liveOf = (s: FakeServer) => (s.disabled ? { state: "disabled", tools: [], error: null } : { state: "ready", tools: ["greet"], error: null });
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
        return reply(ws, id, { server: { ...base, state: "ready", tools: ["greet"], error: null } });
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
      pending_questions: s.pendingQuestions,
      config: { watch: s.watch },
    };
  }
}
