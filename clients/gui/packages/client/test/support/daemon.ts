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
//   it onboards other tools'     a start says `onboarding_suggested`, and `onboard.plan`,
//   files, then the brief        `onboard.apply`, `onboard.decline` and `memory.decline`
//                                answer what is due and take the person's answers
//   it keeps each repository's   `memory.get` answers the brief, whether a librarian is
//   brief, as facts              due, and its facts with their status; `memory.forget`
//                                forgets one fact by id, or the whole brief
//   it keeps the agents          `agents.*` read, check, write and take away the person's
//                                and a workspace's agent files, `agents.changed` tells every
//                                client, and `profile.switch` changes a session's agent
//
// It implements the protocol rather than imitating a screen, for the same reason the
// fake worker does: a test that passes against a fake that agrees with the client by
// construction has proved nothing.

import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
import { FakeAgents, agentHash, checkAgent } from "./agents.js";
import { COMMANDS, DEFINED, expandDefined } from "./commands.js";
import { SessionLog, type LoggedEvent } from "./log.js";
import { PROVIDER_TYPES, SETUP_KINDS } from "./provider-types.js";
import { FakeScratch } from "./scratch.js";

interface Session {
  id: string;
  log: SessionLog;
  /** What the session's `show` calls wrote (issue #472): `scratch.show(log, …)` makes one. */
  scratch: FakeScratch;
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
  /** `private` for one sealed under the person's key (troupe Decision 785); local otherwise. */
  kind?: "local" | "private";
  /** How a private session's sealing stands here, as `session.list` says it. */
  sync?: "current" | "behind" | "paused" | "elsewhere" | "erasure_pending";
  /** The other device that holds a private one, where `sync` is `elsewhere`. */
  device?: string | null;
  /** The session this one is a branch of. */
  parent?: string | null;
  /**
   * Offered to the plane for steering from another device (troupe #58), as
   * `remote.offer` left it and `session.list` says it.
   */
  remote?: { owner: string | null; shares: Array<{ subject: string; role: string }>; state: string; since: string | null; steering: unknown[] } | null;
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
  /**
   * False is a daemon from before troupe #658: `config.get` lists no `provider_types`,
   * `setup.get` no `kinds`, and only Anthropic, OpenAI and the fake are providers it takes.
   */
  servesProviderTypes?: boolean;
  /**
   * The machine's config says `auto_approve: true`, so every session it starts approves
   * every tool call itself, and a workspace's command asks before it is first sent
   * (troupe Decision 814).
   */
  autoApprove?: boolean;
  /**
   * False is a daemon from before the start's questions (troupe Decision 835): the
   * `onboard.*` methods and `memory.decline` answer `method_not_found`.
   */
  onboard?: boolean;
  /**
   * False is a daemon from before troupe Decision 841: `agents.get`, `agents.validate`,
   * `agents.put` and `agents.delete` answer `method_not_found`.
   */
  agentsApi?: boolean;
}

/** A workspace's command waiting on its question (troupe Decision 814). */
interface AskedCommand {
  sessionId: string;
  name: string;
  text: string;
  commandId: string;
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
  /** A scope a server asked for that the sign-in does not carry, until a sign-in lands. */
  step_up: string | null;
}

/** A skill in one of the daemon's layers; `user_agents` and `agents` are the `.agents/skills` read in place (troupe Decision 822). */
export interface FakeSkill {
  name: string;
  description: string;
  layer: "user_agents" | "agents" | "user" | "workspace";
  source: string;
  dir: string;
  linked: boolean;
}

/** A skill the layers hold and do not offer, as `skills.list`'s `skipped` says it. */
export interface FakeSkippedSkill {
  name: string | null;
  layer: FakeSkill["layer"];
  source: string;
  dir: string;
  linked: boolean;
  status: "skipped" | "outside";
  reason: string;
}

/** What the fake finds at a path a test names: the stand-in for the daemon reading a file or a directory. */
export interface Importable {
  servers?: Record<string, Record<string, unknown>>;
  skills?: Array<{ name: string; description: string }>;
}

/** One file onboarding would write, as `onboard.plan` lists it (troupe Decision 835). */
export interface FakeOnboardItem {
  id: string;
  target: "repo" | "workspace" | "user";
  path: string;
  shown: string;
  status: "new" | "changed";
  question: "write" | "create_agents_md";
  source: string;
  also_from: string[];
  was: string | null;
  notes: string[];
  diff: string;
}

/**
 * Where onboarding and the brief stand in one workspace, as the daemon keeps them: what
 * the plan would write, under which version of the rules the workspace was onboarded
 * (null: never), and the brief's survey. Each file answered — written or declined — leaves
 * the plan, and the version is recorded once none is left.
 */
export interface FakeOnboarding {
  version: number;
  recorded: number | null;
  tools: string[];
  items: FakeOnboardItem[];
  skipped?: Array<{ source: string; reason: string }>;
  brief?: { due: "first" | "stale" | "outdated" | "none"; recorded: number | null; version: number };
  /** The sentence onboarding answers with where it may not run, as on a machine a worker runs on. */
  refusal?: string;
}

/**
 * A repository with Claude Code's and Cursor's files and nothing onboarded: an `AGENTS.md`
 * to create from `CLAUDE.md` (its own question), one to add to in `web/`, and two rules.
 * The brief, when asked for, was written by an older survey.
 */
export function exampleOnboarding(opts: { briefOutdated?: boolean } = {}): FakeOnboarding {
  return {
    version: 2,
    recorded: null,
    tools: ["Claude Code", "Cursor"],
    items: [
      {
        id: "p1",
        target: "workspace",
        path: "AGENTS.md",
        shown: "AGENTS.md",
        status: "new",
        question: "create_agents_md",
        source: "CLAUDE.md",
        also_from: [".claude/CLAUDE.md"],
        was: null,
        notes: ["the first heading named CLAUDE.md and is written # AGENTS.md"],
        diff: "+ # AGENTS.md\n+ \n+ Run the tests with `make test` before you push.",
      },
      {
        id: "p2",
        target: "workspace",
        path: "web/AGENTS.md",
        shown: "web/AGENTS.md",
        status: "changed",
        question: "write",
        source: "web/CLAUDE.md",
        also_from: [],
        was: null,
        notes: [],
        diff: "  # web\n  \n+ Components live in src/components, one per file.",
      },
      {
        id: "p3",
        target: "repo",
        path: "rules/style.md",
        shown: ".troupe/rules/style.md",
        status: "new",
        question: "write",
        source: ".cursor/rules/style.mdc",
        also_from: [],
        was: null,
        notes: [],
        diff: '+ ---\n+ globs: ["src/**/*.ts"]\n+ ---\n+ Prefer named exports.',
      },
      {
        id: "p4",
        target: "repo",
        path: "rules/legacy.md",
        shown: ".troupe/rules/legacy.md",
        status: "new",
        question: "write",
        source: ".cursorrules",
        also_from: [],
        was: null,
        notes: ["the legacy file is always applied"],
        diff: "+ ---\n+ alwaysApply: true\n+ ---\n+ Write in British English.",
      },
    ],
    skipped: [{ source: "CLAUDE.local.md", reason: "Claude Code's personal file, usually not committed: move it into your own AGENTS.md by hand, or leave it" }],
    ...(opts.briefOutdated ? { brief: { due: "outdated" as const, recorded: 1, version: 2 } } : {}),
  };
}

