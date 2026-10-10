// The daemon on this computer: one socket, however many sessions.
//
// A worker pod is one session per socket, because the plane mints a token whose audience
// is that pod and that session. A daemon is the opposite: it is *this* person's machine,
// one token admits everything on it, and every session it holds is reachable over the
// connection that is already open. So this is a multiplexer — one `TroupeConnection`, a
// `SessionView` per open session, and an envelope handed to whichever view owns it.
//
// Nothing else about the protocol changes. `subscribe` replays the same way, a command
// is acknowledged rather than performed the same way, and the fold that turns events
// into a transcript is the same function. A second implementation of any of that for
// the local case is how the local case and the remote case start disagreeing.

import { TroupeConnection, TroupeRpcError } from "./connection.js";
import { SessionView } from "./session.js";
import type { ConnectOptions, ConnectionHooks } from "./connection.js";
import type { ConfigScope, ConfigSetParams, ModelConfig, ModelDiscovery, ModelsParams } from "./config.js";
import { syncState } from "./fleet.js";
import type { FleetRow, FleetSource } from "./fleet.js";
import type { MemoryBrief } from "./memory.js";
import type { OnboardApplied, OnboardPlan } from "./onboard.js";
import type { SetupAnswer, SetupFlow, SetupStepName } from "./setup.js";
import type { ConfigChanged, EventEnvelope, Principal, SessionCreateResult, ToolInvoke, TroupeEvent } from "./types.js";

/** What `daemon.json` says about the WebSocket the daemon serves for graphical clients. */
export interface DaemonEndpoint {
  transport: "ws";
  port: number;
  token: string;
}

/** Who this daemon says its user is. `linked` false means the operating system's. */
export interface DaemonIdentity {
  linked: boolean;
  subject?: string;
  display_name?: string | null;
  plane_url?: string | null;
  linked_at?: string | null;
}

/** One session as the daemon's own `session.list` reports it. */
export interface DaemonSessionRow {
  id: string;
  workspace: string;
  branch: string | null;
  profile: string | null;
  state: string;
  status: string | null;
  tokens?: number;
  cost?: number;
  created_at: string | null;
  last_active_at: string | null;
  pinned?: boolean;
  /** `local` or `private`; absent from a daemon before 0.8.4, which listed every session as local. */
  kind?: string;
  /** How a private session's sealing stands here (`SyncState`); null for a local one. */
  sync?: string | null;
  /** The other device that holds a private session, where `sync` is `elsewhere`. */
  device?: string | null;
  owner?: string;
  pending_approvals?: number;
  pending_questions?: number;
  /** What happened while nobody was reading it (`Unseen`); absent from a daemon before #119. */
  unseen?: FleetRow["unseen"];
  /** How the root's last turn failed (`agent_failed`, Decision 727); absent from a daemon before 0.7.1. */
  failed?: { reason: string; detail?: string | null } | null;
  [k: string]: unknown;
}

/** What `session.claim` answers: the plane's row as it now stands, and how sealing stands here. */
export interface ClaimResult {
  session_id: string;
  device: string;
  epoch: number;
  sync: string;
}

export interface Worktree {
  path: string;
  branch: string | null;
  session_id: string | null;
  dirty: boolean;
}

export interface RecentWorkspace {
  path: string;
  last_used_at: string | null;
  sessions: number;
}

/**
 * Which file a server or a skill came from (troupe-remote Decision 700). `session` is one a
 * session still runs that no file names. A skill may also come from an `.agents/skills`
 * (troupe Decision 822): `user_agents` is `~/.agents/skills`, `agents` the repository's;
 * both are read where they are and never written.
 */
export type SourceLayer = "config" | "user" | "workspace" | "session" | "agents" | "user_agents";
/** Which layer a write goes to: the user's files, or a workspace's `.troupe/`. */
export type SourceScope = "user" | "workspace";

