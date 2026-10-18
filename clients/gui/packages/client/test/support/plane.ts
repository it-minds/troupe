// A fake plane: discovery, the login exchange, the harness JSON-RPC, and the CORS
// allowlist — the four things a browser client touches.
//
// It places sessions on a `FakeWorker` and mints pod tokens for it, so a test can go
// from "sign in" to "watch an answer stream" without anything but Node.

import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import type { FakeAdmin } from "./admin.js";
import { readBody, subjectOfIdToken, type FakeIdp } from "./idp.js";
import { encodeToken, type FakeWorker } from "./worker.js";

interface Row {
  id: string;
  owner: string;
  profile: string;
  title: string | null;
  state: string;
  status: string | null;
  /** A turn the harness stopped, `tool_failures` or `agent_failed`, until the next input (Decision 750). */
  failed_reason: string | null;
  epoch: number;
  pinned: boolean;
  reviewed_by: string | null;
  origin: { kind: string; trigger?: string } | null;
  created_at: number;
}

export interface PlaneOptions {
  idp: FakeIdp;
  worker: FakeWorker;
  /** Exact origins a browser may read an answer from. Empty is CORS off. */
  corsOrigins?: string[];
  /** Seconds a pod token is good for. */
  podTokenLifetime?: number;
  /** Seconds a plane token is good for. */
  planeTokenLifetime?: number;
  profiles?: string[];
  /**
   * What `me.client_defaults` answers. Defaults to an organisation that routes through
   * its own gateway; `{ configured: false }` is one whose administrator has set nothing.
   */
  clientDefaults?: Record<string, unknown>;
  /**
   * The version policy per component (`tui`, `daemon`, `desktop`), which `initialize` and
   * `me.client_versions` answer from (Decision 868). None is a plane with no policy set.
   */
  clientVersions?: Record<string, { recommended?: string | null; minimum?: string | null; blocked?: string[] }>;
  /** A plane from before the policy: no `initialize` over `/rpc`, no `me.client_versions`. */
  beforePolicy?: boolean;
  /** The administrative half, `admin.*`. None is a plane whose admin methods are not found. */
  admin?: FakeAdmin;
}

/** SemVer's order, enough for a policy's versions: the numbers, then a pre-release below none. */
export function older(a: string, b: string): boolean {
  const parse = (v: string) => /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(v);
  const x = parse(a);
  const y = parse(b);
  if (!x || !y) return false;
  for (let i = 1; i <= 3; i += 1) {
    if (Number(x[i]) !== Number(y[i])) return Number(x[i]) < Number(y[i]);
  }
  if (x[4] === y[4]) return false;
  if (!x[4]) return false;
  if (!y[4]) return true;
  const xs = x[4].split(".");
  const ys = y[4].split(".");
  for (let i = 0; i < Math.min(xs.length, ys.length); i += 1) {
    const [p, q] = [xs[i]!, ys[i]!];
    if (p === q) continue;
    const [pn, qn] = [/^\d+$/.test(p), /^\d+$/.test(q)];
    if (pn && qn) return Number(p) < Number(q);
    if (pn !== qn) return pn;
    return p < q;
  }
  return xs.length < ys.length;
}

const COMPONENTS: Record<string, string> = { troupe: "tui", "troupe-headless": "tui", "troupe-daemon": "daemon", "troupe-gui": "desktop" };

/** An organisation that points its clients at an OpenAI-compatible gateway of its own. */
export const GATEWAY_DEFAULTS = {
  configured: true,
  provider: "openai",
  base_url: "https://llm-gw.example/v1",
  auth: "bearer",
  models: { default: "glm-5.2", cheap: "qwen3.6-35b" },
};

/**
 * A laptop's session offered to the plane for steering (troupe #58, Decision 921). The
 * fake has no laptop: the worker stands in for it, so `remote.open` hands out the worker's
 * endpoint and a token for it, and what a test steers it is the worker's session.
 */
interface Relayed {
  id: string;
  owner: string;
  ownerName: string;
  workspace: string;
  shares: Array<{ subject: string; role: "observe" | "control" }>;
  offlineSince: string | null;
  offeredAt: string;
}

