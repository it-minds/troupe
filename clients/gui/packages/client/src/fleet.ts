// One list, from however many sources there are.
//
// The merge is here, client-side. No server merges anything: the plane knows the
// sessions that run on workers, a daemon knows the ones that run on this machine, and
// a private session is a row in both. Putting the union in the client is what lets the
// three stay ignorant of each other — and it is the reason this store takes *sources*
// rather than a plane, so stage 2's daemon and stage 3's private sessions are a source
// added to a list rather than a branch cut through every view.
//
// The store holds no session state either. A row is what a source last said, and
// closing the window loses a cache and nothing else.

import { invitationsFrom } from "./invites.js";
import type { Invitation } from "./invites.js";
import type { PlaneClient, SessionRow, SessionsFilter } from "./plane.js";
import { watchRemote } from "./remote.js";
import type { Unseen } from "./types.js";

/**
 * Where a session runs, which is the one thing a person must be able to see at a glance.
 * `remote` is a session on somebody's laptop, theirs or another person's, offered to the
 * plane for steering from another device (troupe #58). `invited` is somebody else's private
 * session they invited this person into, read on this computer from the plane's sealed
 * copy (troupe #765).
 */
export type SessionKind = "team" | "local" | "private" | "remote" | "invited";

/**
 * Whether a session of this kind runs on this computer, reached through its daemon: a
 * local or a private one. A team session is on a pod and a remote one on somebody's
 * laptop, both reached through the plane.
 */
export function onThisComputer(kind: SessionKind | null | undefined): boolean {
  return kind === "local" || kind === "private";
}

/** A person a laptop's session is shared with, or steered by, through the plane. */
export interface RemotePerson {
  subject: string;
  display_name?: string | null;
  email?: string | null;
  role: string;
}

/**
 * A session offered to the plane for steering from another device: on this computer's
 * own row, what the daemon says of the offer; on a `remote` row, what the plane says of
 * the laptop. `state` is `online`, `connecting` or `offline`, and `since` when it went.
 */
export interface RemoteOffer {
  state: string;
  since: string | null;
  owner: string | null;
  ownerName?: string | null;
  shares: RemotePerson[];
  steering: RemotePerson[];
  /**
   * On this computer's own row, whether it comes back after a restart: `across_restarts`
   * where the daemon starts at login, `until_restart` where nothing starts it then; null
   * on a `remote` row, and from a daemon before it said.
   */
  lasts: "across_restarts" | "until_restart" | null;
  /** On this computer's own row: read back from the daemon's record as it started. */
  restored: boolean;
}

/** The daemon's or the plane's word on an offer, or null where it says none. */
export function remoteOffer(value: unknown): RemoteOffer | null {
  if (!value || typeof value !== "object") return null;
  const v = value as Record<string, unknown>;
  return {
    state: typeof v["state"] === "string" ? v["state"] : "offline",
    since: typeof v["since"] === "string" ? v["since"] : null,
    owner: typeof v["owner"] === "string" ? v["owner"] : null,
    ownerName: typeof v["owner_name"] === "string" ? v["owner_name"] : null,
    shares: Array.isArray(v["shares"]) ? (v["shares"] as RemotePerson[]) : [],
    steering: Array.isArray(v["steering"]) ? (v["steering"] as RemotePerson[]) : [],
    lasts: v["lasts"] === "across_restarts" || v["lasts"] === "until_restart" ? v["lasts"] : null,
    restored: v["restored"] === true,
  };
}

/**
 * What an offer of this computer's says of a restart, as the terminal's `/steer` says it:
 * that it came back after one, and that it lasts only until the next where nothing starts
 * the daemon at login. Empty for a `remote` row, which the plane says nothing of this for.
 */
export function offerRestartWords(offer: RemoteOffer): string[] {
  return [offer.restored ? "back after a restart" : null, offer.lasts === "until_restart" ? "until this machine restarts" : null].filter(
    (w): w is string => w !== null,
  );
}