/**
 * One fact of a repository's memory, as `memory.get` lists it (troupe #248): a claim with
 * the files it rests on and their hashes when it was written, how it was learned, and its
 * status, which the daemon works out when it is read.
 */
export interface FakeFact {
  id: string;
  kind: "command" | "convention" | "overview" | "layout" | "note" | "negative";
  claim: string;
  scope: string | null;
  anchors: Array<{ path: string; hash: string }>;
  evidence: { session: string | null; seq: number | null; head: string | null; exit_status?: number; by: string };
  created_at: string;
  verified_at: string;
  status: "current" | "moved" | "missing" | "unanchored";
}

/**
 * A repository's brief as the daemon keeps it. `facts` absent is a daemon from before
 * troupe #248, whose `memory.get` answers the brief's text and no facts. `refresh_due`
 * left out is worked out as the daemon does: absent or stale, and no try held off.
 */
export interface FakeMemory {
  status: "absent" | "stale" | "fresh";
  text?: string | null;
  built_at?: string | null;
  refresh_due?: boolean;
  /** Until when a librarian's try that built nothing holds the next one off. */
  refresh_held_until?: string | null;
  facts?: FakeFact[];
}

/**
 * A repository's memory with a fact of each status: the gate's command, current; a
 * convention whose file changed since; an overview whose file is gone; and a note that
 * rests on no file.
 */
export function exampleFacts(): FakeFact[] {
  const at = "2026-10-08T09:00:00Z";
  return [
    {
      id: "f-check",
      kind: "command",
      claim: "The gate is `mix check`: compile, credo, boundaries, tests",
      scope: null,
      anchors: [{ path: "mix.exs", hash: "3f9a6c0e2b7d41a58c9e0f1d2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d" }],
      evidence: { session: "s-41", seq: 412, head: "7f8a221", exit_status: 0, by: "librarian" },
      created_at: at,
      verified_at: at,
      status: "current",
    },
    {
      id: "f-style",
      kind: "convention",
      claim: "Components live in src/components, one per file",
      scope: "src/**",
      anchors: [{ path: "src/components/index.ts", hash: "aa01bb02cc03dd04ee05ff060718293a4b5c6d7e8f90a1b2c3d4e5f60718293a" }],
      evidence: { session: "s-41", seq: 433, head: "7f8a221", by: "agent:build" },
      created_at: at,
      verified_at: at,
      status: "moved",
    },
    {
      id: "f-layout",
      kind: "overview",
      claim: "The protocol's schema is generated from schema.ex",
      scope: null,
      anchors: [{ path: "protocol/schema.ex", hash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }],
      evidence: { session: "s-41", seq: 450, head: "7f8a221", by: "librarian" },
      created_at: at,
      verified_at: at,
      status: "missing",
    },
    {
      id: "f-note",
      kind: "note",
      claim: "Ask before touching the release workflow",
      scope: null,
      anchors: [],
      evidence: { session: null, seq: null, head: null, by: "person" },
      created_at: at,
      verified_at: at,
      status: "unanchored",
    },
  ];
}

/** The librarian as `session.create` was asked to start it: on which workspace, from which session, with what. */
export interface FakeLibrarian {
  sessionId: string;
  workspace: string;
  parent: string | null;
  prompt: string | null;
  worktree: string | null;
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
  // An Ollama server lists what is pulled there, asked with no key, and prices nothing.
  ollama: [
    { id: "llama3.2:latest", context: null, max_output: null, input: null, output: null },
    { id: "qwen3:8b", context: null, max_output: null, input: null, output: null },
  ],
  openrouter: [
    { id: "anthropic/claude-sonnet-4.5", context: 1_000_000, max_output: 64_000, input: 3.0, output: 15.0 },
    { id: "deepseek/deepseek-chat-v3.1", context: 163_840, max_output: null, input: 0.2, output: 0.8 },
  ],
  // Azure lists its deployments only to its management API: nothing, to a key.
  azure_openai: [],
  gemini: [
    { id: "gemini-2.5-flash", context: null, max_output: null, input: null, output: null },
    { id: "gemini-2.5-pro", context: null, max_output: null, input: null, output: null },
  ],
};

/**
 * The provider types a screen offers, and the ways `setup.get` says a provider may be set
 * up (every type, then the two gateways), as the daemon's `config.get` and `setup.get`
 * carry them (troupe #658): `./provider-types.ts`, which `mix troupe.config.schema` writes
 * from `Troupe.Protocol.ProviderTypes` and CI holds to it, rather than a copy kept here
 * that could drift from the daemon's.
 */
export { PROVIDER_TYPES, SETUP_KINDS };

function reply(ws: WebSocket, id: unknown, result: unknown, error?: unknown): void {
  ws.send(JSON.stringify(error ? { jsonrpc: "2.0", id, error } : { jsonrpc: "2.0", id, result }));
}

function notify(ws: WebSocket, method: string, params: unknown): void {
  ws.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
}

/** The question a workspace's command asks before it is first sent, in the daemon's words (troupe Decision 814). */
function commandQuestion(callId: string, name: string, text: string): Record<string, unknown> {
  const file = `.troupe/commands/${name}.md`;
  return {
    call_id: callId,
    agent_path: ["root"],
    question: `/${name} comes with this workspace, in ${file}, and auto_approve is on: nothing will ask before the tools its prompt leads to run. Send the prompt below?`,
    options: [
      { label: "deny", description: `send nothing; /${name} asks again the next time it runs` },
      { label: "once", description: "send it this time only" },
      { label: "allow", description: `send it, and don't ask again in this workspace until ${file} changes` },
    ],
    multiple: false,
    preview: text,
  };
}

