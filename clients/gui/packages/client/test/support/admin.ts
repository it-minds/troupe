// The fake plane's administrative half: the `admin.*` methods the console calls, with the
// plane's two roles, its refusals and its audit, and nothing a screen needs that the plane
// does not do.
//
// It follows `Troupe.Plane.Admin` rather than a screen: a team admin asking for a team
// that is not theirs is told it is not found, a platform admin's write by anybody else is
// `forbidden` with the role it wanted, a team's laddered value wider than the rungs above
// it is refused with the ceiling quoted, and every write answers the audit's own diff and
// records it. A console that is right against this is right against the plane's rules,
// which `apps/troupe_plane/test` holds the plane to.

import { older } from "./plane.js";

type Refusal = { error: { code: number; message: string; data?: unknown } };
type Answer = { result: unknown } | Refusal;
type Role = "platform_admin" | "team_admin" | "none";
type Changes = Record<string, { from: unknown; to: unknown }>;

const FORBIDDEN = -32004;
const NOT_FOUND = -32005;
const INVALID_PARAMS = -32602;
const METHOD_NOT_FOUND = -32601;
const MANAGED_BY_GITOPS = -32015;

/** The size classes, with what each is for, as `Fleet.SizeClass` says. */
const SIZE_CLASSES: Record<string, string> = {
  standard: "Several sessions share a worker. Right for most work.",
  heavy: "Fewer sessions to a worker, each with more CPU, memory and disk: large repositories, builds and long runs.",
};

/** A trigger's fields `admin.trigger.put` writes, and what an absent one is on a new trigger. */
const TRIGGER_KEYS = ["principal", "profile", "agent", "enabled", "source", "prompt_template", "terms", "visibility", "review", "notify", "notify_url", "concurrency"] as const;
const TRIGGER_DEFAULTS: Record<string, unknown> = { enabled: true, visibility: "team", review: "required", notify: [], concurrency: 1 };

/** The `llm` fields a profile may set only beside `llm.endpoint`. */
const LLM_FIELDS = ["provider", "model", "smallModel", "secretRef", "prices"];

/** The plane's sentence for `llm` settings without an endpoint, or null where they have one or set nothing. */
export function llmProblem(llm: Record<string, unknown>): string | null {
  const empty = (v: unknown) => v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0) || (typeof v === "object" && v !== null && Object.keys(v).length === 0);
  const set = LLM_FIELDS.filter((f) => !empty(llm[f])).map((f) => `llm.${f}`);
  if (set.length === 0 || !empty(llm["endpoint"])) return null;
  const listed = set.length === 1 ? set[0] : `${set.slice(0, -1).join(", ")} and ${set.at(-1)}`;
  const [verb, pronoun] = set.length === 1 ? ["is", "it"] : ["are", "them"];
  return `${listed} ${verb} set without llm.endpoint, and the pods are given the llm settings only with an endpoint: without one they would run on Troupe's built-in model settings instead. Set llm.endpoint, or take ${pronoun} out`;
}

function hostOf(url: unknown): string | null {
  if (typeof url !== "string") return null;
  try {
    const host = new URL(url).hostname;
    return host === "" ? null : host;
  } catch {
    return null;
  }
}

/** A stable content hash, shaped as the plane's: the same document, the same hash. */
function hashOf(value: unknown): string {
  const text = canonical(value);
  let a = 0x811c9dc5;
  let b = 0x01000193;
  for (let i = 0; i < text.length; i++) {
    a = Math.imul(a ^ text.charCodeAt(i), 0x01000193) >>> 0;
    b = Math.imul(b ^ text.charCodeAt(text.length - 1 - i), 0x811c9dc5) >>> 0;
  }
  return `sha256:${a.toString(16).padStart(8, "0")}${b.toString(16).padStart(8, "0")}`;
}

function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (typeof value === "object" && value !== null) {
    return `{${Object.keys(value)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical((value as Record<string, unknown>)[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value ?? null);
}

function revisionJson(r: { revision: number; hash: string; created_by: string; created_at: string }): Record<string, unknown> {
  return { id: `rev-${r.revision}-${r.hash.slice(7, 15)}`, revision: r.revision, hash: r.hash, reconstructed: false, created_by: r.created_by, created_at: r.created_at };
}

const SECTIONS = { agents: "agent", skills: "skill", mcp_servers: "mcp_server", acp_agents: "acp_agent" } as const;
type Section = keyof typeof SECTIONS;

function entries(content: unknown, section: Section): Array<Record<string, unknown>> {
  const list = (content as Record<string, unknown> | null)?.[section];
  return Array.isArray(list) ? (list as Array<Record<string, unknown>>) : [];
}

/** What a bundle carries, by name, as `Troupe.Protocol.Bundle.summary/1` says. */
function bundleSummaryOf(content: Record<string, unknown>): Record<string, unknown> {
  return {
    schema: content["schema"] ?? 0,
    agents: entries(content, "agents").map((e) => e["name"]),
    skills: entries(content, "skills").map((e) => e["name"]),
    mcp_servers: entries(content, "mcp_servers").map((e) => e["name"]),
    acp_agents: entries(content, "acp_agents").map((e) => e["name"]),
  };
}

/** Everything a version carries but its files' text, as `Bundles.describe/1` reads it. */
function describeBundle(content: Record<string, unknown>): Record<string, unknown> {
  const front = (definition: unknown, key: string): string | null => {
    const m = typeof definition === "string" ? new RegExp(`^${key}:\\s*(.+)$`, "m").exec(definition) : null;
    return m ? m[1]!.trim() : null;
  };
  return {
    schema: content["schema"] ?? 0,
    agents: entries(content, "agents").map((a) => ({ name: a["name"], mode: front(a["definition"], "mode"), description: front(a["definition"], "description"), skills: a["skills"] ?? [] })),
    skills: entries(content, "skills").map((s) => ({ name: s["name"], description: s["description"] ?? null, files: Object.keys((s["files"] ?? {}) as Record<string, unknown>).sort() })),
    mcp_servers: entries(content, "mcp_servers").map((m) => ({
      name: m["name"],
      url: m["url"],
      credential_ref: m["credential_ref"] ?? null,
      header: m["header"] ?? "authorization",
      permission: m["permission"] ?? "ask",
      tools: m["tools"] ?? null,
      secret: m["credential_ref"] ? `troupe-mcp-${String(m["name"])}` : null,
    })),
  };
}

/** What publishing would refuse, a sentence each, as the plane's `data.errors`. */
function bundleProblems(content: unknown, egress: string[]): string[] {
  if (typeof content !== "object" || content === null || Array.isArray(content)) return ["a bundle is a JSON object"];
  const doc = content as Record<string, unknown>;
  const out: string[] = [];
  if (doc["schema"] !== undefined && doc["schema"] !== 1) out.push(`schema ${JSON.stringify(doc["schema"])} is not one this plane reads; it reads 1`);
  for (const section of Object.keys(SECTIONS) as Section[]) {
    if (doc[section] !== undefined && !Array.isArray(doc[section])) {
      out.push(`${section} is a list`);
      continue;
    }
    const seen = new Set<string>();
    for (const e of entries(doc, section)) {
      const name = e["name"];
      if (typeof name !== "string" || !/^[a-z0-9-]+$/.test(name)) out.push(`${section}: ${JSON.stringify(name)} is not a name: lowercase letters, digits and dashes`);
      else if (seen.has(name)) out.push(`${section}: ${name} is named twice`);
      else seen.add(name);
    }
  }
  const skills = new Set(entries(doc, "skills").map((s) => s["name"]));
  for (const a of entries(doc, "agents")) {
    if (typeof a["definition"] !== "string" || a["definition"].trim() === "") out.push(`agent ${String(a["name"])} has no definition`);
    for (const s of (a["skills"] ?? []) as unknown[]) if (!skills.has(s)) out.push(`agent ${String(a["name"])} lists the skill ${String(s)}, which this bundle does not have`);
  }
  for (const s of entries(doc, "skills")) {
    if (typeof (s["files"] as Record<string, unknown> | undefined)?.["SKILL.md"] !== "string") out.push(`skill ${String(s["name"])} has no SKILL.md`);
  }
  for (const m of entries(doc, "mcp_servers")) {
    const url = typeof m["url"] === "string" ? m["url"] : "";
    const host = hostOf(url);
    if (!host || !(url.startsWith("https://") || (url.startsWith("http://") && /\.svc(\.cluster\.local)?$/.test(host)))) {
      out.push(`mcp server ${String(m["name"])}: its url is https://, or http:// to a cluster-internal .svc host`);
    } else if (!(egress.includes(host) || /\.svc(\.cluster\.local)?$/.test(host))) {
      out.push(`mcp server ${String(m["name"])}: the cluster policy does not let a pod reach ${host}`);
    }
  }
  return out;
}

/** Every entry the earlier summary had that the later one does not, by the kind a grant names. */
function removedEntries(before: Record<string, unknown>, after: Record<string, unknown>): Array<{ kind: string; name: string }> {
  return (Object.keys(SECTIONS) as Section[]).flatMap((section) =>
    ((before[section] ?? []) as string[]).filter((n) => !((after[section] ?? []) as string[]).includes(n)).map((name) => ({ kind: SECTIONS[section], name })),
  );
}

export interface FakeTeam {
  name: string;
  budget_micros: number | null;
  budget_period: string | null;
  spent_micros: number;
  reserved_micros: number;
  members_may_control: boolean | null;
  idle_timeout_seconds: number | null;
  cache_eviction_days: number | null;
  erase_after_days: number | null;
  pins_allowed: boolean | null;
  volume_storage_class: string | null;
  volume_size: string | null;
  allow_unenforced_workers: boolean;
  admins: string[];
  grants: Array<{ profile: string; volume_mode: string | null }>;
  groups: Array<{ external_id: string; display_name: string | null; issuer: string | null; linked_by: string | null }>;
  members: Array<{ subject: string; display_name: string | null; budget_micros: number | null; spent_micros: number; reserved_micros: number }>;
  spend_by_model: Array<Record<string, unknown>>;
  principals: string[];
  triggers: string[];
}

/** A pod behind a profile, as the plane's summary of a profile lists it. */
export interface FakePod {
  pod: string;
  ordinal: number;
  healthy: boolean;
  draining: boolean;
  last_seen_at: string | null;
  capacity: number;
  active_sessions: number;
  disk_fraction: number | null;
  version: string | null;
  bundle_hash: string | null;
  worker_id: string;
}

/** A worker profile, with what `admin.profiles.list` and `admin.overview` say of it. */
export interface FakeProfile {
  name: string;
  size_class: string;
  replicas: number;
  sessions_per_pod: number;
  channel: string | null;
  image: string | null;
  provisioner: string;
  /** The guarantees its substrate does not give; a grant to a team needs a platform admin's say-so when it gives none. */
  missing_guarantees: string[];
  unenforced: boolean;
  pods: FakePod[];
  max_sessions?: number | null;
  warm_workers?: number;
  /** The rest of the WorkerProfile spec, in the resource's camelCase, as `admin.profile.put` was sent it. */
  spec?: Record<string, unknown>;
  /** On a gitops plane: the resource generation it was read at, and what the last pass said of it. */
  gitops?: { generation: number | null; problem: string | null; reasons: string[] };
}

/** One published version of a configuration channel. */
export interface FakeBundle {
  channel: string;
  version: number;
  hash: string;
  content: Record<string, unknown>;
  published_at: string;
  published_by: string;
  retired_at: string | null;
}