export class FakePlane {
  readonly server: Server;
  readonly rows = new Map<string, Row>();
  readonly relayed = new Map<string, Relayed>();
  /** Every `client_info` an `initialize` over `/rpc` gave, in order. */
  readonly initialized: Array<{ name?: unknown; version?: unknown }> = [];
  corsOrigins: string[];
  podTokenLifetime: number;

  private readonly opts: PlaneOptions;
  private url = "";
  private tokens = new Map<string, { subject: string; name: string; exp: number }>();
  private counter = 0;
  /** The plane's own signing key, once `sign()` gives it one (#657). */
  private signing: { publicKey: string; privateKey: CryptoKey; fingerprint: string } | null = null;
  /** Where the plane says releases are, in the version policy it signs. */
  releaseUrl: string | null = null;

  private constructor(opts: PlaneOptions) {
    this.opts = opts;
    this.corsOrigins = opts.corsOrigins ?? [];
    this.podTokenLifetime = opts.podTokenLifetime ?? 900;
    this.server = createServer((req, res) => void this.handle(req, res));
  }

  static async start(opts: PlaneOptions): Promise<FakePlane> {
    const p = new FakePlane(opts);
    await new Promise<void>((r) => p.server.listen(0, "127.0.0.1", r));
    p.url = `http://127.0.0.1:${(p.server.address() as AddressInfo).port}`;
    return p;
  }

  get baseUrl(): string {
    return this.url;
  }

  /**
   * Sign the version policy from now on with a key of the plane's own, a new one each call
   * (a rotation), served at `/.well-known/troupe-signing-key`, as the plane does (#657).
   * Answers the key as a client pins it.
   */
  async sign(): Promise<{ algorithm: string; public_key: string; fingerprint: string }> {
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
    const publicKey = Buffer.from(raw).toString("base64");
    const digest = Buffer.from(await crypto.subtle.digest("SHA-256", raw)).toString("base64").replace(/=+$/, "");
    this.signing = { publicKey, privateKey: pair.privateKey, fingerprint: `SHA256:${digest}` };
    return { algorithm: "ed25519", public_key: publicKey, fingerprint: this.signing.fingerprint };
  }

  // As `Troupe.Protocol.PlaneSignature` lays it out: canonical JSON of the kind, the plane,
  // the window and the body, signed as it is.
  private async signed(kind: string, answer: Record<string, unknown>, body: Record<string, unknown>): Promise<Record<string, unknown>> {
    if (!this.signing) return answer;
    const canonical = (v: unknown): string =>
      Array.isArray(v)
        ? `[${v.map(canonical).join(",")}]`
        : v && typeof v === "object"
          ? `{${Object.keys(v as object)
              .sort()
              .map((k) => `${JSON.stringify(k)}:${canonical((v as Record<string, unknown>)[k])}`)
              .join(",")}}`
          : JSON.stringify(v ?? null);
    const now = new Date();
    const document = canonical({
      kind,
      plane: this.url,
      signed_at: now.toISOString().replace(/\.\d+Z$/, "Z"),
      expires_at: new Date(now.getTime() + 7 * 24 * 3600 * 1000).toISOString().replace(/\.\d+Z$/, "Z"),
      body,
    });
    const signature = Buffer.from(await crypto.subtle.sign({ name: "Ed25519" }, this.signing.privateKey, new TextEncoder().encode(document))).toString("base64");
    return { ...answer, signed: { algorithm: "ed25519", fingerprint: this.signing.fingerprint, document, signature } };
  }

  async stop(): Promise<void> {
    // Ends what a page left open, a request its unmount cut off, which a close waits for.
    const closed = new Promise<void>((r) => this.server.close(() => r()));
    this.server.closeAllConnections();
    await closed;
  }

  /** Put a session on the worker and in the index, as `session.create` would. */
  seed(owner: string, params: { id?: string; profile?: string; title?: string; origin?: Row["origin"] } = {}): Row {
    const id = params.id ?? `s-${++this.counter}`;
    const row: Row = {
      id,
      owner,
      profile: params.profile ?? "dev",
      title: params.title ?? null,
      state: "active",
      status: "idle",
      failed_reason: null,
      epoch: 1,
      pinned: false,
      reviewed_by: null,
      origin: params.origin ?? { kind: "user" },
      created_at: Date.now() + this.counter,
    };
    this.rows.set(id, row);
    this.opts.worker.createSession(id, { profile: row.profile });
    return row;
  }