export class FakeDaemon {
  /** The token it serves with now; a `restart` draws a new one, as a daemon does. */
  token: string;
  /** The command table `commands.list` answers; a test may add a row of its own. */
  commands: typeof COMMANDS = [...COMMANDS];
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
  /** The sessions `session.claim` took over, oldest first. */
  readonly claims: string[] = [];
  /** How many times `daemon.stop` was asked, for an update to replace the daemon. */
  stopsAsked = 0;
  /** Refuse every claim as the daemon does one whose plane copy went further than this one. */
  claimsDiverge = false;
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
  /** The `transcript` keys the file sets (troupe #474), by name; one not here is its default. */
  transcript: Record<string, unknown> = {};
  /** What a workspace's `.troupe/config.yaml` sets, by workspace and key: `config.get` with that workspace answers it over the user's. */
  projects: Record<string, Record<string, unknown>> = {};
  /** Every file's per-tool rules (troupe #658), as `config.get` answers them. */
  permissions: Array<Record<string, unknown>> = [];
  /** The two layers of `mcp.json` and `skills/`, as the seven `mcp.*`/`skills.*` methods keep them. */
  servers: FakeServer[] = [];
  /** Sign-ins by server name (troupe-remote Decision 741); a server with `oauth` and no entry is signed out. */
  signIns: Record<string, FakeAuth> = {};
  /** What the provider says to a sign-out, by server name: evoked where nothing is set and there was a sign-in. */
  revocations: Record<string, { state: "revoked" | "failed" | "unsupported" | "none"; reason: string | null }> = {};
  /** The access token each sign-in left in the state directory, which no answer carries. */
  readonly signInTokens: Record<string, string> = {};
  /** Every call `mcp.call` made to a server, as the server would have received it (troupe Decision 748). */
  readonly serverCalls: FakeServerCall[] = [];
  /** `mcp.call`'s answers by command id: one asked again is answered from the first. */
  private readonly answered = new Map<string, unknown>();
  skills: FakeSkill[] = [];
  /** The skills a nearer layer's name hid, or that are outside their edge. */
  skippedSkills: FakeSkippedSkill[] = [];
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
  /** How long a method takes to answer, by its name: a busy machine, for any other method. */
  delayMs: Record<string, number> = {};
  /**
   * A method the daemon does, once, whose answer never reaches the client: `hold` keeps the
   * socket open and says nothing, `drop` closes the socket in its place, as a daemon whose
   * connection went in the middle of the call. What it did stays done.
   */
  loseReply: Record<string, "hold" | "drop"> = {};
  /** Whether sessions approve every tool call themselves, as `auto_approve: true` in the machine's config does. */
  autoApprove: boolean;
  /**
   * The workspace's commands somebody answered `allow` for, as `<workspace> /<name>` beside
   * the prompt its file had then (troupe Decision 814): another prompt asks again.
   */
  readonly commandsAllowed = new Map<string, string>();
  /** Workspace commands waiting on their question, by the question's `call_id`. */
  private readonly askedCommands = new Map<string, AskedCommand>();
  /** Onboarding and the brief by workspace (troupe Decision 835); a workspace not here has nothing due. */
  onboarding: Record<string, FakeOnboarding> = {};
  /** Each file `onboard.apply` wrote or `onboard.decline` turned down, as `<workspace> <id>`. */
  readonly onboarded = new Map<string, "written" | "declined">();
  /** The version a workspace's whole plan was declined for (`onboard.decline` with `all`). */
  readonly onboardDeclined = new Map<string, number>();
  /** The survey version a workspace's outdated brief was declined for (`memory.decline`). */
  readonly briefDeclined = new Map<string, number>();
  /** Every librarian `session.create` started, oldest first. */
  readonly librarians: FakeLibrarian[] = [];
  /** Each repository's brief and facts (troupe #248); a workspace not here has a fresh brief with no facts yet. */
  memory: Record<string, FakeMemory> = {};
  /** The directories git knows, which `worktree.list` answers a main checkout for; any other is a plain directory. */
  readonly repositories = new Set<string>(["/home/ada/project", "/home/ada/repo"]);
  /** The config's `memory` and `memory_auto_refresh`, as `config.get` reports them; both default on. */
  memoryOn = true;
  memoryAutoRefresh = true;
  /** The agent files of every layer (troupe Decision 841): the built-ins, the person's and each workspace's. */
  readonly agents: FakeAgents;

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
  private readonly servesProviderTypes: boolean;
  private readonly servesOnboard: boolean;
  private readonly servesAgents: boolean;
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
    this.servesProviderTypes = opts.servesProviderTypes ?? true;
    this.servesOnboard = opts.onboard ?? true;
    this.servesAgents = opts.agentsApi ?? true;
    this.agents = new FakeAgents(`/home/${this.osUser}/.config/troupe`);
    this.autoApprove = opts.autoApprove ?? false;
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