/** One MCP server as `mcp.list` reports it. `env` is the names of its variables; the values never leave the daemon. */
export interface LocalServer {
  name: string;
  layer: SourceLayer;
  source: string | null;
  transport?: "stdio" | "http";
  command?: string | null;
  args?: string[];
  url?: string | null;
  cd?: string | null;
  env?: string[];
  permission?: "ask" | "auto";
  disabled?: boolean;
  /** Why the daemon will not start it: an unset `{env:VAR}`, or no transport. */
  refused?: string | null;
  /** For a workspace-level server: whether somebody has approved it there. */
  trust?: "trusted" | "pending" | null;
  /** A server that wants you signed in (troupe-remote Decision 741): what its entry says about the sign-in. */
  oauth?: { client_id: string; scopes?: string[] | null; issuer?: string } | null;
  /** How your sign-in to it stands, never a token; null for a server that takes none. */
  auth?: ServerAuth | null;
  /** From the session named in the call, or from a check; null when nothing has run it. `sign_in` waits for yours. */
  state: string | null;
  tools: string[];
  error: string | null;
}

/**
 * Your sign-in to a server that wants you (troupe-remote Decision 741). `signing_in`
 * while a browser is out, `expired` when it ran out or was refused and you sign in
 * again; `account` is whose it is, when the provider said; `error` why the last
 * attempt failed.
 */
export interface ServerAuth {
  state: "signed_out" | "signing_in" | "signed_in" | "expired";
  account: string | null;
  error: string | null;
}

/** What `mcp.sign_in` answers: the URL to open, where the browser comes back to, and when the daemon stops waiting. */
export interface SignInStarted {
  server: string;
  url: string;
  redirect_uri: string;
  expires_at: string;
}

/** One of your server's tools as `mcp.tools` lists it: what a session is given to call it by. */
export interface ServerTool {
  name: string;
  description: string;
  schema: Record<string, unknown>;
}

/**
 * What `mcp.tools` answers (troupe Decision 748): the server asked for its tools with your
 * sign-in, outside any session. `state` is `ready`, `sign_in` while it waits for yours, or
 * `error`, as a check says it.
 */
export interface ServerTools {
  server: string;
  state: string;
  error: string | null;
  tools: ServerTool[];
}

/** What `mcp.call` answers: the tool's answer as a session's model reads it, never a token. */
export interface ServerToolResult {
  server: string;
  tool: string;
  content: string;
}

/** One skill as `skills.list` reports it. */
export interface LocalSkill {
  name: string;
  description: string;
  layer: SourceLayer;
  source: string;
  dir: string;
  linked: boolean;
}

/**
 * A skill the layers hold and do not offer, as `skills.list`'s `skipped` says it (troupe
 * Decision 822): `skipped` when a nearer layer has its name, or its folder's name is not
 * one a skill may have; `outside` when it is outside its edge and was not read. `reason`
 * says which, in words. An `.agents/skills` linked out whole is one entry with no name.
 */
export interface SkippedSkill {
  name: string | null;
  layer: SourceLayer;
  source: string;
  dir: string;
  linked: boolean;
  status: "skipped" | "outside";
  reason: string;
}

/** What `mcp.add` and `skills.add` answer for a file or a directory brought in. */
export interface ImportResult {
  path: string;
  from: string;
  added: string[];
  skipped: Array<{ name: string; reason: string }>;
  warnings?: string[];
  linked: boolean;
}

export interface RemoveResult {
  path: string;
  removed: string[];
}

export interface ScopedParams {
  scope?: SourceScope;
  workspace?: string;
}

export interface CreateLocalParams {
  workspace: string;
  profile?: string;
  prompt?: string;
  /** `auto` branches when the workspace already has a live session. */
  worktree?: "auto" | "never" | "always";
  /** Only what a client may choose: `auto_approve`, `watch`, `profile`, `full_send`. */
  config?: Record<string, unknown>;
  /**
   * A private session: sealed under the person's own key to the plane the daemon is linked
   * at, with the plane token the signed-in client hands it (`linkIdentity`). A daemon that
   * cannot seal yet makes the session anyway, and says `syncing: false`.
   */
  private?: boolean;
  /** The session this one is a branch of, as the librarian is of the session that started it. */
  parent?: string;
}

export interface DaemonHooks {
  onClose?: (reason: string) => void;
  /**
   * A socket is open: the first, or one dialled again after the last one dropped, at the
   * endpoint it reached. Whatever said "not answering" when the socket closed hears here
   * that the daemon answers again.
   */
  onOpen?: (endpoint: DaemonEndpoint) => void;
  /**
   * Where the daemon says it is now, read before dialling again after a socket dropped or
   * a dial failed. A daemon that restarts publishes a new port and a new token — the
   * kernel picks the one and the other is random — so the pair this client was made with
   * names nothing once it has. Null, or a read that fails, keeps the pair it has. A desktop
   * shell reads `daemon.json`; a browser was told by hand, has nothing to read, and dials
   * where it was told.
   */
  locate?: () => Promise<DaemonEndpoint | null>;
  /** A tool the client is hosting. Registered per session through `tools.register`. */
  onToolInvoke?: (invoke: ToolInvoke) => Promise<unknown>;
}

