// A fake plane: discovery, the login exchange, the harness JSON-RPC, and the CORS
// allowlist — the four things a browser client touches.
//
// It places sessions on a `FakeWorker` and mints pod tokens for it, so a test can go
// from "sign in" to "watch an answer stream" without anything but Node.

import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";
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
  /** A plane from before a person's watch (`/v1/relay/watch`): `remote.list` is asked instead. */
  beforeWatch?: boolean;
  /** What `me.clients` answers: the person's own clients as the plane last saw them. */
  clientsSeen?: Array<Record<string, unknown>>;
  /** What `me.memory` answers: the organisation's and the person's teams' documents. */
  memory?: Array<Record<string, unknown>>;
  /** Each person's own memory document to start with, by subject (#55's user level). */
  own?: Record<string, string>;
  /** What `artifact.*` serves, in any order: the list sorts them, newest published first. */
  artifacts?: FakeArtifact[];
  /** `false` is a plane whose administrator switched artifacts off. */
  artifactsEnabled?: boolean;
  /** Who may publish to the whole organisation. */
  publishOrganisation?: "everyone" | "platform_admins";
  /** Whether an administrator allows public links (`artifacts_public_links`). */
  publicLinks?: boolean;
}

/** A file of an artifact's version, with what it holds, which no answer carries. */
export interface FakeArtifactFile {
  path: string;
  content_type: string;
  content: string;
}

/** A version of an artifact as the fake keeps it. */
export interface FakeArtifactVersion {
  n: number;
  files: FakeArtifactFile[];
  published_by: { subject: string; display_name: string | null };
  published_at: string;
  note?: string | null;
  rolled_back_to?: number | null;
}

/** A link to an artifact as the fake keeps it, token and all. */
export interface FakeArtifactShare {
  id: string;
  artifact: string;
  token: string;
  role: "view" | "edit";
  public: boolean;
  expires_at: string | null;
  revoked_at: string | null;
  created_by: string;
  created_at: string;
  /** Who the plane signed in through it, by subject, and whether the owner revoked them. */
  uses: Array<{ subject: string; at: string; revoked: boolean }>;
}

/** An artifact as the fake keeps it: what `artifact.list` says of it, and its versions. */
export interface FakeArtifact {
  id: string;
  title: string;
  kind: "html" | "markdown" | "file";
  visibility: string;
  owner: { subject: string; display_name: string | null };
  origin: { session_id: string | null; profile: string | null; agent: string | null; where: "pod" | "laptop" | "person" };
  team: string | null;
  created_at: string;
  /** Oldest first, as they were published. */
  versions: FakeArtifactVersion[];
  /** The version its owner pinned, or null for the newest. */
  pinned?: number | null;
  /** The owner's switch for its public links. */
  public_links?: boolean;
}

/** An artifact with the plane's shape: one version of one HTML page, unless told otherwise. */
export function artifact(id: string, owner: { subject: string; display_name: string | null }, fields: Partial<FakeArtifact> = {}): FakeArtifact {
  return {
    id,
    title: id,
    kind: "html",
    visibility: "organisation",
    owner,
    origin: { session_id: null, profile: null, agent: null, where: "person" },
    team: null,
    created_at: "2026-10-25T10:00:00Z",
    versions: [{ n: 1, files: [{ path: "index.html", content_type: "text/html", content: "<h1>A page</h1>" }], published_by: owner, published_at: "2026-10-25T10:00:00Z" }],
    ...fields,
  };
}

/** A person's own memory document as the fake plane keeps it. */
interface OwnMemory {
  version: number;
  text: string;
  changed_by: string | null;
  changed_at: string | null;
}