/** A team's trigger, as the plane keeps one, with its revisions. */
export interface FakeTrigger {
  id: string;
  team: string;
  name: string;
  principal: string;
  profile: string;
  agent: string | null;
  enabled: boolean;
  source: Record<string, unknown>;
  prompt_template: string | null;
  terms: Record<string, unknown> | null;
  visibility: string;
  review: string;
  notify: string[];
  notify_url: string | null;
  concurrency: number;
  last_fired_at: string | null;
  created_by: string;
  updated_at: string;
  revisions: Array<{ revision: number; hash: string; created_by: string; created_at: string; document: Record<string, unknown> }>;
  gitops?: { generation: number | null; problem: string | null; reasons: string[] };
}

/** An entitlement row: what a team may use of a bundle on a profile, which a publish can take away. */
export interface FakeEntitlement {
  team: string;
  profile: string;
  kind: "agent" | "skill" | "mcp_server" | "acp_agent";
  name: string;
  mode: "allow" | "deny";
}

/**
 * A session as the plane keeps one. Its team, where it came from and whether a person has
 * read it are the plane's to know; what an admin method answers is `sessionJson`, which,
 * as the plane's own summary, names no team and no cost.
 */
export interface FakeSession {
  id: string;
  owner: string;
  team: string | null;
  profile: string;
  state: "active" | "dormant" | "read_only" | "erased" | "erasure_pending";
  visibility: "private" | "team";
  last_seq: number;
  object_bytes: number;
  workspace_bytes: number;
  pinned: boolean;
  pinned_by: string | null;
  last_active_at: string;
  parent: string | null;
  origin: "user" | "trigger";
  reviewed: boolean;
  repository?: { owner: string; name: string; ref?: string | null } | null;
  github?: Record<string, unknown> | null;
}

interface Setting {
  key: string;
  group: string;
  type: "string" | "enum" | "integer" | "boolean" | "enforced";
  values?: string[];
  summary: string;
  consequence: string;
  fallback?: unknown;
}

/** A setting more than one rung decides: the team's column, and which way narrower runs. */
interface Laddered {
  field: string;
  narrower: "lower" | "off";
  deployed: number | boolean;
}

/** The keys an enforced set may hold, as `Troupe.Protocol.Organisation` lists them. */
export const ENFORCEABLE = [
  { key: "approvals", kind: "order", order: ["wait", "deny"], meaning: "the loosest it may be", type: "enum", values: ["wait", "deny"] },
  { key: "provider", kind: "fixed", meaning: "what it is", type: "enum", values: ["anthropic", "openai", "fake"] },
  { key: "base_url", kind: "fixed", meaning: "what it is", type: "string" },
  { key: "managed_mcp_servers_only", kind: "order", order: [false, true], meaning: "the loosest it may be", type: "boolean" },
  { key: "managed_permission_rules_only", kind: "order", order: [false, true], meaning: "the loosest it may be", type: "boolean" },
  { key: "max_tokens", kind: "ceiling", meaning: "the most it may be", type: "integer", min: 1 },
  { key: "max_turns", kind: "ceiling", meaning: "the most it may be", type: "integer", min: 1 },
  { key: "wall_clock_ms", kind: "ceiling", meaning: "the most it may be", type: "integer", min: 1 },
  { key: "max_depth", kind: "ceiling", meaning: "the most it may be", type: "integer", min: 0 },
] as const;

const SETTINGS: Setting[] = [
  {
    key: "client_provider",
    group: "client_defaults",
    type: "enum",
    values: ["anthropic", "openai"],
    summary: "The provider people's own machines use: Anthropic's API, or anything that speaks OpenAI's Chat Completions.",
    consequence: "Unset means the clients offer no organisation defaults at all.",
  },
  { key: "client_base_url", group: "client_defaults", type: "string", summary: "Where that provider is: a gateway's URL, or empty for the provider's own API.", consequence: "An OpenAI-compatible provider needs one." },
  {
    key: "client_auth",
    group: "client_defaults",
    type: "enum",
    values: ["api_key", "bearer"],
    fallback: "api_key",
    summary: "How the key is presented: the provider's own header, or Authorization: Bearer for a gateway.",
    consequence: "Wrong, and every request from a machine using the defaults is refused as unauthenticated.",
  },
  { key: "client_model_default", group: "client_defaults", type: "string", summary: "The model that does the editing, as the provider names it.", consequence: "Pre-filled as the default model." },
  { key: "client_model_cheap", group: "client_defaults", type: "string", summary: "The cheaper model for exploring, summarising and quick questions.", consequence: "Pre-filled as the cheap model." },
  { key: "client_model_expensive", group: "client_defaults", type: "string", summary: "The premium model an orchestrating agent may ask for, if there is one.", consequence: "Pre-filled as the expensive model." },
  {
    key: "client_enforced",
    group: "client_defaults",
    type: "enforced",
    summary: "What people's own machines may not go past, as a JSON object.",
    consequence: "A number is a ceiling a machine may lower and not raise. Any other key is refused.",
  },
];

const GROUPS = [
  { key: "team_defaults", title: "What a new team starts with", blurb: "Applied when a group is enabled as a team." },
  {
    key: "client_defaults",
    title: "What people's own machines talk to",
    blurb:
      "The organisation's defaults for a person's local sessions, below their own settings: provider, URL and models. Never a key; each person pastes their own. And what those sessions may not go past, above everything a person sets.",
  },
];

const LADDERED: Record<string, Laddered> = {
  default_idle_timeout_seconds: { field: "idle_timeout_seconds", narrower: "lower", deployed: 1800 },
  default_cache_eviction_days: { field: "cache_eviction_days", narrower: "lower", deployed: 7 },
  default_erase_after_days: { field: "erase_after_days", narrower: "lower", deployed: 365 },
  pins_allowed: { field: "pins_allowed", narrower: "off", deployed: true },
  members_may_control: { field: "members_may_control", narrower: "off", deployed: true },
};

const TEAM_KEYS = [
  "budget_micros",
  "budget_period",
  "idle_timeout_seconds",
  "cache_eviction_days",
  "erase_after_days",
  "members_may_control",
  "pins_allowed",
  "volume_size",
  "volume_storage_class",
  "allow_unenforced_workers",
];
const INTEGER_KEYS = ["budget_micros", "idle_timeout_seconds", "cache_eviction_days", "erase_after_days"];
const BOOLEAN_KEYS = ["members_may_control", "pins_allowed", "allow_unenforced_workers"];

/** A team's name, as `Identity.Team` holds it to. */
const TEAM_NAME = /^[a-z0-9]([a-z0-9-]{0,56}[a-z0-9])?$/;
const TEAM_NAME_RULE =
  "lowercase letters, digits and dashes, starting and ending with a letter or digit, at most 58 characters — it becomes part of a Kubernetes name and an OpenBao path";

/** What a team enabled from a group starts with, where the platform has set no team defaults. */
const NEW_TEAM: Partial<FakeTeam> = {
  budget_micros: 0,
  budget_period: "monthly",
  idle_timeout_seconds: 1800,
  cache_eviction_days: 7,
  erase_after_days: 365,
  pins_allowed: true,
  members_may_control: false,
  volume_size: "10Gi",
};

/** The name a group's team gets when none is given: its display name, made into a label. */
function defaultTeamName(group: { external_id: string; display_name: string | null }): string {
  return (group.display_name ?? group.external_id)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 58)
    .replace(/-+$/g, "");
}

const COMPONENTS = ["tui", "daemon", "desktop"];
const VERSION = /^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$/;

interface Policy {
  recommended: string | null;
  minimum: string | null;
  blocked: string[];
  updated_by: string | null;
  updated_at: string | null;
}

export interface AuditEntry {
  actor: string;
  action: string;
  subject_kind: string | null;
  subject_id: string | null;
  detail: Record<string, unknown> | null;
  occurred_at: string;
}

const refuse = (code: number, message: string, data?: unknown): Refusal => ({ error: { code, message, ...(data === undefined ? {} : { data }) } });

/** The diff the plane's audit records: a dotted path per field that moved, maps walked. */
export function diff(before: Record<string, unknown>, now: Record<string, unknown>, path: string[] = []): Changes {
  const out: Changes = {};
  const plain = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
  for (const key of new Set([...Object.keys(before), ...Object.keys(now)])) {
    const was = before[key] ?? null;
    const is = now[key] ?? null;
    if (JSON.stringify(was) === JSON.stringify(is)) continue;
    if (plain(was) && plain(is)) Object.assign(out, diff(was, is, [...path, key]));
    else out[[...path, key].join(".")] = { from: was, to: is };
  }
  return out;
}

export class FakeAdmin {
  readonly platformAdmins: Set<string>;
  readonly teams = new Map<string, FakeTeam>();
  readonly groups: Array<{ external_id: string; display_name: string | null; looks_duplicated?: { others: string[]; likely: string } | null }>;
  /** Who is in each group, by its external id, as the identity provider says: membership is never the plane's. */
  readonly memberships: Record<string, string[]>;
  /** People's display names, by subject, for a member a link brings in. */
  readonly names: Record<string, string>;
  readonly profiles: FakeProfile[];
  readonly sessions: FakeSession[];
  /** What a platform admin stored over the deployment, by key. */
  readonly stored = new Map<string, unknown>();
  /** What the plane was deployed with, by key; a key absent here is unset. */
  readonly deployed: Record<string, unknown>;
  readonly policies: Record<string, Policy>;
  readonly audit: AuditEntry[] = [];
  /** Answer this method with this error instead: how a test sees a screen's error state. */
  readonly failing = new Map<string, { code: number; message: string; data?: unknown }>();
  /** Hold every answer this long: how a test, or a person, sees a screen's loading state. */
  holdMs = 0;
  /** The keys the enforced set may hold, as this plane lists them; `null` is a plane from before it listed any. */
  enforceable: ReadonlyArray<Record<string, unknown> & { key: string }> | null = ENFORCEABLE;
  /** How this plane provisions: `direct` writes profiles and triggers, `gitops` reads them from a repository and refuses a write. */
  mode: "direct" | "gitops" = "direct";
  /** Where a gitops plane reads from, as its `gitops_source` setting says. */
  gitopsSource: string | null = null;
  /** Every published version, by channel, oldest first. */
  readonly bundles = new Map<string, FakeBundle[]>();
  readonly triggerRows: FakeTrigger[] = [];
  readonly entitlements: FakeEntitlement[] = [];
  /** The cluster policy, as far as a profile and a bundle are checked against it. */
  readonly policy = {
    imageRepositories: ["registry.example.com/troupe"],
    egress: ["llm-gw.example.com", "mcp.example.com", "wiki.example.com", "github.example.com", "hooks.example.com"],
  };

  constructor(
    opts: {
      platformAdmins?: string[];
      teams?: FakeTeam[];
      groups?: Array<{ external_id: string; display_name: string | null; looks_duplicated?: { others: string[]; likely: string } | null }>;
      memberships?: Record<string, string[]>;
      names?: Record<string, string>;
      profiles?: FakeProfile[];
      sessions?: FakeSession[];
      deployed?: Record<string, unknown>;
    } = {},
  ) {
    this.platformAdmins = new Set(opts.platformAdmins ?? []);
    for (const t of opts.teams ?? []) this.teams.set(t.name, t);
    this.groups = opts.groups ?? [];
    this.memberships = opts.memberships ?? {};
    this.names = opts.names ?? {};
    this.profiles = opts.profiles ?? [];
    this.sessions = opts.sessions ?? [];
    this.deployed = opts.deployed ?? {};
    this.policies = Object.fromEntries(COMPONENTS.map((c) => [c, { recommended: null, minimum: null, blocked: [], updated_by: null, updated_at: null }]));
  }

