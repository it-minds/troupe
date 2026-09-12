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

export interface Me {
  subject: string;
  display_name?: string;
  teams: string[];
  profiles: string[];
  [k: string]: unknown;
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
    this.fetchImpl = fetchImpl;
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
  createSession(
    planeToken: string,
    params: { profile: string; team?: string; title?: string; prompt?: string; visibility?: string },
  ): Promise<Attachment> {
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

  listSessions(planeToken: string, filter: Record<string, unknown> = {}): Promise<{ sessions: unknown[] }> {
    return this.rpc(planeToken, "sessions.list", { filter });
  }
}