/** Somebody watching one session's events alongside its view's owner. */
type Listener = (e: TroupeEvent) => void;

/** `ws://127.0.0.1:<port>/v1/socket` — loopback, never a name that could resolve away. */
export function daemonUrl(endpoint: Pick<DaemonEndpoint, "port">): string {
  return `ws://127.0.0.1:${endpoint.port}/v1/socket`;
}

/**
 * One connection to the local daemon, with the sessions open on it.
 *
 * Views are registered rather than owning their own socket, and an envelope is offered
 * to each until one claims it. That is the same routing `SessionView.handle` does on a
 * worker socket; there is simply more than one candidate here.
 */
export class DaemonClient {
  private at: DaemonEndpoint;
  // Whether the next dial follows a socket that dropped or a dial that failed, and so
  // reads where the daemon is before it goes.
  private lost = false;
  private conn: TroupeConnection | null = null;
  private readonly views = new Map<string, SessionView>();
  // Sessions whose `open` is between dialling and subscribing. A second `open` for the
  // same session during that window joins the first rather than making a second view:
  // two views for one session would each claim the envelope first, and the one that
  // lost would never see an event — which is a transcript that silently stops.
  private readonly openingViews = new Map<string, Promise<SessionView>>();
  // How many callers hold each open session. A screen and a file pane, or one screen
  // mounted twice by a framework that does that, share one view — and the view goes
  // when the last of them lets go, not when the first does. Without this the first
  // `close` unsubscribed a view somebody else was still reading, and what they read
  // from then on was nothing.
  private readonly holders = new Map<string, number>();
  // The listeners handed to `open`, per session, each with how to stop it: null while its
  // view is still being made, and the listener waits to be attached before `subscribe`.
  private readonly listening = new Map<string, Map<Listener, (() => void) | null>>();
  // Who hears `config.changed`, across every socket this client dials.
  private readonly configListeners = new Set<(c: ConfigChanged) => void>();
  private readonly hooks: DaemonHooks;
  private opening: Promise<TroupeConnection> | null = null;

  constructor(endpoint: DaemonEndpoint, hooks: DaemonHooks = {}) {
    this.at = endpoint;
    this.hooks = hooks;
  }

  /** Where the daemon is: where this client was told, or where `locate` last found it. */
  get endpoint(): DaemonEndpoint {
    return this.at;
  }

  get connected(): boolean {
    return this.conn !== null;
  }

  /**
   * What this daemon says it can do, from its own `initialize`.
   *
   * Asked rather than assumed, because a client and a daemon are updated separately and
   * a control for something the daemon has never heard of is worse than no control: it
   * looks like a setting that did not take. `private_sessions` is the one that matters
   * here — sealing a session under the person's own key is server work, and until a
   * daemon reports it the GUI does not offer it.
   */
  get capabilities(): Record<string, unknown> {
    return (this.conn?.hello.capabilities ?? {}) as Record<string, unknown>;
  }

  get supportsPrivateSessions(): boolean {
    return Boolean(this.capabilities["private_sessions"]);
  }

  /**
   * Who the daemon admitted this connection as, from its own `initialize`: the operating
   * system's user as `local:<name>`, or the linked account's subject. Null until the
   * socket is open.
   *
   * It is what "you" means on this computer. A person with no plane has no other name,
   * and a transcript that cannot tell their own words from somebody else's is the first
   * thing that looks wrong.
   */
  get principal(): Principal | null {
    return this.conn?.hello.principal ?? null;
  }

