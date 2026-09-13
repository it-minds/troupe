// The plane's client-facing HTTP surface. None of this is a WebSocket: discovery,
// the OIDC device grant against the identity provider, `/auth/exchange`, and plain
// JSON-RPC over `POST /rpc`. The plane hands out a worker endpoint and a pod-scoped
// token; the live session is then spoken to the worker directly (see connection.ts).

import { TroupeRpcError } from "./connection.js";
import type { JsonRpcError, JsonRpcResponse } from "./types.js";

export interface Discovery {
  issuer: string;
  client_id: string;
  device_authorization_endpoint: string;
  token_endpoint: string;
  scopes: string[];
  plane: { name: string; rpc: string; jwks: string; protocol_version: string; [k: string]: unknown };
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
  [k: string]: unknown;
}

export interface Team {
  name: string;
  id: string;
  budget_micros?: number;
  members_may_control?: boolean;
  idle_timeout_seconds?: number;
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
  [k: string]: unknown;
}

/** One session as the plane's index knows it — no content, and no log was replayed. */
export interface SessionRow {
  id: string;
  owner: string;
  profile: string;
  visibility: string;
  state: "active" | "dormant" | "read_only" | "erased" | string;
  epoch: number;
  title: string | null;
  last_active_at: string | null;
  last_seq: number;
  head_hash: string | null;
  object_bytes: number | null;
  workspace_bytes: number | null;
  pinned: boolean;
  /** What the worker last reported: idle, thinking, acting, waiting, done, interrupted. */
  status: string | null;
  done_reason: string | null;
  pending_approvals: number | null;
  cost_micros: number | null;
  origin: { kind?: string; trigger?: string; [k: string]: unknown } | null;
  terms: Record<string, unknown> | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  your_role: "owner" | "collaborator" | "viewer" | null;
  [k: string]: unknown;
}

export interface WorkerPod {
  pod: string;
  ordinal: number;
  endpoint: string;
  healthy: boolean;
  draining: boolean;
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
  [k: string]: unknown;
}

export interface SessionsFilter {
  profile?: string;
  state?: string;
  status?: string;
  origin?: string;
  trigger?: string;
  needs_review?: boolean;
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
  terms?: { budget_micros?: number; max_turns?: number; wall_clock_seconds?: number; approvals?: "wait" | "deny" };
  origin?: { kind?: string; [k: string]: unknown };
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
   * The plane's index, not a replay: `status`, `done_reason`, `pending_approvals` and
   * `cost_micros` are what the worker last reported over the control channel, which is
   * what makes a list of fifty sessions one request instead of fifty logs.
   *
   * Filters are top-level params, not a nested `filter` object.
   */
  listSessions(planeToken: string, filter: SessionsFilter = {}): Promise<{ sessions: SessionRow[] }> {
    return this.rpc(planeToken, "sessions.list", filter);
  }

  getSession(planeToken: string, sessionId: string): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.get", { session_id: sessionId });
  }

  listProfiles(planeToken: string): Promise<{ profiles: ProfileOffering[] }> {
    return this.rpc(planeToken, "profiles.list", {});
  }

  listTeams(planeToken: string): Promise<{ teams: Team[] }> {
    return this.rpc(planeToken, "teams.list", {});
  }

  /** Mark a session looked at. An acknowledgement; it changes nothing the agent does. */
  reviewSession(planeToken: string, sessionId: string): Promise<SessionRow> {
    return this.rpc<SessionRow>(planeToken, "session.review", { session_id: sessionId });
  }

  /** Let another subject in. Owner or team admin only. */
  grantSession(
    planeToken: string,
    sessionId: string,
    subject: string,
    role: "collaborator" | "viewer",
  ): Promise<{ session_id: string; subject: string; role: string; pushed: boolean }> {
    return this.rpc(planeToken, "session.grant", { session_id: sessionId, subject, role });
  }

  pinSession(planeToken: string, sessionId: string, pinned: boolean): Promise<unknown> {
    return this.rpc(planeToken, pinned ? "session.pin" : "session.unpin", { session_id: sessionId });
  }

  eraseSession(planeToken: string, sessionId: string): Promise<unknown> {
    return this.rpc(planeToken, "session.erase", { session_id: sessionId });
  }
}