  role(subject: string): Role {
    if (this.platformAdmins.has(subject)) return "platform_admin";
    return [...this.teams.values()].some((t) => t.admins.includes(subject)) ? "team_admin" : "none";
  }

  /** The teams this subject may see: every one for a platform admin, their own for a team admin. */
  private visible(subject: string): FakeTeam[] {
    const role = this.role(subject);
    return [...this.teams.values()].filter((t) => role === "platform_admin" || t.admins.includes(subject));
  }

  async call(subject: string, method: string, params: Record<string, unknown>): Promise<Answer> {
    if (this.holdMs > 0) await new Promise((r) => setTimeout(r, this.holdMs));
    const failing = this.failing.get(method);
    if (failing) return { error: failing };
    const role = this.role(subject);
    const admin = role !== "none";
    const notAdmin = refuse(FORBIDDEN, "forbidden", { required_role: "team_admin" });
    const notPlatform = refuse(FORBIDDEN, "forbidden", { required_role: "platform_admin" });

    switch (method) {
      case "admin.teams.list":
        return admin ? { result: this.visible(subject).map((t) => this.teamJson(t)) } : notAdmin;

      case "admin.groups.list":
        return admin ? { result: this.groups } : notAdmin;

      case "admin.team.update": {
        const found = this.fetchTeam(subject, params["name"]);
        if ("error" in found) return found;
        const team = found.team;
        const attrs = Object.fromEntries(Object.entries((params["attrs"] ?? {}) as Record<string, unknown>).filter(([k]) => TEAM_KEYS.includes(k)));
        if ("allow_unenforced_workers" in attrs && role !== "platform_admin") {
          return refuse(FORBIDDEN, "forbidden", {
            field: "allow_unenforced_workers",
            reason: "only a platform admin decides whether a team may run where nothing is enforced",
          });
        }
        for (const [k, v] of Object.entries(attrs)) {
          if (INTEGER_KEYS.includes(k) && v !== null && !(Number.isInteger(v) && (v as number) >= 0)) {
            return refuse(INVALID_PARAMS, "invalid_params", { reason: `${k} must be a whole number, 0 or more` });
          }
          if (BOOLEAN_KEYS.includes(k) && typeof v !== "boolean") return refuse(INVALID_PARAMS, "invalid_params", { reason: `${k} must be true or false` });
        }
        for (const [key, spec] of Object.entries(LADDERED)) {
          if (!(spec.field in attrs)) continue;
          const asked = attrs[spec.field] as number | boolean | null;
          const ceiling = this.ceiling(key);
          if (asked !== null && this.tightness(spec, asked) > this.tightness(spec, ceiling)) {
            return refuse(FORBIDDEN, "forbidden", {
              field: spec.field,
              asked,
              ceiling,
              decided_by: this.stored.has(key) ? "platform" : "deployment",
              reason: "a lower rung may only narrow",
            });
          }
        }
        const before = this.comparable(team);
        Object.assign(team, attrs);
        const changes = diff(before, this.comparable(team));
        this.record(subject, "team.update", team.name, changes);
        return { result: { team: this.teamJson(team), changes } };
      }

      case "admin.team.disable.preview":
      case "admin.team.disable": {
        if (role !== "platform_admin") return notPlatform;
        const found = this.fetchTeam(subject, params["name"]);
        if ("error" in found) return found;
        const t = found.team;
        const effect = {
          team: t.name,
          groups: t.groups.map((g) => g.external_id),
          members: t.members.length,
          grants: t.grants.map((g) => g.profile),
          admins: t.admins,
          principals: t.principals,
          triggers: [...new Set([...t.triggers, ...this.triggerRows.filter((r) => r.team === t.name).map((r) => r.name)])].sort(),
          sessions_kept: this.sessions.filter((s) => s.team === t.name && s.state !== "erased").length,
          confirm: t.name,
        };
        if (method === "admin.team.disable") {
          // Every grant revoked first, so the team's sessions go read-only; then the row,
          // and the sessions stay, with no team.
          for (const s of this.sessions) {
            if (s.team !== t.name) continue;
            if (s.state === "active" || s.state === "dormant") s.state = "read_only";
            s.team = null;
          }
          this.teams.delete(t.name);
          for (let i = this.triggerRows.length - 1; i >= 0; i--) if (this.triggerRows[i]!.team === t.name) this.triggerRows.splice(i, 1);
          const { confirm: _confirm, ...recorded } = effect;
          this.record(subject, "team.disable", t.name, recorded);
        }
        return { result: effect };
      }

      case "admin.team.enable": {
        if (role !== "platform_admin") return notPlatform;
        const groupId = params["group"];
        if (typeof groupId !== "string") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["group"] });
        const group = this.groups.find((g) => g.external_id === groupId);
        if (!group) return refuse(NOT_FOUND, "not_found", { group: groupId });
        const attrs = (params["attrs"] ?? {}) as Record<string, unknown>;
        const name = typeof attrs["name"] === "string" && attrs["name"] !== "" ? attrs["name"] : defaultTeamName(group);
        if (!TEAM_NAME.test(name)) return refuse(INVALID_PARAMS, "invalid_params", { reason: `name: ${TEAM_NAME_RULE}`, fields: ["name"] });
        // Keyed on the name, as the plane's is: a name that is already a team's updates that
        // team and links the group into it. The console says so before it sends one.
        const enabled = this.teams.get(name) ?? team(name, NEW_TEAM);
        Object.assign(enabled, Object.fromEntries(Object.entries(attrs).filter(([k]) => TEAM_KEYS.includes(k))));
        this.teams.set(name, enabled);
        this.link(enabled, group, "enable_team");
        this.record(subject, "team.enable", name, { group: groupId });
        return { result: this.teamJson(enabled) };
      }

      case "admin.team.link":
      case "admin.team.unlink.preview":
      case "admin.team.unlink": {
        if (role !== "platform_admin") return notPlatform;
        const found = this.fetchTeam(subject, params["name"]);
        if ("error" in found) return found;
        const t = found.team;
        const groupId = params["group"];
        const group = this.groups.find((g) => g.external_id === groupId);
        if (!group) return refuse(NOT_FOUND, "not_found", { group: groupId });
        if (method === "admin.team.link") {
          this.link(t, group, subject);
          this.record(subject, "team.link", t.name, { group: group.external_id });
          return { result: { team: t.name, group: group.external_id, members: t.members.length } };
        }
        const effect = this.unlinkEffect(t, group.external_id);
        if (method === "admin.team.unlink") {
          t.groups = t.groups.filter((g) => g.external_id !== group.external_id);
          t.members = t.members.filter((m) => !effect.losing.includes(m.subject));
          this.record(subject, "team.unlink", t.name, effect);
        }
        return { result: effect };
      }