  /** The open socket, dialling it if this is the first caller. Concurrent calls share one dial. */
  async connection(opts: Partial<ConnectOptions> = {}): Promise<TroupeConnection> {
    if (this.conn) return this.conn;
    if (this.opening) return this.opening;

    const hooks: ConnectionHooks = {
      onEvent: (envelope) => this.route(envelope),
      // `resync_required` names the topic, not the session — a subscription is the
      // thing that lost its place. `session:<id>` is how a session's topic is spelled.
      onResyncRequired: (r) => {
        const view = this.views.get(r.topic.replace(/^session:/, ""));
        void view?.resubscribe().catch(() => undefined);
      },
      onClose: (reason) => {
        this.conn = null;
        this.lost = true;
        for (const view of this.views.values()) view.unbind();
        this.hooks.onClose?.(reason);
      },
      onConfigChanged: (changed) => {
        for (const listener of this.configListeners) listener(changed);
      },
      ...(this.hooks.onToolInvoke ? { onToolInvoke: this.hooks.onToolInvoke } : {}),
    };

    this.opening = this.dial(hooks, opts)
      .then((conn) => {
        this.conn = conn;
        this.lost = false;
        // A view here was open when the last socket dropped, and its subscription went with
        // that socket. It carries on from its cursor, so the daemon replays what it missed
        // with no gap and no duplicate; one that fails waits for the next socket, and one
        // closed meanwhile is let go again.
        for (const view of this.views.values()) {
          view.bind(conn);
          void view
            .resubscribe()
            .then(() => (this.views.get(view.sessionId) === view ? undefined : view.unsubscribe()))
            .catch(() => undefined);
        }
        this.hooks.onOpen?.(this.at);
        return conn;
      })
      .finally(() => {
        this.opening = null;
      });

    return this.opening;
  }

  /**
   * Dial the daemon: where it was, or, after a socket that dropped or a dial that failed,
   * where it says it is now. A dial that fails leaves the next one to read again.
   */
  private async dial(hooks: ConnectionHooks, opts: Partial<ConnectOptions>): Promise<TroupeConnection> {
    if (this.lost && this.hooks.locate) {
      const found = await this.hooks.locate().catch(() => null);
      if (found) this.at = found;
    }
    try {
      return await TroupeConnection.open(
        {
          url: daemonUrl(this.at),
          token: this.at.token,
          clientInfo: { name: "troupe-gui", version: "1" },
          // Tools only when something is actually hosting them: a client that says it can
          // serve `tool.invoke` and then answers `method_not_found` is worse than one that
          // never offered.
          capabilities: { blobs: true, ...(this.hooks.onToolInvoke ? { tools: true } : {}) },
          ...opts,
        },
        hooks,
      );
    } catch (e) {
      this.lost = true;
      throw e;
    }
  }

  private route(envelope: EventEnvelope): void {
    for (const view of this.views.values()) if (view.handle(envelope)) return;
  }

  /**
   * Open a session on this daemon, subscribing from the beginning.
   *
   * The view is registered before `subscribe` is sent, so an event that arrives while
   * the subscription is being acknowledged is folded rather than dropped. A second
   * caller joins the same view — its `hooks` are not installed, since the view already
   * has an owner — and each caller owes one `close`.
   *
   * `listener` watches alongside whoever owns the view, and is attached before anything
   * is sent: the replay can arrive in the same read as `subscribe`'s answer, before this
   * resolves, and a caller that listened only once it had the view would miss the whole
   * history. It is given back to `close`. A caller that joins a view already open hears
   * from then on.
   *
   * An open that fails, refused or cut off, fails for everybody who joined it, and leaves
   * nothing behind: no view for the next `open` to find unsubscribed, and no holder who
   * owes a `close`.
   */
  async open(sessionId: string, hooks: ConstructorParameters<typeof SessionView>[2] = {}, listener?: Listener): Promise<SessionView> {
    this.holders.set(sessionId, (this.holders.get(sessionId) ?? 0) + 1);
    const existing = this.views.get(sessionId);
    if (listener) this.listenersOf(sessionId).set(listener, existing ? existing.listen(listener) : null);
    // Joined while it is still subscribing, rather than handed a view that may never be.
    const pending = this.openingViews.get(sessionId);
    try {
      return await (pending ?? existing ?? this.subscribeView(sessionId, hooks));
    } catch (e) {
      await this.close(sessionId, listener);
      throw e;
    }
  }

  private subscribeView(sessionId: string, hooks: ConstructorParameters<typeof SessionView>[2]): Promise<SessionView> {
    const opening = (async () => {
      const conn = await this.connection();
      const view = new SessionView(conn, sessionId, hooks);
      // Everybody who asked while the socket was being dialled, before the first event.
      const listeners = this.listenersOf(sessionId);
      for (const [l, stop] of listeners) if (!stop) listeners.set(l, view.listen(l));
      this.views.set(sessionId, view);
      try {
        await view.subscribe(0);
      } catch (e) {
        if (this.views.get(sessionId) === view) this.views.delete(sessionId);
        throw e;
      }
      return view;
    })().finally(() => this.openingViews.delete(sessionId));

    this.openingViews.set(sessionId, opening);
    return opening;
  }