/**
 * What the desktop app says once, as an offer is made, where nothing starts the daemon at
 * login: the terminal's `/steer on` says the same.
 */
export const RESTART_SENTENCE =
  "It stays offered until this machine restarts: troupe-daemon login on starts the daemon when you log in, and the offer comes back with it.";

/**
 * How a private session's sealing stands, as the daemon's `session.list` says it (troupe
 * Decision 785); only private sessions have one, and it is about the copy, not the
 * session. `current` is sealed through its last event, `behind` is sealing with events
 * still to seal, `paused` is not sealing until this computer is handed a sign-in again,
 * `elsewhere` is another device's until it is claimed here (`device` names it), and
 * `erasure_pending` is erased, with its key not destroyed yet.
 */
export type SyncState = "current" | "behind" | "paused" | "elsewhere" | "erasure_pending";

const SYNC_STATES: readonly SyncState[] = ["current", "behind", "paused", "elsewhere", "erasure_pending"];

/** A source's `sync`, or null for one this client does not know: it says nothing rather than something wrong. */
export function syncState(value: unknown): SyncState | null {
  return SYNC_STATES.includes(value as SyncState) ? (value as SyncState) : null;
}

/**
 * A sync state in words: the label a list shows and the sentence behind it. The desktop
 * app and the terminal client say the same.
 */
export function syncWords(state: SyncState, device?: string | null): { label: string; detail: string } {
  switch (state) {
    case "current":
      return { label: "Synced", detail: "Sealed under your key through its last event" };
    case "behind":
      return { label: "Syncing", detail: "Being sealed; its latest events are not sealed yet" };
    case "paused":
      return { label: "Not syncing", detail: "Nothing is sealed until this computer is signed in again" };
    case "elsewhere":
      return {
        label: device ? `On ${device}` : "On another device",
        detail: `${device ?? "Another device"} sealed it last; claim it to seal it from this computer`,
      };
    case "erasure_pending":
      return { label: "Waiting to be erased", detail: "Erased; its key is not destroyed yet" };
  }
}

/** Whether this computer can take the session over: a private one another device holds, which only this computer's daemon says. */
export function claimable(row: Pick<FleetRow, "kind" | "sync">): boolean {
  return row.kind === "private" && row.sync === "elsewhere";
}

export interface FleetRow {
  id: string;
  kind: SessionKind;
  /** Which source produced this row; the key for opening it again. */
  source: string;
  title: string | null;
  profile: string | null;
  owner: string | null;
  state: string;
  /** What the worker or daemon last reported, not what the log says. */
  status: string | null;
  doneReason: string | null;
  pendingApprovals: number;
  /** Questions still open: the agent's `ask_user`, or the budget's or the failure guard's. */
  pendingQuestions: number;
  costMicros: number | null;
  lastActiveAt: string | null;
  pinned: boolean;
  yourRole: string | null;
  origin: { kind?: string; trigger?: string; [k: string]: unknown } | null;
  reviewedBy: string | null;
  sync: SyncState | null;
  /** The other device that holds a private session, where `sync` is `elsewhere` and the daemon heard its name. */
  device?: string | null;
  /**
   * What happened while nobody was reading the session, where the source counts it — a
   * daemon since #119; a plane's rows and an older daemon's say nothing.
   */
  unseen?: Unseen | null;
  /**
   * How the root agent's last turn failed, where the source says: `agent_failed`, a root
   * that kept crashing, and the session stopped on it (Decision 727); or `tool_failures`,
   * a tool that kept failing until the harness stopped the turn. A daemon's rows say the
   * first, with what the agent raised; a plane's say either, by its reason alone, since a
   * plane holds no content (Decision 750). An older daemon or plane says nothing.
   */
  failed?: { reason: string; detail: string | null } | null;
  /**
   * Offered to the plane for steering from another device: this computer's own session
   * (what the daemon says of it) or a `remote` row (what the plane says of its laptop).
   */
  remote?: RemoteOffer | null;
  /** The invitation this person holds into it, where somebody invited them by name (troupe #765). */
  invitation?: Invitation | null;
  /** The source's own row, for anything a view needs that this shape does not carry. */
  raw: unknown;
}