      case "admin.team.grant":
      case "admin.team.revoke": {
        if (role !== "platform_admin") return notPlatform;
        const found = this.fetchTeam(subject, params["name"]);
        if ("error" in found) return found;
        const t = found.team;
        const profile = params["profile"];
        if (typeof profile !== "string") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["profile"] });
        if (method === "admin.team.revoke") {
          t.grants = t.grants.filter((g) => g.profile !== profile);
          // The grant is what made those sessions allowed: they go read-only, not away.
          for (const s of this.sessions) {
            if (s.team === t.name && s.profile === profile && (s.state === "active" || s.state === "dormant")) s.state = "read_only";
          }
          this.record(subject, "team.revoke", t.name, { profile });
          return { result: this.teamJson(t) };
        }
        const spec = this.profiles.find((p) => p.name === profile);
        if (spec?.unenforced && !t.allow_unenforced_workers) {
          return refuse(FORBIDDEN, "forbidden", {
            profile,
            provisioner: spec.provisioner,
            missing: spec.missing_guarantees,
            team: t.name,
            reason: `this substrate does not provide ${spec.missing_guarantees.join(", ")}; a platform admin must allow unenforced workers for this team first`,
          });
        }
        const mode = ((params["attrs"] ?? {}) as Record<string, unknown>)["volume_mode"];
        if (mode !== undefined && mode !== "ro" && mode !== "rw") return refuse(INVALID_PARAMS, "invalid_params", { reason: "volume_mode: is invalid; it is ro or rw" });
        const held = t.grants.find((g) => g.profile === profile);
        if (held) held.volume_mode = typeof mode === "string" ? mode : held.volume_mode;
        else t.grants.push({ profile, volume_mode: typeof mode === "string" ? mode : "ro" });
        this.record(subject, "team.grant", t.name, { profile });
        return { result: this.teamJson(t) };
      }

      case "admin.team.admin.add":
      case "admin.team.admin.remove": {
        if (role !== "platform_admin") return notPlatform;
        const found = this.fetchTeam(subject, params["name"]);
        if ("error" in found) return found;
        const t = found.team;
        const who = params["subject"];
        if (typeof who !== "string" || who === "") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["subject"] });
        if (method === "admin.team.admin.add") t.admins = [...new Set([...t.admins, who])].sort();
        else t.admins = t.admins.filter((a) => a !== who);
        this.record(subject, method === "admin.team.admin.add" ? "team.admin.add" : "team.admin.remove", t.name, { subject: who });
        return { result: { team: t.name, admins: t.admins } };
      }

      case "admin.overview": {
        if (!admin) return notAdmin;
        const seen = this.sessionsFor(subject);
        const count = (state: string) => seen.filter((s) => s.state === state).length;
        return {
          result: {
            profiles: this.profilesFor(subject).map((p) => this.profileJson(p)),
            teams: this.visible(subject).map((t) => ({
              name: t.name,
              budget_micros: t.budget_micros,
              budget_period: t.budget_period,
              spent_micros: t.spent_micros,
              reserved_micros: t.reserved_micros,
            })),
            sessions: { active: count("active"), dormant: count("dormant"), read_only: count("read_only") },
          },
        };
      }

      case "admin.profiles.list":
        return admin ? { result: this.profilesFor(subject).map((p) => this.profileJson(p)) } : notAdmin;

      case "admin.provisioning.mode":
        return admin ? { result: this.mode } : notAdmin;

      case "admin.profile.get": {
        if (role !== "platform_admin") return notPlatform;
        const p = this.profiles.find((x) => x.name === params["name"]);
        if (!p) return refuse(NOT_FOUND, "not_found", { profile: params["name"] });
        return {
          result: {
            profile: this.profileJson(p),
            spec: p.spec ?? {},
            policy: this.verdict({ name: p.name, image: p.image, spec: p.spec ?? {} }),
            bundle: this.bundleState(p),
            identity_problems: this.identityProblems(p.spec ?? {}),
            gitops: this.gitopsOf(p.gitops),
          },
        };
      }

      case "admin.profile.preview":
      case "admin.profile.put": {
        if (role !== "platform_admin") return notPlatform;
        const attrs = ((typeof params["profile"] === "object" && params["profile"] !== null ? params["profile"] : params) ?? {}) as Record<string, unknown>;
        const name = attrs["name"];
        if (typeof name !== "string" || name === "") return refuse(INVALID_PARAMS, "invalid_params", { reason: "a profile has a name", missing: ["name"] });
        const before = this.profiles.find((p) => p.name === name) ?? null;
        if (method === "admin.profile.preview") {
          // The stored profile with the write laid over it, as the plane compares them: what
          // the write does not send stays as it is, and the name says which profile.
          const was = this.comparable_profile(before);
          const { name: _name, ...sent } = this.comparable_attrs(attrs);
          return { result: { policy: this.verdict(attrs), changes: diff(was, { ...was, ...sent }), mode: this.mode } };
        }
        const held = this.heldByRepository(subject, "profile.put", name, "WorkerProfile");
        if (held) return held;
        const refused = this.profileRefusal(attrs);
        if (refused) return refused;
        const spec = (attrs["spec"] ?? {}) as Record<string, unknown>;
        const sizeClass = typeof attrs["size_class"] === "string" ? attrs["size_class"] : (before?.size_class ?? "standard");
        const after: FakeProfile = before ?? {
          name,
          size_class: sizeClass,
          replicas: 0,
          sessions_per_pod: 0,
          channel: null,
          image: null,
          provisioner: "kubernetes",
          missing_guarantees: [],
          unenforced: false,
          pods: [],
        };
        const was = this.comparable_profile(before);
        // A field not sent is left as it was, as a changeset casts only what it is given;
        // `null` sent clears it.
        after.image = attrs["image"] as string;
        after.size_class = sizeClass;
        after.sessions_per_pod = sizeClass === "heavy" ? 2 : 4;
        if ("max_sessions" in attrs) after.max_sessions = typeof attrs["max_sessions"] === "number" ? attrs["max_sessions"] : null;
        if ("warm_workers" in attrs) after.warm_workers = typeof attrs["warm_workers"] === "number" ? attrs["warm_workers"] : 0;
        if (typeof attrs["provisioner"] === "string") after.provisioner = attrs["provisioner"];
        if ("spec" in attrs) {
          after.spec = spec;
          after.channel = typeof spec["configBundleChannel"] === "string" && spec["configBundleChannel"] !== "" ? spec["configBundleChannel"] : "stable";
        }
        if (!before) this.profiles.push(after);
        const changes = diff(was, this.comparable_profile(after));
        this.record(subject, "profile.put", name, changes);
        return { result: { profile: this.profileJson(after), changes, provisioning: { mode: this.mode, state: "applied" }, identity_problems: this.identityProblems(spec) } };
      }

      case "admin.profile.delete": {
        if (role !== "platform_admin") return notPlatform;
        const p = this.profiles.find((x) => x.name === params["name"]);
        if (!p) return refuse(NOT_FOUND, "not_found", { profile: params["name"] });
        if (p.gitops?.problem !== "missing") {
          const held = this.heldByRepository(subject, "profile.delete", p.name, "WorkerProfile");
          if (held) return held;
        }
        this.record(subject, "profile.delete", p.name, this.comparable_profile(p));
        // Its grants go with it, and the sessions that ran on it turn read-only, not away.
        for (const t of this.teams.values()) t.grants = t.grants.filter((g) => g.profile !== p.name);
        for (const s of this.sessions) if (s.profile === p.name && (s.state === "active" || s.state === "dormant")) s.state = "read_only";
        this.profiles.splice(this.profiles.indexOf(p), 1);
        return { result: { profile: p.name, deleted: true, provisioning: { mode: this.mode, state: p.gitops ? "row_deleted" : "deleted" } } };
      }

      case "admin.mcp.check": {
        if (!admin) return notAdmin;
        const host = hostOf(params["url"]);
        if (!host) return refuse(INVALID_PARAMS, "invalid_params", { reason: "not a URL with a host", url: params["url"] });
        return { result: { host, allowed: this.egressAllowed(host) } };
      }

      case "admin.bundles.list": {
        if (!admin) return notAdmin;
        if (typeof params["channel"] !== "string") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["channel"] });
        return { result: [...(this.bundles.get(params["channel"]) ?? [])].reverse().map((b) => this.bundleSummary(b)) };
      }

      case "admin.bundle.get": {
        if (!admin) return notAdmin;
        const b = this.bundleAt(params["channel"], params["version"]);
        if (!b) return refuse(NOT_FOUND, "not_found", { channel: params["channel"], version: params["version"] });
        return {
          result: {
            ...this.bundleSummary(b),
            content: b.content,
            detail: describeBundle(b.content),
            adoption: this.profiles.filter((p) => p.channel === b.channel).map((p) => this.adoption(p, b.hash)),
          },
        };
      }

      case "admin.bundle.validate": {
        if (role !== "platform_admin") return notPlatform;
        const errors = bundleProblems(params["content"], this.policy.egress);
        if (errors.length) return refuse(INVALID_PARAMS, "invalid_params", { errors });
        return { result: { ok: true, summary: bundleSummaryOf(params["content"] as Record<string, unknown>), hash: hashOf(params["content"]) } };
      }

      case "admin.bundle.preview": {
        if (!admin) return notAdmin;
        const channel = params["channel"];
        if (typeof channel !== "string") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["channel"] });
        const errors = bundleProblems(params["content"], this.policy.egress);
        if (errors.length) return refuse(INVALID_PARAMS, "invalid_params", { errors });
        const base = params["from"] === undefined || params["from"] === null ? this.current(channel) : this.bundleAt(channel, params["from"]);
        if (params["from"] !== undefined && params["from"] !== null && !base) return refuse(NOT_FOUND, "not_found", { channel, version: params["from"] });
        const was = base ? bundleSummaryOf(base.content) : null;
        const now = bundleSummaryOf(params["content"] as Record<string, unknown>);
        const removed = was ? removedEntries(was, now) : [];
        const losers = this.entitlements
          .filter((e) => e.mode === "allow" && removed.some((r) => r.kind === e.kind && r.name === e.name))
          .filter((e) => this.profiles.some((p) => p.name === e.profile && p.channel === channel))
          .map(({ team, profile, kind, name }) => ({ team, profile, kind, name }));
        return { result: { channel, from: base?.version ?? null, hash: hashOf(params["content"]), changes: diff(was ?? {}, now), removed, losers } };
      }

      case "admin.bundle.publish": {
        if (role !== "platform_admin") return notPlatform;
        const channel = params["channel"];
        if (typeof channel !== "string" || channel === "") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["channel"] });
        const errors = bundleProblems(params["content"], this.policy.egress);
        if (errors.length) return refuse(INVALID_PARAMS, "invalid_params", { errors });
        const versions = this.bundles.get(channel) ?? [];
        const content = params["content"] as Record<string, unknown>;
        const b: FakeBundle = {
          channel,
          version: (versions.at(-1)?.version ?? 0) + 1,
          hash: hashOf(content),
          content,
          published_at: new Date().toISOString(),
          published_by: subject,
          retired_at: null,
        };
        this.bundles.set(channel, [...versions, b]);
        this.record(subject, "bundle.publish", channel, { version: b.version, hash: b.hash, summary: bundleSummaryOf(content) });
        return { result: this.bundleSummary(b) };
      }

      case "admin.bundle.retire": {
        if (role !== "platform_admin") return notPlatform;
        const b = this.bundleAt(params["channel"], params["version"]);
        if (!b) return refuse(NOT_FOUND, "not_found", { reason: ":not_found" });
        b.retired_at = new Date().toISOString();
        this.record(subject, "bundle.retire", b.channel, { version: b.version });
        return { result: this.bundleSummary(b) };
      }

      case "admin.principals.list": {
        const found = this.fetchTeam(subject, params["team"]);
        if ("error" in found) return found;
        return {
          result: found.team.principals.map((p) => ({
            subject: p,
            name: p.split("/").at(-1) ?? p,
            description: null,
            profiles: found.team.grants.map((g) => g.profile),
            created_by: "alice@example.com",
            created_at: "2026-10-01T09:30:00Z",
            disabled_at: null,
            last_used_at: null,
            enabled: true,
          })),
        };
      }

      case "admin.triggers.list": {
        const found = this.fetchTeam(subject, params["team"]);
        if ("error" in found) return found;
        return { result: this.triggerRows.filter((t) => t.team === found.team.name).sort((a, b) => a.name.localeCompare(b.name)).map((t) => this.triggerJson(t)) };
      }

      case "admin.trigger.put": {
        const attrs = ((typeof params["trigger"] === "object" && params["trigger"] !== null ? params["trigger"] : params) ?? {}) as Record<string, unknown>;
        const found = this.fetchTeam(subject, attrs["team"]);
        if ("error" in found) return found;
        const t = found.team;
        const name = attrs["name"];
        if (typeof name !== "string" || name === "") return refuse(INVALID_PARAMS, "invalid_params", { reason: "a trigger has a name", missing: "name" });
        const held = this.heldByRepository(subject, "trigger.put", `${t.name}/${name}`, "Trigger");
        if (held) return held;
        if (typeof attrs["profile"] === "string" && !this.profiles.some((p) => p.name === attrs["profile"])) {
          return refuse(INVALID_PARAMS, "invalid_params", { profile: attrs["profile"], reason: `${String(attrs["profile"])} is not a profile this plane has` });
        }
        const existing = this.triggerRows.find((r) => r.team === t.name && r.name === name) ?? null;
        const refused = this.triggerRefusal(t, attrs, existing);
        if (refused) return refused;
        const before = existing ? this.comparable_trigger(existing) : {};
        const now = new Date().toISOString();
        const row: FakeTrigger = existing ?? {
          id: `trg-${t.name}-${name}`,
          team: t.name,
          name,
          principal: "",
          profile: "",
          agent: null,
          enabled: true,
          source: {},
          prompt_template: null,
          terms: null,
          visibility: "team",
          review: "required",
          notify: [],
          notify_url: null,
          concurrency: 1,
          last_fired_at: null,
          created_by: subject,
          updated_at: now,
          revisions: [],
        };
        for (const key of TRIGGER_KEYS) if (key in attrs) (row as unknown as Record<string, unknown>)[key] = attrs[key] ?? TRIGGER_DEFAULTS[key] ?? null;
        row.updated_at = now;
        if (!existing) this.triggerRows.push(row);
        const changes = diff(before, this.comparable_trigger(row));
        const revision = this.revise(row, subject);
        this.record(subject, "trigger.put", `${t.name}/${name}`, { ...changes, __revision__: revision.revision, __revision_hash__: revision.hash });
        return { result: { trigger: this.triggerJson(row), changes, revision: revisionJson(revision) } };
      }

      case "admin.trigger.delete":
      case "admin.trigger.revisions": {
        const found = this.fetchTeam(subject, params["team"]);
        if ("error" in found) return found;
        const row = this.triggerRows.find((r) => r.team === found.team.name && r.name === params["name"]);
        if (!row) return refuse(NOT_FOUND, "not_found", { trigger: params["name"] });
        if (method === "admin.trigger.revisions") return { result: [...row.revisions].reverse().map((r) => ({ ...revisionJson(r), document: r.document })) };
        if (row.gitops?.problem !== "missing") {
          const held = this.heldByRepository(subject, "trigger.delete", `${row.team}/${row.name}`, "Trigger");
          if (held) return held;
        }
        this.record(subject, "trigger.delete", `${row.team}/${row.name}`, this.comparable_trigger(row));
        this.triggerRows.splice(this.triggerRows.indexOf(row), 1);
        return { result: { team: row.team, name: row.name, deleted: true } };
      }

      case "admin.sessions.list": {
        if (!admin) return notAdmin;
        const filter = this.filterOf(params);
        let rows = this.sessionsFor(subject);
        if (typeof filter["profile"] === "string") rows = rows.filter((s) => s.profile === filter["profile"]);
        if (filter["state"] !== undefined) {
          const states = [filter["state"]].flat();
          rows = rows.filter((s) => states.includes(s.state));
        }
        if (filter["needs_review"] === true || filter["needs_review"] === "true") rows = rows.filter((s) => s.origin !== "user" && !s.reviewed);
        // A `team` in the filter is declared by the plane's schema and not applied by it.
        rows = [...rows].sort((a, b) => b.last_active_at.localeCompare(a.last_active_at));
        const limit = typeof filter["limit"] === "number" ? filter["limit"] : 200;
        return { result: rows.slice(0, limit).map((s) => this.sessionJson(s)) };
      }

      case "admin.session.erase.preview":
      case "admin.session.erase": {
        if (!admin) return notAdmin;
        const id = params["session_id"];
        if (typeof id !== "string") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["session_id"] });
        const session = this.sessionsFor(subject).find((s) => s.id === id);
        if (!session) return refuse(NOT_FOUND, "not_found", { session_id: id });
        if (method === "admin.session.erase.preview") {
          const forks = this.sessions.filter((s) => s.parent === id && s.state !== "erased");
          return {
            result: {
              session_id: id,
              owner: session.owner,
              profile: session.profile,
              object_bytes: session.object_bytes,
              workspace_bytes: session.workspace_bytes,
              survivors: forks.map((f) => f.id),
              survivor_count: forks.length,
              confirm: id,
            },
          };
        }
        this.record(subject, "session.erase", id, { profile: session.profile });
        session.state = "erased";
        return { result: { session_id: id, head_hash: `sha256:${id.replace(/[^0-9a-f]/g, "").padEnd(16, "0")}`, state: "erased" } };
      }

      case "admin.audit.verify":
        if (role !== "platform_admin") return notPlatform;
        return { result: { checked: this.audit.length, unchained: 0, from: this.audit[0]?.occurred_at ?? null, result: "ok" } };

      case "admin.settings.list":
        if (!admin) return notAdmin;
        return {
          result: {
            groups: GROUPS,
            settings: SETTINGS.map((s) => this.describe(s)),
            ladder: ["deployment", "platform", "team", "profile", "session"],
            laddered: Object.keys(LADDERED).sort(),
          },
        };

      case "admin.setting.put":
      case "admin.setting.reset": {
        if (role !== "platform_admin") return notPlatform;
        const key = String(params["key"] ?? "");
        const setting = SETTINGS.find((s) => s.key === key);
        if (!setting) return refuse(NOT_FOUND, "not_found", { setting: key });
        const before = this.valueOf(setting);
        if (method === "admin.setting.reset") {
          this.stored.delete(key);
        } else {
          const parsed = this.parse(setting, params["value"]);
          if ("error" in parsed) return refuse(INVALID_PARAMS, "invalid_params", { setting: key, reason: parsed.error });
          this.stored.set(key, parsed.value);
        }
        const value = this.valueOf(setting);
        const changes = diff({ [key]: before }, { [key]: value });
        this.record(subject, method === "admin.setting.put" ? "setting.put" : "setting.reset", key, changes);
        return { result: { key, value, effect: "Takes effect on the next request.", changes } };
      }

      case "admin.setting.effective": {
        if (!admin) return notAdmin;
        const key = String(params["key"] ?? "");
        let team: FakeTeam | null = null;
        if (params["team"] !== undefined) {
          const found = this.fetchTeam(subject, params["team"]);
          if ("error" in found) return found;
          team = found.team;
        }
        if (!LADDERED[key]) return refuse(NOT_FOUND, "not_found", { setting: key, reason: "not a setting more than one rung decides", laddered: Object.keys(LADDERED).sort() });
        return { result: { ...this.effective(key, team), team: team?.name ?? null } };
      }

      case "admin.clients.get":
        return admin ? { result: { clients: Object.fromEntries(COMPONENTS.map((c) => [c, { component: c, ...this.policies[c] }])) } } : notAdmin;

      case "admin.clients.put": {
        if (role !== "platform_admin") return notPlatform;
        const component = String(params["component"] ?? "");
        if (!COMPONENTS.includes(component)) {
          return refuse(INVALID_PARAMS, "invalid_params", { field: "component", reason: `a policy is held for ${COMPONENTS.join(", ")}; not "${component}"` });
        }
        const policy = (params["policy"] ?? {}) as Record<string, unknown>;
        const current = this.policies[component]!;
        const next = { ...current, blocked: [...current.blocked] };
        for (const key of ["recommended", "minimum"] as const) {
          if (!(key in policy)) continue;
          const v = policy[key];
          if (v === null || v === "") next[key] = null;
          else {
            const m = typeof v === "string" ? VERSION.exec(v.trim()) : null;
            if (!m) return refuse(INVALID_PARAMS, "invalid_params", { field: key, reason: `${key} ${JSON.stringify(v)} is not a version, as releases are numbered (0.13.0-beta)` });
            next[key] = m[1]!;
          }
        }
        if ("blocked" in policy) {
          const list = policy["blocked"] ?? [];
          if (!Array.isArray(list)) return refuse(INVALID_PARAMS, "invalid_params", { field: "blocked", reason: "blocked is a list of versions" });
          const versions: string[] = [];
          for (const v of list) {
            const m = typeof v === "string" ? VERSION.exec(v.trim()) : null;
            if (!m) return refuse(INVALID_PARAMS, "invalid_params", { field: "blocked", reason: `${JSON.stringify(v)} is not a version, as releases are numbered (0.13.0-beta)` });
            if (!versions.includes(m[1]!)) versions.push(m[1]!);
          }
          next.blocked = versions;
        }
        if (next.recommended && next.minimum && older(next.recommended, next.minimum)) {
          return refuse(INVALID_PARAMS, "invalid_params", { field: "minimum", reason: `the minimum ${next.minimum} is newer than the recommended version ${next.recommended}` });
        }
        if (next.recommended && next.blocked.includes(next.recommended)) {
          return refuse(INVALID_PARAMS, "invalid_params", { field: "recommended", reason: `the recommended version ${next.recommended} is blocked` });
        }
        const fields = (p: Policy) => ({ recommended: p.recommended, minimum: p.minimum, blocked: p.blocked });
        const changes = diff(fields(current), fields(next));
        this.policies[component] = { ...next, updated_by: subject, updated_at: new Date().toISOString() };
        this.record(subject, "clients.put", component, changes);
        return { result: { component, ...this.policies[component], changes } };
      }

      case "admin.audit.list": {
        if (!admin) return notAdmin;
        // Newest first, narrowed as the plane narrows: by actor, by kind (the action's first
        // word) and by subject, at most `limit` rows, a hundred where none is given.
        const filter = this.filterOf(params);
        let rows = [...this.audit].reverse();
        if (typeof filter["actor"] === "string") rows = rows.filter((r) => r.actor === filter["actor"]);
        if (typeof filter["kind"] === "string") rows = rows.filter((r) => r.subject_kind === filter["kind"]);
        if (typeof filter["subject_id"] === "string") rows = rows.filter((r) => r.subject_id === filter["subject_id"]);
        const limit = typeof filter["limit"] === "number" ? filter["limit"] : 100;
        return { result: rows.slice(0, limit) };
      }

      default:
        return refuse(METHOD_NOT_FOUND, "method_not_found", { method });
    }
  }

  // -- teams ---------------------------------------------------------------------------

  private fetchTeam(subject: string, name: unknown): { team: FakeTeam } | Refusal {
    const role = this.role(subject);
    if (role === "none") return refuse(FORBIDDEN, "forbidden", { required_role: "team_admin" });
    if (typeof name !== "string") return refuse(INVALID_PARAMS, "invalid_params", { missing: "team" });
    const team = this.teams.get(name);
    // Not found, rather than forbidden, for a team that is not this team admin's: whether it
    // exists is itself something they should not learn.
    if (!team || (role === "team_admin" && !team.admins.includes(subject))) return refuse(NOT_FOUND, "not_found", { team: name });
    return { team };
  }

  private comparable(team: FakeTeam): Record<string, unknown> {
    return Object.fromEntries(TEAM_KEYS.map((k) => [k, (team as unknown as Record<string, unknown>)[k] ?? null]));
  }

  private teamJson(team: FakeTeam): Record<string, unknown> {
    const { principals: _p, triggers: _t, ...shown } = team;
    return { ...shown, effective: Object.keys(LADDERED).sort().map((key) => this.effective(key, team)) };
  }

  /** Draw a team's members from a group too: its people join, once each. */
  private link(team: FakeTeam, group: { external_id: string; display_name: string | null }, by: string): void {
    if (!team.groups.some((g) => g.external_id === group.external_id)) {
      team.groups.push({ external_id: group.external_id, display_name: group.display_name, issuer: "https://idp.example.com", linked_by: by });
    }
    for (const person of this.memberships[group.external_id] ?? []) {
      if (team.members.some((m) => m.subject === person)) continue;
      team.members.push({ subject: person, display_name: this.names[person] ?? null, budget_micros: null, spent_micros: 0, reserved_micros: 0 });
    }
  }

  /** Who is in the group, who keeps the team through another of its groups, and who loses it. */
  private unlinkEffect(team: FakeTeam, groupId: string): Record<string, unknown> & { losing: string[] } {
    const inGroup = new Set(this.memberships[groupId] ?? []);
    const remaining = new Set(team.groups.filter((g) => g.external_id !== groupId).flatMap((g) => this.memberships[g.external_id] ?? []));
    const losing = [...inGroup].filter((p) => !remaining.has(p)).sort();
    return {
      team: team.name,
      group: groupId,
      in_group: inGroup.size,
      keep_access: [...inGroup].filter((p) => remaining.has(p)).length,
      lose_access: losing.length,
      losing,
      sessions_they_can_open: this.sessions.filter((s) => s.state !== "erased" && losing.includes(s.owner)).length,
    };
  }

  // -- profiles and sessions --------------------------------------------------------

  /** Every profile for a platform admin; a team admin's teams' granted ones for a team admin. */
  private profilesFor(subject: string): FakeProfile[] {
    if (this.role(subject) === "platform_admin") return this.profiles;
    const granted = new Set(this.visible(subject).flatMap((t) => t.grants.map((g) => g.profile)));
    return this.profiles.filter((p) => granted.has(p.name));
  }

  /** Every session not erased for a platform admin; their teams' for a team admin. */
  private sessionsFor(subject: string): FakeSession[] {
    const all = this.role(subject) === "platform_admin";
    const teams = new Set(this.visible(subject).map((t) => t.name));
    return this.sessions.filter((s) => s.state !== "erased" && (all || (s.team !== null && teams.has(s.team))));
  }

  private profileJson(p: FakeProfile): Record<string, unknown> {
    return {
      name: p.name,
      size_class: p.size_class,
      size_class_summary: SIZE_CLASSES[p.size_class] ?? null,
      max_sessions: p.max_sessions ?? null,
      warm_workers: p.warm_workers ?? 0,
      gitops: this.gitopsOf(p.gitops),
      replicas: p.replicas,
      sessions_per_pod: p.sessions_per_pod,
      capacity_sessions: p.replicas * p.sessions_per_pod,
      channel: p.channel,
      image: p.image,
      provisioner: p.provisioner,
      missing_guarantees: p.missing_guarantees,
      unenforced: p.unenforced,
      conditions: [],
      pods: p.pods,
      capacity: p.pods.reduce((n, pod) => n + pod.capacity, 0),
      active_sessions: p.pods.reduce((n, pod) => n + pod.active_sessions, 0),
    };
  }

  /** What the plane's summary of a session says: no team, no cost, never content. */
  private sessionJson(s: FakeSession): Record<string, unknown> {
    return {
      id: s.id,
      owner: s.owner,
      profile: s.profile,
      state: s.state,
      visibility: s.visibility,
      epoch: 1,
      last_seq: s.last_seq,
      object_bytes: s.object_bytes,
      workspace_bytes: s.workspace_bytes,
      pinned: s.pinned,
      pinned_by: s.pinned_by,
      last_active_at: s.last_active_at,
      repository: s.repository ?? null,
      github: s.github ?? null,
    };
  }

  /** What the audit compares of a profile, as the plane's `comparable/1` takes it. */
  private comparable_profile(p: FakeProfile | null): Record<string, unknown> {
    if (!p) return {};
    return {
      size_class: p.size_class,
      max_sessions: p.max_sessions ?? null,
      warm_workers: p.warm_workers ?? 0,
      provisioner: p.provisioner,
      replicas: p.replicas,
      sessions_per_pod: p.sessions_per_pod,
      config_bundle_channel: p.channel,
      image: p.image,
      spec: p.spec ?? {},
    };
  }

  /** A write's fields as the plane's preview compares them: what was sent, and the channel its spec names. */
  private comparable_attrs(attrs: Record<string, unknown>): Record<string, unknown> {
    const spec = attrs["spec"];
    if (typeof spec !== "object" || spec === null) return { ...attrs };
    const channel = (spec as Record<string, unknown>)["configBundleChannel"];
    return { ...attrs, config_bundle_channel: typeof channel === "string" && channel !== "" ? channel : "stable" };
  }

  /** What the plane refuses of a profile before it writes one, in its words. */
  private profileRefusal(attrs: Record<string, unknown>): Refusal | null {
    const spec = (attrs["spec"] ?? {}) as Record<string, unknown>;
    const storage = spec["storage"];
    const derived = ["replicas", "sessionsPerPod", "sessions_per_pod", "resources", "storage"].filter((k) =>
      k === "storage"
        ? "storage" in attrs || (storage !== undefined && (typeof storage !== "object" || storage === null || Object.keys(storage).some((s) => s !== "storageClassName")))
        : k in attrs || k in spec,
    );
    if (derived.length) {
      return refuse(INVALID_PARAMS, "invalid_params", { reason: "the plane writes these; set size_class, max_sessions and warm_workers instead", not_yours: derived });
    }
    if ("config_bundle_channel" in attrs) {
      return refuse(INVALID_PARAMS, "invalid_params", { reason: "a profile's bundle channel is spec.configBundleChannel, which its pods follow", not_yours: ["config_bundle_channel"] });
    }
    if (typeof attrs["image"] !== "string" || attrs["image"] === "") return refuse(INVALID_PARAMS, "invalid_params", { reason: "image: can't be blank" });
    const llm = spec["llm"];
    if (typeof llm === "object" && llm !== null) {
      const problem = llmProblem(llm as Record<string, unknown>);
      if (problem) return refuse(INVALID_PARAMS, "invalid_params", { reason: `spec: ${problem}` });
    }
    const verdict = this.verdict(attrs);
    if (!verdict["allowed?"]) return refuse(INVALID_PARAMS, "invalid_params", { policy_violations: verdict.violations });
    return null;
  }

  /** What the cluster policy makes of a profile: its image's repository, and the hosts its egress names. */
  private verdict(attrs: Record<string, unknown>): { "allowed?": boolean; violations: string[] } {
    const violations: string[] = [];
    const image = attrs["image"];
    if (typeof image === "string" && image !== "release" && !this.policy.imageRepositories.some((r) => image === r || image.startsWith(`${r}/`) || image.startsWith(`${r}:`) || image.startsWith(`${r}@`))) {
      violations.push(`image ${image} is not from a repository the cluster policy allows (${this.policy.imageRepositories.join(", ")})`);
    }
    const egress = ((attrs["spec"] ?? {}) as Record<string, unknown>)["egress"] as Record<string, unknown> | undefined;
    for (const host of (egress?.["fqdns"] as string[] | undefined) ?? []) {
      if (!this.egressAllowed(host)) violations.push(`egress to ${host} is not a host the cluster policy allows`);
    }
    return { "allowed?": violations.length === 0, violations };
  }

  private egressAllowed(host: string): boolean {
    return this.policy.egress.includes(host) || host.endsWith(".svc") || host.endsWith(".svc.cluster.local");
  }

  /** A server the channel's bundle calls with client credentials that the profile names no identity for. */
  private identityProblems(spec: Record<string, unknown>): string[] {
    const channel = typeof spec["configBundleChannel"] === "string" ? spec["configBundleChannel"] : "stable";
    const servers = ((this.current(channel)?.content["mcp_servers"] ?? []) as Array<Record<string, unknown>>).filter((s) => s["credential_mode"] === "client_credentials");
    const named = new Set(((spec["mcpIdentities"] ?? []) as Array<Record<string, unknown>>).map((i) => i["server"]));
    return servers.filter((s) => !named.has(s["name"])).map((s) => `mcp server ${String(s["name"])} is called with client credentials, and the profile gives it no identity in mcpIdentities`);
  }

  private gitopsOf(g: FakeProfile["gitops"]): Record<string, unknown> | null {
    if (this.mode !== "gitops") return null;
    return { locked: true, source: this.gitopsSource, generation: g?.generation ?? null, problem: g?.problem ?? null, problem_generation: null, reasons: g?.reasons ?? [] };
  }

  /** The refusal every write to what a repository holds gets on a gitops plane, recorded as the attempt it is. */
  private heldByRepository(subject: string, action: string, name: string, kind: string): Refusal | null {
    if (this.mode !== "gitops") return null;
    this.record(subject, action, name, { outcome: "refused", reason: "managed_by_gitops" });
    return refuse(MANAGED_BY_GITOPS, "managed_by_gitops", {
      kind,
      name,
      source: this.gitopsSource,
      reason: `this plane is in gitops mode: a ${kind} is a resource a repository holds${this.gitopsSource ? ` (${this.gitopsSource})` : ""}, and a change to one is a commit there`,
    });
  }

  // -- bundles -------------------------------------------------------------------------

  private bundleSummary(b: FakeBundle): Record<string, unknown> {
    return {
      channel: b.channel,
      version: b.version,
      hash: b.hash,
      summary: bundleSummaryOf(b.content),
      published_at: b.published_at,
      published_by: b.published_by,
      retired_at: b.retired_at,
    };
  }

  private bundleAt(channel: unknown, version: unknown): FakeBundle | null {
    if (typeof channel !== "string") return null;
    const n = typeof version === "string" ? Number(version) : version;
    return (this.bundles.get(channel) ?? []).find((b) => b.version === n) ?? null;
  }

  /** The newest version of a channel that is not retired: what a new session gets. */
  private current(channel: string): FakeBundle | null {
    return [...(this.bundles.get(channel) ?? [])].reverse().find((b) => b.retired_at === null) ?? null;
  }

  private adoption(p: FakeProfile, hash: string): Record<string, unknown> {
    const current = p.pods.filter((pod) => pod.bundle_hash === hash);
    const stale = p.pods.filter((pod) => pod.bundle_hash !== hash).map((pod) => ({ pod: pod.pod, reported: pod.bundle_hash }));
    return { profile: p.name, expected: hash, pods: p.pods.length, current: current.map((pod) => pod.pod), ahead: [], stale, "adopted?": stale.length === 0 && p.pods.length > 0 };
  }

  private bundleState(p: FakeProfile): Record<string, unknown> {
    const channel = p.channel ?? "stable";
    const b = this.current(channel);
    if (!b) return { channel, published: null, "adopted?": null };
    return { channel, published: b.version, ...this.adoption(p, b.hash) };
  }

  // -- triggers ------------------------------------------------------------------------

  private comparable_trigger(row: FakeTrigger): Record<string, unknown> {
    return Object.fromEntries(TRIGGER_KEYS.map((k) => [k, (row as unknown as Record<string, unknown>)[k] ?? null]));
  }

  /** What `trigger_put` refuses, in its words: what creating one needs, and each field's rule. */
  private triggerRefusal(team: FakeTeam, attrs: Record<string, unknown>, existing: FakeTrigger | null): Refusal | null {
    if (!existing) {
      for (const needed of ["principal", "profile", "source"]) {
        if (attrs[needed] === undefined || attrs[needed] === null || attrs[needed] === "") return refuse(INVALID_PARAMS, "invalid_params", { missing: needed });
      }
    }
    if ("principal" in attrs && !team.principals.includes(String(attrs["principal"]))) {
      return refuse(INVALID_PARAMS, "invalid_params", { reason: `${String(attrs["principal"])} is not a service principal of ${team.name}` });
    }
    if ("source" in attrs) {
      const source = (attrs["source"] ?? {}) as Record<string, unknown>;
      if (!["schedule", "webhook", "manual"].includes(String(source["kind"]))) return refuse(INVALID_PARAMS, "invalid_params", { reason: "source: has a kind of schedule, webhook, manual" });
      if (source["kind"] === "schedule" && (typeof source["cron"] !== "string" || source["cron"].trim().split(/\s+/).length !== 5)) {
        return refuse(INVALID_PARAMS, "invalid_params", { reason: "source: a schedule's cron is five fields, minute hour day-of-month month day-of-week" });
      }
      if (source["tz"] !== undefined && source["tz"] !== null && source["tz"] !== "" && source["tz"] !== "UTC") {
        return refuse(INVALID_PARAMS, "invalid_params", { reason: `source: ${String(source["tz"])} is not a zone this plane keeps; it keeps UTC` });
      }
    }
    if ("visibility" in attrs && !["private", "team"].includes(String(attrs["visibility"]))) return refuse(INVALID_PARAMS, "invalid_params", { reason: "visibility: is private or team" });
    if ("review" in attrs && !["required", "none"].includes(String(attrs["review"]))) return refuse(INVALID_PARAMS, "invalid_params", { reason: "review: is required or none" });
    if ("concurrency" in attrs && attrs["concurrency"] !== null && !(Number.isInteger(attrs["concurrency"]) && (attrs["concurrency"] as number) >= 1 && (attrs["concurrency"] as number) <= 100)) {
      return refuse(INVALID_PARAMS, "invalid_params", { reason: "concurrency: is 1 to 100" });
    }
    const terms = (attrs["terms"] ?? {}) as Record<string, unknown>;
    if (terms["max_turns"] !== undefined && !(Number.isInteger(terms["max_turns"]) && (terms["max_turns"] as number) >= 1 && (terms["max_turns"] as number) <= 500)) {
      return refuse(INVALID_PARAMS, "invalid_params", { reason: "terms: max_turns is 1 to 500" });
    }
    if (typeof attrs["notify_url"] === "string" && attrs["notify_url"] !== "") {
      const host = hostOf(attrs["notify_url"]);
      if (!host || !/^https?:\/\//.test(attrs["notify_url"])) return refuse(INVALID_PARAMS, "invalid_params", { reason: "notify_url: is an absolute http or https URL" });
      if (!this.egressAllowed(host)) return refuse(INVALID_PARAMS, "invalid_params", { reason: `notify_url: ${host} is not a host this deployment's egress policy allows` });
    }
    return null;
  }

  /** A new revision where the document moved; the last one where it did not, as switching it on or off does not. */
  revise(row: FakeTrigger, by: string, at = new Date().toISOString()): FakeTrigger["revisions"][number] {
    const { enabled: _enabled, ...document } = this.comparable_trigger(row);
    const hash = hashOf(document);
    const last = row.revisions.at(-1);
    if (last && last.hash === hash) return last;
    const made = { revision: (last?.revision ?? 0) + 1, hash, created_by: by, created_at: at, document };
    row.revisions.push(made);
    return made;
  }

  private triggerJson(row: FakeTrigger): Record<string, unknown> {
    const last = row.revisions.at(-1);
    const kind = (row.source ?? {})["kind"];
    return {
      id: row.id,
      team: row.team,
      name: row.name,
      principal: row.principal,
      profile: row.profile,
      agent: row.agent,
      enabled: row.enabled,
      source: row.source,
      prompt_template: row.prompt_template,
      terms: row.terms,
      visibility: row.visibility,
      review: row.review,
      notify: row.notify,
      notify_url: row.notify_url,
      concurrency: row.concurrency,
      has_key: kind === "webhook",
      key_rotated_at: kind === "webhook" ? row.updated_at : null,
      key_rotated_by: kind === "webhook" ? row.created_by : null,
      last_fired_at: row.last_fired_at,
      created_by: row.created_by,
      updated_at: row.updated_at,
      revision: last ? revisionJson(last) : null,
      ...(this.mode === "gitops" ? { gitops: { ...this.gitopsOf(row.gitops), resource: `${row.team}.${row.name}` } } : {}),
    };
  }

  /** A list method's narrowing: under `filter`, or the params themselves, as the plane reads either. */
  private filterOf(params: Record<string, unknown>): Record<string, unknown> {
    const filter = params["filter"];
    return typeof filter === "object" && filter !== null ? (filter as Record<string, unknown>) : params;
  }

  // -- the ladder ----------------------------------------------------------------------

  private tightness(spec: Laddered, value: unknown): number {
    if (spec.narrower === "lower") return typeof value === "number" ? value : Infinity;
    return value === false ? 0 : value === true ? 1 : Infinity;
  }

  private opinions(key: string, team: FakeTeam | null): Array<{ rung: string; value: unknown }> {
    const spec = LADDERED[key]!;
    const teamValue = team ? (team as unknown as Record<string, unknown>)[spec.field] : null;
    return [
      { rung: "deployment", value: spec.deployed },
      { rung: "platform", value: this.stored.has(key) ? this.stored.get(key) : null },
      { rung: "team", value: teamValue ?? null },
    ].filter((o) => o.value !== null && o.value !== undefined);
  }

  private ceiling(key: string): unknown {
    const spec = LADDERED[key]!;
    const above = this.opinions(key, null);
    return above.reduce((best, o) => (this.tightness(spec, o.value) < this.tightness(spec, best) ? o.value : best), above[0]!.value);
  }

  private effective(key: string, team: FakeTeam | null): Record<string, unknown> {
    const spec = LADDERED[key]!;
    const opinions = this.opinions(key, team);
    const winner = opinions.reduce((best, o) => (this.tightness(spec, o.value) < this.tightness(spec, best.value) ? o : best), opinions[0]!);
    return { key, field: spec.field, value: winner.value, decided_by: winner.rung, ceiling: this.ceiling(key), opinions };
  }

  // -- settings ------------------------------------------------------------------------

  private valueOf(setting: Setting): unknown {
    if (this.stored.has(setting.key)) return this.stored.get(setting.key);
    return this.deployed[setting.key] ?? setting.fallback ?? null;
  }

  private describe(setting: Setting): Record<string, unknown> {
    const value = this.valueOf(setting);
    const deployed = this.deployed[setting.key] ?? setting.fallback ?? null;
    const shown = (v: unknown) => (v === null ? null : setting.type === "enforced" ? JSON.stringify(v) : v);
    return {
      key: setting.key,
      group: setting.group,
      type: setting.type,
      values: setting.values ?? null,
      summary: setting.summary,
      consequence: setting.consequence,
      effect: "immediate",
      effect_description: "Takes effect on the next request.",
      editable: true,
      secret: false,
      set: value !== null && value !== "",
      source: this.stored.has(setting.key) ? "stored" : value === null ? "unset" : "deployed",
      deployed: shown(deployed),
      value: shown(value),
      ...(setting.type === "enforced" && this.enforceable ? { enforceable: this.enforceable } : {}),
    };
  }

  private parse(setting: Setting, raw: unknown): { value: unknown } | { error: string } {
    const text = typeof raw === "string" ? raw : JSON.stringify(raw);
    switch (setting.type) {
      case "string":
        return { value: text };
      case "enum":
        return setting.values!.includes(text) ? { value: text } : { error: `must be one of: ${setting.values!.join(", ")}` };
      case "integer":
        return /^\d+$/.test(text.trim()) ? { value: Number(text.trim()) } : { error: "must be a whole number" };
      case "boolean":
        return ["true", "false"].includes(text) ? { value: text === "true" } : { error: "must be true or false" };
      case "enforced": {
        if (text.trim() === "") return { value: {} };
        let set: unknown;
        try {
          set = JSON.parse(text);
        } catch {
          return { error: 'must be a JSON object, such as {"approvals": "deny"}' };
        }
        if (typeof set !== "object" || set === null || Array.isArray(set)) return { error: "the enforced set must be an object of keys and values" };
        const kept: Record<string, unknown> = {};
        const reasons: string[] = [];
        const listed = (this.enforceable ?? ENFORCEABLE) as ReadonlyArray<{ key: string; type?: unknown; values?: unknown; min?: unknown }>;
        for (const [key, value] of Object.entries(set as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b))) {
          if (value === null) continue;
          const spec = listed.find((e) => e.key === key);
          if (!spec) {
            const keys = listed.map((e) => e.key);
            reasons.push(`${key} is not a key an organisation may enforce; the ones it may are ${keys.slice(0, -1).join(", ")} and ${keys.at(-1)}`);
            continue;
          }
          const values = (spec.values ?? []) as string[];
          const min = typeof spec.min === "number" ? spec.min : 0;
          const ok =
            spec.type === "enum"
              ? typeof value === "string" && values.includes(value)
              : spec.type === "string"
                ? typeof value === "string" && value !== ""
                : spec.type === "boolean"
                  ? typeof value === "boolean"
                  : Number.isInteger(value) && (value as number) >= min;
          if (ok) kept[key] = value;
          else
            reasons.push(
              `${key} must be ${spec.type === "integer" ? `a whole number, at least ${min}` : spec.type === "enum" ? `one of ${values.join(", ")}` : spec.type === "boolean" ? "true or false" : "a non-empty string"}, not ${JSON.stringify(value)}`,
            );
        }
        return reasons.length ? { error: reasons.join("; ") } : { value: kept };
      }
    }
  }

  private record(actor: string, action: string, subject: string, detail: Record<string, unknown>): void {
    this.audit.push({ actor, action, subject_kind: action.split(".")[0] ?? null, subject_id: subject, detail, occurred_at: new Date().toISOString() });
  }
}