  /**
   * What the daemon says when its poll finds the plane's version policy changed (#657):
   * `config.changed` with scope `versions` to every client attached.
   */
  announceVersions(planeUrl: string, keys: string[]): void {
    for (const c of this.clients) notify(c.ws, "config.changed", { scope: "versions", path: planeUrl, keys });
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
    // A close is a handshake. A client that never answers it (one unmounted mid-call), or
    // one that connected while this stops and so is in no list above, would hold both
    // closes below open for `ws`'s 30 s: give the handshake a moment, then end what is left.
    await new Promise<void>((resolve) => setTimeout(resolve, 100));
    for (const ws of this.wss?.clients ?? []) ws.terminate();
    await new Promise<void>((resolve) => this.wss?.close(() => resolve()));
    // And what is not a socket: a request a page cut off by its unmount, which a close waits for.
    const closed = new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
    this.server?.closeAllConnections();
    await closed;
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

  /** Close every client's socket and stay up where it was: the next call dials again, to the same daemon. */
  dropClients(): void {
    for (const c of this.clients) c.ws.terminate();
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
      scratch: new FakeScratch(),
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
      kind: session.kind ?? "local",
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

  /**
   * What a session's start writes when onboarding or the brief is due in its workspace
   * (troupe Decisions 827 and 835): one `onboarding_suggested`, with what is due, counts by
   * kind and the harness's sentence; nothing when nothing is. `session.create` calls it; a
   * test calls it for a session it seeded.
   */
  suggest(sessionId: string): LoggedEvent | null {
    const session = this.sessions.get(sessionId)!;
    const o = this.onboarding[session.workspace];
    if (!o) return null;
    const plan = this.planOf(session.workspace);
    const due = plan.onboarding.due;
    const briefDue = plan.brief.due;
    if (due === "none" && briefDue !== "outdated" && !o.refusal) return null;
    // The workspace's own files only, as the notice counts them: what a client would ask about.
    const own = plan.onboarding.items.filter((i) => i.target !== "user");
    const counts = {
      files: own.length,
      write: own.filter((i) => i.question === "write").length,
      create_agents_md: own.filter((i) => i.question === "create_agents_md").length,
    };
    const n = own.length;
    const sentences = [
      ...(due === "first"
        ? [`Other tools' files are here: \`troupe onboard\` would bring in ${n === 1 ? "1 file" : `${n} files`} as Troupe's own files. Run it in this workspace to see each as a diff and choose; nothing is written until you do.`]
        : []),
      ...(due === "outdated"
        ? [`This workspace was onboarded under version ${o.recorded} of the onboarding rules, and this build's are version ${o.version}: run \`troupe onboard\` to see what they would write now.`]
        : []),
      ...(briefDue === "outdated" && o.brief
        ? [`The project brief was written by version ${o.brief.recorded ?? 0} of the librarian's survey, and this build's is version ${o.brief.version}: \`/memory refresh\` has the librarian write it again.`]
        : []),
    ];
    return session.log.append("onboarding_suggested", {
      workspace: session.workspace,
      reasons: [...(due === "none" ? [] : [due]), ...(briefDue === "outdated" ? ["brief"] : [])],
      due,
      brief_due: briefDue,
      counts,
      message: sentences.join(" ") || "Other tools' files are here.",
      command: "troupe onboard",
      onboarding_version: o.version,
      ...(o.recorded !== null ? { onboarded_version: o.recorded } : {}),
      ...(o.brief ? { survey_version: o.brief.version, ...(o.brief.recorded !== null ? { brief_version: o.brief.recorded } : {}) } : {}),
    });
  }

  /** The files of a workspace's plan nobody has answered yet. */
  private openItems(workspace: string): FakeOnboardItem[] {
    return (this.onboarding[workspace]?.items ?? []).filter((i) => !this.onboarded.has(`${workspace} ${i.id}`));
  }

  /** What `onboard.plan` answers, as the daemon works it out from what was answered. */
  planOf(workspace: string): {
    onboarding: { due: "first" | "outdated" | "none"; recorded: number | null; version: number; tools: string[]; items: FakeOnboardItem[]; skipped: Array<{ source: string; reason: string }> };
    brief: { due: "first" | "stale" | "outdated" | "none"; recorded: number | null; version: number };
    refusal: string | null;
  } {
    const o = this.onboarding[workspace];
    if (!o) {
      return {
        onboarding: { due: "none", recorded: null, version: 2, tools: [], items: [], skipped: [] },
        brief: { due: "none", recorded: null, version: 1 },
        refusal: null,
      };
    }
    const b = o.brief ?? { due: "none" as const, recorded: null, version: 1 };
    const brief = { ...b, due: b.due === "outdated" && this.briefDeclined.get(workspace) === b.version ? ("none" as const) : b.due };
    if (o.refusal) {
      return { onboarding: { due: "none", recorded: o.recorded, version: o.version, tools: [], items: [], skipped: [] }, brief, refusal: o.refusal };
    }
    const open = this.openItems(workspace);
    const answered = (o.recorded !== null && o.recorded >= o.version) || this.onboardDeclined.get(workspace) === o.version || open.length === 0;
    const due = answered ? "none" : o.recorded === null ? "first" : "outdated";
    // Listed only while onboarding is due: with nothing due no source is asked.
    if (due === "none") return { onboarding: { due, recorded: o.recorded, version: o.version, tools: [], items: [], skipped: [] }, brief, refusal: null };
    return { onboarding: { due, recorded: o.recorded, version: o.version, tools: o.tools, items: open, skipped: o.skipped ?? [] }, brief, refusal: null };
  }

  /**
   * `onboard.plan`, `onboard.apply`, `onboard.decline` and `memory.decline`, with the
   * daemon's semantics (`Troupe.Onboard.Start`): `all` writes every open file that is only
   * a write and never a new `AGENTS.md` (Decision 827), which is written only when named; the
   * first write records the workspace as onboarded under this version, so the plan says
   * nothing is due from then on while the files it listed can still be answered by id; a no
   * is remembered for this version; `command_id` is optional.
   */
  private onboardCall(ws: WebSocket, id: unknown, method: string, params: Record<string, unknown>): void {
    const invalid = (reason: string) => reply(ws, id, null, { code: -32602, message: "invalid_params", data: { reason } });
    const workspace = String(params["workspace"] ?? "");
    if (!workspace) return invalid("workspace is required");
    if (method === "onboard.plan") return reply(ws, id, this.planOf(workspace));
    const o = this.onboarding[workspace];

    if (method === "memory.decline") {
      if (o?.brief) this.briefDeclined.set(workspace, o.brief.version);
      return reply(ws, id, { declined: true });
    }

    if (o?.refusal) return invalid(o.refusal);
    const open = this.openItems(workspace);
    const all = params["all"] === true;
    const ids = all
      ? (method === "onboard.apply" ? open.filter((i) => i.question === "write") : open).map((i) => i.id)
      : Array.isArray(params["ids"])
        ? params["ids"].map(String)
        : null;
    if (!ids) return invalid("name the items by id, or pass all: true");
    const stamp = (): void => {
      if (o && this.openItems(workspace).length === 0) o.recorded = o.version;
    };

    if (method === "onboard.apply") {
      const written: Array<{ id: string; shown: string; action: string }> = [];
      const refused: Array<{ id: string; reason: string }> = [];
      for (const itemId of ids) {
        const item = open.find((i) => i.id === itemId);
        if (!item) {
          refused.push({
            id: itemId,
            reason: "it is not proposed as it was shown any more: its source or the file changed, or it was written or left out since; ask for the plan again",
          });
          continue;
        }
        this.onboarded.set(`${workspace} ${itemId}`, "written");
        written.push({ id: itemId, shown: item.shown, action: item.status === "new" ? "created" : "replaced" });
      }
      // The manifest a write leaves says the workspace is onboarded, under this version.
      if (o && written.length > 0) o.recorded = o.version;
      stamp();
      return reply(ws, id, { written, refused });
    }

    // onboard.decline
    let declined = 0;
    for (const itemId of ids) {
      if (!open.some((i) => i.id === itemId)) continue;
      this.onboarded.set(`${workspace} ${itemId}`, "declined");
      declined += 1;
    }
    if (all && o) this.onboardDeclined.set(workspace, o.version);
    stamp();
    return reply(ws, id, { declined });
  }

  /**
   * `memory.get` and `memory.forget` (troupe #248), with the daemon's shapes: the brief's
   * status, path and text, whether a librarian started by itself is due and until when a
   * try that built nothing holds it off, and the facts with their status and `generated`,
   * which a daemon from before facts leaves out. `memory.forget` with an `id` forgets that
   * fact; without one, the whole brief.
   */
  private memoryCall(ws: WebSocket, id: unknown, method: string, params: Record<string, unknown>): void {
    const invalid = (reason: string) => reply(ws, id, null, { code: -32602, message: "invalid_params", data: { reason } });
    const workspace = String(params["workspace"] ?? "");
    if (!workspace) return invalid("workspace is required");
    const memory = this.memory[workspace];

    if (method === "memory.get") {
      const m = memory ?? { status: "fresh" as const, facts: [] };
      const status = this.memoryOn ? m.status : "disabled";
      const held = m.refresh_held_until ?? null;
      const facts = m.facts;
      return reply(ws, id, {
        status,
        path: `${workspace}/.troupe/memory.md`,
        built_at: m.built_at ?? null,
        sections: facts ? [...new Set(facts.map((f) => f.kind))] : [],
        text: m.text ?? (facts && facts.length > 0 ? `# Project brief\n\n${facts.map((f) => `- ${f.claim}`).join("\n")}` : null),
        refresh_due: m.refresh_due ?? ((status === "absent" || status === "stale") && held === null),
        refresh_held_until: held,
        ...(facts ? { facts, generated: true } : {}),
      });
    }

    // memory.forget
    if (!params["command_id"]) return invalid("command_id is required");
    const factId = params["id"];
    if (typeof factId === "string") {
      const at = memory?.facts?.findIndex((f) => f.id === factId) ?? -1;
      if (at < 0) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "fact", id: factId } });
      memory!.facts!.splice(at, 1);
      return reply(ws, id, { forgotten: true, id: factId });
    }
    this.memory[workspace] = { status: "absent", text: null, ...(memory?.facts ? { facts: [] } : {}) };
    return reply(ws, id, { forgotten: true });
  }

  /** A command's prompt, sent as the session's input under the `commands.run` that asked. */
  private sendCommand(session: Session, text: string, commandId: string): void {
    const actor = { kind: "user", subject: this.principal.subject };
    session.log.append("input_queued", { command_id: commandId, author: this.principal.subject, text }, actor);
    session.log.append("input_accepted", { command_id: commandId, author: this.principal.subject }, actor);
    session.log.append("user_input", { command_id: commandId, text, source: "user" }, actor);
  }

  /**
   * The answer to a workspace's command's question, read as the daemon reads it (troupe
   * Decision 814): `allow` sends it and remembers its prompt, `once` sends it, and anything
   * else sends nothing and says how to run it later.
   */
  private answerCommand(session: Session, asked: AskedCommand, text: string): void {
    const answer = text.trim().toLowerCase();
    const allow = ["allow", "always", "a"].includes(answer);
    if (allow || ["once", "o", "yes", "y", "send"].includes(answer)) {
      if (allow) this.commandsAllowed.set(`${session.workspace} /${asked.name}`, DEFINED[asked.name] ?? "");
      this.sendCommand(session, asked.text, asked.commandId);
      return;
    }
    const name = asked.name;
    session.log.append("command_declined", {
      name,
      command_id: asked.commandId,
      reason: `/${name} was not sent. Run /${name} again to be asked again; allow sends it from then on without asking, until .troupe/commands/${name}.md changes.`,
    });
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
    const sessionId = String(params["session_id"] ?? "");
    const session = this.sessions.get(sessionId);
    const delay = this.delayMs[method] ?? 0;
    if (delay > 0 && !params["__delayed"]) {
      setTimeout(() => this.handle(client, id, method, { ...params, __delayed: true }), delay);
      return;
    }
    const lose = this.loseReply[method];
    if (lose) delete this.loseReply[method];
    const ws = lose ? ({ send: () => lose === "drop" && client.ws.terminate() } as unknown as WebSocket) : client.ws;

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

      // The person accepting the plane's new key, by the fingerprint they were shown (#657).
      case "identity.accept_plane_key": {
        const offered = this.planeKey?.offered;
        if (!this.planeKey || !offered || offered.fingerprint !== params["fingerprint"]) {
          return reply(ws, id, null, { code: -32602, message: "invalid_params", data: { reason: `the plane offers no key ${String(params["fingerprint"])}: nothing is accepted` } });
        }
        this.planeKey = { plane_url: this.planeKey.plane_url, ...offered };
        return reply(ws, id, { plane_key: this.planeKey });
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
        // `private` beside `workspace`, as the daemon reads it; one inside `config` is a
        // setting no client may choose, and is not asked for.
        const asked = params["private"] === true;
        // A branch names a session the daemon has, or is refused, as the daemon refuses it.
        const parent = typeof params["parent"] === "string" ? params["parent"] : null;
        if (parent !== null && !this.sessions.has(parent)) {
          return reply(ws, id, null, { code: -32602, message: "invalid_params", data: { field: "parent", reason: "no such session" } });
        }
        const profile = typeof params["profile"] === "string" && params["profile"] ? params["profile"] : undefined;
        const created = this.seed(workspace, {
          watch: Boolean(config.watch),
          parent,
          ...(profile ? { profile } : {}),
          ...(asked ? { kind: "private" as const, sync: this.planeToken !== null ? ("current" as const) : ("paused" as const) } : {}),
        });
        if (asked) this.privateSessions.add(created.id);
        if (profile === "librarian") {
          const prompt = typeof params["prompt"] === "string" ? params["prompt"] : null;
          this.librarians.push({ sessionId: created.id, workspace, parent, prompt, worktree: typeof params["worktree"] === "string" ? params["worktree"] : null });
          // The fake librarian builds the brief at once, under this build's survey.
          const brief = this.onboarding[workspace]?.brief;
          if (brief) Object.assign(brief, { due: "none", recorded: brief.version });
          const memory = this.memory[workspace];
          if (memory && memory.status !== "fresh") Object.assign(memory, { status: "fresh", refresh_due: false, built_at: new Date().toISOString() });
        } else {
          // What a start finds due, said once in the new session's log (Decisions 827, 835).
          this.suggest(created.id);
        }
        return reply(ws, id, {
          session_id: created.id,
          workspace,
          worktree: null,
          branch: null,
          syncing: asked && this.planeToken !== null,
        });
      }

      // A session offered to the plane for steering from another device, and taken back
      // (troupe #58): a private one is refused, as the daemon refuses it.
      case "remote.offer": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "session", id: sessionId } });
        if (session.kind === "private") {
          return reply(ws, id, null, { code: -32004, message: "forbidden", data: { reason: "a private session is never offered to the plane" } });
        }
        const share = Array.isArray(params["share"]) ? (params["share"] as Array<{ person: string; role?: string }>) : [];
        session.remote = {
          owner: this.linked?.subject ?? null,
          shares: share.map((s) => ({ subject: s.person, display_name: s.person, email: s.person, role: s.role ?? "observe" })),
          state: "online",
          since: null,
          steering: [],
        };
        return reply(ws, id, { session_id: sessionId, remote: session.remote });
      }

      case "remote.withdraw": {
        if (session) session.remote = null;
        return reply(ws, id, { session_id: sessionId, remote: null });
      }

      // A private session another device holds, taken over here (troupe Decision 785).
      case "session.claim": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "session", id: sessionId } });
        if (session.kind !== "private") {
          return reply(ws, id, null, { code: -32602, message: "invalid_params", data: { session_id: sessionId, reason: "not a private session" } });
        }
        if (session.sync === "erasure_pending") {
          return reply(ws, id, null, { code: -32005, message: "not_found", data: { session_id: sessionId, reason: "erased" } });
        }
        // The other device sealed events this copy does not have.
        if (this.claimsDiverge) {
          return reply(ws, id, null, { code: -32006, message: "conflict", data: { session_id: sessionId, reason: "diverged" } });
        }
        this.claims.push(sessionId);
        session.sync = "current";
        session.device = null;
        return reply(ws, id, { session_id: sessionId, device: "this-laptop", epoch: 2, sync: "current" });
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
        const callId = String(params["call_id"] ?? "");
        const asked = this.askedCommands.get(callId);
        if (asked) {
          this.askedCommands.delete(callId);
          this.answerCommand(session, asked, String(params["text"] ?? ""));
        }
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

      // The scratchpad (issue #472), and `fs.read` on its documents' `scratch:/` paths. A
      // session's other files are not this fake's: nothing here reads them.
      case "scratch.list":
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        return reply(ws, id, session.scratch.list());

      case "fs.read": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found" });
        const doc = session.scratch.read(String(params["path"] ?? ""));
        return doc ? reply(ws, id, doc) : reply(ws, id, null, { code: -32005, message: "not_found" });
      }

      case "commands.list":
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "session", id: sessionId } });
        return reply(ws, id, { commands: this.commands });

      // A command a file defines, as the daemon runs it (Decision 763): its prompt, with
      // `arguments` for `$ARGUMENTS`, goes in as input under the call's `command_id`.
      case "commands.run": {
        if (!session) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "session", id: sessionId } });
        const name = String(params["name"] ?? "");
        const text = expandDefined(name, String(params["arguments"] ?? ""));
        if (text === null) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "command", name } });
        const commandId = String(params["command_id"] ?? "");
        // A workspace's command asks first while every tool call is approved unasked,
        // unless its prompt, as the file has it now, was allowed before (troupe Decision 814).
        const project = COMMANDS.find((c) => c.name === name)?.source === "project";
        if (this.autoApprove && project && this.commandsAllowed.get(`${session.workspace} /${name}`) !== DEFINED[name]) {
          const callId = `command-${this.nextId++}`;
          this.askedCommands.set(callId, { sessionId: session.id, name, text, commandId });
          session.log.append("question_asked", commandQuestion(callId, name, text));
          return reply(ws, id, { accepted: true, command_id: commandId, question: callId });
        }
        this.sendCommand(session, text, commandId);
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

      case "worktree.list": {
        const workspace = typeof params["workspace"] === "string" ? params["workspace"] : null;
        // `status: false` (troupe #650): each tree's path, branch and session alone.
        const status = params["status"] === false ? {} : { dirty: false, checked: true };
        const branches = [...this.sessions.values()]
          .filter((s) => s.branch && (workspace === null || s.workspace === workspace))
          .map((s) => ({ path: `${s.workspace}-troupe`, branch: s.branch, session_id: s.id, ...status }));
        if (workspace === null) return reply(ws, id, { worktrees: branches });
        // `git worktree list` in the directory: its main checkout first, and nothing at all
        // in a directory git does not know or in a folder its repository ignores.
        const main = { path: workspace, branch: "main", session_id: null, ...status };
        return reply(ws, id, { worktrees: this.repositories.has(workspace) ? [main, ...branches] : [] });
      }

      case "memory.get":
      case "memory.forget":
        return this.memoryCall(ws, id, method, params);

      case "watch.set": {
        const workspace = String(params["workspace"] ?? "");
        const enabled = params["enabled"] !== false;
        const already = [...this.sessions.values()].find((s) => s.watch && s.workspace === workspace);
        const mine = [...this.sessions.values()].find((s) => s.workspace === workspace);
        if (enabled && already && already !== mine) {
          return reply(ws, id, null, { code: -32006, message: "conflict", data: { reason: "watch is exclusive per workspace" } });
        }
        const changed = mine && mine.watch !== enabled;
        if (mine) mine.watch = enabled;
        reply(ws, id, { enabled, backend: "poll" });
        // The session whose watch went on or off says so, to every client attached (troupe
        // Decision 844): the terminal's `/watch` is heard by the desktop app's box.
        if (mine && changed) this.ephemeral(mine, "watch_changed", { enabled, backend: enabled ? "poll" : "off" });
        return;
      }

      case "watch.get": {
        const workspace = String(params["workspace"] ?? "");
        const watching = [...this.sessions.values()].find((s) => s.watch && s.workspace === workspace);
        return reply(ws, id, { enabled: Boolean(watching), backend: watching ? "poll" : "off", session_id: watching?.id ?? null });
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

      case "onboard.plan":
      case "onboard.apply":
      case "onboard.decline":
      case "memory.decline":
        if (!this.servesOnboard) return reply(ws, id, null, { code: -32601, message: "method_not_found", data: { method } });
        return this.onboardCall(ws, id, method, params);

      case "agents.list":
      case "agents.get":
      case "agents.validate":
      case "agents.put":
      case "agents.delete":
        if (method !== "agents.list" && !this.servesAgents) return reply(ws, id, null, { code: -32601, message: "method_not_found", data: { method } });
        return this.agentsCall(ws, id, method, params);

      case "profile.switch":
        return this.switchAgent(ws, id, params);

      // Stopping between turns, for an update to replace the daemon's release (Decision
      // 865): a session at work keeps it running and is named. The fake says it stops and
      // goes on answering; `stopsAsked` counts the asking.
      case "daemon.stop": {
        this.stopsAsked += 1;
        const atWork = [...this.sessions.values()].filter((s) => ["thinking", "acting", "compacting"].includes(s.status));
        if (atWork.length > 0) {
          return reply(ws, id, { stopping: false, reason: "at_work", at_work: atWork.map((s) => ({ id: s.id, workspace: s.workspace })) });
        }
        return reply(ws, id, { stopping: true });
      }

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

    if (method === "config.get") return reply(ws, id, this.configJson(typeof params["workspace"] === "string" ? params["workspace"] : undefined));

    if (method === "config.models") {
      const provider = String(params["provider"] ?? s.provider ?? "anthropic");
      const offers = this.offers(provider);
      if (!offers) return invalid(`unknown provider ${provider}`);
      // Asked with no key at all, as an Ollama server is.
      if (provider === "ollama") return reply(ws, id, { models: offers, failures: [] });
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
    if (!this.offers(provider)) return invalid(`provider must be one of ${this.providers().join(", ")}`);
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
        if (!this.offers(provider)) return invalid(`provider must be one of ${[...this.providers(), "fake"].join(", ")}, not ${JSON.stringify(provider)}`);
        const kind = String(answer["kind"] ?? provider);
        const baseUrl = ((answer["base_url"] as string | null) ?? "").trim() || null;
        if ((kind === "gateway" || kind === "litellm") && !baseUrl) return invalid(`a ${kind} needs its base URL, ending in /v1`);
        if (provider === "azure_openai" && !baseUrl) {
          return invalid("azure_openai needs the address of your resource, such as https://<resource>.openai.azure.com");
        }
        advance({ provider, kind, base_url: baseUrl, auth: (answer["auth"] as string) ?? "api_key" }, "key");
        // A provider that takes no key is asked for its models at once, and the key step is
        // not on its path.
        if (kind === "ollama") {
          flow.offered = OFFERS["ollama"]!;
          const ids = flow.offered.map((m) => String(m["id"]));
          flow.suggested = { default: ids[0] ?? null, cheap: ids[1] ?? ids[0] ?? null };
          flow.check = { state: "ok", reason: null };
          flow.answers["key"] = { source: "none" };
          flow.step = "models";
        }
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
        } else if (provider["provider"] === "azure_openai") {
          return invalid("azure_openai needs a key; paste one");
        } else if (provider["base_url"]) {
          key = null;
          source = { source: "none" };
        } else {
          const kindVar = SETUP_KINDS.find((k) => k["id"] === provider["kind"])?.["key_var"];
          return invalid(`${provider["provider"]} needs a key; paste one, or keep it in ${String(kindVar ?? "its variable")}`);
        }
        // The real daemon lists the provider's models with the key; here a key is right
        // when it looks like one, and a gateway given none cannot be asked.
        if (key && !key.startsWith("sk-") && provider["provider"] !== "azure_openai") {
          flow.check = { state: "refused", reason: "401 unauthorized: the key was refused" };
          break;
        }
        flow.key = typeof answer["env"] === "string" ? `{env:${answer["env"]}}` : key;
        flow.offered = key ? OFFERS[String(provider["provider"])]! : [];
        const ids = flow.offered.map((m) => String(m["id"]));
        flow.suggested = { default: ids[0] ?? null, cheap: ids[1] ?? ids[0] ?? null };
        flow.check =
          provider["provider"] === "azure_openai"
            ? { state: "unknown", reason: "Azure OpenAI does not list its deployments to a key, so the key was not tried; type a deployment's name" }
            : key
              ? { state: "ok", reason: null }
              : { state: "unknown", reason: "no key was given, so nothing was asked" };
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

  /** What a provider offers, or nothing for one this daemon does not take. */
  private offers(provider: string): Array<Record<string, unknown>> | undefined {
    return this.providers().includes(provider) ? OFFERS[provider] : undefined;
  }

  private providers(): string[] {
    return this.servesProviderTypes ? Object.keys(OFFERS) : ["anthropic", "openai"];
  }

  private setupJson(): Record<string, unknown> {
    const flow = this.setup;
    const path =
      flow.answers["where"]?.["choice"] === "plane"
        ? ["where", "finish"]
        : typeof flow.answers["provider"]?.["reuse"] === "string"
          ? ["where", "provider", "workspace", "daemon", "finish"]
          : flow.answers["provider"]?.["kind"] === "ollama"
            ? SETUP_STEPS.filter((s) => s !== "key")
            : [...SETUP_STEPS];
    const config = this.configJson();
    const vendorVars = this.servesProviderTypes
      ? PROVIDER_TYPES.map((t) => t["key_var"]).filter((v): v is string => typeof v === "string")
      : ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"];
    return {
      needed: this.setupCompleted === null && !this.settings.exists,
      completed: this.setupCompleted,
      step: flow.step,
      steps: path.map((name) => ({ name, done: name in flow.answers })),
      answers: flow.answers,
      ...(this.servesProviderTypes ? { kinds: SETUP_KINDS } : {}),
      detected: {
        env: Object.keys(this.env).filter((v) => vendorVars.includes(v)),
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
    this.signIns[name] = { state: "signed_in", account, error: null, step_up: null };
    this.signInTokens[name] = `at-${name}-${Math.random().toString(36).slice(2)}`;
  }

  /** A tool of the server asked for a scope the sign-in does not carry: `mcp.list` says so until a sign-in lands. */
  wantScope(name: string, scope: string): void {
    const now = this.signIns[name] ?? { state: "signed_out", account: null, error: null, step_up: null };
    this.signIns[name] = { ...now, step_up: scope };
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

    const visible = <T extends { layer: string }>(rows: T[]): T[] => rows.filter((r) => r.layer === "user" || r.layer === "user_agents" || Boolean(workspace));
    const authOf = (s: FakeServer): FakeAuth | null => (s.oauth ? (this.signIns[s.name] ?? { state: "signed_out", account: null, error: null, step_up: null }) : null);
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
          const held = this.signIns[name]?.state === "signed_in" || this.signIns[name]?.state === "expired";
          const revocation = held ? (this.revocations[name] ?? { state: "revoked", reason: null }) : { state: "none", reason: null };
          delete this.signIns[name];
          return reply(ws, id, { server: name, auth: authOf(known), revocation });
        }
        this.signIns[name] = { state: "signing_in", account: this.signIns[name]?.account ?? null, error: null, step_up: this.signIns[name]?.step_up ?? null };
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
        return reply(ws, id, { skills: visible(this.skills), skipped: visible(this.skippedSkills) });

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

  /** What a model is checked against: the models the provider serves, once a key lists them, and the roles. */
  private servedModels(): { served: string[] | null; roles: string[] } {
    const offers = this.settings.provider && this.settings.api_key ? OFFERS[this.settings.provider] : undefined;
    return { served: offers ? offers.map((o) => String(o["id"])) : null, roles: ["default", "cheap", "expensive"] };
  }

  /** Every client attached hears an agent file written or taken away, the one that did it too. */
  announceAgent(changed: { name: string; scope: string; path: string; action: string; workspace?: string }): void {
    for (const c of this.clients) notify(c.ws, "agents.changed", changed);
  }

  /** An ephemeral event on a session, to every subscription to it: written in no log. */
  ephemeral(session: Session, type: string, data: Record<string, unknown>, agent: string[] = ["root"]): void {
    const topic = `session:${session.id}`;
    for (const c of this.clients) {
      for (const sub of c.subs.values()) {
        if (sub.topic === topic) notify(c.ws, "event", { topic, subscription_id: sub.id, session_id: session.id, event: { ephemeral: true, type, agent, data } });
      }
    }
  }

  /**
   * The five `agents.*` methods (troupe Decision 841), with the daemon's semantics: a
   * listing of the primaries a workspace sees, one definition whole, a check that writes
   * nothing, and writes into the person's agents or a workspace's `.troupe/agents` that
   * write nothing while the check finds an error. A built-in is changed by a copy and
   * never deleted; every write is announced.
   */
  private agentsCall(ws: WebSocket, id: unknown, method: string, params: Record<string, unknown>): void {
    const invalid = (data: Record<string, unknown>) => reply(ws, id, null, { code: -32602, message: "invalid_params", data });
    const named = typeof params["session_id"] === "string" ? this.sessions.get(params["session_id"]) : undefined;
    if (typeof params["session_id"] === "string" && !named) {
      return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "session", session_id: params["session_id"] } });
    }
    const workspace = typeof params["workspace"] === "string" && params["workspace"] ? params["workspace"] : (named?.workspace ?? null);
    const models = this.servedModels();
    const ctx = { worktree: workspace !== null && [...this.sessions.values()].some((s) => s.workspace === workspace && s.state === "active"), ...models, workspace };
    const name = params["name"];

    // The primaries, and with `subagents` the subagents after them (troupe Decision 852).
    if (method === "agents.list") {
      if (!workspace) return invalid({ field: "workspace", missing: "workspace", reason: "required" });
      const agents = this.agents
        .resolve(workspace)
        .filter((d) => d.meta["mode"] === "primary" || (params["subagents"] === true && d.meta["mode"] === "subagent"))
        .sort((a, b) => Number(a.meta["mode"] !== "primary") - Number(b.meta["mode"] !== "primary") || a.name.localeCompare(b.name))
        .map((d) => this.agents.row(d, ctx));
      const listed = this.agents.skipped.filter((s) => !s.workspace || s.workspace === workspace).map(({ workspace: _w, ...s }) => s);
      const broken = this.agents.brokenFiles(workspace).map((b) => ({ name: b.name, path: b.path, reason: b.reason }));
      return reply(ws, id, { agents, skipped: [...listed, ...broken] });
    }

    // What answers, with the file of the name that does not parse beside it, or that file
    // alone when nothing answers (troupe Decision 852).
    if (method === "agents.get") {
      if (typeof name !== "string" || !name) return invalid({ field: "name", missing: "name", reason: "required" });
      const found = this.agents.find(name, workspace);
      const broken = this.agents.brokenFiles(workspace).find((b) => b.name === name);
      const brokenJson = broken ? { scope: broken.scope, layer: broken.scope, path: broken.path, text: broken.text, hash: agentHash(broken.text), reason: broken.reason } : null;
      if (!found && brokenJson) return reply(ws, id, { name, broken: brokenJson });
      if (!found) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "agent", name } });
      const family = named ? [named.parent ?? named.id] : [];
      const running = named
        ? [...this.sessions.values()]
            .filter((s) => (family.includes(s.id) || (s.parent && family.includes(s.parent))) && s.state === "active" && s.profile === name)
            .map((s) => ({ session_id: s.id, parent: s.parent ?? null }))
        : [];
      return reply(ws, id, { ...this.agents.whole(found, workspace, ctx, running), broken: brokenJson });
    }

    const source = params["source"];
    if (method === "agents.validate") {
      if (typeof source !== "string") return invalid({ field: "source", reason: "required" });
      return reply(ws, id, checkAgent(source, { ...(name !== undefined ? { name } : {}), ...models }));
    }

    // agents.put and agents.delete
    if (!params["command_id"]) return invalid({ reason: "command_id is required" });
    if (typeof name !== "string" || !name) return invalid({ field: "name", missing: "name", reason: "required" });
    const asked = params["scope"];
    const scope = asked === "user" ? "user" : asked === "project" || asked === "workspace" ? "project" : null;
    if (!scope) return invalid({ field: "scope", reason: `scope is user or project, not ${JSON.stringify(asked ?? null)}` });
    if (scope === "project" && !workspace) return invalid({ field: "workspace", reason: "a project agent is a workspace's: name the workspace, or a session in it" });
    if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(name)) {
      return invalid({ field: "name", reason: `${JSON.stringify(name)} is not a name an agent may have: lowercase letters, digits and dashes, starting with a letter or digit, at most 64` });
    }
    const announce = (path: string, action: string): void =>
      this.announceAgent({ name, scope, path, action, ...(scope === "project" ? { workspace: workspace! } : {}) });

    if (method === "agents.put") {
      if (typeof source !== "string") return invalid({ field: "source", reason: "required" });
      const checked = checkAgent(source, { name, ...models });
      if (!checked.ok) {
        const [first, ...rest] = checked.errors;
        return invalid({ reason: `${name} is not saved: ${first!.message}${rest.length ? `, and ${rest.length} more (in errors)` : ""}`, errors: checked.errors, warnings: checked.warnings });
      }
      const shadowed =
        scope === "user" && workspace && this.agents.files.some((f) => f.name === name && f.layer === "project" && f.workspace === workspace)
          ? [{ field: "name", message: `the repository's .troupe/agents/${name}.md has this name too, and is the one that runs in this workspace` }]
          : [];
      // A save over a file that changed since the client read it is refused (troupe Decision 852).
      const expected = params["if_hash"];
      if (typeof expected === "string" && expected !== "") {
        const there = this.agents.files.find((f) => f.name === name && f.layer === scope && (scope !== "project" || f.workspace === workspace));
        const now = there ? agentHash(there.text) : null;
        if (now !== expected) {
          const shown = this.agents.pathOf({ name, layer: scope, ...(scope === "project" ? { workspace: workspace! } : {}) });
          const reason = now
            ? `${shown} changed since it was opened, saved from somewhere else: nothing is written. Read it again to see the change; saving over it replaces that change`
            : `${shown} was taken away since it was opened: nothing is written. Read the agents again; saving it now makes it anew`;
          return reply(ws, id, null, { code: -32006, message: "conflict", data: { reason, hash: now } });
        }
      }
      const written = this.agents.put(name, scope, workspace, source);
      reply(ws, id, { name, scope, layer: scope, path: written.path, action: written.action, warnings: [...checked.warnings, ...shadowed] });
      return announce(written.path, written.action);
    }

    const removed = this.agents.delete(name, scope, workspace);
    if (removed === null) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "agent", name, scope } });
    if ("forbidden" in removed) return reply(ws, id, null, { code: -32004, message: "forbidden", data: { reason: removed.forbidden } });
    reply(ws, id, { name, scope, path: removed.path, deleted: true, layer: this.agents.find(name, workspace)?.layer ?? null });
    return announce(removed.path, "deleted");
  }

  /**
   * `profile.switch` as the daemon does it since troupe Decision 841: the agent read from
   * its file now, a name nothing defines refused, a subagent refused, and `profile_switched`
   * with where it came from and the tools it gained and lost, under the switcher.
   */
  private switchAgent(ws: WebSocket, id: unknown, params: Record<string, unknown>): void {
    const session = this.sessions.get(String(params["session_id"] ?? ""));
    if (!session) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "session" } });
    const to = String(params["profile"] ?? "");
    const next = this.agents.find(to, session.workspace);
    if (!next) return reply(ws, id, null, { code: -32005, message: "not_found", data: { kind: "agent", name: to } });
    if (next.meta["mode"] !== "primary") {
      return reply(ws, id, null, { code: -32602, message: "invalid_params", data: { field: "profile", reason: `${to} is a subagent: a session or a branch runs a primary agent` } });
    }
    const now = this.agents.find(session.profile, session.workspace);
    const before = now ? this.agents.toolsOf(now) : [];
    const after = this.agents.toolsOf(next);
    session.log.append(
      "profile_switched",
      {
        from: session.profile,
        to,
        layer: next.layer,
        tools_added: after.filter((t) => !before.includes(t)),
        tools_removed: before.filter((t) => !after.includes(t)),
        command_id: params["command_id"],
      },
      { kind: "user", subject: this.principal.subject },
    );
    session.profile = to;
    return reply(ws, id, { accepted: true, profile: to, layer: next.layer });
  }

  private configJson(workspace?: string): Record<string, unknown> {
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
      ...(this.servesProviderTypes ? { provider_types: PROVIDER_TYPES } : {}),
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
    // A workspace's own file, over the user's, for a question asked about that workspace.
    const project = workspace ? (this.projects[workspace] ?? {}) : {};
    const layered = (entry: ReturnType<typeof key>) =>
      entry.key in project ? { ...entry, value: project[entry.key], layer: "project", source: `${workspace}/.troupe/config.yaml` } : entry;
    return {
      ...answer,
      workspace: workspace ?? null,
      trusted: false,
      files: [{ scope: "user", path, exists: s.exists }],
      keys: [
        key("models.default", s.models.default, "claude-sonnet-5", "model"),
        key("models.cheap", s.models.cheap, null, "cheap model"),
        key("models.expensive", s.models.expensive, null, "expensive model"),
        key("ui.theme", this.ui["ui.theme"], UI_DEFAULTS["ui.theme"], "theme"),
        key("ui.mode", this.ui["ui.mode"], UI_DEFAULTS["ui.mode"], "light or dark"),
        key("ui.notifications", this.ui["ui.notifications"], UI_DEFAULTS["ui.notifications"], "notifications"),
        key("memory", this.memoryOn ? undefined : false, true, "project brief"),
        key("memory_auto_refresh", this.memoryAutoRefresh ? undefined : false, true, "refresh the brief"),
        key("transcript.detail", this.transcript["transcript.detail"], "quiet", "transcript detail"),
      ].map(layered),
      permissions: this.permissions,
      warnings: [],
      errors: [],
    };
  }

  /**
   * The key the linked plane signs with, as this machine pinned it, and the one it offers
   * instead where it changed (#657): what `identity.get` carries as `plane_key`. None, as a
   * daemon from before it or one linked to a plane that signs nothing.
   */
  planeKey: { plane_url: string; algorithm: string; public_key: string; fingerprint: string; offered?: { algorithm: string; public_key: string; fingerprint: string } } | null = null;

  private identityJson(): Record<string, unknown> {
    const key = this.planeKey ? { plane_key: this.planeKey } : {};
    if (!this.linked) return { linked: false, ...key };
    return {
      linked: true,
      subject: this.linked.subject,
      display_name: this.linked.display_name ?? null,
      plane_url: this.linked.plane_url ?? null,
      linked_at: new Date().toISOString(),
      ...key,
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
      kind: s.kind ?? "local",
      sync: s.kind === "private" ? (s.sync ?? "paused") : null,
      device: s.kind === "private" && s.sync === "elsewhere" ? (s.device ?? null) : null,
      ...(this.linked ? { owner: this.linked.subject } : {}),
      parent: s.parent ?? null,
      pending_approvals: s.pendingApprovals,
      pending_questions: s.pendingQuestions,
      unseen: this.unseenOf(s),
      failed: this.failedOf(s),
      config: { watch: s.watch },
      remote: s.remote ?? null,
    };
  }
}