  /** A laptop's session, offered by `owner` and shared as `shares` says, its laptop online. */
  relay(owner: string, params: { id?: string; ownerName?: string; workspace?: string; shares?: Relayed["shares"] } = {}): Relayed {
    const id = params.id ?? `s-laptop-${++this.counter}`;
    const offer: Relayed = {
      id,
      owner,
      ownerName: params.ownerName ?? owner,
      workspace: params.workspace ?? "project",
      shares: params.shares ?? [],
      offlineSince: null,
      offeredAt: new Date(Date.now() + this.counter).toISOString(),
    };
    this.relayed.set(id, offer);
    this.opts.worker.createSession(id, { profile: "build" });
    return offer;
  }

  /** The laptop went: offline since now, or `at`; `null` brings it back. */
  offline(id: string, at: string | null = new Date().toISOString()): void {
    const offer = this.relayed.get(id);
    if (!offer) throw new Error(`no relayed session ${id}`);
    offer.offlineSince = at;
  }

  private relayRole(offer: Relayed, subject: string): string | null {
    if (offer.owner === subject) return "control";
    return offer.shares.find((s) => s.subject === subject)?.role ?? null;
  }

  /**
   * A turn the harness stopped, as the pod's report leaves the row (Decision 750): the
   * reason and nothing else, and a root that kept crashing asleep after it.
   */
  fail(id: string, reason: "tool_failures" | "agent_failed"): void {
    const row = this.rows.get(id);
    if (!row) throw new Error(`no session ${id}`);
    row.failed_reason = reason;
    if (reason === "agent_failed") row.state = "dormant";
  }

  private async handle(req: import("node:http").IncomingMessage, res: import("node:http").ServerResponse): Promise<void> {
    const path = (req.url ?? "/").split("?")[0]!;
    const origin = (req.headers["origin"] as string | undefined) ?? null;

    // The allowlist, as the plane implements it: exact match, echoed back only to a
    // request that presented it, never `*`, and only on the routes a browser calls.
    const browserRoute = path === "/rpc" || path === "/auth/exchange" || path.startsWith("/.well-known/");
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (this.corsOrigins.length > 0 && browserRoute) {
      headers["vary"] = "origin";
      if (origin && this.corsOrigins.includes(origin)) headers["access-control-allow-origin"] = origin;
    }
    if (req.method === "OPTIONS") {
      if (headers["access-control-allow-origin"]) {
        headers["access-control-allow-methods"] = "GET, POST, OPTIONS";
        headers["access-control-allow-headers"] = "authorization, content-type";
        headers["access-control-max-age"] = "600";
      }
      res.writeHead(204, headers);
      res.end();
      return;
    }

    const json = (status: number, payload: unknown) => {
      res.writeHead(status, headers);
      res.end(JSON.stringify(payload));
    };

    if (path === "/.well-known/troupe") {
      return json(200, {
        issuer: this.opts.idp.issuer,
        client_id: "troupe-gui",
        device_authorization_endpoint: this.opts.idp.deviceAuthorizationEndpoint,
        token_endpoint: this.opts.idp.tokenEndpoint,
        scopes: ["openid", "profile", "email", "offline_access", "groups"],
        plane: { name: "fake", rpc: "/rpc", jwks: "/.well-known/jwks.json", protocol_version: "1" },
      });
    }

    if (path === "/.well-known/troupe-signing-key") {
      if (!this.signing) return json(404, { error: "not_found" });
      return json(200, { algorithm: "ed25519", public_key: this.signing.publicKey, fingerprint: this.signing.fingerprint, version: 1 });
    }

    const body = await readBody(req);

    if (path === "/auth/exchange") {
      const parsed = JSON.parse(body || "{}") as { id_token?: string };
      if (!parsed.id_token) return json(401, { error: "unauthenticated", reason: "no_token" });
      const { sub, name } = subjectOfIdToken(parsed.id_token);
      const token = `pt-${sub}-${++this.counter}`;
      const exp = Math.floor(Date.now() / 1000) + (this.opts.planeTokenLifetime ?? 900);
      this.tokens.set(token, { subject: sub, name, exp });
      return json(200, {
        token,
        expires_at: exp,
        subject: sub,
        display_name: name,
        teams: ["core"],
        profiles: this.opts.profiles ?? ["dev", "ux"],
      });
    }

    if (path === "/rpc") {
      const auth = (req.headers["authorization"] as string | undefined) ?? "";
      const held = this.tokens.get(auth.replace(/^Bearer /i, ""));
      if (!held || held.exp * 1000 <= Date.now()) return json(401, { error: "unauthenticated" });
      const request = JSON.parse(body || "{}") as { id?: number; method?: string; params?: Record<string, unknown> };
      const method = request.method ?? "";
      let answer =
        this.opts.admin && method.startsWith("admin.")
          ? await this.opts.admin.call(held.subject, method, request.params ?? {})
          : this.rpc(held.subject, held.name, method, request.params ?? {});
      // The version policy, with where releases are, signed where the plane has a key.
      if (method === "me.client_versions" && "result" in answer && (this.signing || this.releaseUrl)) {
        const versions = answer.result as Record<string, unknown>;
        const release = { url: this.releaseUrl };
        answer = { result: await this.signed("client_versions", { ...versions, release }, { versions, release }) };
      }
      return json(200, { jsonrpc: "2.0", id: request.id ?? null, ...answer });
    }

    json(404, { error: "not_found" });
  }