  private listenersOf(sessionId: string): Map<Listener, (() => void) | null> {
    const found = this.listening.get(sessionId);
    if (found) return found;
    const made = new Map<Listener, (() => void) | null>();
    this.listening.set(sessionId, made);
    return made;
  }

  /**
   * Let go of a session, and stop `listener` if `open` was given one. The view is
   * unsubscribed when the last holder does; the socket stays, because other sessions
   * are on it.
   */
  async close(sessionId: string, listener?: Listener): Promise<void> {
    if (listener) {
      this.listening.get(sessionId)?.get(listener)?.();
      this.listening.get(sessionId)?.delete(listener);
    }
    const left = (this.holders.get(sessionId) ?? 1) - 1;
    if (left > 0) {
      this.holders.set(sessionId, left);
      return;
    }
    this.holders.delete(sessionId);
    this.listening.delete(sessionId);
    const view = this.views.get(sessionId);
    if (!view) return;
    this.views.delete(sessionId);
    if (this.conn) await view.unsubscribe().catch(() => undefined);
  }

  /** How many callers currently hold a session open. For tests. */
  holdersOf(sessionId: string): number {
    return this.holders.get(sessionId) ?? 0;
  }

  /** Let the socket go. Called when the daemon is forgotten, not when a session closes. */
  disconnect(): void {
    this.views.clear();
    this.holders.clear();
    this.listening.clear();
    this.conn?.close();
    this.conn = null;
  }

