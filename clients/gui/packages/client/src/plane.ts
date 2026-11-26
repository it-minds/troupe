// The plane's client-facing HTTP surface. None of this is a WebSocket: discovery,
// the OIDC device grant against the identity provider, `/auth/exchange`, and plain
// JSON-RPC over `POST /rpc`. The plane hands out a worker endpoint and a pod-scoped
// token; the live session is then spoken to the worker directly (see connection.ts).

import { TroupeRpcError } from "./connection.js";
import type { OwnMemory, OwnMemoryPreview, OwnMemorySaved } from "./instructions.js";
import type { Invitation, Invitee, InviteRole, Person } from "./invites.js";
import type { PlaneDocument } from "./own.js";
import type { ProfileView } from "./profile.js";
import type { RemoteListRow } from "./remote.js";
import type { JsonRpcError, JsonRpcResponse } from "./types.js";

export interface Discovery {
  issuer: string;
  client_id: string;
  device_authorization_endpoint: string;
  token_endpoint: string;
  scopes: string[];
  plane: { name: string; rpc: string; jwks: string; protocol_version: string; [k: string]: unknown };
  /** Whether the plane has a break-glass door (`POST /auth/breakglass`); absent from a plane older than it. */
  breakglass?: boolean;
  [k: string]: unknown;
}

export interface DeviceAuthorization {
  device_code: string;
  user_code: string;
  verification_uri: string;
  verification_uri_complete?: string;
  interval?: number;
  expires_in: number;
}

export interface IdpTokens {
  id_token?: string;
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  [k: string]: unknown;
}

export interface PlaneCredential {
  token: string;
  expires_at: number;
  subject: string;
  display_name?: string;
  teams: string[];
  profiles: string[];
  [k: string]: unknown;
}

/** What `session.create`, `session.open` and `token.mint` all return. */
export interface Attachment {
  session_id: string;
  epoch?: number;
  mode?: "activate" | "read" | string;
  endpoint: string;
  worker_id: string;
  pod?: string;
  role: "owner" | "collaborator" | "viewer" | string;
  /** `null` when the plane could not mint one; treat as a failure. */
  token: string | null;
  expires_at?: number;
  /** `pending` while a full profile waits for a place: no endpoint yet, and `retry_after_ms` says when to `token.mint` again. */
  state?: string;
  retry_after_ms?: number;
  [k: string]: unknown;
}

export interface Team {
  name: string;
  id: string;
  budget_micros?: number;
  members_may_control?: boolean;
  idle_timeout_seconds?: number;
  /** The GitHub repositories its sessions may name, `owner/name` or `owner/*` (troupe #1207); absent from an older plane. */
  repositories?: string[];
  [k: string]: unknown;
}

/**
 * `me` answers with team *objects*, where `/auth/exchange` answers with their names.
 * Two different shapes for the same word, so they are two different types here.
 */
export interface Me {
  subject: string;
  display_name?: string;
  email?: string;
  kind?: string;
  teams: Team[];
  profiles: string[];
  platform_admin?: boolean;
  /** Signed in with the plane's break-glass token rather than through the identity provider. */
  breakglass?: boolean;
  [k: string]: unknown;
}

/** One of the person's own clients as the plane last saw it (`me.clients`), and how its version stands against the plane's policy. */
export interface OwnClient {
  component: string;
  version: string;
  platform?: string | null;
  seen_at?: string | null;
  standing: string;
  recommended?: string | null;
}

/** What `POST /auth/breakglass` answers: a plane token for the break-glass subject, and when it ends. */
export interface BreakGlassAnswer {
  token: string;
  /** ISO 8601, UTC. */
  expires_at: string;
  subject: string;
  [k: string]: unknown;
}