  private rpc(
    subject: string,
    name: string,
    method: string,
    params: Record<string, unknown>,
  ): { result: unknown } | { error: { code: number; message: string; data?: unknown } } {
    const worker = this.opts.worker;
    const profiles = this.opts.profiles ?? ["dev", "ux"];

    const policy = (component: string) => {
      const p = this.opts.clientVersions?.[component] ?? {};
      return { recommended: p.recommended ?? null, minimum: p.minimum ?? null, blocked: p.blocked ?? [] };
    };

    switch (method) {
      // The handshake over `/rpc` (Decision 868): `me`, and the policy for the kind of
      // client this is, or `update_required` for one on a blocked version or below the
      // minimum.
      case "initialize": {
        if (this.opts.beforePolicy) return { error: { code: -32601, message: "method_not_found", data: { method } } };
        const info = (params["client_info"] ?? {}) as { name?: unknown; version?: unknown };
        this.initialized.push(info);
        const component = COMPONENTS[String(info.name)];
        const version = typeof info.version === "string" ? info.version : null;
        const principal = this.rpc(subject, name, "me", {});
        const hello = (clientUpdate: unknown) => ({
          result: { protocol_version: "1", server_info: { name: "troupe-plane", version: "test" }, principal: "result" in principal ? principal.result : null, client_update: clientUpdate },
        });
        if (!component) return hello(null);
        const p = policy(component);
        const blocked = version !== null && p.blocked.includes(version);
        if (blocked || (version !== null && p.minimum && older(version, p.minimum))) {
          const program = { tui: "troupe", daemon: "troupe-daemon", desktop: "the desktop app" }[component];
          const reason = blocked
            ? `This plane does not serve ${program} ${version}, which its administrators have blocked.`
            : `This plane needs ${program} ${p.minimum} or later, and this is ${version}.`;
          return {
            error: {
              code: -32016,
              message: "update_required",
              data: { component, version, minimum: p.minimum, recommended: p.recommended, blocked, run: null, reason },
            },
          };
        }
        const action = version !== null && p.recommended && older(version, p.recommended) ? "suggest" : "none";
        return hello({ component, ...p, action });
      }

      case "me.client_versions":
        if (this.opts.beforePolicy) return { error: { code: -32601, message: "method_not_found", data: { method } } };
        return { result: { tui: policy("tui"), daemon: policy("daemon"), desktop: policy("desktop") } };

      case "me":
        return {
          result: {
            subject,
            display_name: name,
            kind: "user",
            teams: [{ name: "core", id: "t-1", budget_micros: 1_000_000 }],
            profiles,
            platform_admin: this.opts.admin?.role(subject) === "platform_admin",
          },
        };

      // What any signed-in person's client should use. Never a key: the plane does not
      // hold one to hand out, and each person brings their own.
      case "me.client_defaults":
        return { result: this.opts.clientDefaults ?? GATEWAY_DEFAULTS };

      case "teams.list":
        return { result: { teams: [{ name: "core", id: "t-1", budget_micros: 1_000_000 }] } };

      case "profiles.list":
        return {
          result: {
            profiles: profiles.map((p) => ({
              name: p,
              pods: [{ pod: `${p}-0`, ordinal: 0, endpoint: worker.endpoint, healthy: true, draining: false, capacity: 8, active_sessions: worker.sessions.size }],
              capacity: 8,
              active_sessions: worker.sessions.size,
              healthy_pods: 1,
              channel: "stable",
              bundle_version: "3",
              bundle_hash: "sha256:abc",
              agents: ["build", "plan", "explore"],
              skills: [{ name: "review", description: "read a diff and comment" }],
              mcp_servers: ["github"],
            })),
          },
        };

      case "sessions.list": {
        const rows = [...this.rows.values()]
          .filter((r) => !params["profile"] || r.profile === params["profile"])
          .filter((r) => !params["state"] || r.state === params["state"])
          .filter((r) => !params["status"] || r.status === params["status"])
          .filter((r) => !params["origin"] || r.origin?.kind === params["origin"])
          .filter((r) => !params["needs_review"] || (r.origin?.kind !== "user" && !r.reviewed_by))
          .sort((a, b) => b.created_at - a.created_at);
        return { result: { sessions: rows.map((r) => this.sessionJson(r, subject)) } };
      }

      case "session.get": {
        const row = this.rows.get(String(params["session_id"] ?? ""));
        if (!row) return { error: { code: -32005, message: "not_found" } };
        return { result: this.sessionJson(row, subject) };
      }

      case "session.create": {
        const profile = String(params["profile"] ?? "");
        if (!profiles.includes(profile)) return { error: { code: -32002, message: "invalid_params", data: { profiles } } };
        const agent = params["agent"] === undefined ? undefined : String(params["agent"]);
        if (agent && !["build", "plan", "explore"].includes(agent)) {
          return { error: { code: -32602, message: "invalid_params", data: { agents: ["build", "plan", "explore"] } } };
        }
        const title = params["title"] === undefined ? undefined : String(params["title"]);
        const row = this.seed(subject, title === undefined ? { profile } : { profile, title });
        return { result: this.attachment(row, subject, name, "owner", "activate") };
      }

      case "session.open": {
        const row = this.rows.get(String(params["session_id"] ?? ""));
        if (!row) return { error: { code: -32005, message: "not_found" } };
        const mode = params["mode"] === "activate" ? "activate" : "read";
        const role = row.owner === subject ? "owner" : "collaborator";
        return { result: this.attachment(row, subject, name, role, mode) };
      }

      case "token.mint": {
        const row = this.rows.get(String(params["session_id"] ?? ""));
        if (!row) return { error: { code: -32005, message: "not_found" } };
        const role = row.owner === subject ? "owner" : "collaborator";
        return { result: this.attachment(row, subject, name, role, "activate") };
      }

      case "remote.list": {
        const sessions = [...this.relayed.values()].flatMap((o) => {
          const role = this.relayRole(o, subject);
          if (!role) return [];
          return [
            {
              id: o.id,
              kind: "remote",
              owner: o.owner,
              owner_name: o.ownerName,
              workspace: o.workspace,
              state: o.offlineSince ? "offline" : "online",
              offline_since: o.offlineSince,
              offered_at: o.offeredAt,
              your_role: o.owner === subject ? "owner" : role,
              shares: o.owner === subject ? o.shares : null,
            },
          ];
        });
        return { result: { sessions } };
      }

      case "remote.open": {
        const offer = this.relayed.get(String(params["session_id"] ?? ""));
        const role = offer ? this.relayRole(offer, subject) : null;
        if (!offer || !role) return { error: { code: -32005, message: "not_found" } };
        if (offer.offlineSince) {
          return { error: { code: -32010, message: "unavailable", data: { reason: "the laptop is offline", offline_since: offer.offlineSince } } };
        }
        const scopes = role === "control" ? ["observe", "control"] : ["observe"];
        const exp = Math.floor(Date.now() / 1000) + this.podTokenLifetime;
        const podRole = role === "control" ? "collaborator" : "viewer";
        return {
          result: {
            session_id: offer.id,
            kind: "remote",
            state: "active",
            endpoint: this.opts.worker.endpoint,
            role: podRole,
            your_role: offer.owner === subject ? "owner" : role,
            token: encodeToken({ sub: subject, name, session_id: offer.id, role: podRole, scopes, aud: this.opts.worker.workerId, exp }),
            expires_at: exp,
          },
        };
      }

      case "session.review": {
        const row = this.rows.get(String(params["session_id"] ?? ""));
        if (!row) return { error: { code: -32005, message: "not_found" } };
        row.reviewed_by = subject;
        return { result: this.sessionJson(row, subject) };
      }

      case "session.pin":
      case "session.unpin": {
        const row = this.rows.get(String(params["session_id"] ?? ""));
        if (!row) return { error: { code: -32005, message: "not_found" } };
        row.pinned = method === "session.pin";
        return { result: this.sessionJson(row, subject) };
      }

      default:
        return { error: { code: -32601, message: "method_not_found", data: { method } } };
    }
  }