  private async call<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const conn = await this.connection();
    return conn.call<T>(method, params);
  }

  private async command<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const conn = await this.connection();
    return conn.call<T>(method, { command_id: conn.nextCommandId(), ...params });
  }

  identity(): Promise<DaemonIdentity> {
    return this.call<DaemonIdentity>("identity.get");
  }

  /**
   * Tell the daemon who is using it.
   *
   * Not authentication — the socket's token already admitted the caller. It is a label,
   * so that what happens here is recorded under a name that means something off this
   * machine, which is what a private session synced to a plane needs.
   *
   * `plane_token` is the one part that is not a label: the daemon signs nobody in, and
   * registers and seals a private session with the token it is handed here. It holds it
   * in memory and in no answer, so a client signed in hands it over again when its token
   * is renewed and when the daemon has restarted (issue #365).
   */
  linkIdentity(identity: { subject: string; display_name?: string; plane_url?: string; plane_token?: string }): Promise<DaemonIdentity> {
    return this.command<DaemonIdentity>("identity.link", { ...identity });
  }

  unlinkIdentity(): Promise<DaemonIdentity> {
    return this.command<DaemonIdentity>("identity.unlink");
  }

  /**
   * Take back the plane token handed over with `linkIdentity`, when the person signs out
   * here. The daemon lets go of it where it is that person's at that plane, and seals
   * nothing until a client links it with a token again; the label stays (issue #381).
   */
  signOutIdentity(params: { plane_url: string; subject?: string }): Promise<{ signed_out: boolean }> {
    return this.command("identity.sign_out", { ...params });
  }

  listSessions(filter: Record<string, unknown> = {}): Promise<{ sessions: DaemonSessionRow[] }> {
    return this.call("session.list", { filter });
  }

  createSession(params: CreateLocalParams): Promise<SessionCreateResult> {
    return this.command<SessionCreateResult>("session.create", { ...params });
  }

  archiveSession(sessionId: string): Promise<unknown> {
    return this.command("session.archive", { session_id: sessionId });
  }

  eraseSession(sessionId: string): Promise<unknown> {
    return this.command("session.erase", { session_id: sessionId });
  }

  /**
   * Take a private session another device sealed last over on this computer (troupe
   * Decision 785): the daemon claims it at the plane and seals it from here. Refused with
   * `conflict` where the other device sealed events this computer's copy does not hold.
   */
  claimSession(sessionId: string): Promise<ClaimResult> {
    return this.command<ClaimResult>("session.claim", { session_id: sessionId });
  }

  recentWorkspaces(): Promise<{ workspaces: RecentWorkspace[] }> {
    return this.call("workspace.recent");
  }

  searchWorkspaces(query: string, limit = 20): Promise<{ workspaces: Array<{ path: string; score: number }> }> {
    return this.call("workspace.search", { query, limit });
  }

  worktrees(workspace?: string): Promise<{ worktrees: Worktree[] }> {
    return this.call("worktree.list", workspace ? { workspace } : {});
  }

  removeWorktree(path: string, force = false): Promise<unknown> {
    return this.command("worktree.remove", { path, force });
  }

  /** Watch mode is exclusive per workspace; a second session on it answers `conflict`. */
  setWatch(workspace: string, enabled: boolean): Promise<{ enabled: boolean; backend?: string }> {
    return this.command("watch.set", { workspace, enabled });
  }

  /**
   * The model settings in effect, and the file they come from.
   *
   * `workspace` asks as a session in that directory would see them, which is what
   * surfaces a project's own settings file as an override.
   */
  modelConfig(workspace?: string): Promise<ModelConfig> {
    return this.call<ModelConfig>("config.get", workspace ? { workspace } : {});
  }

  /**
   * Ask a provider which models it offers, with settings that need not be saved yet.
   *
   * A query rather than a command — nothing changes — but it is `admin` all the same,
   * because it spends the key it is handed on a request to somebody else's server.
   */
  discoverModels(params: ModelsParams = {}): Promise<ModelDiscovery> {
    return this.call<ModelDiscovery>("config.models", { ...params });
  }

  /** Write the model settings. The next session reads them; nothing has to restart. */
  setModelConfig(params: ConfigSetParams): Promise<ModelConfig> {
    return this.command<ModelConfig>("config.set", { ...params });
  }

  /**
   * Write one setting into the file of `scope` (troupe #57) — the user's own unless told
   * otherwise — and answer what `config.get` now says, with `written`. `null` takes the
   * key out of that file. The daemon refuses a key that scope may not set. Ask only a
   * daemon that `servesKeys`: an older one would read this as the model panel's save.
   */
  setSetting(key: string, value: unknown, scope: ConfigScope = "user", workspace?: string): Promise<ModelConfig> {
    return this.command<ModelConfig>("config.set", { key, value, scope, ...(workspace ? { workspace } : {}) });
  }

  /**
   * Hear `config.changed`: a settings file the daemon writes changed, from this client or
   * another (troupe #57), so a screen shows what the terminal set. Returns the function
   * that stops listening. Heard while a socket is open, which every call opens.
   */
  onConfigChanged(listener: (changed: ConfigChanged) => void): () => void {
    this.configListeners.add(listener);
    return () => void this.configListeners.delete(listener);
  }

  /**
   * The first run's questions, as far as they have been answered (troupe Decision 705).
   *
   * The daemon holds the flow, so a screen that closes and reopens finds the answers
   * still there, and the key typed at one step is written at a later one without ever
   * coming back here.
   */
  setup(): Promise<SetupFlow> {
    return this.call<SetupFlow>("setup.get");
  }

  /** Answer one step; the answer is the flow one step on. `admin`: it may send a key to a provider and write the settings. */
  answerSetup(step: SetupStepName, answer: SetupAnswer): Promise<SetupFlow> {
    return this.command<SetupFlow>("setup.answer", { step, answer });
  }

  /**
   * Offer a tool that runs on this computer to one session.
   *
   * Answered with a consent challenge the first time: the daemon will not let a client
   * put a tool in front of an agent until a person has confirmed the exact words it
   * sends back. Registering is `control`, because it is steering the session.
   */
  registerTools(sessionId: string, tools: unknown[], consent?: string): Promise<unknown> {
    return this.command("tools.register", { session_id: sessionId, tools, ...(consent ? { consent } : {}) });
  }

  unregisterTools(sessionId: string, names: string[]): Promise<unknown> {
    return this.command("tools.unregister", { session_id: sessionId, names });
  }

  /**
   * Your own MCP servers, from the daemon's layers (troupe-remote Decision 700).
   *
   * With a `workspace`, its `.troupe/mcp.json` is read over your own file; with a
   * `session_id`, each server carries the state it has in that session.
   */
  listServers(opts: { workspace?: string; session_id?: string } = {}): Promise<{ servers: LocalServer[]; warnings: string[] }> {
    return this.call("mcp.list", { ...opts });
  }

  /** Bring another tool's `.mcp.json` in: copied into the layer's file, or read in place with `link`. */
  importServers(params: ScopedParams & { from: string; link?: boolean }): Promise<ImportResult> {
    return this.command<ImportResult>("mcp.add", { ...params });
  }

  /** Write one server, merged onto what the layer has under that name: `{ disabled: true }` alone turns one off. */
  writeServer(params: ScopedParams & { name: string; server: Record<string, unknown> }): Promise<{ name: string; path: string; entry: Record<string, unknown>; warnings: string[] }> {
    return this.command("mcp.add", { ...params });
  }

  /** Take a server out of its file, or unlink a linked file with `include`. */
  removeServer(params: ScopedParams & ({ name: string } | { include: string })): Promise<RemoveResult> {
    return this.command<RemoveResult>("mcp.remove", { ...params });
  }

  /**
   * Try a server. In a session it is read again from its files and started, which is
   * also how one that died is brought back; otherwise it is run once and stopped.
   * `admin`, as it runs a command on this computer.
   */
  checkServer(params: { session_id?: string; workspace?: string; name: string; server?: Record<string, unknown> }): Promise<{ server: LocalServer }> {
    return this.call("mcp.check", { ...params });
  }

  /**
   * Sign in to a server that wants you (troupe-remote Decision 741). The daemon runs the
   * sign-in and listens for the browser on its own machine; open `url` there, and read
   * how it stands from `listServers`' `auth`. A session waiting for it carries on once
   * it lands.
   */
  signInServer(params: { name: string; workspace?: string; session_id?: string }): Promise<SignInStarted> {
    return this.command<SignInStarted>("mcp.sign_in", { ...params });
  }

  /** Forget your sign-in to a server on this computer. */
  signOutServer(params: { name: string; workspace?: string; session_id?: string }): Promise<{ server: string; auth: ServerAuth | null }> {
    return this.command("mcp.sign_out", { ...params });
  }

  /**
   * A server's tools, asked with your sign-in outside any session (troupe Decision 748):
   * what a session on a pod is offered of it. `admin`, since the asking goes out as you.
   */
  serverTools(params: { name: string; workspace?: string }): Promise<ServerTools> {
    return this.call<ServerTools>("mcp.tools", { ...params });
  }

  /**
   * Call one of a server's tools with your sign-in, outside any session: how a pod's
   * `tool.invoke` for a server you offered it is served. The daemon makes the call and the
   * token stays there. `command_id` names the call, so one the pod sends again after a
   * drop is answered from the first rather than made twice.
   */
  callServerTool(params: { name: string; tool: string; arguments: Record<string, unknown>; command_id: string }): Promise<ServerToolResult> {
    return this.command<ServerToolResult>("mcp.call", { ...params });
  }

  /** Every skill the layers offer, and beside them the ones they hold and do not offer, with why (`skipped`; a daemon before 0.9.3 says none). */
  listSkills(workspace?: string): Promise<{ skills: LocalSkill[]; skipped?: SkippedSkill[] }> {
    return this.call("skills.list", workspace ? { workspace } : {});
  }

  /** Bring a directory of skills in, such as `~/.claude/skills`: copied, or read in place with `link`. */
  importSkills(params: ScopedParams & { from: string; link?: boolean }): Promise<ImportResult> {
    return this.command<ImportResult>("skills.add", { ...params });
  }

  removeSkill(params: ScopedParams & ({ name: string } | { include: string })): Promise<RemoveResult> {
    return this.command<RemoveResult>("skills.remove", { ...params });
  }

  /**
   * What onboarding would write in a workspace, and whether its brief is due (troupe
   * Decision 835): each file with its diff, the other tools' files passed over, and the
   * daemon's sentence where onboarding may not run. Reads; writes nothing.
   */
  onboardPlan(workspace: string): Promise<OnboardPlan> {
    return this.call<OnboardPlan>("onboard.plan", { workspace });
  }

  /**
   * Write the files named, or with `all` every one that is only a write: an `AGENTS.md`
   * that is not there is written only when named (Decision 827). The daemon records the
   * version once the plan is answered.
   */
  onboardApply(workspace: string, which: "all" | string[]): Promise<OnboardApplied> {
    return this.command<OnboardApplied>("onboard.apply", { workspace, ...(which === "all" ? { all: true } : { ids: which }) });
  }

  /** Say no to the files named, or to all of them: remembered for this version of the rules. */
  onboardDecline(workspace: string, which: "all" | string[]): Promise<{ declined: number }> {
    return this.command("onboard.decline", { workspace, ...(which === "all" ? { all: true } : { ids: which }) });
  }

  /** Say no to rewriting a brief an older survey wrote: remembered for this survey's version. */
  declineBrief(workspace: string): Promise<unknown> {
    return this.command("memory.decline", { workspace });
  }

  /**
   * A repository's brief (troupe #248): its status, whether a librarian is due, and its
   * facts with their status, which a daemon from before facts leaves out for the text.
   */
  memory(workspace: string): Promise<MemoryBrief> {
    return this.call<MemoryBrief>("memory.get", { workspace });
  }

  /** Forget one fact of a repository's memory, by its id; `memory.md` is written again without it. */
  forgetFact(workspace: string, id: string): Promise<unknown> {
    return this.command("memory.forget", { workspace, id });
  }

  /** Forget the whole brief, every fact with it, and the record of a librarian's try at it. */
  forgetBrief(workspace: string): Promise<unknown> {
    return this.command("memory.forget", { workspace });
  }

  /**
   * Start the librarian on a workspace's brief, as a branch of the session that asked, in
   * the checkout itself (it writes one file, the brief), as the terminal client starts it.
   */
  startLibrarian(params: { workspace: string; parent: string; prompt: string }): Promise<SessionCreateResult> {
    return this.createSession({ workspace: params.workspace, profile: "librarian", worktree: "never", parent: params.parent, prompt: params.prompt });
  }
}