/** Anything that can list sessions. A plane, a daemon, or a test's stub. */
export interface FleetSource {
  readonly id: string;
  readonly kind: SessionKind;
  list(): Promise<FleetRow[]>;
  /**
   * A source that is told what changes rather than asked: `push` is its whole list each
   * time it changes, `live` whether it is being told now. While it is, the store's poll
   * leaves it alone but for a safety net (`fleetTiming.safetyNetMs`). Returns the stop.
   */
  watch?(push: (rows: FleetRow[]) => void, live: (up: boolean) => void): () => void;
}

/**
 * How often a watched source is asked anyway while its watch is up: never what delivers a
 * change, only what would mend a list a missed message left wrong.
 */
export const fleetTiming = { safetyNetMs: 5 * 60_000 };

/**
 * A plane's row. A private session is one of the person's own the plane lists beside the
 * team's (`kind`); the plane cannot say how this computer's copy stands, only that one is
 * waiting to be erased (troupe Decision 756).
 */
export function rowFromPlane(row: SessionRow, source = "plane"): FleetRow {
  const kind = row.kind === "private" ? "private" : "team";
  return {
    id: row.id,
    kind,
    source,
    title: row.title ?? null,
    profile: row.profile ?? null,
    owner: row.owner ?? null,
    state: row.state ?? "dormant",
    status: row.status ?? null,
    doneReason: row.done_reason ?? null,
    pendingApprovals: row.pending_approvals ?? 0,
    pendingQuestions: row.pending_questions ?? 0,
    costMicros: row.cost_micros ?? null,
    lastActiveAt: row.last_active_at ?? null,
    pinned: Boolean(row.pinned),
    yourRole: row.your_role ?? null,
    origin: row.origin ?? null,
    reviewedBy: row.reviewed_by ?? null,
    sync: kind === "private" && row.state === "erasure_pending" ? "erasure_pending" : null,
    failed: row.failed_reason ? { reason: row.failed_reason, detail: null } : null,
    raw: row,
  };
}

/**
 * The plane as a source.
 *
 * `/rpc` is request and answer — the plane pushes nothing to a harness client, by
 * design, because the `fleet` topic belongs to the worker and the plane is not in the
 * data path. So the "summary subscription" over team sessions is a poll of
 * `sessions.list`, and a session that is *open* gets its live detail from the worker
 * socket the session view already holds, which is where liveness actually belongs.
 */
export class PlaneSource implements FleetSource {
  readonly id = "plane";
  readonly kind = "team" as const;

  constructor(
    private readonly plane: PlaneClient,
    private readonly token: () => Promise<string>,
    private readonly filter: SessionsFilter = {},
  ) {}

  async list(): Promise<FleetRow[]> {
    const token = await this.token();
    const { sessions } = await this.plane.listSessions(token, this.filter);
    return sessions.map((s) => rowFromPlane(s, this.id));
  }
}

/** A row of the plane's `remote.list`: a laptop's session offered for steering. */
export function rowFromRemote(row: Record<string, unknown>, source = "remote"): FleetRow {
  const state = typeof row["state"] === "string" ? row["state"] : "offline";
  return {
    id: String(row["id"]),
    kind: "remote",
    source,
    title: typeof row["workspace"] === "string" ? row["workspace"] : null,
    profile: null,
    owner: typeof row["owner"] === "string" ? row["owner"] : null,
    // Online is a laptop the plane can reach now; offline is said with since when.
    state: state === "online" ? "active" : "offline",
    status: null,
    doneReason: null,
    pendingApprovals: 0,
    pendingQuestions: 0,
    costMicros: null,
    lastActiveAt: typeof row["offered_at"] === "string" ? row["offered_at"] : null,
    pinned: false,
    yourRole: typeof row["your_role"] === "string" ? row["your_role"] : null,
    origin: null,
    reviewedBy: null,
    sync: null,
    remote: remoteOffer({
      state,
      since: row["offline_since"],
      owner: row["owner"],
      owner_name: row["owner_name"],
      shares: row["shares"] ?? [],
    }),
    raw: row,
  };
}