  private attachment(row: Row, subject: string, name: string, role: "owner" | "collaborator", mode: string): unknown {
    const scopes = role === "owner" ? ["observe", "control", "admin"] : ["observe", "control"];
    const exp = Math.floor(Date.now() / 1000) + this.podTokenLifetime;
    return {
      session_id: row.id,
      epoch: row.epoch,
      mode,
      endpoint: this.opts.worker.endpoint,
      worker_id: this.opts.worker.workerId,
      pod: `${row.profile}-0`,
      role,
      token: encodeToken({ sub: subject, name, session_id: row.id, role, scopes, aud: this.opts.worker.workerId, exp }),
      expires_at: exp,
    };
  }

  private sessionJson(row: Row, subject: string): unknown {
    const session = this.opts.worker.sessions.get(row.id);
    return {
      id: row.id,
      owner: row.owner,
      profile: row.profile,
      visibility: "team",
      state: row.state,
      epoch: row.epoch,
      title: row.title,
      last_active_at: new Date(row.created_at).toISOString(),
      last_seq: session?.log.headSeq ?? 0,
      head_hash: session?.log.headHash ?? null,
      object_bytes: null,
      workspace_bytes: null,
      pinned: row.pinned,
      // The index, reported by the worker over the control channel — not a replay.
      status: session?.status ?? row.status,
      done_reason: null,
      failed_reason: row.failed_reason,
      pending_approvals: session?.pendingApprovalCount ?? 0,
      cost_micros: session?.costMicros ?? 0,
      origin: row.origin,
      terms: null,
      reviewed_by: row.reviewed_by,
      reviewed_at: row.reviewed_by ? new Date().toISOString() : null,
      your_role: row.owner === subject ? "owner" : "collaborator",
    };
  }
}

/**
 * `fetch` with a browser's same-origin policy in front of it.
 *
 * Node's fetch does not enforce CORS — it is not a browser and has no origin to
 * protect — so a test run here would pass against a plane that refuses every browser.
 * This wrapper does what the browser does: it sends the `Origin` header, and if the
 * answer does not carry an `access-control-allow-origin` naming that origin, the
 * response is not handed to the caller at all. `fetch` rejects with a `TypeError` and
 * the reason stays in a console the page cannot read, which is exactly the blindness
 * `PlaneUnreachableError` exists to translate.
 */
export function browserFetch(origin: string, base: typeof fetch = globalThis.fetch): typeof fetch {
  return async (input, init) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const headers = new Headers(init?.headers);
    headers.set("origin", origin);
    const res = await base(url, { ...init, headers });
    const allowed = res.headers.get("access-control-allow-origin");
    if (allowed !== origin && allowed !== "*") {
      throw new TypeError(`Failed to fetch: ${url} did not allow the origin ${origin}`);
    }
    return res;
  };
}