/** One session as the plane's index knows it — no content, and no log was replayed. */
export interface SessionRow {
  id: string;
  owner: string;
  /** The owner's name, where the plane has one (troupe #931); absent from an older plane. */
  owner_name?: string | null;
  profile: string;
  /** `team` for every member of its team, `private` for its owner and the people invited. */
  visibility: string;
  /** The team it runs for, by name, which it is given to; absent from an older plane. */
  team?: string | null;
  /** `erasure_pending`: a private session somebody erased whose key is not destroyed yet (troupe Decision 756). */
  state: "active" | "dormant" | "read_only" | "erasure_pending" | "erased" | string;
  /** `private` for one of the person's own sessions, listed beside the team's; absent from a plane before the column. */
  kind?: "team" | "private" | string;
  /** The device that sealed a private session last. */
  device?: string | null;
  /** How long it lasts: `throwaway`, `normal` or `persistent` (troupe #1209). Absent from an older plane, which makes every session normal. */
  lifespan?: string | null;
  /** When a throwaway session is erased if nothing keeps it; null for any other. */
  erases_at?: string | null;
  epoch: number;
  title: string | null;
  /** The agent it was created as or last switched to; null for the profile's default. Absent from an older plane. */
  agent?: string | null;
  /** When it was made. Absent from an older plane. */
  created_at?: string | null;
  last_active_at: string | null;
  last_seq: number;
  head_hash: string | null;
  object_bytes: number | null;
  workspace_bytes: number | null;
  pinned: boolean;
  /** What the worker last reported: idle, thinking, acting, waiting, done, interrupted. */
  status: string | null;
  done_reason: string | null;
  /**
   * A turn the harness stopped, until the root's next input: `tool_failures` or
   * `agent_failed` (Decision 750). Absent from a plane older than the column.
   */
  failed_reason?: string | null;
  pending_approvals: number | null;
  /** Absent from a plane older than the column. */
  pending_questions?: number | null;
  cost_micros: number | null;
  origin: { kind?: string; trigger?: string; [k: string]: unknown } | null;
  terms: Record<string, unknown> | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  your_role: "owner" | "collaborator" | "viewer" | null;
  /**
   * Hidden from the session list by its owner, for everyone who sees it, and kept whole:
   * listed only when `sessions.list` is asked for archived ones. Absent from a plane before it.
   */
  archived?: boolean;
  /**
   * The bundle version it is pinned to, of `bundle_channel`; the version that channel would
   * start a session on now (`bundle_current`), which its owner may raise it to; and a raise
   * asked for that no pod has taken yet (`bundle_raise_to`). Absent from an older plane.
   */
  bundle_version?: number | null;
  bundle_channel?: string | null;
  bundle_current?: number | null;
  bundle_raise_to?: number | null;
  /**
   * Every GitHub repository it holds, the one it was created on first (troupe #1207); absent
   * from an older plane, which says the one in `repository`.
   */
  repositories?: SessionRepository[];
  [k: string]: unknown;
}

/** What a session did on one repository, as its pod reported it: metadata only. */
export interface RepositoryRecord {
  branch?: string | null;
  commit?: string | null;
  pushes?: number | null;
  pull_request?: { number: number; url: string } | null;
  stopped?: { at: string; reason: string } | null;
  [k: string]: unknown;
}

/**
 * One GitHub repository a pod session holds: where its clone is in the workspace (`.` for
 * the root, `owner/name` for every other), who attached it, and what the session did there.
 */
export interface SessionRepository {
  owner: string;
  name: string;
  ref?: string | null;
  path?: string;
  attached_by?: string | null;
  attached_at?: string | null;
  github?: RepositoryRecord | null;
}

/** A repository as `session.create` and `session.repository.add` take one. */
export type RepositoryName = string | { owner: string; name: string; ref?: string | null };

export interface WorkerPod {
  pod: string;
  ordinal: number;
  endpoint: string;
  healthy: boolean;
  draining: boolean;
  /** A pod the operator removed and that has gone quiet, kept until the plane forgets it: no room, no health. Absent from a plane before it. */
  gone?: boolean;
  capacity: number;
  active_sessions: number;
  disk_used_bytes?: number;
  disk_total_bytes?: number;
  version?: string;
  bundle_hash?: string;
  [k: string]: unknown;
}

/**
 * What a session created on this profile will have, answered before it is created.
 * `agents` is what it may start as; `skills` and `mcp_servers` are what the channel's
 * current bundle gives it.
 */