/**
 * The laptop sessions the plane relays, as a source: the person's own from their other
 * computers, and those people shared with them. Watched (`/v1/relay/watch`), so an offer
 * made on a laptop, its withdrawal and the laptop coming or going reach the list as they
 * happen; asked with `remote.list` only while the watch is down, and as a safety net.
 */
export class RemoteSource implements FleetSource {
  readonly id = "remote";
  readonly kind = "remote" as const;

  constructor(
    private readonly plane: PlaneClient,
    private readonly token: () => Promise<string>,
    private readonly clientInfo?: { name: string; version: string },
  ) {}

  watch(push: (rows: FleetRow[]) => void, live: (up: boolean) => void): () => void {
    // The invitations to the person ride the same watch (troupe #765): each list is the
    // offers and the invitations as they last stood.
    let offered: FleetRow[] = [];
    let invited: FleetRow[] = [];
    const w = watchRemote({
      planeUrl: this.plane.baseUrl,
      token: this.token,
      onSessions: (sessions) => {
        offered = sessions.map((s) => rowFromRemote(s, this.id));
        push([...offered, ...invited]);
      },
      onInvites: (invites) => {
        invited = invites.map((i) => rowFromInvite(i, this.id));
        push([...offered, ...invited]);
      },
      onLive: live,
      ...(this.clientInfo ? { clientInfo: this.clientInfo } : {}),
    });
    return () => w.close();
  }

  async list(): Promise<FleetRow[]> {
    const token = await this.token();
    const [offered, invited] = await Promise.all([
      this.plane
        .rpc<{ sessions: Record<string, unknown>[] }>(token, "remote.list", {})
        .then(({ sessions }) => (sessions ?? []).map((s) => rowFromRemote(s, this.id)))
        // A plane from before #58 relays nothing, which is no sessions rather than a fault.
        .catch(none),
      this.plane
        .rpc<{ invites: unknown }>(token, "invites.list", {})
        .then(({ invites }) => invitationsFrom(invites).map((i) => rowFromInvite(i, this.id)))
        // Nor does a plane from before #765 invite anybody.
        .catch(none),
    ]);
    return [...offered, ...invited];
  }
}

function none(e: unknown): FleetRow[] {
  if ((e as { code?: unknown }).code === -32601) return [];
  throw e;
}

/**
 * An invitation as a row: a pod session's, which the plane's own listing has too and this
 * only marks with who invited the person; or a private session's, `invited`, which only
 * this person's daemon can read, from the plane's sealed copy (troupe #765).
 */
export function rowFromInvite(i: Invitation, source = "remote"): FleetRow {
  return {
    id: i.session_id,
    kind: i.kind === "private" ? "invited" : "team",
    source,
    title: i.title ?? null,
    profile: i.profile ?? null,
    owner: i.owner,
    state: i.state ?? "dormant",
    status: null,
    doneReason: null,
    pendingApprovals: 0,
    pendingQuestions: 0,
    costMicros: null,
    lastActiveAt: i.invited_at,
    pinned: false,
    yourRole: i.kind === "private" ? i.role : i.role === "control" ? "collaborator" : "viewer",
    origin: null,
    reviewedBy: null,
    sync: null,
    invitation: i,
    raw: i,
  };
}