/** What a save changes, line by line: the lines both keep, then those it drops and adds. */
function lineDiff(before: string, now: string): Array<{ op: "same" | "del" | "add"; text: string }> {
  const a = before === "" ? [] : before.split("\n");
  const b = now === "" ? [] : now.split("\n");
  let same = 0;
  while (same < a.length && same < b.length && a[same] === b[same]) same += 1;
  return [
    ...a.slice(0, same).map((text) => ({ op: "same" as const, text })),
    ...a.slice(same).map((text) => ({ op: "del" as const, text })),
    ...b.slice(same).map((text) => ({ op: "add" as const, text })),
  ];
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
 * A laptop's session offered to the plane for steering (troupe #58). The
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
  readonly initialized: Array<{ name?: unknown; version?: unknown; platform?: unknown }> = [];
  /** Every `/rpc` method asked, in order: what a test counts to tell a push from a poll. */
  readonly asked: string[] = [];
  /** Each person's own memory document, by subject. */
  readonly own = new Map<string, OwnMemory>();
  /** The artifacts published to it, by id. */
  readonly artifacts = new Map<string, FakeArtifact>();
  /** Every `artifact.open` asked, in order, with the link it answered. */
  readonly opened: Array<{ subject: string; id: string; version: number | null; url: string }> = [];
  /** The links made to artifacts, by id. */
  readonly shares = new Map<string, FakeArtifactShare>();
  /** Every `artifact.preview` asked, in order, with what it showed and the address it answered. */
  readonly previews: Array<{ subject: string; id: string; base: number; path: string; text: string; url: string }> = [];
  /**
   * The people's watches open now (`/v1/relay/watch`), with the list each was last sent. A
   * watch is here from the moment its `initialize` is answered, so a change made once a test
   * sees it is pushed behind that answer on the same socket.
   */
  readonly watches = new Set<{ ws: WebSocket; subject: string; sent: string }>();
  private readonly wss: WebSocketServer | null;
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
  /** Refuse a version without signing the refusal, though the plane signs (#657). */
  unsignedRefusals = false;

  private constructor(opts: PlaneOptions) {
    this.opts = opts;
    for (const [subject, text] of Object.entries(opts.own ?? {})) {
      this.own.set(subject, { version: 1, text, changed_by: subject, changed_at: "2026-10-24T09:00:00Z" });
    }
    for (const a of opts.artifacts ?? []) this.artifacts.set(a.id, a);
    this.corsOrigins = opts.corsOrigins ?? [];
    this.podTokenLifetime = opts.podTokenLifetime ?? 900;
    this.server = createServer((req, res) => void this.handle(req, res));
    this.wss = opts.beforeWatch ? null : new WebSocketServer({ server: this.server, path: "/v1/relay/watch" });
    this.wss?.on("connection", (ws) => this.onWatch(ws));
  }

  /**
   * A person's watch on the laptop sessions offered to them, as the plane's
   * `Troupe.Plane.Remote.Watch` keeps it: `initialize` with a plane token answers the list,
   * and each change that alters it is sent as `remote.changed`.
   */
  private onWatch(ws: WebSocket): void {
    let watch: { ws: WebSocket; subject: string; sent: string } | null = null;
    const send = (payload: unknown) => ws.readyState === ws.OPEN && ws.send(JSON.stringify(payload));
    ws.on("close", () => watch && this.watches.delete(watch));
    ws.on("message", (raw) => {
      let msg: { id?: number | string; method?: string; params?: Record<string, unknown> };
      try {
        msg = JSON.parse(String(raw)) as typeof msg;
      } catch {
        return;
      }
      const params = msg.params ?? {};
      const held = (token: unknown) => {
        const t = typeof token === "string" ? this.tokens.get(token) : undefined;
        return t && t.exp * 1000 > Date.now() ? t : null;
      };
      if (msg.method === "initialize") {
        const person = held((params["auth"] as { token?: unknown } | undefined)?.token);
        if (!person) {
          send({ jsonrpc: "2.0", id: msg.id, error: { code: -32003, message: "unauthenticated" } });
          return void ws.close(1000);
        }
        const sessions = this.remoteRows(person.subject);
        watch = { ws, subject: person.subject, sent: JSON.stringify(sessions) };
        this.watches.add(watch);
        return void send({
          jsonrpc: "2.0",
          id: msg.id,
          result: {
            protocol_version: "1",
            server_info: { name: "troupe-plane", watch: "remote" },
            principal: { subject: person.subject, display_name: person.name },
            scopes: [],
            capabilities: { remote_changed: true },
            auth: { expires_at: person.exp },
            sessions,
          },
        });
      }
      if (!watch) return void send({ jsonrpc: "2.0", id: msg.id, error: { code: -32001, message: "not_initialized" } });
      if (msg.method === "remote.list") return void send({ jsonrpc: "2.0", id: msg.id, result: { sessions: this.remoteRows(watch.subject) } });
      if (msg.method === "auth.refresh") {
        const person = held((params["auth"] as { token?: unknown } | undefined)?.token);
        if (!person || person.subject !== watch.subject) return void send({ jsonrpc: "2.0", id: msg.id, error: { code: -32003, message: "unauthenticated" } });
        return void send({ jsonrpc: "2.0", id: msg.id, result: { auth: { expires_at: person.exp } } });
      }
      if (msg.id !== undefined) send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method_not_found" } });
    });
  }

  /** Tell every watch whose list this changed. */
  private changed(): void {
    for (const w of this.watches) {
      const sessions = this.remoteRows(w.subject);
      const said = JSON.stringify(sessions);
      if (said === w.sent) continue;
      w.sent = said;
      if (w.ws.readyState === w.ws.OPEN) w.ws.send(JSON.stringify({ jsonrpc: "2.0", method: "remote.changed", params: { sessions } }));
    }
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

  /** Change the version policy from now on, as an administrator does on the console. */
  setClientVersions(versions: NonNullable<PlaneOptions["clientVersions"]>): void {
    this.opts.clientVersions = versions;
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
      expires_at: new Date(now.getTime() + (kind === "update_required" ? 3600 : 7 * 24 * 3600) * 1000).toISOString().replace(/\.\d+Z$/, "Z"),
      body,
    });
    const signature = Buffer.from(await crypto.subtle.sign({ name: "Ed25519" }, this.signing.privateKey, new TextEncoder().encode(document))).toString("base64");
    return { ...answer, signed: { algorithm: "ed25519", fingerprint: this.signing.fingerprint, document, signature } };
  }

  async stop(): Promise<void> {
    for (const w of this.watches) w.ws.terminate();
    this.watches.clear();
    if (this.wss) await new Promise<void>((r) => this.wss!.close(() => r()));
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
    this.changed();
    return offer;
  }

  /** The laptop went: offline since now, or `at`; `null` brings it back. */
  offline(id: string, at: string | null = new Date().toISOString()): void {
    const offer = this.relayed.get(id);
    if (!offer) throw new Error(`no relayed session ${id}`);
    offer.offlineSince = at;
    this.changed();
  }

  /** The laptop's person withdrew it: gone from every list. */
  withdraw(id: string): void {
    this.relayed.delete(id);
    this.changed();
  }

  /** The laptop's person shared it anew. */
  share(id: string, shares: Relayed["shares"]): void {
    const offer = this.relayed.get(id);
    if (!offer) throw new Error(`no relayed session ${id}`);
    offer.shares = shares;
    this.changed();
  }

  /** The person's `remote.list`, as the plane answers it. */
  private ownOf(subject: string): OwnMemory {
    return this.own.get(subject) ?? { version: 0, text: "", changed_by: null, changed_at: null };
  }

  private ownJson(own: OwnMemory): Record<string, unknown> {
    return { ...own, hash: own.version ? `sha256:own-${own.version}` : null, bytes: new TextEncoder().encode(own.text).length, limit: 8192 };
  }

  /** Whether this person may see this artifact: their own, the organisation's, a profile of theirs, or a link's. */
  private mayRead(a: FakeArtifact, subject: string): boolean {
    return this.roleOf(a, subject) !== null;
  }

  /** What this person is to it: its owner, an edit link's holder, or one who may view it. */
  private roleOf(a: FakeArtifact, subject: string): "owner" | "edit" | "view" | null {
    if (a.owner.subject === subject) return "owner";
    const linked = this.linkRole(a, subject);
    if (linked === "edit") return "edit";
    if (linked === "view" || a.visibility === "organisation") return "view";
    const profile = a.visibility.startsWith("profile:") ? a.visibility.slice("profile:".length) : null;
    return profile !== null && (this.opts.profiles ?? ["dev", "ux"]).includes(profile) ? "view" : null;
  }

  private liveShare(sh: FakeArtifactShare): boolean {
    return !sh.revoked_at && (!sh.expires_at || Date.parse(sh.expires_at) > Date.now());
  }

  private linkRole(a: FakeArtifact, subject: string): "edit" | "view" | null {
    let role: "edit" | "view" | null = null;
    for (const sh of this.shares.values()) {
      if (sh.artifact !== a.id || !this.liveShare(sh) || !sh.uses.some((u) => u.subject === subject && !u.revoked)) continue;
      role = sh.role === "edit" || role === "edit" ? "edit" : "view";
    }
    return role;
  }

  private isPublic(a: FakeArtifact): boolean {
    return (this.opts.publicLinks ?? false) && a.public_links !== false && [...this.shares.values()].some((sh) => sh.artifact === a.id && sh.public && this.liveShare(sh));
  }

  private shareJson(sh: FakeArtifactShare): Record<string, unknown> {
    const state = sh.revoked_at ? "revoked" : sh.expires_at && Date.parse(sh.expires_at) <= Date.now() ? "expired" : sh.public && !this.opts.publicLinks ? "switched off" : "live";
    return {
      id: sh.id,
      role: sh.role,
      public: sh.public,
      state,
      expires_at: sh.expires_at,
      revoked_at: sh.revoked_at,
      created_by: sh.created_by,
      created_at: sh.created_at,
      used_by: sh.uses.map((u) => ({ person: { subject: u.subject, display_name: u.subject }, first_used_at: u.at, last_used_at: u.at, revoked_at: u.revoked ? u.at : null })),
    };
  }

  private publish(a: FakeArtifact, subject: string, files: FakeArtifactFile[], extra: Partial<FakeArtifactVersion> = {}): void {
    const n = a.versions[a.versions.length - 1]!.n + 1;
    a.versions.push({ n, files, published_by: { subject, display_name: subject }, published_at: new Date(Date.parse("2026-10-25T10:00:00Z") + n * 60_000).toISOString(), note: null, rolled_back_to: null, ...extra });
  }

  /** An artifact as `artifact.list` answers it to this person: never a file's content. */
  private artifactJson(a: FakeArtifact, subject: string): Record<string, unknown> {
    const latest = a.versions[a.versions.length - 1]!;
    const { versions: _versions, ...shown } = a;
    return {
      ...shown,
      mine: a.owner.subject === subject,
      role: this.roleOf(a, subject),
      version: latest.n,
      current: a.pinned ?? latest.n,
      pinned: a.pinned ?? null,
      may_edit: ["owner", "edit"].includes(this.roleOf(a, subject) ?? ""),
      public_links: a.public_links !== false,
      public: this.isPublic(a),
      bytes: latest.files.reduce((n, f) => n + new TextEncoder().encode(f.content).length, 0),
      url: `https://artifacts.example.test/a/${a.id}/`,
      published_at: latest.published_at,
      may_delete: a.owner.subject === subject || this.opts.admin?.role(subject) === "platform_admin",
    };
  }

  /** Its versions, newest first, each with its files described and none of what they hold. */
  private artifactVersions(a: FakeArtifact): Array<Record<string, unknown>> {
    return [...a.versions]
      .sort((x, y) => y.n - x.n)
      .map((v) => {
        const files = v.files.map((f) => ({ path: f.path, sha256: `sha256:${a.id}-${v.n}-${f.path}`, content_type: f.content_type, bytes: new TextEncoder().encode(f.content).length }));
        return {
          n: v.n,
          hash: `sha256:${a.id}-${v.n}`,
          bytes: files.reduce((n, f) => n + f.bytes, 0),
          files,
          published_by: v.published_by,
          published_at: v.published_at,
          note: v.note ?? null,
          rolled_back_to: v.rolled_back_to ?? null,
          url: `https://artifacts.example.test/a/${a.id}/v${v.n}/`,
        };
      });
  }

  private remoteRows(subject: string): Array<Record<string, unknown>> {
    return [...this.relayed.values()].flatMap((o) => {
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
      this.asked.push(method);
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
      // A refusal of a version, signed as `update_required` where the plane has a key.
      if ("error" in answer && answer.error.code === -32016 && !this.unsignedRefusals) {
        const data = answer.error.data as Record<string, unknown>;
        answer = { error: { ...answer.error, data: await this.signed("update_required", data, data) } };
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
        const info = (params["client_info"] ?? {}) as { name?: unknown; version?: unknown; platform?: unknown };
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

      case "remote.list":
        return { result: { sessions: this.remoteRows(subject) } };

      // A person's own clients, as the plane last saw them, against its policy now.
      case "me.clients":
        return { result: { clients: this.opts.clientsSeen ?? [] } };

      // The memory a person's machine reads into every session: signed, as the plane signs it.
      case "me.memory": {
        const own = this.ownOf(subject);
        const mine = own.text === "" ? [] : [{ scope: "user", name: null, version: own.version, hash: `sha256:own-${own.version}`, updated_at: own.changed_at, text: own.text }];
        return { result: { documents: [...(this.opts.memory ?? []), ...mine], user: this.ownJson(own) } };
      }

      // A person's own memory: what a save would change, written nowhere; and the save, over
      // the version edited, refused where somebody saved since.
      case "me.memory.preview": {
        const own = this.ownOf(subject);
        const text = String(params["text"] ?? "").replace(/\r\n/g, "\n").trimEnd();
        const bytes = new TextEncoder().encode(text).length;
        if (bytes > 8192) return { error: { code: -32602, message: "invalid_params", data: { reason: `a memory document holds at most 8192 bytes; this one is ${bytes}` } } };
        return {
          result: {
            version: own.version,
            bytes,
            limit: 8192,
            unchanged: own.text === text,
            diff: lineDiff(own.text, text),
            effect: "Every session you run reads it from its next turn. Nobody else reads it.",
          },
        };
      }

      case "me.memory.put": {
        const own = this.ownOf(subject);
        const text = String(params["text"] ?? "").replace(/\r\n/g, "\n").trimEnd();
        if (params["version"] !== own.version) {
          return { error: { code: -32006, message: "conflict", data: { reason: `your memory was saved somewhere else since; version ${own.version} is in force now`, version: own.version } } };
        }
        if (text === own.text) return { result: { changed: false, entry: null, user: this.ownJson(own) } };
        const now = { version: own.version + 1, text, changed_by: subject, changed_at: new Date().toISOString() };
        this.own.set(subject, now);
        return { result: { changed: true, entry: null, user: this.ownJson(now) } };
      }

      // Artifacts, as any signed-in person asks for them: the list, one with its versions, a
      // one-time link to open it on the artifacts host, and its deletion by its owner or a
      // platform admin's takedown. No answer carries what a file holds.
      case "artifact.list": {
        const enabled = this.opts.artifactsEnabled ?? true;
        const rows = enabled
          ? [...this.artifacts.values()]
              .filter((a) => this.mayRead(a, subject))
              .filter((a) => params["mine"] !== true || a.owner.subject === subject)
              .filter((a) => params["shared"] !== true || (a.owner.subject !== subject && this.linkRole(a, subject) !== null))
              .filter((a) => typeof params["visibility"] !== "string" || a.visibility === params["visibility"])
              .map((a) => this.artifactJson(a, subject))
              .sort((x, y) => String(y["published_at"]).localeCompare(String(x["published_at"])))
          : [];
        return {
          result: { enabled, profiles, publish_organisation: this.opts.publishOrganisation ?? "everyone", public_links: this.opts.publicLinks ?? false, gallery_url: `${this.url}/console#/artifacts`, artifacts: rows },
        };
      }

      case "artifact.get": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || !this.mayRead(a, subject)) return { error: { code: -32005, message: "not_found" } };
        const shares = a.owner.subject === subject ? { shares: [...this.shares.values()].filter((sh) => sh.artifact === a.id).map((sh) => this.shareJson(sh)), public_links_allowed: this.opts.publicLinks ?? false } : {};
        return { result: { ...this.artifactJson(a, subject), versions: this.artifactVersions(a), ...shares } };
      }

      // A version, a rollback and a pin; one text file read for an editor and an edit's
      // preview; links made, spent, listed and revoked; the owner's public-links switch.
      case "artifact.put": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || !this.mayRead(a, subject)) return { error: { code: -32005, message: "not_found" } };
        if (!["owner", "edit"].includes(this.roleOf(a, subject) ?? "")) return { error: { code: -32004, message: "forbidden", data: { reason: "only its owner, or somebody the owner gave an edit link, publishes a new version of an artifact" } } };
        const newest = a.versions[a.versions.length - 1]!;
        const base = typeof params["base"] === "number" ? params["base"] : null;
        if (base !== null && base !== newest.n) return { error: { code: -32009, message: "conflict", data: { reason: `version ${newest.n} was published after version ${base}, which this edit was made on; open version ${newest.n} and make the edit again` } } };
        const sent = ((params["files"] as Array<{ path: string; bytes: string; content_type?: string }> | undefined) ?? []).map((f) => ({ path: f.path, content_type: f.content_type ?? (f.path.endsWith(".md") ? "text/markdown" : "text/html"), content: Buffer.from(f.bytes, "base64").toString("utf8") }));
        const kept = base === null ? [] : newest.files.filter((f) => !sent.some((x) => x.path === f.path));
        this.publish(a, subject, [...kept, ...sent].sort((x, y) => x.path.localeCompare(y.path)), { note: typeof params["note"] === "string" ? params["note"] : null });
        return { result: { ...this.artifactJson(a, subject), versions: this.artifactVersions(a) } };
      }

      case "artifact.rollback": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || !this.mayRead(a, subject)) return { error: { code: -32005, message: "not_found" } };
        if (!["owner", "edit"].includes(this.roleOf(a, subject) ?? "")) return { error: { code: -32004, message: "forbidden" } };
        const old = a.versions.find((v) => v.n === params["version"]);
        if (!old) return { error: { code: -32005, message: "not_found" } };
        this.publish(a, subject, old.files, { note: `rolled back to v${old.n}`, rolled_back_to: old.n });
        return { result: { ...this.artifactJson(a, subject), versions: this.artifactVersions(a) } };
      }

      case "artifact.pin": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || !this.mayRead(a, subject)) return { error: { code: -32005, message: "not_found" } };
        if (a.owner.subject !== subject) return { error: { code: -32004, message: "forbidden", data: { reason: "only its owner pins a version of an artifact" } } };
        a.pinned = typeof params["version"] === "number" ? params["version"] : null;
        return { result: { ...this.artifactJson(a, subject), versions: this.artifactVersions(a) } };
      }

      case "artifact.read": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || !this.mayRead(a, subject)) return { error: { code: -32005, message: "not_found" } };
        const n = typeof params["version"] === "number" ? params["version"] : (a.pinned ?? a.versions[a.versions.length - 1]!.n);
        const v = a.versions.find((x) => x.n === n);
        const f = v?.files.find((x) => x.path === params["path"]);
        if (!v || !f) return { error: { code: -32005, message: "not_found" } };
        return { result: { id: a.id, version: v.n, path: f.path, content_type: f.content_type, text: f.content } };
      }

      case "artifact.preview": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || !this.mayRead(a, subject)) return { error: { code: -32005, message: "not_found" } };
        if (!["owner", "edit"].includes(this.roleOf(a, subject) ?? "")) return { error: { code: -32004, message: "forbidden" } };
        const url = `https://artifacts.example.test/p/preview-${++this.counter}/`;
        this.previews.push({ subject, id: a.id, base: Number(params["base"]), path: String(params["path"]), text: String(params["text"]), url });
        return { result: { url, expires_in: 3600 } };
      }

      case "artifact.share": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || !this.mayRead(a, subject)) return { error: { code: -32005, message: "not_found" } };
        if (a.owner.subject !== subject) return { error: { code: -32004, message: "forbidden", data: { reason: "only its owner shares an artifact" } } };
        const pub = params["public"] === true;
        if (pub && !this.opts.publicLinks) return { error: { code: -32004, message: "forbidden", data: { reason: "public links are switched off on this plane; an administrator turns them on with artifacts_public_links under Policy and settings" } } };
        if (pub && typeof params["expires"] !== "string") return { error: { code: -32602, message: "invalid_params", data: { reason: "a public link needs an expiry (expires), at most 90 days away" } } };
        const n = ++this.counter;
        const sh: FakeArtifactShare = {
          id: `share-${n}`,
          artifact: a.id,
          token: `token-${n}-abcdefghijklmnopqrstuvwxyz`,
          role: params["role"] === "edit" ? "edit" : "view",
          public: pub,
          expires_at: typeof params["expires"] === "string" ? params["expires"] : null,
          revoked_at: null,
          created_by: subject,
          created_at: "2026-10-25T12:00:00Z",
          uses: [],
        };
        this.shares.set(sh.id, sh);
        const url = `https://artifacts.example.test/s/${sh.token}${pub ? "/" : ""}`;
        return { result: { token: sh.token, url, share: this.shareJson(sh) } };
      }

      case "artifact.unshare": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || a.owner.subject !== subject) return { error: { code: -32004, message: "forbidden" } };
        if (typeof params["share"] === "string") {
          const sh = this.shares.get(params["share"]);
          if (!sh || sh.artifact !== a.id) return { error: { code: -32005, message: "not_found" } };
          sh.revoked_at = "2026-10-25T13:00:00Z";
          return { result: { revoked: true, id: a.id, share: sh.id } };
        }
        for (const sh of this.shares.values()) if (sh.artifact === a.id) for (const u of sh.uses) if (u.subject === params["person"]) u.revoked = true;
        return { result: { revoked: true, id: a.id, person: params["person"] } };
      }

      case "artifact.redeem": {
        const sh = [...this.shares.values()].find((x) => x.token === params["token"] && this.liveShare(x));
        if (!sh || sh.uses.some((u) => u.subject === subject && u.revoked)) return { error: { code: -32005, message: "not_found", data: { reason: "this link has expired, was revoked, or is not one" } } };
        if (!sh.uses.some((u) => u.subject === subject)) sh.uses.push({ subject, at: "2026-10-25T12:30:00Z", revoked: false });
        const url = `https://artifacts.example.test/enter?ticket=t-${++this.counter}`;
        this.opened.push({ subject, id: sh.artifact, version: null, url });
        return { result: { id: sh.artifact, role: sh.role, url } };
      }

      case "artifact.public": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || a.owner.subject !== subject) return { error: { code: -32004, message: "forbidden" } };
        a.public_links = params["enabled"] === true;
        return { result: { ...this.artifactJson(a, subject), versions: this.artifactVersions(a) } };
      }

      case "artifact.open": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || !this.mayRead(a, subject)) return { error: { code: -32005, message: "not_found" } };
        const version = typeof params["version"] === "number" ? params["version"] : null;
        if (version !== null && !a.versions.some((v) => v.n === version)) return { error: { code: -32005, message: "not_found" } };
        const url = `https://artifacts.example.test/enter?ticket=t-${++this.counter}`;
        this.opened.push({ subject, id: a.id, version, url });
        return { result: { url, expires_in: 60 } };
      }

      case "artifact.delete": {
        const a = this.artifacts.get(String(params["id"] ?? ""));
        if (!a || !this.mayRead(a, subject)) return { error: { code: -32005, message: "not_found" } };
        if (a.owner.subject !== subject && this.opts.admin?.role(subject) !== "platform_admin") {
          return { error: { code: -32004, message: "forbidden", data: { reason: "only its owner or a platform admin deletes an artifact" } } };
        }
        this.artifacts.delete(a.id);
        return { result: { deleted: true, id: a.id } };
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
