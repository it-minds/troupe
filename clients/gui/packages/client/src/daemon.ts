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

import { TroupeConnection } from "./connection.js";
import { SessionView } from "./session.js";
import type { ConnectOptions, ConnectionHooks } from "./connection.js";
import type { FleetRow, FleetSource } from "./fleet.js";
import type { EventEnvelope, SessionCreateResult, ToolInvoke } from "./types.js";

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
  kind?: string;
  owner?: string;
  pending_approvals?: number;
  [k: string]: unknown;
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

export interface CreateLocalParams {
  workspace: string;
  profile?: string;
  prompt?: string;
  /** `auto` branches when the workspace already has a live session. */
  worktree?: "auto" | "never" | "always";
  /** Only what a client may choose: `auto_approve`, `watch`, `profile`, `private`. */
  config?: Record<string, unknown>;
}

export interface DaemonHooks {
  onClose?: (reason: string) => void;
  /** A tool the client is hosting. Registered per session through `tools.register`. */
  onToolInvoke?: (invoke: ToolInvoke) => Promise<unknown>;
}

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
  readonly endpoint: DaemonEndpoint;
  private conn: TroupeConnection | null = null;
  private readonly views = new Map<string, SessionView>();
  // Sessions whose `open` is between dialling and subscribing. A second `open` for the
  // same session during that window joins the first rather than making a second view:
  // two views for one session would each claim the envelope first, and the one that
  // lost would never see an event — which is a transcript that silently stops.
  private readonly openingViews = new Map<string, Promise<SessionView>>();
  private readonly hooks: DaemonHooks;
  private opening: Promise<TroupeConnection> | null = null;

  constructor(endpoint: DaemonEndpoint, hooks: DaemonHooks = {}) {
    this.endpoint = endpoint;
    this.hooks = hooks;
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
        for (const view of this.views.values()) view.unbind();
        this.hooks.onClose?.(reason);
      },
      ...(this.hooks.onToolInvoke ? { onToolInvoke: this.hooks.onToolInvoke } : {}),
    };

    this.opening = TroupeConnection.open(
      {
        url: daemonUrl(this.endpoint),
        token: this.endpoint.token,
        clientInfo: { name: "troupe-gui", version: "1" },
        // Tools only when something is actually hosting them: a client that says it can
        // serve `tool.invoke` and then answers `method_not_found` is worse than one that
        // never offered.
        capabilities: { blobs: true, ...(this.hooks.onToolInvoke ? { tools: true } : {}) },
        ...opts,
      },
      hooks,
    )
      .then((conn) => {
        this.conn = conn;
        for (const view of this.views.values()) view.bind(conn);
        return conn;
      })
      .finally(() => {
        this.opening = null;
      });

    return this.opening;
  }

  private route(envelope: EventEnvelope): void {
    for (const view of this.views.values()) if (view.handle(envelope)) return;
  }

  /**
   * Open a session on this daemon, subscribing from the beginning.
   *
   * The view is registered before `subscribe` is sent, so an event that arrives while
   * the subscription is being acknowledged is folded rather than dropped.
   */
  async open(sessionId: string, hooks: ConstructorParameters<typeof SessionView>[2] = {}): Promise<SessionView> {
    const existing = this.views.get(sessionId);
    if (existing) return existing;
    const pending = this.openingViews.get(sessionId);
    if (pending) return pending;

    const opening = (async () => {
      const conn = await this.connection();
      const view = new SessionView(conn, sessionId, hooks);
      this.views.set(sessionId, view);
      await view.subscribe(0);
      return view;
    })().finally(() => this.openingViews.delete(sessionId));

    this.openingViews.set(sessionId, opening);
    return opening;
  }

  /** Stop following a session. The socket stays: other sessions are on it. */
  async close(sessionId: string): Promise<void> {
    const view = this.views.get(sessionId);
    if (!view) return;
    this.views.delete(sessionId);
    if (this.conn) await view.unsubscribe().catch(() => undefined);
  }

  /** Let the socket go. Called when the daemon is forgotten, not when a session closes. */
  disconnect(): void {
    this.views.clear();
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
   */
  linkIdentity(identity: { subject: string; display_name?: string; plane_url?: string }): Promise<DaemonIdentity> {
    return this.command<DaemonIdentity>("identity.link", { ...identity });
  }

  unlinkIdentity(): Promise<DaemonIdentity> {
    return this.command<DaemonIdentity>("identity.unlink");
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
}

/**
 * The daemon as a row source for the one list.
 *
 * `kind` comes from the daemon's own row where it says one and is `local` otherwise: a
 * session created before the daemon knew about kinds is a local session, because there
 * was nothing else it could have been.
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
    // The daemon reports whole currency units where the plane reports micros.
    costMicros: typeof row.cost === "number" ? Math.round(row.cost * 1_000_000) : null,
    lastActiveAt: row.last_active_at ?? null,
    pinned: Boolean(row.pinned),
    // Everything on this machine is the user's own; there is no ACL to be a viewer on.
    yourRole: "owner",
    origin: null,
    reviewedBy: null,
    sync: kind === "private" ? ((row["sync"] as FleetRow["sync"]) ?? "this-device-only") : null,
    raw: row,
  };
}