export interface FleetFilter {
  kind?: SessionKind | "all";
  state?: string;
  status?: string;
  profile?: string;
  /** Substring, matched against the title and the id. */
  query?: string;
  /** Only sessions with an approval waiting. */
  needsApproval?: boolean;
}

export interface FleetSnapshot {
  rows: FleetRow[];
  /** Per source: when it last answered, and what went wrong if it did not. */
  sources: Record<string, { at: number; error: string | null }>;
  loading: boolean;
}

const emptySnapshot: FleetSnapshot = { rows: [], sources: {}, loading: false };

/**
 * The union of every source, newest activity first.
 *
 * A source that fails does not empty the list: its last rows stay and its error is
 * recorded against it, so a plane that has gone away does not take the local sessions
 * off the screen with it.
 */
export class FleetStore {
  private sources: FleetSource[] = [];
  private bySource = new Map<string, FleetRow[]>();
  private snapshot: FleetSnapshot = emptySnapshot;
  private listeners = new Set<(s: FleetSnapshot) => void>();
  private timer: ReturnType<typeof setInterval> | null = null;
  private inFlight: Promise<void> | null = null;
  /** Whether `poll` is running, which is when watched sources are watched. */
  private watching = false;
  private readonly watches = new Map<string, () => void>();
  /** The watched sources whose watch is up now. */
  private readonly live = new Set<string>();
  /** When each source last answered or was told, for the safety net. */
  private readonly heard = new Map<string, number>();

  constructor(sources: FleetSource[] = []) {
    for (const s of sources) this.addSource(s);
  }

  addSource(source: FleetSource): void {
    const before = this.sources.find((s) => s.id === source.id);
    this.sources = [...this.sources.filter((s) => s.id !== source.id), source];
    if (before !== source) this.unwatch(source.id);
    if (this.watching) this.watchOne(source);
  }

  removeSource(id: string): void {
    this.unwatch(id);
    this.sources = this.sources.filter((s) => s.id !== id);
    this.bySource.delete(id);
    this.recompute();
  }

  /** Whether a watched source is being told what changes now. */
  isLive(id: string): boolean {
    return this.live.has(id);
  }

  private watchOne(source: FleetSource): void {
    if (!source.watch || this.watches.has(source.id)) return;
    const stop = source.watch(
      (rows) => {
        if (!this.sources.includes(source)) return;
        this.bySource.set(source.id, rows);
        this.heard.set(source.id, Date.now());
        this.snapshot = { ...this.snapshot, sources: { ...this.snapshot.sources, [source.id]: { at: Date.now(), error: null } } };
        this.recompute();
      },
      (up) => {
        if (up) this.live.add(source.id);
        else this.live.delete(source.id);
      },
    );
    this.watches.set(source.id, stop);
  }

  private unwatch(id: string): void {
    this.watches.get(id)?.();
    this.watches.delete(id);
    this.live.delete(id);
  }

  get current(): FleetSnapshot {
    return this.snapshot;
  }

  subscribe(listener: (s: FleetSnapshot) => void): () => void {
    this.listeners.add(listener);
    listener(this.snapshot);
    return () => void this.listeners.delete(listener);
  }

  /** Ask every source. Concurrent calls share one round. */
  async refresh(): Promise<void> {
    return this.ask(() => true);
  }

  /**
   * The poll's round: every source but a watched one whose watch is up, which is asked
   * only once the safety net is due.
   */
  private tick(): Promise<void> {
    const now = Date.now();
    return this.ask((s) => !this.live.has(s.id) || now - (this.heard.get(s.id) ?? 0) >= fleetTiming.safetyNetMs);
  }

  private async ask(which: (s: FleetSource) => boolean): Promise<void> {
    if (this.inFlight) return this.inFlight;
    this.emit({ ...this.snapshot, loading: true });
    this.inFlight = this.round(which).finally(() => {
      this.inFlight = null;
    });
    return this.inFlight;
  }