/** A team with the plane's shape, everything not given empty or unset. */
export function team(name: string, fields: Partial<FakeTeam> = {}): FakeTeam {
  return {
    name,
    budget_micros: null,
    budget_period: "monthly",
    spent_micros: 0,
    reserved_micros: 0,
    members_may_control: null,
    idle_timeout_seconds: null,
    cache_eviction_days: null,
    erase_after_days: null,
    pins_allowed: null,
    volume_storage_class: null,
    volume_size: null,
    allow_unenforced_workers: false,
    admins: [],
    grants: [],
    groups: [],
    members: [],
    spend_by_model: [],
    principals: [],
    triggers: [],
    ...fields,
  };
}

/** A pod, healthy and reporting unless told otherwise. */
export function pod(name: string, ordinal: number, fields: Partial<FakePod> = {}): FakePod {
  return {
    pod: name,
    ordinal,
    healthy: true,
    draining: false,
    last_seen_at: "2026-10-13T08:59:30Z",
    capacity: 4,
    active_sessions: 0,
    disk_fraction: 0.2,
    version: "0.17.0-beta",
    bundle_hash: "sha256:5d1c0b7e",
    worker_id: `w-${name}`,
    ...fields,
  };
}

/** A session with the plane's shape, a person's, active and unpinned unless told otherwise. */
export function session(id: string, owner: string, team: string | null, profile: string, fields: Partial<FakeSession> = {}): FakeSession {
  return {
    id,
    owner,
    team,
    profile,
    state: "active",
    visibility: "team",
    last_seq: 40,
    object_bytes: 2_400_000,
    workspace_bytes: 180_000_000,
    pinned: false,
    pinned_by: null,
    last_active_at: "2026-10-13T08:00:00Z",
    parent: null,
    origin: "user",
    reviewed: false,
    ...fields,
  };
}