/**
 * The daemon as a row source for the one list.
 *
 * `kind` comes from the daemon's own row where it says one and is `local` otherwise: a
 * session created before the daemon knew about kinds is a local session, because there
 * was nothing else it could have been. A private one carries its `sync`, and the device
 * that holds it where that is another one.
 */
export class DaemonSource implements FleetSource {
  readonly id: string;
  readonly kind = "local" as const;

  constructor(
    private readonly daemon: DaemonClient,
    id = "daemon",
  ) {
    this.id = id;
  }

  async list(): Promise<FleetRow[]> {
    const { sessions } = await this.daemon.listSessions();
    return sessions.map((s) => rowFromDaemon(s, this.id));
  }
}

/**
 * Why `session.claim` was refused, in words a person can act on; the terminal client says
 * the same. Anything else is said as the error says it.
 */
export function claimRefusal(e: unknown): string {
  if (e instanceof TroupeRpcError) {
    const reason = e.data?.["reason"];
    if (reason === "diverged") return "Another device sealed events this computer's copy does not have, so it stays with that device";
    if (e.code === -32007) return "Another device claimed it first";
    if (reason === "erased") return "It has been erased";
    if (reason === "not_registered") return "It is not registered yet; it is once this computer is signed in";
    if (reason === "unlinked") return "Sign in on this computer to claim it";
  }
  return e instanceof Error ? e.message : String(e);
}