export interface ProfileOffering {
  name: string;
  pods: WorkerPod[];
  capacity: number;
  active_sessions: number;
  healthy_pods: number;
  channel: string | null;
  bundle_version: string | null;
  bundle_hash: string | null;
  agents: string[];
  skills: Array<{ name: string; description?: string }>;
  mcp_servers: string[];
  /**
   * The administrator's ceiling on the profile's sessions at once, running and waiting;
   * null for none. Below it a full profile makes a create wait (`pending`); at it, a
   * create is refused with `capacity`. Absent from a plane before it said so.
   */
  max_sessions?: number | null;
  /** The caller's teams that may use it, by name: whom a session there is open to. */
  teams?: string[];
  /**
   * How many GitHub repositories a session here may hold; null where the profile has no
   * `spec.github` and a new session is offered none (troupe #1207). Absent from an older plane.
   */
  max_repositories?: number | null;
  [k: string]: unknown;
}

export interface SessionsFilter {
  profile?: string;
  state?: string;
  status?: string;
  origin?: string;
  trigger?: string;
  needs_review?: boolean;
  /** True lists only the archived sessions; omitted or false, only those not archived. */
  archived?: boolean;
  /** Only the sessions of this lifespan; a plane from before lifespans ignores it. */
  lifespan?: "throwaway" | "normal" | "persistent";
  limit?: number;
}

export interface CreateSessionParams {
  profile: string;
  team?: string;
  title?: string;
  /** The first input. At most 64 KiB, and never stored by the plane. */
  prompt?: string;
  /** One of `profiles.list`'s `agents`; refused with the list if it is not. */
  agent?: string;
  visibility?: string;
  /** How long it lasts; absent is normal. Send it only to a plane whose `initialize` says `lifespans`. */
  lifespan?: "throwaway" | "normal" | "persistent";
  terms?: { budget_micros?: number; max_turns?: number; wall_clock_seconds?: number; approvals?: "wait" | "deny" };
  origin?: { kind?: string; [k: string]: unknown };
  /** The GitHub repositories it starts on, the first cloned at the workspace's root (troupe #1207). */
  repositories?: RepositoryName[];
}

const trimSlash = (s: string) => s.replace(/\/+$/, "");

export class PlaneHttpError extends Error {
  readonly status: number;
  readonly body: string;
  constructor(what: string, status: number, body: string) {
    super(`${what}: HTTP ${status}${body ? `: ${body.slice(0, 200)}` : ""}`);
    this.name = "PlaneHttpError";
    this.status = status;
    this.body = body;
  }
}

/**
 * Turn whatever a plane puts in `endpoint` into a WebSocket URL.
 * Mirrors the reference client: ws(s) as-is; http(s) scheme-swapped with `/v1/socket`
 * appended if the path is empty; a bare host becomes `wss://host/v1/socket`.
 */