  private async round(which: (s: FleetSource) => boolean): Promise<void> {
    const sources = this.snapshot.sources;
    const next: FleetSnapshot["sources"] = { ...sources };
    await Promise.all(
      this.sources.filter(which).map(async (s) => {
        try {
          this.bySource.set(s.id, await s.list());
          this.heard.set(s.id, Date.now());
          next[s.id] = { at: Date.now(), error: null };
        } catch (e) {
          // Keep what the source last said. A list that empties because a token expired
          // is worse than a list that is briefly stale and says so.
          next[s.id] = { at: next[s.id]?.at ?? 0, error: e instanceof Error ? e.message : String(e) };
        }
      }),
    );
    this.snapshot = { ...this.snapshot, sources: next };
    this.recompute();
  }

  /**
   * Poll every `ms`, and watch every source that can be watched. Returns the stop
   * function. A watched source is asked on the poll only while its watch is down.
   */
  poll(ms = 5_000): () => void {
    this.stop();
    this.watching = true;
    for (const s of this.sources) this.watchOne(s);
    void this.refresh();
    this.timer = setInterval(() => void this.tick(), ms);
    return () => this.stop();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.watching = false;
    for (const id of [...this.watches.keys()]) this.unwatch(id);
  }

  /**
   * Apply one source's live news without a round trip: what a worker's summary
   * subscription says about a session that is open, folded onto the row.
   */
  patch(id: string, patch: Partial<FleetRow>): void {
    for (const [source, rows] of this.bySource) {
      const i = rows.findIndex((r) => r.id === id);
      if (i < 0) continue;
      const next = rows.slice();
      next[i] = { ...rows[i]!, ...patch };
      this.bySource.set(source, next);
      this.recompute();
      return;
    }
  }

  private recompute(): void {
    // A private session is one session with two rows — the plane's and the daemon's.
    // The daemon's copy wins on everything the daemon actually knows, because it is the
    // one running the agent; the plane's contributes the fact that it exists elsewhere.
    //
    // A session this computer offered is also on the plane's list of relayed ones; this
    // computer's own row comes after it and wins, since here it is not remote at all.
    const merged = new Map<string, FleetRow>();
    for (const kind of ["team", "remote", "local", "private"] as const) {
      for (const source of this.sources.filter((s) => s.kind === kind)) {
        for (const row of this.bySource.get(source.id) ?? []) {
          const existing = merged.get(row.id);
          // An invitation marks the row the plane already lists with who invited the person,
          // and is a row of its own only where nothing else lists the session.
          if (existing && row.invitation) merged.set(row.id, { ...existing, invitation: row.invitation });
          else merged.set(row.id, existing ? joined(existing, row) : row);
        }
      }
    }
    const rows = [...merged.values()].sort(byActivity);
    this.emit({ ...this.snapshot, rows, loading: false });
  }

  private emit(s: FleetSnapshot): void {
    this.snapshot = s;
    for (const l of this.listeners) l(s);
  }
}

/**
 * The daemon's row over the plane's, but for one thing the plane knows first: a session
 * somebody erased is waiting to be erased whatever the daemon says, since the daemon hears
 * it only when it is next linked (troupe Decision 756).
 */
function joined(existing: FleetRow, row: FleetRow): FleetRow {
  const next = { ...existing, ...row, raw: row.raw };
  return existing.sync === "erasure_pending" ? { ...next, sync: "erasure_pending" } : next;
}

/** Pinned first, then most recently active; a row with no activity sorts last. */
function byActivity(a: FleetRow, b: FleetRow): number {
  if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
  const ta = a.lastActiveAt ? Date.parse(a.lastActiveAt) : 0;
  const tb = b.lastActiveAt ? Date.parse(b.lastActiveAt) : 0;
  if (ta !== tb) return tb - ta;
  return a.id < b.id ? 1 : -1;
}

