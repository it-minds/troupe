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

import type { PlaneClient, SessionRow, SessionsFilter } from "./plane.js";

/** Where a session runs, which is the one thing a person must be able to see at a glance. */
export type SessionKind = "team" | "local" | "private";

/** Only private sessions have one; it is about the copy, not the session. */
export type SyncState = "synced" | "pending" | "conflict" | "this-device-only";

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
  costMicros: number | null;
  lastActiveAt: string | null;
  pinned: boolean;
  yourRole: string | null;
  origin: { kind?: string; trigger?: string; [k: string]: unknown } | null;
  reviewedBy: string | null;
  sync: SyncState | null;
  /** The source's own row, for anything a view needs that this shape does not carry. */
  raw: unknown;
}

/** Anything that can list sessions. A plane, a daemon, or a test's stub. */
export interface FleetSource {
  readonly id: string;
  readonly kind: SessionKind;
  list(): Promise<FleetRow[]>;
}

export function rowFromPlane(row: SessionRow, source = "plane"): FleetRow {
  return {
    id: row.id,
    kind: "team",
    source,
    title: row.title ?? null,
    profile: row.profile ?? null,
    owner: row.owner ?? null,
    state: row.state ?? "dormant",
    status: row.status ?? null,
    doneReason: row.done_reason ?? null,
    pendingApprovals: row.pending_approvals ?? 0,
    costMicros: row.cost_micros ?? null,
    lastActiveAt: row.last_active_at ?? null,
    pinned: Boolean(row.pinned),
    yourRole: row.your_role ?? null,
    origin: row.origin ?? null,
    reviewedBy: row.reviewed_by ?? null,
    sync: null,
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

  constructor(sources: FleetSource[] = []) {
    for (const s of sources) this.addSource(s);
  }

  addSource(source: FleetSource): void {
    this.sources = [...this.sources.filter((s) => s.id !== source.id), source];
  }

  removeSource(id: string): void {
    this.sources = this.sources.filter((s) => s.id !== id);
    this.bySource.delete(id);
    this.recompute();
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
    if (this.inFlight) return this.inFlight;
    this.emit({ ...this.snapshot, loading: true });
    this.inFlight = this.round().finally(() => {
      this.inFlight = null;
    });
    return this.inFlight;
  }

  private async round(): Promise<void> {
    const sources = this.snapshot.sources;
    const next: FleetSnapshot["sources"] = { ...sources };
    await Promise.all(
      this.sources.map(async (s) => {
        try {
          this.bySource.set(s.id, await s.list());
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

  /** Poll every `ms`. Returns the stop function. */
  poll(ms = 5_000): () => void {
    this.stop();
    void this.refresh();
    this.timer = setInterval(() => void this.refresh(), ms);
    return () => this.stop();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
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
    const merged = new Map<string, FleetRow>();
    for (const kind of ["team", "local", "private"] as const) {
      for (const source of this.sources.filter((s) => s.kind === kind)) {
        for (const row of this.bySource.get(source.id) ?? []) {
          const existing = merged.get(row.id);
          merged.set(row.id, existing ? { ...existing, ...row, raw: row.raw } : row);
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

/** Every session with an approval waiting, which is what the inbox is a list of. */
export function awaitingApproval(rows: FleetRow[]): FleetRow[] {
  return rows.filter((r) => r.pendingApprovals > 0);
}

export function totalCostMicros(rows: FleetRow[]): number {
  return rows.reduce((n, r) => n + (r.costMicros ?? 0), 0);
}