export function rowFromDaemon(row: DaemonSessionRow, source = "daemon"): FleetRow {
  const kind = row.kind === "private" ? "private" : "local";
  return {
    id: row.id,
    kind,
    source,
    // A local session's name is where it is: nobody titles the work they are doing in
    // their own checkout, and the path is what they would have called it anyway.
    title: (row["title"] as string | undefined) ?? row.workspace ?? null,
    profile: row.profile ?? null,
    owner: row.owner ?? null,
    state: row.state ?? "dormant",
    status: row.status ?? null,
    doneReason: (row["done_reason"] as string | undefined) ?? null,
    pendingApprovals: row.pending_approvals ?? 0,
    pendingQuestions: row.pending_questions ?? 0,
    // The daemon reports whole currency units where the plane reports micros.
    costMicros: typeof row.cost === "number" ? Math.round(row.cost * 1_000_000) : null,
    lastActiveAt: row.last_active_at ?? null,
    pinned: Boolean(row.pinned),
    // Everything on this machine is the user's own; there is no ACL to be a viewer on.
    yourRole: "owner",
    origin: null,
    reviewedBy: null,
    sync: kind === "private" ? syncState(row.sync) : null,
    device: kind === "private" ? (row.device ?? null) : null,
    unseen: row.unseen ?? null,
    failed: row.failed ? { reason: row.failed.reason, detail: row.failed.detail ?? null } : null,
    raw: row,
  };
}