export function filterRows(rows: FleetRow[], filter: FleetFilter): FleetRow[] {
  const q = filter.query?.trim().toLowerCase();
  return rows.filter((r) => {
    if (filter.kind && filter.kind !== "all" && r.kind !== filter.kind) return false;
    if (filter.state && r.state !== filter.state) return false;
    if (filter.status && r.status !== filter.status) return false;
    if (filter.profile && r.profile !== filter.profile) return false;
    if (filter.needsApproval && r.pendingApprovals <= 0) return false;
    if (q && !`${r.title ?? ""} ${r.id}`.toLowerCase().includes(q)) return false;
    return true;
  });
}

/** Every session with an approval waiting. */
export function awaitingApproval(rows: FleetRow[]): FleetRow[] {
  return rows.filter((r) => r.pendingApprovals > 0);
}

/**
 * Every session waiting on its person, which is what the inbox is a list of: an approval
 * or a question, the agent's or the harness's. A session waiting on a question used to
 * reach nobody, because the rows counted only approvals.
 */
export function awaitingYou(rows: FleetRow[]): FleetRow[] {
  return rows.filter((r) => r.pendingApprovals > 0 || r.pendingQuestions > 0);
}

export function totalCostMicros(rows: FleetRow[]): number {
  return rows.reduce((n, r) => n + (r.costMicros ?? 0), 0);
}

/** Whether a row has anything to say about while nobody was reading it. */
export function hasUnseen(unseen: Unseen | null | undefined): unseen is Unseen {
  return Boolean(unseen && (unseen.turns > 0 || unseen.approvals > 0 || unseen.questions > 0));
}

const plural = (n: number, one: string): string => `${n} ${one}${n === 1 ? "" : "s"}`;

/**
 * "2 turns finished, 1 question waiting": counts in a line. A request is `waiting` while
 * the row still has one of its kind open, and `asked` when it ended while nobody was
 * there — timed out, or answered by somebody else.
 */
export function describeUnseen(
  counts: Pick<Unseen, "turns" | "approvals" | "questions">,
  open: Pick<FleetRow, "pendingApprovals" | "pendingQuestions" | "failed"> = { pendingApprovals: 0, pendingQuestions: 0 },
): string {
  return [
    counts.turns > 0 ? turnsEnded(counts.turns, Boolean(open.failed)) : null,
    counts.approvals > 0 ? `${plural(counts.approvals, "approval")} ${open.pendingApprovals > 0 ? "waiting" : "asked"}` : null,
    counts.questions > 0 ? `${plural(counts.questions, "question")} ${open.pendingQuestions > 0 ? "waiting" : "asked"}` : null,
  ]
    .filter(Boolean)
    .join(", ");
}

/** The turns that ended, the last of them a failure when the row says the session stopped on one. */
function turnsEnded(turns: number, failed: boolean): string {
  if (!failed) return `${plural(turns, "turn")} finished`;
  return turns === 1 ? "1 turn failed" : `${plural(turns, "turn")} ended, the last one failed`;
}

/**
 * "2 turns finished, 1 question waiting since 14:02": a row's `unseen`, for the line a
 * person reads on coming back. The clock is the local one, with the day in front when it
 * was not today. Null with nothing to say.
 */
export function unseenSummary(row: Pick<FleetRow, "unseen" | "pendingApprovals" | "pendingQuestions" | "failed">, now: Date = new Date()): string | null {
  const unseen = row.unseen;
  if (!hasUnseen(unseen)) return null;
  const said = describeUnseen(unseen, row);
  const at = unseen.since ? new Date(unseen.since) : null;
  if (!at || Number.isNaN(at.getTime())) return said;
  const clock = `${String(at.getHours()).padStart(2, "0")}:${String(at.getMinutes()).padStart(2, "0")}`;
  const today = at.toDateString() === now.toDateString();
  return `${said} since ${today ? clock : `${at.toLocaleDateString(undefined, { day: "numeric", month: "short" })} ${clock}`}`;
}