/**
 * An organisation to look at: Alice administers the platform, Bob the design team, and
 * Carol nothing. Three teams — one with everything set, one over its budget, one with
 * nothing yet — four profiles (one short of a pod, one draining, one on machines nothing
 * is enforced on), sessions on them, a gateway the clients default to, and an audit with
 * some history in it.
 */
export function exampleAdmin(): FakeAdmin {
  const member = (subject: string, display_name: string, spent_micros = 0, budget_micros: number | null = null) => ({
    subject,
    display_name,
    budget_micros,
    spent_micros,
    reserved_micros: 0,
  });
  const admin = new FakeAdmin({
    platformAdmins: ["alice@example.com"],
    groups: [
      { external_id: "grp-core", display_name: "Core engineering" },
      { external_id: "grp-design", display_name: "Design" },
      { external_id: "grp-research", display_name: "Research" },
      { external_id: "grp-platform", display_name: "Platform owners" },
    ],
    memberships: {
      "grp-core": ["alice@example.com", "dan@example.com", "erin@example.com"],
      "grp-design": ["bob@example.com", "fay@example.com"],
      "grp-research": ["gus@example.com"],
      "grp-platform": ["alice@example.com", "hana@example.com"],
    },
    names: {
      "alice@example.com": "Alice",
      "bob@example.com": "Bob",
      "dan@example.com": "Dan",
      "erin@example.com": "Erin",
      "fay@example.com": "Fay",
      "gus@example.com": "Gus",
      "hana@example.com": "Hana",
    },
    deployed: { client_provider: "openai", client_base_url: "https://llm-gw.example.com/v1", client_auth: "bearer" },
    teams: [
      team("core", {
        budget_micros: 500_000_000,
        spent_micros: 212_400_000,
        reserved_micros: 4_000_000,
        idle_timeout_seconds: 1200,
        cache_eviction_days: 5,
        erase_after_days: 90,
        pins_allowed: true,
        members_may_control: true,
        volume_size: "20Gi",
        volume_storage_class: "fast-ssd",
        admins: ["dan@example.com"],
        grants: [
          { profile: "dev", volume_mode: "rw" },
          { profile: "ux", volume_mode: "ro" },
        ],
        groups: [{ external_id: "grp-core", display_name: "Core engineering", issuer: "https://idp.example.com", linked_by: "alice@example.com" }],
        members: [member("alice@example.com", "Alice", 80_000_000), member("dan@example.com", "Dan", 120_000_000, 150_000_000), member("erin@example.com", "Erin", 12_400_000)],
        spend_by_model: [{ model: "sonnet", spent_micros: 180_000_000 }],
        principals: ["svc:core/nightly"],
      }),
      team("design", {
        budget_micros: 250_000_000,
        spent_micros: 261_100_000,
        erase_after_days: 30,
        members_may_control: false,
        admins: ["bob@example.com"],
        grants: [{ profile: "ux", volume_mode: "ro" }],
        groups: [{ external_id: "grp-design", display_name: "Design", issuer: "https://idp.example.com", linked_by: "alice@example.com" }],
        members: [member("bob@example.com", "Bob", 200_000_000), member("fay@example.com", "Fay", 61_100_000)],
        principals: ["svc:design/digest"],
      }),
      team("research"),
    ],
    profiles: [
      {
        name: "dev",
        size_class: "standard",
        replicas: 2,
        sessions_per_pod: 4,
        channel: "stable",
        image: "registry.example.com/troupe/worker:0.17.0-beta",
        provisioner: "kubernetes",
        missing_guarantees: [],
        unenforced: false,
        pods: [pod("troupe-w-dev-0", 0, { active_sessions: 3 }), pod("troupe-w-dev-1", 1, { draining: true, active_sessions: 1 })],
        max_sessions: 12,
        warm_workers: 1,
        // Every part of a spec: what the editor has fields for, what it has none for
        // (identities, GitHub, prices, a server's credential settings, a field the console
        // has never heard of) and what the plane writes itself (`sessionsPerPod`).
        spec: {
          llm: {
            endpoint: "https://llm-gw.example.com/v1",
            provider: "openai",
            model: "glm-5.2",
            smallModel: "qwen3.6-35b",
            secretRef: { name: "llm-gateway", key: "api-key" },
            prices: { "glm-5.2": { input: 0.5, output: 1.5 } },
          },
          egress: { fqdns: ["llm-gw.example.com", "mcp.example.com"], gitHosts: ["github.example.com"] },
          storage: { storageClassName: "fast-ssd" },
          mcpServers: [
            {
              name: "jira",
              url: "https://mcp.example.com/jira",
              credentialRef: "JIRA_TOKEN",
              header: "authorization",
              timeoutMs: 30000,
              secretRef: { name: "jira-mcp", key: "token" },
              credentialMode: "profile",
            },
          ],
          mcpIdentities: [
            {
              server: "wiki",
              clientId: "troupe-dev",
              scope: "wiki.read",
              tokenUrl: "https://login.example.com/oauth2/token",
              transitKey: "troupe-dev",
              keyVersion: 2,
              algorithm: "RS256",
            },
          ],
          github: { permissions: { contents: "write", pull_requests: "write", checks: "read" } },
          configBundleChannel: "stable",
          orgMount: true,
          repositoryOverridesBundle: false,
          personalTools: "allow",
          sandboxHints: { tmpfs: "1Gi" },
          sessionsPerPod: 4,
        },
      },
      {
        name: "ux",
        size_class: "standard",
        replicas: 1,
        sessions_per_pod: 4,
        channel: "stable",
        image: "registry.example.com/troupe/worker:0.17.0-beta",
        provisioner: "kubernetes",
        missing_guarantees: [],
        unenforced: false,
        pods: [pod("troupe-w-ux-0", 0, { active_sessions: 2 })],
        warm_workers: 1,
        spec: { egress: { fqdns: ["mcp.example.com"] }, configBundleChannel: "stable", personalTools: "forbid" },
      },
      {
        name: "heavy",
        size_class: "heavy",
        replicas: 2,
        sessions_per_pod: 2,
        channel: "canary",
        image: "registry.example.com/troupe/worker:0.17.0-beta",
        provisioner: "kubernetes",
        missing_guarantees: [],
        unenforced: false,
        pods: [pod("troupe-w-heavy-0", 0, { capacity: 2, bundle_hash: "sha256:c4a7e9d2" })],
        max_sessions: 4,
        spec: { configBundleChannel: "canary" },
      },
      {
        name: "build-box",
        size_class: "standard",
        replicas: 1,
        sessions_per_pod: 2,
        channel: "stable",
        image: null,
        provisioner: "ssh",
        missing_guarantees: ["sandbox", "egress_by_hostname"],
        unenforced: true,
        pods: [pod("build-box-0", 0, { healthy: false, last_seen_at: null, capacity: 2 })],
      },
    ],
    sessions: [
      session("s-7f3a9c21", "alice@example.com", "core", "dev", { last_active_at: "2026-10-13T08:52:00Z", last_seq: 212 }),
      session("s-7f3a9c22", "dan@example.com", "core", "dev", { state: "dormant", pinned: true, pinned_by: "dan@example.com", last_active_at: "2026-10-12T17:10:00Z" }),
      session("s-7f3a9c23", "erin@example.com", "core", "ux", {
        last_active_at: "2026-10-13T08:40:00Z",
        workspace_bytes: 64_000_000,
        // Pushed its branch and opened no pull request yet.
        repository: { owner: "example-org", name: "gadgets", ref: "main" },
        github: { branch: "troupe/session-s-7f3a9c23", commit: "9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d", pushes: 1 },
      }),
      session("s-7f3a9c24", "svc:core/nightly", "core", "dev", {
        origin: "trigger",
        visibility: "team",
        last_active_at: "2026-10-13T03:05:00Z",
        repository: { owner: "example-org", name: "widgets", ref: null },
        github: {
          branch: "troupe/issue-7-fix-login",
          commit: "4f1c2a9e0b7d6c5a4f3e2d1c0b9a8f7e6d5c4b3a",
          pushes: 3,
          pull_request: { number: 7, url: "https://github.example.com/example-org/widgets/pull/7" },
          stopped: { at: "2026-10-13T03:40:00Z", reason: "3 red CI rounds" },
        },
      }),
      session("s-7f3a9c25", "dan@example.com", "core", "dev", { state: "dormant", parent: "s-7f3a9c22", last_active_at: "2026-10-11T15:00:00Z" }),
      session("s-7f3a9c26", "erin@example.com", "core", "dev", { state: "read_only", last_active_at: "2026-10-09T11:20:00Z", object_bytes: 9_800_000 }),
      session("s-7f3a9c27", "alice@example.com", "core", "ux", { state: "dormant", visibility: "private", last_active_at: "2026-10-10T09:45:00Z" }),
      session("s-4b81d003", "bob@example.com", "design", "ux", { last_active_at: "2026-10-13T08:30:00Z", last_seq: 97 }),
      session("s-4b81d004", "fay@example.com", "design", "ux", { state: "dormant", last_active_at: "2026-10-12T14:00:00Z" }),
      session("s-4b81d005", "bob@example.com", "design", "ux", { state: "dormant", last_active_at: "2026-10-08T10:00:00Z" }),
    ],
  });
  // Two versions of stable, the second current and on every pod; one of canary, which
  // the heavy profile follows.
  const reviewer = { name: "pr-reviewer", definition: "---\nmode: primary\ndescription: Reviews a pull request against the checklist.\n---\nYou review pull requests.", skills: ["review-checklist"] };
  const checklist = { name: "review-checklist", description: "How we review.", files: { "SKILL.md": "---\nname: review-checklist\n---\nRead the diff twice.", "checklist.md": "- tests\n- docs" } };
  const jira = { name: "jira", url: "https://mcp.example.com/jira", credential_ref: "JIRA_TOKEN", permission: "ask", tools: ["search_issues", "get_issue"] };
  admin.bundles.set("stable", [
    {
      channel: "stable",
      version: 1,
      hash: "sha256:9b2f41aa",
      content: { schema: 1, agents: [reviewer], skills: [checklist], mcp_servers: [jira] },
      published_at: "2026-10-02T10:00:00Z",
      published_by: "alice@example.com",
      retired_at: null,
    },
    {
      channel: "stable",
      version: 2,
      hash: "sha256:5d1c0b7e",
      content: {
        schema: 1,
        agents: [reviewer, { name: "docs-writer", definition: "---\nmode: subagent\ndescription: Writes the docs a change needs.\n---\nYou write docs." }],
        skills: [checklist],
        mcp_servers: [jira, { name: "wiki", url: "https://wiki.example.com/mcp", credential_mode: "client_credentials", permission: "auto" }],
      },
      published_at: "2026-10-09T14:20:00Z",
      published_by: "alice@example.com",
      retired_at: null,
    },
  ]);
  admin.bundles.set("canary", [
    {
      channel: "canary",
      version: 1,
      hash: "sha256:c4a7e9d2",
      content: { schema: 1, agents: [reviewer], skills: [checklist], mcp_servers: [] },
      published_at: "2026-10-11T08:00:00Z",
      published_by: "alice@example.com",
      retired_at: null,
    },
  ]);
  // Core may use the reviewer on dev: a version without it takes that away from core.
  admin.entitlements.push({ team: "core", profile: "dev", kind: "agent", name: "pr-reviewer", mode: "allow" });
  const nightly = {
    principal: "svc:core/nightly",
    profile: "dev",
    agent: "pr-reviewer",
    source: { kind: "schedule", cron: "0 3 * * 1-5", tz: "UTC" },
    prompt_template: "Update the dependencies of {{trigger.name}} and open a pull request.",
    terms: { max_turns: 80, approvals: "deny" },
    visibility: "team",
    review: "required",
    notify: ["dan@example.com"],
    notify_url: null,
    concurrency: 1,
  };
  admin.triggerRows.push(
    {
      id: "trg-core-nightly-deps",
      team: "core",
      name: "nightly-deps",
      enabled: true,
      ...nightly,
      last_fired_at: "2026-10-13T03:00:00Z",
      created_by: "dan@example.com",
      updated_at: "2026-10-05T12:00:00Z",
      revisions: [],
    },
    {
      id: "trg-design-weekly-digest",
      team: "design",
      name: "weekly-digest",
      principal: "svc:design/digest",
      profile: "ux",
      agent: null,
      enabled: false,
      source: { kind: "webhook", provider: "github" },
      prompt_template: "Summarise what changed in {{event.repository}} this week.",
      terms: null,
      visibility: "team",
      review: "none",
      notify: [],
      notify_url: "https://hooks.example.com/troupe",
      concurrency: 2,
      last_fired_at: null,
      created_by: "bob@example.com",
      updated_at: "2026-10-08T09:00:00Z",
      revisions: [],
    },
  );
  for (const row of admin.triggerRows) admin.revise(row, row.created_by, row.updated_at);
  admin.stored.set("client_model_default", "glm-5.2");
  admin.stored.set("client_enforced", { approvals: "wait", max_turns: 200 });
  admin.stored.set("default_erase_after_days", 180);
  admin.policies["tui"] = { recommended: "0.16.0-beta", minimum: "0.14.0-beta", blocked: ["0.15.0-beta"], updated_by: "alice@example.com", updated_at: "2026-10-11T09:30:00Z" };
  // What the plane would have recorded getting here: some history for the Audit screen.
  admin.audit.push(
    { actor: "alice@example.com", action: "team.enable", subject_kind: "team", subject_id: "core", detail: { group: "grp-core" }, occurred_at: "2026-10-01T09:00:00Z" },
    { actor: "alice@example.com", action: "team.grant", subject_kind: "team", subject_id: "core", detail: { profile: "dev" }, occurred_at: "2026-10-01T09:02:00Z" },
    { actor: "alice@example.com", action: "team.enable", subject_kind: "team", subject_id: "design", detail: { group: "grp-design" }, occurred_at: "2026-10-02T10:15:00Z" },
    { actor: "alice@example.com", action: "team.admin.add", subject_kind: "team", subject_id: "design", detail: { subject: "bob@example.com" }, occurred_at: "2026-10-02T10:16:00Z" },
    { actor: "dan@example.com", action: "team.update", subject_kind: "team", subject_id: "core", detail: { idle_timeout_seconds: { from: 1800, to: 1200 } }, occurred_at: "2026-10-07T13:41:00Z" },
    { actor: "alice@example.com", action: "setting.put", subject_kind: "setting", subject_id: "client_model_default", detail: { client_model_default: { from: null, to: "glm-5.2" } }, occurred_at: "2026-10-10T08:05:00Z" },
    { actor: "alice@example.com", action: "clients.put", subject_kind: "clients", subject_id: "tui", detail: { minimum: { from: null, to: "0.14.0-beta" } }, occurred_at: "2026-10-11T09:30:00Z" },
  );
  return admin;
}