export function normalizeEndpoint(endpoint: string): string {
  if (/^wss?:\/\//i.test(endpoint)) return endpoint;
  if (/^https?:\/\//i.test(endpoint)) {
    const u = new URL(endpoint);
    u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
    if (u.pathname === "" || u.pathname === "/") u.pathname = "/v1/socket";
    return u.toString();
  }
  return `wss://${endpoint}/v1/socket`;
}

export class PlaneClient {
  readonly baseUrl: string;
  private readonly fetchImpl: typeof fetch;
  private nextId = 1;

  constructor(baseUrl: string, fetchImpl: typeof fetch = globalThis.fetch) {
    this.baseUrl = trimSlash(baseUrl);
    // Bound, because a browser's `fetch` refuses to run with any receiver but the
    // window: held as a field and called as `this.fetchImpl(…)` it would throw
    // "Illegal invocation", which arrives looking exactly like a blocked request.
    this.fetchImpl = fetchImpl.bind(globalThis);
  }

  /** The `fetch` this client was built with, for callers that speak to the provider. */
  get http(): typeof fetch {
    return this.fetchImpl;
  }

  /** `GET /.well-known/troupe` — no auth. */
  async discover(): Promise<Discovery> {
    const res = await this.fetchImpl(`${this.baseUrl}/.well-known/troupe`, { headers: { accept: "application/json" } });
    if (!res.ok) throw new PlaneHttpError("discover", res.status, await res.text());
    return (await res.json()) as Discovery;
  }

  /** Step one of the device grant: ask the IdP for a user code. Form-encoded. */
  async startDeviceFlow(d: Discovery): Promise<DeviceAuthorization> {
    const body = new URLSearchParams({ client_id: d.client_id, scope: d.scopes.join(" ") });
    const res = await this.fetchImpl(d.device_authorization_endpoint, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body,
    });
    if (!res.ok) throw new PlaneHttpError("device_authorization", res.status, await res.text());
    return (await res.json()) as DeviceAuthorization;
  }

  /**
   * Poll the IdP until the user approves. Honors `authorization_pending` and
   * `slow_down` (which doubles the interval). Resolves with the IdP's tokens.
   */
  async pollDeviceFlow(
    d: Discovery,
    auth: DeviceAuthorization,
    opts: { signal?: AbortSignal; onPoll?: () => void } = {},
  ): Promise<IdpTokens> {
    let intervalMs = (auth.interval ?? 5) * 1000;
    const deadline = Date.now() + auth.expires_in * 1000;
    while (Date.now() < deadline) {
      if (opts.signal?.aborted) throw new Error("device flow aborted");
      await new Promise((r) => setTimeout(r, intervalMs));
      opts.onPoll?.();
      const body = new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        device_code: auth.device_code,
        client_id: d.client_id,
      });
      const res = await this.fetchImpl(d.token_endpoint, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
        body,
      });
      const json = (await res.json().catch(() => ({}))) as { error?: string } & IdpTokens;
      if (res.ok) return json;
      switch (json.error) {
        case "authorization_pending":
          continue;
        case "slow_down":
          intervalMs *= 2;
          continue;
        default:
          throw new Error(`device flow failed: ${json.error ?? res.status}`);
      }
    }
    throw new Error("device flow expired before the user approved it");
  }

  /** Refresh at the IdP. Most providers rotate the refresh token: persist the new one. */
  async refreshIdp(d: Discovery, refreshToken: string): Promise<IdpTokens> {
    const body = new URLSearchParams({ grant_type: "refresh_token", refresh_token: refreshToken, client_id: d.client_id });
    const res = await this.fetchImpl(d.token_endpoint, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body,
    });
    if (!res.ok) throw new PlaneHttpError("refresh", res.status, await res.text());
    return (await res.json()) as IdpTokens;
  }

  /** `POST /auth/exchange {id_token}` → a plane token good for at most 15 minutes. */
  async exchange(idToken: string): Promise<PlaneCredential> {
    const res = await this.fetchImpl(`${this.baseUrl}/auth/exchange`, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ id_token: idToken }),
    });
    if (!res.ok) throw new PlaneHttpError("exchange", res.status, await res.text());
    return (await res.json()) as PlaneCredential;
  }

  /**
   * `POST /auth/breakglass {token}` → a plane token for the break-glass subject. The plane
   * answers 403 to a token it does not hold and 404 where no door is configured, both of
   * which arrive here as a `PlaneHttpError` with that status.
   */
  async breakGlass(breakglassToken: string): Promise<BreakGlassAnswer> {
    const res = await this.fetchImpl(`${this.baseUrl}/auth/breakglass`, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ token: breakglassToken }),
    });
    if (!res.ok) throw new PlaneHttpError("breakglass", res.status, await res.text());
    return (await res.json()) as BreakGlassAnswer;
  }

  /** One JSON-RPC request over `POST /rpc`, bearer-authenticated with a plane token. */
  async rpc<T = unknown>(planeToken: string, method: string, params: unknown = {}): Promise<T> {
    const id = this.nextId++;
    const res = await this.fetchImpl(`${this.baseUrl}/rpc`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
        authorization: `Bearer ${planeToken}`,
      },
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
    });
    if (res.status === 401) {
      const err: JsonRpcError = { code: -32003, message: "unauthenticated" };
      throw new TroupeRpcError(method, err);
    }
    if (!res.ok) throw new PlaneHttpError(method, res.status, await res.text());
    const msg = (await res.json()) as JsonRpcResponse;
    if (msg.error) throw new TroupeRpcError(method, msg.error);
    return msg.result as T;
  }

  me(planeToken: string): Promise<Me> {
    return this.rpc<Me>(planeToken, "me");
  }

  /** Place a new session on a worker. Returns the endpoint and pod token to dial. */
  createSession(planeToken: string, params: CreateSessionParams): Promise<Attachment> {
    return this.rpc<Attachment>(planeToken, "session.create", params);
  }

  /** Attach to an existing session. `read` never wakes a dormant session. */
  openSession(planeToken: string, sessionId: string, mode: "read" | "activate" = "read"): Promise<Attachment> {
    return this.rpc<Attachment>(planeToken, "session.open", { session_id: sessionId, mode });
  }

  /** Re-mint the pod token for an open connection, for `auth.refresh`. */
  mintToken(planeToken: string, sessionId: string): Promise<Attachment> {
    return this.rpc<Attachment>(planeToken, "token.mint", { session_id: sessionId });
  }

  /**
   * The plane's index, not a replay: `status`, `done_reason`, `pending_approvals`,
   * `pending_questions` and `cost_micros` are what the worker last reported over the
   * control channel, which is what makes a list of fifty sessions one request instead of
   * fifty logs.
   *
   * Filters are top-level params, not a nested `filter` object.
   */
  listSessions(planeToken: string, filter: SessionsFilter = {}): Promise<{ sessions: SessionRow[] }> {
    return this.rpc(planeToken, "sessions.list", filter);
  }

  /**
   * One session as the list has it. `not_found` both for one that is gone and for one the
   * person may not see: the plane does not say whether a session it will not show exists.
   */
  getSession(planeToken: string, sessionId: string): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.get", { session_id: sessionId });
  }

  listProfiles(planeToken: string): Promise<{ profiles: ProfileOffering[] }> {
    return this.rpc(planeToken, "profiles.list", {});
  }

  /**
   * What a profile the person may use gives a session on it, composed by the plane from
   * what it enforces, before any session exists. `not_found` for a profile they may not use.
   */
  profile(planeToken: string, name: string): Promise<ProfileView> {
    return this.rpc<ProfileView>(planeToken, "profile.get", { name });
  }

  /** Mark a session looked at. An acknowledgement; it changes nothing the agent does. */
  reviewSession(planeToken: string, sessionId: string): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.review", { session_id: sessionId });
  }

  /**
   * Invite a person into a pod session by name, to follow it (`observe`) or steer it
   * (`control`): the session's grant made visible (troupe #765). Owner or team admin only.
   * A private session is invited from the daemon that seals it (`DaemonClient.inviteSession`).
   */
  inviteToSession(planeToken: string, sessionId: string, subject: string, role: InviteRole): Promise<{ session_id: string; invite: Invitee }> {
    return this.rpc(planeToken, "session.invite", { session_id: sessionId, subject, role });
  }

  /** Take an invitation back: every route it gave ends. */
  uninviteFromSession(planeToken: string, sessionId: string, subject: string): Promise<{ session_id: string; subject: string }> {
    return this.rpc(planeToken, "session.uninvite", { session_id: sessionId, subject });
  }

  /** Whom a session is shared with by name, to anybody in it. */
  sessionInvites(planeToken: string, sessionId: string): Promise<{ session_id: string; invites: Invitee[] }> {
    return this.rpc(planeToken, "session.invites", { session_id: sessionId });
  }

  /** The invitations to this person. */
  listInvites(planeToken: string): Promise<{ invites: Invitation[] }> {
    return this.rpc(planeToken, "invites.list", {});
  }

  /** People whose name starts with `query`, among those this person may invite into `sessionId` or shares a team with. */
  searchPeople(planeToken: string, query: string, sessionId?: string): Promise<{ people: Person[] }> {
    return this.rpc(planeToken, "people.search", sessionId ? { query, session_id: sessionId } : { query });
  }

  /** The laptop sessions the plane relays to this person: their own from their other computers, and those shared with them. */
  remoteSessions(planeToken: string): Promise<{ sessions: RemoteListRow[] }> {
    return this.rpc(planeToken, "remote.list", {});
  }

  /** The versions of this person's own clients the plane last saw, each with how it stands against the plane's policy. */
  clientsSeen(planeToken: string): Promise<{ clients: OwnClient[] }> {
    return this.rpc(planeToken, "me.clients", {});
  }

  /** The person's own memory as `user`, and the levels above it as `documents`, as the plane answers `me.memory`. */
  ownMemory(planeToken: string): Promise<{ documents?: PlaneDocument[]; user?: OwnMemory }> {
    return this.rpc(planeToken, "me.memory", {});
  }

  /** What saving `text` as the person's own memory would change, saving nothing. */
  previewOwnMemory(planeToken: string, text: string): Promise<OwnMemoryPreview> {
    return this.rpc<OwnMemoryPreview>(planeToken, "me.memory.preview", { text });
  }

  /** Save `text` as the person's own memory over `version`; a version since saved is refused. */
  putOwnMemory(planeToken: string, text: string, version: number): Promise<OwnMemorySaved> {
    return this.rpc<OwnMemorySaved>(planeToken, "me.memory.put", { text, version });
  }

  /** Keep a session at the top of the session list, and out of the plane's retention, or let it go. Its owner's alone. */
  pinSession(planeToken: string, sessionId: string, pinned: boolean): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, pinned ? "session.pin" : "session.unpin", { session_id: sessionId });
  }

  /** Name a session, or take its name off with an empty title; the answer is its row. Its owner's alone. */
  setSessionTitle(planeToken: string, sessionId: string, title: string): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.title.set", { session_id: sessionId, title });
  }

  /**
   * Give a pod session to its team (`team`) or take it back (`private`) after it started
   * (troupe #1169); the answer is its row. Its owner's alone: anybody else is refused
   * `forbidden`. Invitations stay as they are.
   */
  setSessionVisibility(planeToken: string, sessionId: string, visibility: "team" | "private"): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.visibility.set", { session_id: sessionId, visibility });
  }

  /**
   * How long a session lasts, changed by its owner (troupe #1209); the answer is its row.
   * Its owner's alone: anybody else is refused `forbidden`. A pod session's and a private one's.
   */
  setSessionLifespan(planeToken: string, sessionId: string, lifespan: "throwaway" | "normal" | "persistent"): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.lifespan.set", { session_id: sessionId, lifespan });
  }

  /** Erase a session, irreversibly: its owner's, or an administrator's. `erased` is false while its key is not destroyed yet. */
  eraseSession(planeToken: string, sessionId: string): Promise<{ session_id: string; erased: boolean; state: string }> {
    return this.rpc(planeToken, "session.erase", { session_id: sessionId });
  }

  /**
   * Raise a pod session to its channel's current bundle version (troupe #1177); the answer
   * is its row. Its owner's alone. A session whose agent is working is refused `conflict`
   * with `raise_to`: the raise is kept, and lands when the agent is done (`raiseKept`).
   */
  raiseSessionBundle(planeToken: string, sessionId: string): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.bundle.raise", { session_id: sessionId });
  }

  /** The person's teams, each with what it lets its sessions do: its GitHub `repositories` among them. */
  listTeams(planeToken: string): Promise<{ teams: Team[] }> {
    return this.rpc<{ teams: Team[] }>(planeToken, "teams.list");
  }

  /**
   * Attach a GitHub repository to a pod session (troupe #1207); the answer is its row. Its
   * owner's alone. Its pod clones it into `owner/name` without a restart, or at the next
   * wake of a session that sleeps.
   */
  addSessionRepository(planeToken: string, sessionId: string, repository: RepositoryName): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.repository.add", { session_id: sessionId, repository });
  }

  /**
   * Take a repository off a pod session: its directory goes and its tokens are revoked. Its
   * owner's alone; refused `conflict` with `reason: "busy"` while a push on it is going.
   */
  removeSessionRepository(planeToken: string, sessionId: string, repository: string): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.repository.remove", { session_id: sessionId, repository });
  }

  /**
   * Hide a session from the session list, for everyone who sees it, keeping it whole; a
   * running one is put to sleep first. Its owner's alone: anybody else is refused `forbidden`.
   * Activity does not bring it back; only `unarchiveSession` does.
   */
  archiveSession(planeToken: string, sessionId: string): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.archive", { session_id: sessionId });
  }

  /** Put an archived session back in the session list. Its owner's alone, as archiving it is. */
  unarchiveSession(planeToken: string, sessionId: string): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.unarchive", { session_id: sessionId });
  }
}
