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
import { PROVIDER_TYPES } from "./provider-types.js";
import { MAX_DEPTH, WRITTEN_KEYS, empty as emptyResolved, fieldsOf, merge as mergeExtends, rowOf } from "./extends.js";
import type { Resolved } from "./extends.js";

type Refusal = { error: { code: number; message: string; data?: unknown } };
type IdentityCheckRow = { name: string; ok: boolean; detail: string; took_ms: number };
type Answer = { result: unknown } | Refusal;
type Role = "platform_admin" | "team_admin" | "none";
type Changes = Record<string, { from: unknown; to: unknown }>;

const FORBIDDEN = -32004;
const NOT_FOUND = -32005;
const INVALID_PARAMS = -32602;
const METHOD_NOT_FOUND = -32601;
const MANAGED_BY_GITOPS = -32015;
const CONFLICT = -32006;

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

/** A secret the plane mints and shows once: a prefix and random letters. */
let minted = 0;
function secretOf(prefix: string): string {
  minted += 1;
  return `${prefix}_${minted.toString(36)}${Math.random().toString(36).slice(2, 14)}${Math.random().toString(36).slice(2, 14)}`;
}

/** Whether a notification target still passes the rule it was accepted under, in `Notify.validate/1`'s words. */
function notifyRefusal(url: string): string | null {
  const host = hostOf(url);
  if (!host || !/^https?:\/\//.test(url)) return "a target is an absolute http or https URL that names a host";
  if (["localhost", "127.0.0.1", "::1", "[::1]"].includes(host)) return "a target may not be this machine";
  return null;
}

/** A machine as `host_summary/1` answers: never the hash, and three states. */
function hostJson(h: FakeHost): Record<string, unknown> {
  return { ...h, state: !h.enabled ? "disabled" : h.last_enrolled_at === null ? "never_seen" : "enrolled" };
}

/** Where clones come from, for an API URL, as `GitHub.git_url/1` reads it; null for a URL that is no GitHub's. */
function gitUrlOf(api: string): string | null {
  try {
    const u = new URL(api);
    const path = u.pathname.replace(/\/+$/, "");
    if (u.protocol !== "https:") return null;
    if (u.hostname.startsWith("api.") && path === "") return `https://${u.hostname.slice(4)}`;
    if (path === "/api/v3") return `https://${u.host}`;
    return null;
  } catch {
    return null;
  }
}

/** A manifest as YAML, with any notes as comments above it: enough of YAML for the console to show one. */
function yamlOf(value: unknown, notes: string[]): string {
  const scalar = (v: unknown) => (typeof v === "string" ? (/^[\w./:@-]+$/.test(v) ? v : JSON.stringify(v)) : JSON.stringify(v ?? null));
  const lines = (v: unknown, indent: string): string[] => {
    if (Array.isArray(v)) return v.length === 0 ? [`${indent}[]`] : v.flatMap((x) => (typeof x === "object" && x !== null ? [`${indent}-`, ...lines(x, `${indent}  `)] : [`${indent}- ${scalar(x)}`]));
    if (typeof v === "object" && v !== null) {
      return Object.entries(v).flatMap(([k, x]) =>
        typeof x === "object" && x !== null && (Array.isArray(x) ? x.length > 0 : Object.keys(x).length > 0) ? [`${indent}${k}:`, ...lines(x, `${indent}  `)] : [`${indent}${k}: ${Array.isArray(x) ? "[]" : typeof x === "object" && x !== null ? "{}" : scalar(x)}`],
      );
    }
    return [`${indent}${scalar(v)}`];
  };
  return [...notes.map((n) => `# ${n}`), ...lines(value, "")].join("\n") + "\n";
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
  /** The repositories its sessions may name and the fix loop's caps, as the plane answers them. */
  github: { repositories: string[]; max_pushes: number | null; max_runs: number | null };
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
  /** The one profile this one extends; with one, the fields above are the profile in effect and `own` what it wrote. */
  extends?: string | null;
  own?: Record<string, unknown> | null;
  /** On a gitops plane: the resource generation it was read at, and what the last pass said of it. */
  gitops?: { generation: number | null; problem: string | null; reasons: string[] };
  /** The WorkerProfile's status conditions, as the operator wrote them. */
  conditions?: Array<{ type: string; status: string; reason?: string; message?: string }>;
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
  /** Whether it has a webhook key; where absent, a webhook that names no repository has one. */
  has_key?: boolean;
}

/** A trigger's run, as `admin.runs.list` answers it, with the team whose trigger it is. */
export interface FakeRun {
  id: string;
  team: string;
  trigger: string;
  trigger_id: string;
  idempotency_key: string;
  session_id: string | null;
  fired_at: string;
  fired_by: string | null;
  source: string;
  revision: number | null;
  revision_hash: string | null;
  event: Record<string, unknown> | null;
  state: string;
  status: string | null;
  done_reason: string | null;
  failed_reason: string | null;
  pending_approvals: number | null;
  pending_questions: number | null;
  cost_micros: number | null;
  repository: string | null;
  issue: { number: number; url: string | null; title: string | null } | null;
  github: Record<string, unknown> | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
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
  type: "string" | "enum" | "integer" | "boolean" | "enforced" | "list";
  values?: string[];
  summary: string;
  consequence: string;
  fallback?: unknown;
  /** Never shown: the plane says whether one is set. */
  secret?: boolean;
  /** `false` for what belongs to the deployment and is listed here to be read. */
  editable?: boolean;
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

// The plane's settings, in its panels' order. The organisation's document and the client
// defaults are the console's Organisation screen; sign-in is its Sign-in screen; the rest
// are Policy and settings.
const SETTINGS: Setting[] = [
  {
    key: "platform_admin_group",
    group: "administration",
    type: "string",
    summary: "The identity-provider group whose members administer this whole platform.",
    consequence: "Members of this group can do everything here. Setting it to a group you are not in removes your own access at your next request; a break-glass session can put it back.",
  },
  {
    key: "groups_claim",
    group: "administration",
    type: "string",
    fallback: "groups",
    summary: "The claim in an identity token that carries a person's groups.",
    consequence: "Wrong, and every login arrives with no groups: nobody is a platform admin and nobody is in a team.",
  },
  { key: "platform_budget_micros", group: "administration", type: "integer", summary: "What the whole platform may spend in a month, in millionths.", consequence: "Above every team's. It only ever narrows." },
  {
    key: "provisioning_mode",
    group: "provisioning",
    type: "enum",
    values: ["direct", "gitops"],
    fallback: "direct",
    editable: false,
    summary: "Whether this plane writes profiles to the cluster, or reads them from resources a repository puts there.",
    consequence: "Deployment only.",
  },
  { key: "default_budget_micros", group: "team_defaults", type: "integer", summary: "What a new team may spend, in millionths; 0 is no ceiling.", consequence: "Existing teams keep theirs." },
  { key: "default_budget_period", group: "team_defaults", type: "enum", values: ["monthly", "never"], fallback: "monthly", summary: "Whether a new team's ceiling turns over each month or is a total.", consequence: "Existing teams keep theirs." },
  { key: "default_idle_timeout_seconds", group: "team_defaults", type: "integer", fallback: 1800, summary: "How long a session sits idle before it is put to sleep.", consequence: "No team may set a longer one." },
  { key: "default_cache_eviction_days", group: "team_defaults", type: "integer", fallback: 7, summary: "How long a dormant session's workspace is kept on a pod's disk.", consequence: "No team may set a longer one." },
  { key: "default_erase_after_days", group: "team_defaults", type: "integer", fallback: 365, summary: "How long a session is kept before it is erased.", consequence: "No team may keep sessions longer." },
  { key: "pins_allowed", group: "team_defaults", type: "boolean", fallback: true, summary: "Whether a session may be pinned against eviction.", consequence: "Off here and no team may turn it on, whatever their own setting says." },
  { key: "members_may_control", group: "team_defaults", type: "boolean", fallback: true, summary: "Whether a team's members may drive each other's sessions.", consequence: "Off here and no team may turn it on." },
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
  { key: "managed_mcp_servers_only", group: "sessions", type: "boolean", fallback: false, summary: "Whether a session may use only the MCP servers its bundle names.", consequence: "On, a person's own servers are not offered to sessions here." },
  { key: "default_bundle_channel", group: "sessions", type: "string", fallback: "stable", summary: "The channel a profile follows when it names none.", consequence: "Profiles that name one keep theirs." },
  { key: "issuer", group: "sign_in", type: "string", summary: "The identity provider's issuer URL.", consequence: "Wrong, and nobody signs in. Saved behind a check; reset puts the deployment's back." },
  { key: "client_id", group: "sign_in", type: "string", summary: "This plane's client id at the provider.", consequence: "The provider refuses a sign-in for a client it does not know." },
  { key: "client_secret", group: "sign_in", type: "string", secret: true, summary: "The client's secret, for the console's code exchange.", consequence: "Never shown. A blank field keeps it." },
  { key: "authorization_endpoint", group: "sign_in", type: "string", summary: "Where a browser is sent to sign in; blank means the one discovery names.", consequence: "Must agree with what the provider publishes." },
  { key: "device_authorization_endpoint", group: "sign_in", type: "string", summary: "Where the CLI asks for a device code; blank means discovery's.", consequence: "Must agree with what the provider publishes." },
  { key: "token_endpoint", group: "sign_in", type: "string", summary: "Where codes are exchanged for tokens; blank means discovery's.", consequence: "Must agree with what the provider publishes." },
  { key: "scopes", group: "sign_in", type: "list", fallback: "openid profile email", summary: "The scopes a sign-in asks for.", consequence: "Without openid there is no identity to verify." },
  { key: "subject_claim", group: "sign_in", type: "string", fallback: "sub", editable: false, summary: "Which claim is the person.", consequence: "Deployment only." },
  { key: "audience", group: "deployment", type: "string", editable: false, summary: "The audience a plane token carries.", consequence: "Deployment only. Workers and the plane must agree." },
  { key: "base_url", group: "deployment", type: "string", editable: false, summary: "Where this plane is.", consequence: "Deployment only. The OIDC redirect must match it exactly." },
  { key: "scim_token", group: "deployment", type: "string", secret: true, editable: false, summary: "The deployment's own SCIM token.", consequence: "Deployment only, and never shown." },
  { key: "breakglass_token", group: "deployment", type: "string", secret: true, editable: false, summary: "The break-glass door's token.", consequence: "Deployment only, and never shown." },
];

/** The keys of the identity provider's settings, as `admin.provider.*` take them. */
const SIGN_IN_KEYS = ["issuer", "client_id", "client_secret", "authorization_endpoint", "device_authorization_endpoint", "token_endpoint", "scopes"];

const GROUPS = [
  { key: "administration", title: "Who administers this platform", blurb: "Both of these decide whether anybody can use this console at all." },
  { key: "provisioning", title: "How a change reaches the cluster", blurb: "Both are the deployment's to decide." },
  { key: "team_defaults", title: "What a new team starts with", blurb: "Applied when a group is enabled as a team." },
  {
    key: "client_defaults",
    title: "What people's own machines talk to",
    blurb:
      "The organisation's defaults for a person's local sessions, below their own settings: provider, URL and models. Never a key; each person pastes their own. And what those sessions may not go past, above everything a person sets.",
  },
  { key: "sessions", title: "What a new session runs with", blurb: "Defaults for work started after the change." },
  { key: "sign_in", title: "Where people sign in", blurb: "The identity provider, on its own screen." },
  { key: "deployment", title: "What this plane was deployed with", blurb: "Read-only here on purpose. Change them in the deployment and roll it." },
];

/** What each substrate gives a profile's workers, as `Provisioner.account/1` names them. */
const PROVISIONERS = [
  {
    name: "kubernetes",
    guarantees: ["admission_policy", "network_policy", "egress_checked_at_admission", "disruption_budget"],
    missing: ["fqdn_egress"],
    instead: { fqdn_egress: "egress_checked_at_admission" },
  },
  { name: "ssh", guarantees: [], missing: ["admission_policy", "network_policy", "fqdn_egress", "disruption_budget"], instead: {} },
];

/** The size classes a profile may be, as `admin.profile.choices` lists them. */
const SIZE_CLASS_CHOICES = [
  { name: "standard", sessions_per_worker: 4, summary: "Several sessions share a worker. Right for most work." },
  { name: "heavy", sessions_per_worker: 2, summary: "Fewer sessions per worker, with more CPU, memory and disk each." },
];

/** A machine registered to a profile, as the fake keeps one. */
export interface FakeHost {
  name: string;
  profile: string;
  address: string | null;
  enabled: boolean;
  registered_at: string;
  last_enrolled_at: string | null;
}

/** A team's service principal beyond its subject: what a principal row says. */
export interface FakePrincipal {
  subject: string;
  team: string;
  name: string;
  description: string | null;
  profiles: string[];
  sponsor: string | null;
  created_by: string;
  created_at: string;
  disabled_at: string | null;
  disabled_reason: string | null;
  last_used_at: string | null;
}

/** The control port's CA, as a registered machine is given it. */
const CONTROL_CA = "-----BEGIN CERTIFICATE-----\nMIIBfakeControlPortCAforTheConsoleTests0000000000000000000000000000\n-----END CERTIFICATE-----\n";

const GITHUB_OWNER = /^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$/;

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
  "github",
];
const INTEGER_KEYS = ["budget_micros", "idle_timeout_seconds", "cache_eviction_days", "erase_after_days"];

type TeamGitHubFake = FakeTeam["github"];

/** A repository a team may list: `owner/name`, or `owner/*` for every one of the owner's. */
const TEAM_REPOSITORY = /^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}\/(?:\*|[A-Za-z0-9._-]{1,100})$/;

/** A team's `github` as the plane reads it: only the keys sent, each checked, over what the team has. */
function readTeamGitHub(current: TeamGitHubFake, sent: unknown): { github: TeamGitHubFake } | { refused: Answer } {
  const refused = (field: string, reason: string) => ({ refused: refuse(INVALID_PARAMS, "invalid_params", { field, reason }) });
  if (sent === null) return { github: { repositories: [], max_pushes: null, max_runs: null } };
  if (typeof sent !== "object" || Array.isArray(sent)) return refused("github", "github is an object: {repositories, max_pushes, max_runs}");
  const github = { ...current };
  for (const [key, value] of Object.entries(sent as Record<string, unknown>)) {
    if (key === "repositories") {
      if (value !== null && !Array.isArray(value)) return refused("github.repositories", "repositories is a list of owner/name, or owner/*");
      const list = (value ?? []) as unknown[];
      const bad = list.find((r) => typeof r !== "string" || !TEAM_REPOSITORY.test(r.trim()) || r.trim().endsWith("/.."));
      if (bad !== undefined) return refused("github.repositories", `${JSON.stringify(bad)} is not a repository: owner/name, or owner/* for every repository of the owner`);
      github.repositories = [...new Set((list as string[]).map((r) => r.trim()))];
    } else if (key === "max_pushes" || key === "max_runs") {
      if (value !== null && !(Number.isInteger(value) && (value as number) >= 1 && (value as number) <= 1000)) {
        return refused(`github.${key}`, `github.${key} is a whole number from 1 to 1000, not ${JSON.stringify(value)}`);
      }
      github[key] = value as number | null;
    } else {
      return refused(`github.${key}`, "github takes repositories, max_pushes, max_runs");
    }
  }
  return { github };
}
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
  readonly runRows: FakeRun[] = [];
  readonly entitlements: FakeEntitlement[] = [];
  /** The cluster policy, as far as a profile and a bundle are checked against it. */
  readonly policy = {
    imageRepositories: ["registry.example.com/troupe"],
    egress: ["llm-gw.example.com", "mcp.example.com", "wiki.example.com", "github.example.com", "hooks.example.com"],
  };
  /** The plane's GitHub App, as `admin.github.put` left it. */
  readonly github: {
    app_id: number | null;
    api_url: string | null;
    installations: Array<{ owner: string; installation_id: number }>;
    key: { type: string; fingerprint: string; version: number } | null;
    /** The transit version the webhook secret is at; null for none. */
    webhook_secret_version: number | null;
    updated_by: string | null;
    updated_at: string | null;
  } = { app_id: null, api_url: null, installations: [], key: null, webhook_secret_version: null, updated_by: null, updated_at: null };
  /** The deliveries the App's webhook took, oldest first. */
  readonly deliveries: Array<{ id: string; event: string; action: string | null; received_at: string; outcome: Record<string, unknown> | null }> = [];
  /** What GitHub itself knows of an App: its slug, the key it holds the public half of, and where it is installed. */
  githubKnows: { app_id: number; slug: string; fingerprint: string; installations: Array<{ owner: string; installation_id: number }> } | null = null;
  /** The machines registered to profiles. */
  readonly hostRows: FakeHost[] = [];
  /** Service principals beyond their subjects, by subject. */
  readonly principalRows = new Map<string, FakePrincipal>();
  /** People who look held twice, as `Identity.lookalikes/0` would set them out. */
  readonly peopleAlike: Array<{ by: string; people: Array<Record<string, unknown>>; likely: string; [k: string]: unknown }> = [];
  /** Person-mode MCP servers and the profiles that carry them; which people have connected to which slot. */
  readonly personServers: Array<{ name: string; slot: string; profiles: string[] }> = [];
  readonly connected = new Set<string>();
  /** The issuers whose discovery answers: a provider check passes for these. */
  readonly answeringIssuers = new Set<string>(["https://idp.example.com"]);
  /** The SCIM connector. */
  readonly scimState = {
    token_set: false,
    rotated_at: null as string | null,
    rotated_by: null as string | null,
    last_seen_at: null as string | null,
    last_seen_op: null as string | null,
    teams_from_groups: false,
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
        if ("github" in attrs) {
          // As `GitHub.Policy.read_team/2` reads it: the keys sent, over what the team has.
          const read = readTeamGitHub(team.github, attrs["github"]);
          if ("refused" in read) return read.refused;
          attrs["github"] = read.github;
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
        // As written, for an editor to send back; the summary is the profile in effect.
        const written = this.writtenOf(p);
        const result: Record<string, unknown> = {
          profile: this.profileJson(p),
          spec: written["spec"] ?? {},
          written: { ...written, extends: p.extends ?? null },
          extended_by: this.childrenOf(p.name),
          policy: this.verdict({ name: p.name, image: p.image, spec: p.spec ?? {} }),
          bundle: this.bundleState(p),
          identity_problems: this.identityProblems(p.spec ?? {}),
          gitops: this.gitopsOf(p.gitops),
        };
        if (params["effective"] === true) {
          const resolved = this.resolveProfile(p.name, {});
          result["effective"] =
            typeof resolved === "string"
              ? { extends: p.extends ?? null, chain: [], profile: null, fields: [], problems: [resolved] }
              : { extends: p.extends ?? null, chain: resolved.chain, profile: rowOf(resolved), fields: fieldsOf(resolved), problems: resolved.problems };
        }
        return { result };
      }

      case "admin.profile.preview":
      case "admin.profile.put": {
        if (role !== "platform_admin") return notPlatform;
        const sentAttrs = ((typeof params["profile"] === "object" && params["profile"] !== null ? params["profile"] : params) ?? {}) as Record<string, unknown>;
        const name = sentAttrs["name"];
        if (typeof name !== "string" || name === "") return refuse(INVALID_PARAMS, "invalid_params", { reason: "a profile has a name", missing: ["name"] });
        const before = this.profiles.find((p) => p.name === name) ?? null;
        const parent = typeof sentAttrs["extends"] === "string" && sentAttrs["extends"] !== "" ? sentAttrs["extends"] : null;
        if (parent && method === "admin.profile.put" && this.mode === "gitops") {
          this.record(subject, "profile.put", name, { outcome: "refused", reason: "managed_by_gitops", extends: parent });
          return refuse(MANAGED_BY_GITOPS, "managed_by_gitops", {
            kind: "WorkerProfile",
            name,
            extends: parent,
            reason: `this plane is in gitops mode, and a profile extends another only on a plane that writes its profiles itself: a repository's manifest holds the whole profile, ${parent}'s fields included, until a plane resolves extends from a repository`,
          });
        }
        // A write that names a parent, or stops naming one, is the profile in effect.
        const effect = this.inEffect(name, sentAttrs, parent, before);
        if (typeof effect === "string") return refuse(INVALID_PARAMS, "invalid_params", { ...(parent ? { extends: parent } : {}), reason: effect });
        const { attrs, own } = effect;
        const below = this.effectsBelow(name, { extends: parent, written: own ?? this.rootWritten(before, attrs) });
        if (method === "admin.profile.preview") {
          // The stored profile with the write laid over it, as the plane compares them: what
          // the write does not send stays as it is, and the name says which profile.
          const was = this.comparable_profile(before);
          const { name: _name, ...sent } = this.comparable_attrs({ ...attrs, extends: parent });
          return { result: { policy: this.verdict(attrs), changes: diff(was, { ...was, ...sent }), mode: this.mode, extended_by: below } };
        }
        const held = this.heldByRepository(subject, "profile.put", name, "WorkerProfile");
        if (held) return held;
        const refused = this.profileRefusal(attrs);
        if (refused) return refused;
        const stuck = below.find((b) => b.problem);
        if (stuck) return refuse(INVALID_PARAMS, "invalid_params", { extended_by: stuck.name, reason: `${stuck.name} extends ${name}, and with this change it would not be saved: ${stuck.problem}` });
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
        after.extends = parent;
        after.own = own;
        if (!before) this.profiles.push(after);
        const changes = diff(was, this.comparable_profile(after));
        // Every profile below, written again as it now resolves, and named in the one record.
        const rewritten: Record<string, { changes: Changes; provisioning: unknown }> = {};
        for (const b of below) {
          const child = this.profiles.find((x) => x.name === b.name);
          const resolved = this.resolveProfile(b.name, {});
          if (!child || typeof resolved === "string") continue;
          const childWas = this.comparable_profile(child);
          Object.assign(child, rowOf(resolved));
          child.sessions_per_pod = child.size_class === "heavy" ? 2 : 4;
          rewritten[b.name] = { changes: diff(childWas, this.comparable_profile(child)), provisioning: { mode: this.mode, state: "applied" } };
        }
        const detail = Object.keys(rewritten).length ? { ...changes, extended_by: Object.fromEntries(Object.entries(rewritten).map(([k, v]) => [k, v.changes])) } : changes;
        this.record(subject, "profile.put", name, detail);
        return { result: { profile: this.profileJson(after), changes, provisioning: { mode: this.mode, state: "applied" }, identity_problems: this.identityProblems(spec), extended_by: rewritten } };
      }

      case "admin.profile.delete": {
        if (role !== "platform_admin") return notPlatform;
        const p = this.profiles.find((x) => x.name === params["name"]);
        if (!p) return refuse(NOT_FOUND, "not_found", { profile: params["name"] });
        const children = this.childrenOf(p.name);
        if (children.length) {
          return refuse(CONFLICT, "conflict", {
            profile: p.name,
            extended_by: children,
            reason: `${children.join(", ")} ${children.length === 1 ? "extends" : "extend"} ${p.name}: make ${children.length === 1 ? "it" : "each"} extend another profile, or none, before deleting ${p.name}`,
          });
        }
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
        return { result: found.team.principals.map((p) => this.principalJson(this.principalRow(found.team, p))) };
      }

      case "admin.principal.create": {
        const found = this.fetchTeam(subject, params["team"]);
        if ("error" in found) return found;
        const t = found.team;
        const attrs = ((typeof params["principal"] === "object" && params["principal"] !== null ? params["principal"] : params) ?? {}) as Record<string, unknown>;
        const name = typeof attrs["name"] === "string" ? attrs["name"].trim() : "";
        if (!/^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$/.test(name)) return refuse(INVALID_PARAMS, "invalid_params", { reason: `name: lowercase letters, digits and dashes, not ${JSON.stringify(attrs["name"] ?? "")}` });
        const profiles = Array.isArray(attrs["profiles"]) ? (attrs["profiles"] as unknown[]).map(String) : [];
        if (profiles.length === 0) return refuse(INVALID_PARAMS, "invalid_params", { missing: "profiles" });
        const outside = profiles.filter((p) => !t.grants.some((g) => g.profile === p));
        if (outside.length) return refuse(INVALID_PARAMS, "invalid_params", { reason: `${t.name} is not granted ${outside.join(", ")}`, profiles: outside });
        const sponsor = typeof attrs["sponsor"] === "string" ? attrs["sponsor"].trim() : "";
        if (!sponsor) return refuse(INVALID_PARAMS, "invalid_params", { missing: "sponsor", reason: "a principal names a person answerable for what it does" });
        if (!t.members.some((m) => m.subject === sponsor)) return refuse(INVALID_PARAMS, "invalid_params", { sponsor, reason: `${sponsor} is not a member of ${t.name}` });
        const made = `svc:${t.name}/${name}`;
        if (t.principals.includes(made)) return refuse(INVALID_PARAMS, "invalid_params", { reason: `subject: ${made} has already been taken` });
        t.principals.push(made);
        const row: FakePrincipal = {
          subject: made,
          team: t.name,
          name,
          description: typeof attrs["description"] === "string" && attrs["description"] !== "" ? attrs["description"] : null,
          profiles,
          sponsor,
          created_by: subject,
          created_at: new Date().toISOString(),
          disabled_at: null,
          disabled_reason: null,
          last_used_at: null,
        };
        this.principalRows.set(made, row);
        this.record(subject, "principal.create", made, { team: t.name, profiles, sponsor });
        return { result: { ...this.principalJson(row), secret: secretOf("tps") } };
      }

      case "admin.principal.rotate":
      case "admin.principal.disable": {
        const who = params["subject"];
        if (typeof who !== "string") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["subject"] });
        const t = [...this.teams.values()].find((x) => x.principals.includes(who));
        const found = this.fetchTeam(subject, t?.name ?? "");
        if (!t || "error" in found) return refuse(NOT_FOUND, "not_found", { subject: who });
        const row = this.principalRow(t, who);
        if (method === "admin.principal.disable") {
          row.disabled_at = new Date().toISOString();
          row.disabled_reason = "disabled";
          this.record(subject, "principal.disable", who, {});
          return { result: this.principalJson(row) };
        }
        if (row.disabled_at) return refuse(INVALID_PARAMS, "invalid_params", { subject: who, reason: "a disabled principal is not rotated" });
        this.record(subject, "principal.rotate", who, {});
        return { result: { ...this.principalJson(row), secret: secretOf("tps") } };
      }

      case "admin.identity.duplicates": {
        if (role !== "platform_admin") return notPlatform;
        return { result: { people: this.peopleAlike, groups: this.groupsAlike() } };
      }

      case "admin.identity.check": {
        if (!admin) return notAdmin;
        const asked = typeof params["group"] === "string" && params["group"] !== "" ? params["group"] : null;
        const candidate = asked ?? (this.valueOf(SETTINGS.find((s) => s.key === "platform_admin_group")!) as string | null);
        const claim = String(this.valueOf(SETTINGS.find((s) => s.key === "groups_claim")!));
        const members = candidate ? (this.memberships[candidate] ?? null) : null;
        const you = (members ?? []).includes(subject);
        const adminCheck = !candidate
          ? { name: "Platform admins", ok: false, detail: "No platform admin group is set, so nobody who signs in is a platform admin.", took_ms: 0 }
          : members === null
            ? { name: "Platform admins", ok: false, detail: `${candidate} has never arrived in the ${claim} claim of anybody's token. Either the group id is wrong, or the provider is not sending group claims, or nobody in it has signed in yet.`, took_ms: 0 }
            : { name: "Platform admins", ok: members.length > 0, detail: `${members.length} person/people known here carry ${candidate} in the ${claim} claim${you ? ", including you." : ", and you are not one of them."}`, took_ms: 0 };
        const checks = [...this.providerChecks(this.signInValues()), adminCheck];
        return { result: { checks, ok: checks.every((c) => c.ok), group: candidate, redirect_uri: `${this.baseUrl()}/admin/callback` } };
      }

      case "admin.provider.get":
        return admin ? { result: this.providerState() } : notAdmin;

      case "admin.provider.check": {
        if (!admin) return notAdmin;
        const candidate = { ...this.signInValues(), ...this.given(params["attrs"]) };
        const checks = this.providerChecks(candidate);
        return { result: { checks, ok: checks.every((c) => c.ok), candidate: { issuer: candidate["issuer"], token_endpoint: candidate["token_endpoint"], device_authorization_endpoint: candidate["device_authorization_endpoint"] } } };
      }

      case "admin.provider.put": {
        if (role !== "platform_admin") return notPlatform;
        const now = this.signInValues();
        // Blank fields, and fields that say what the plane already reads, are not changes.
        const attrs = Object.fromEntries(Object.entries(this.given(params["attrs"])).filter(([k, v]) => k === "client_secret" || String(now[k] ?? "") !== v));
        if (Object.keys(attrs).length === 0) return refuse(INVALID_PARAMS, "invalid_params", { missing: "attrs", reason: "nothing to save" });
        if (params["force"] !== true) {
          const checks = this.providerChecks({ ...now, ...attrs });
          if (!checks.every((c) => c.ok)) {
            return refuse(INVALID_PARAMS, "invalid_params", { reason: "the provider did not stand behind these values; fix them, or save anyway with force if you know the provider is down", checks });
          }
        }
        const before = this.comparableSignIn();
        for (const [k, v] of Object.entries(attrs)) this.stored.set(k, v);
        const changes: Record<string, unknown> = diff(before, this.comparableSignIn());
        if ("client_secret" in attrs) changes["rotated"] = ["client_secret"];
        this.record(subject, "provider.put", "sign-in", changes);
        return { result: { ...this.providerState(), changes } };
      }

      case "admin.provider.reset": {
        if (role !== "platform_admin") return notPlatform;
        const before = this.comparableSignIn();
        for (const k of SIGN_IN_KEYS) this.stored.delete(k);
        const changes = diff(before, this.comparableSignIn());
        this.record(subject, "provider.reset", "sign-in", changes);
        return { result: { ...this.providerState(), changes } };
      }

      case "admin.scim.get":
        return admin ? { result: this.scimJson() } : notAdmin;

      case "admin.scim.rotate": {
        if (role !== "platform_admin") return notPlatform;
        Object.assign(this.scimState, { token_set: true, rotated_at: new Date().toISOString(), rotated_by: subject });
        this.record(subject, "scim.rotate", "connector", {});
        return { result: { ...this.scimJson(), token: secretOf("scim") } };
      }

      case "admin.scim.delete": {
        if (role !== "platform_admin") return notPlatform;
        const expected = `${this.baseUrl()}/scim/v2`;
        if (params["base_url"] !== expected) return refuse(INVALID_PARAMS, "invalid_params", { reason: `the base URL to confirm with is ${expected}`, base_url: expected });
        this.scimState.token_set = false;
        this.record(subject, "scim.delete", "connector", {});
        return { result: this.scimJson() };
      }

      case "admin.scim.update": {
        if (role !== "platform_admin") return notPlatform;
        const attrs = (params["attrs"] ?? {}) as Record<string, unknown>;
        if (typeof attrs["teams_from_groups"] !== "boolean") return refuse(INVALID_PARAMS, "invalid_params", { reason: "teams_from_groups is true or false" });
        const changes = diff({ teams_from_groups: this.scimState.teams_from_groups }, { teams_from_groups: attrs["teams_from_groups"] });
        this.scimState.teams_from_groups = attrs["teams_from_groups"];
        this.record(subject, "scim.update", "connector", changes);
        return { result: { ...this.scimJson(), changes } };
      }

      case "admin.integrations.list": {
        if (!admin) return notAdmin;
        const servers = this.serversByProfile();
        return {
          result: {
            servers: servers.filter((s) => s.profiles.length > 1),
            profile_servers: servers.filter((s) => s.profiles.length <= 1),
            egress: this.egressHosts(servers),
            notify: this.visible(subject).flatMap((t) =>
              this.triggerRows
                .filter((r) => r.team === t.name && typeof r.notify_url === "string" && r.notify_url !== "")
                .map((r) => ({ team: t.name, trigger: r.name, url: r.notify_url!, refusal: notifyRefusal(r.notify_url!) })),
            ),
          },
        };
      }

      case "admin.github.get":
        return admin ? { result: this.githubJson() } : notAdmin;

      case "admin.github.put": {
        if (role !== "platform_admin") return notPlatform;
        const app = ((typeof params["app"] === "object" && params["app"] !== null ? params["app"] : params) ?? {}) as Record<string, unknown>;
        const read = this.readGithub(app);
        if ("error" in read) return read;
        const before = this.githubFields();
        Object.assign(this.github, read.changes, { updated_by: subject, updated_at: new Date().toISOString() });
        const changes = diff(before, this.githubFields());
        this.record(subject, "github.put", "app", changes);
        return { result: { ...this.githubJson(), changes } };
      }

      case "admin.github.deliveries": {
        if (role !== "platform_admin") return notPlatform;
        const limit = typeof params["limit"] === "number" && params["limit"] > 0 ? Math.min(params["limit"], 200) : 50;
        return { result: [...this.deliveries].reverse().slice(0, limit) };
      }

      case "admin.github.check":
        return role === "platform_admin" ? { result: this.githubCheck() } : notPlatform;

      case "admin.github.delete": {
        if (role !== "platform_admin") return notPlatform;
        if (this.github.app_id === null && this.github.key === null && this.github.installations.length === 0) return refuse(NOT_FOUND, "not_found", { reason: "this plane has no GitHub App" });
        if (this.github.app_id !== null && String(params["app_id"]) !== String(this.github.app_id)) {
          return refuse(INVALID_PARAMS, "invalid_params", { reason: `the App ID to confirm with is ${this.github.app_id}`, app_id: this.github.app_id });
        }
        const before = this.githubFields();
        Object.assign(this.github, { app_id: null, api_url: null, installations: [], key: null, webhook_secret_version: null, updated_by: null, updated_at: null });
        const changes = diff(before, this.githubFields());
        this.record(subject, "github.delete", "app", changes);
        return { result: { ...this.githubJson(), changes } };
      }

      case "admin.provisioners.list":
        return admin ? { result: PROVISIONERS } : notAdmin;

      case "admin.profile.choices":
        return admin ? { result: { provider_types: PROVIDER_TYPES, size_classes: SIZE_CLASS_CHOICES } } : notAdmin;

      case "admin.hosts.list": {
        if (role !== "platform_admin") return notPlatform;
        if (!this.profiles.some((p) => p.name === params["profile"])) return refuse(NOT_FOUND, "not_found", { profile: params["profile"] });
        return { result: this.hostRows.filter((h) => h.profile === params["profile"]).map((h) => hostJson(h)) };
      }

      case "admin.host.register": {
        if (role !== "platform_admin") return notPlatform;
        const profile = params["profile"];
        if (!this.profiles.some((p) => p.name === profile)) return refuse(NOT_FOUND, "not_found", { profile });
        const attrs = (params["host"] ?? {}) as Record<string, unknown>;
        const name = typeof attrs["name"] === "string" ? attrs["name"].trim() : "";
        if (!/^[a-z0-9]([a-z0-9.-]{0,61}[a-z0-9])?$/.test(name)) return refuse(INVALID_PARAMS, "invalid_params", { reason: "name: lowercase letters, digits, dots and dashes" });
        if (this.hostRows.some((h) => h.profile === profile && h.name === name)) return refuse(INVALID_PARAMS, "invalid_params", { reason: `name: ${name} is registered to ${String(profile)} already` });
        const address = typeof attrs["address"] === "string" && attrs["address"].trim() !== "" ? attrs["address"].trim() : null;
        const host: FakeHost = { name, profile: String(profile), address, enabled: true, registered_at: new Date().toISOString(), last_enrolled_at: null };
        this.hostRows.push(host);
        this.record(subject, "host.register", `${host.profile}/${name}`, { profile: host.profile, address });
        return { result: { ...hostJson(host), secret: secretOf("wh"), ca: CONTROL_CA } };
      }

      case "admin.host.rotate":
      case "admin.host.enabled": {
        if (role !== "platform_admin") return notPlatform;
        const host = this.hostRows.find((h) => h.profile === params["profile"] && h.name === params["name"]);
        if (!host) return refuse(NOT_FOUND, "not_found", { profile: params["profile"], host: params["name"] });
        if (method === "admin.host.rotate") {
          this.record(subject, "host.rotate", `${host.profile}/${host.name}`, {});
          return { result: { ...hostJson(host), secret: secretOf("wh"), ca: CONTROL_CA } };
        }
        if (typeof params["enabled"] !== "boolean") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["enabled"] });
        host.enabled = params["enabled"];
        this.record(subject, host.enabled ? "host.enable" : "host.disable", `${host.profile}/${host.name}`, {});
        return { result: hostJson(host) };
      }

      case "admin.pod.drain": {
        if (role !== "platform_admin") return notPlatform;
        const owner = this.profiles.find((p) => p.pods.some((x) => x.worker_id === params["worker_id"]));
        const target = owner?.pods.find((x) => x.worker_id === params["worker_id"]);
        if (!owner || !target) return refuse(NOT_FOUND, "not_found", { worker_id: params["worker_id"] });
        this.record(subject, "pod.drain", target.pod, { profile: owner.name });
        const held = target.active_sessions;
        target.draining = true;
        target.active_sessions = 0;
        return { result: { pod: target.pod, worker_id: target.worker_id, sessions: held, drained: held, cancelled: [], took_ms: 1200 } };
      }

      case "admin.profiles.export": {
        if (role !== "platform_admin") return notPlatform;
        return { result: this.exported() };
      }

      case "admin.connections.list": {
        if (!admin) return notAdmin;
        let teams = this.visible(subject);
        if (params["team"] !== undefined) {
          const found = this.fetchTeam(subject, params["team"]);
          if ("error" in found) return found;
          teams = [found.team];
        }
        const granted = (t: FakeTeam, profiles: string[]) => t.grants.some((g) => profiles.includes(g.profile));
        const servers = this.personServers.filter((s) => teams.some((t) => granted(t, s.profiles)));
        const carried = new Set(servers.flatMap((s) => s.profiles));
        return {
          result: {
            servers: servers.map((s) => ({
              ...s,
              people: [...new Map(teams.filter((t) => granted(t, s.profiles)).flatMap((t) => t.members).map((m) => [m.subject, m])).values()]
                .sort((a, b) => a.subject.localeCompare(b.subject))
                .map((m) => ({ subject: m.subject, display_name: m.display_name, connected: this.connected.has(`${m.subject}|${s.slot}`) })),
            })),
            sessions: this.sessions
              .filter((x) => x.state !== "erased" && x.team !== null && teams.some((t) => t.name === x.team) && carried.has(x.profile))
              .map((x) => ({ id: x.id, profile: x.profile, team: x.team, owner: x.owner, state: x.state })),
            credentials_readable: false,
          },
        };
      }

      case "admin.person.budget": {
        if (role !== "platform_admin") return notPlatform;
        const who = params["subject"];
        const rows = [...this.teams.values()].flatMap((t) => t.members.filter((m) => m.subject === who));
        if (typeof who !== "string" || rows.length === 0) return refuse(NOT_FOUND, "not_found", { subject: who });
        const asked = params["budget_micros"];
        if (asked !== null && asked !== undefined && !(Number.isInteger(asked) && (asked as number) >= 0)) return refuse(INVALID_PARAMS, "invalid_params", { reason: "budget_micros: is a whole number of millionths, 0 or more" });
        const before = rows[0]!.budget_micros ?? null;
        const now = asked === 0 || asked === null || asked === undefined ? null : (asked as number);
        for (const r of rows) r.budget_micros = now;
        const changes = diff({ budget_micros: before }, { budget_micros: now });
        this.record(subject, "person.budget", who, changes);
        return { result: { subject: who, budget_micros: now, changes } };
      }

      case "admin.budget.explain": {
        if (role !== "platform_admin") return notPlatform;
        const who = params["subject"];
        if (typeof who !== "string" || who === "") return refuse(INVALID_PARAMS, "invalid_params", { method, missing: ["subject"] });
        let t: FakeTeam | null = null;
        if (params["team"] !== undefined) {
          const found = this.fetchTeam(subject, params["team"]);
          if ("error" in found) return found;
          t = found.team;
        }
        return { result: this.ceilings(who, t) };
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
        // A new webhook trigger is made with its key, answered this once; one on a GitHub
        // repository is fired by the App and has none.
        const minted = !existing && row.source["kind"] === "webhook" && !row.source["repository"] ? `twk_fake${Math.random().toString(36).slice(2, 14)}` : null;
        if (!existing) row.has_key = minted !== null;
        const changes = diff(before, this.comparable_trigger(row));
        const revision = this.revise(row, subject);
        this.record(subject, "trigger.put", `${t.name}/${name}`, { ...changes, __revision__: revision.revision, __revision_hash__: revision.hash, ...(minted ? { __key_minted__: true } : {}) });
        return { result: { trigger: this.triggerJson(row), changes, revision: revisionJson(revision), ...(minted ? { key: minted, url: `/trigger/${row.id}` } : {}) } };
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

      case "admin.runs.list": {
        if (!admin) return notAdmin;
        const filter = this.filterOf(params);
        let teams = this.visible(subject);
        if (typeof filter["team"] === "string") {
          const found = this.fetchTeam(subject, filter["team"]);
          if ("error" in found) return found;
          teams = [found.team];
        }
        const names = teams.map((t) => t.name);
        let rows = this.runRows.filter((r) => names.includes(r.team));
        if (typeof filter["trigger"] === "string") rows = rows.filter((r) => r.trigger === filter["trigger"]);
        rows = [...rows].sort((a, b) => b.fired_at.localeCompare(a.fired_at));
        const limit = typeof filter["limit"] === "number" ? filter["limit"] : 50;
        return { result: rows.slice(0, limit).map((r) => ({ ...r })) };
      }

      case "admin.run.review": {
        if (!admin) return notAdmin;
        const names = this.visible(subject).map((t) => t.name);
        const row = this.runRows.find((r) => r.session_id === params["session_id"] && names.includes(r.team));
        if (!row) return refuse(NOT_FOUND, "not_found", { session_id: params["session_id"] });
        row.reviewed_by = subject;
        row.reviewed_at = new Date().toISOString();
        this.record(subject, "run.review", row.session_id!, {});
        return { result: { session_id: row.session_id, reviewed_by: subject } };
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
        if (setting.editable === false) return refuse(INVALID_PARAMS, "invalid_params", { setting: key, reason: "this one belongs to the deployment and cannot be changed from here" });
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

  // -- a profile that extends another, as `Troupe.Plane.Fleet.Extends` resolves it -------

  /** What a profile wrote: `own` for one that extends another, its own fields otherwise. */
  private writtenOf(p: FakeProfile): Record<string, unknown> {
    if (p.extends) return { ...(p.own ?? {}) };
    return { image: p.image, size_class: p.size_class, max_sessions: p.max_sessions ?? null, warm_workers: p.warm_workers ?? 0, provisioner: p.provisioner, spec: p.spec ?? {} };
  }

  /** What a write that names no parent leaves a profile having written: its fields, the write's over them. */
  private rootWritten(before: FakeProfile | null, attrs: Record<string, unknown>): Record<string, unknown> {
    const base = before ? this.writtenOf({ ...before, extends: null }) : {};
    return { ...base, ...Object.fromEntries(WRITTEN_KEYS.filter((k) => k in attrs).map((k) => [k, attrs[k]])) };
  }

  private childrenOf(name: string): string[] {
    return this.profiles
      .filter((p) => p.extends === name)
      .map((p) => p.name)
      .sort();
  }

  /** Every profile below `name`, each after the one it extends. */
  private descendantsOf(name: string): string[] {
    const out: string[] = [];
    const queue = [name];
    while (queue.length) {
      for (const child of this.childrenOf(queue.shift() as string)) {
        if (out.includes(child)) continue;
        out.push(child);
        queue.push(child);
      }
    }
    return out;
  }

  /** From the profile that extends nothing down to `name`, with what each wrote, or why there is no such chain. */
  private chainOf(name: string, overrides: Record<string, { extends: string | null; written: Record<string, unknown> }>): Array<[string, Record<string, unknown>]> | { missing: string } | { cycle: string[] } {
    const below: Array<[string, Record<string, unknown>]> = [];
    let at: string | null = name;
    while (at) {
      if (below.some(([n]) => n === at) || below.length >= MAX_DEPTH) return { cycle: below.map(([n]) => n) };
      const step: string = at;
      const override: { extends: string | null; written: Record<string, unknown> } | undefined = overrides[step];
      const row = this.profiles.find((p) => p.name === step);
      if (!override && !row) return { missing: step };
      below.unshift([step, override ? override.written : this.writtenOf(row as FakeProfile)]);
      at = override ? override.extends : (row?.extends ?? null);
    }
    return below;
  }

  private resolveProfile(name: string, overrides: Record<string, { extends: string | null; written: Record<string, unknown> }>): (Resolved & { chain: string[] }) | string {
    const chain = this.chainOf(name, overrides);
    if ("missing" in chain) return `${chain.missing} is extended in this chain and is not a profile on this plane any more`;
    if ("cycle" in chain) return `${chain.cycle.join(" → ")} extend each other in a circle`;
    const resolved = chain.reduce<Resolved>((parent, [profile, written]) => mergeExtends(parent, written, profile), emptyResolved());
    return { ...resolved, chain: chain.map(([n]) => n) };
  }

  /** Whether `name` may extend `parent`, in the plane's sentences where it may not. */
  private extendsProblem(name: string, parent: string): string | null {
    if (name === parent) return `${name} cannot extend itself`;
    const above = this.chainOf(parent, {});
    if ("missing" in above) return `${name} extends ${parent}, which is not a profile on this plane: create ${parent} first, or extend another`;
    if ("cycle" in above) return `${above.cycle.join(" → ")} extend each other in a circle`;
    const names = above.map(([n]) => n);
    if (names.includes(name)) return `${name} cannot extend ${parent}, because ${parent} already extends ${name} (${names.join(" → ")}): a profile cannot be its own ancestor`;
    const height = (n: string): number => Math.max(0, ...this.childrenOf(n).map((c) => 1 + height(c)));
    const length = names.length + 1 + height(name);
    if (length > MAX_DEPTH) return `${name} extending ${parent} would make a chain of ${length} profiles (${[...names, name].join(" → ")}), and a chain is at most ${MAX_DEPTH}: extend a profile nearer the one that extends nothing`;
    return null;
  }

  /**
   * The write as the plane reads it: resolved where it names a parent, and for a profile
   * that stops naming one, what it had in effect with the write laid over it.
   */
  private inEffect(name: string, sent: Record<string, unknown>, parent: string | null, before: FakeProfile | null): { attrs: Record<string, unknown>; own: Record<string, unknown> | null } | string {
    const own = { ...(before?.extends ? (before.own ?? {}) : {}), ...Object.fromEntries(WRITTEN_KEYS.filter((k) => k in sent).map((k) => [k, sent[k]])) };
    const via = parent ?? before?.extends ?? null;
    if (!via) return { attrs: sent, own: null };
    if (parent) {
      const problem = this.extendsProblem(name, parent);
      if (problem) return problem;
    }
    const resolved = this.resolveProfile(name, { [name]: { extends: via, written: own } });
    if (typeof resolved === "string") return resolved;
    const { channel: _channel, ...row } = rowOf(resolved);
    return { attrs: { ...row, name }, own: parent ? own : null };
  }

  /** Each profile below `name` as this write would leave it: its diff, the policy's verdict, and what would refuse the write. */
  private effectsBelow(name: string, write: { extends: string | null; written: Record<string, unknown> }): Array<{ name: string; changes: Changes; policy: unknown; problem: string | null }> {
    return this.descendantsOf(name).map((child) => {
      const current = this.profiles.find((p) => p.name === child) ?? null;
      const resolved = this.resolveProfile(child, { [name]: write });
      if (typeof resolved === "string") return { name: child, changes: {}, policy: null, problem: resolved };
      const { channel, ...row } = rowOf(resolved);
      const was = this.comparable_profile(current);
      const llm = ((row["spec"] ?? {}) as Record<string, unknown>)["llm"];
      const llmWrong = typeof llm === "object" && llm !== null ? llmProblem(llm as Record<string, unknown>) : null;
      const policy = this.verdict({ ...row, name: child });
      return {
        name: child,
        changes: diff(was, { ...was, ...row, config_bundle_channel: channel, sessions_per_pod: row["size_class"] === "heavy" ? 2 : 4 }),
        policy,
        problem: llmWrong ? `spec: ${llmWrong}` : policy["allowed?"] ? null : policy.violations.join("; "),
      };
    });
  }

  private profileJson(p: FakeProfile): Record<string, unknown> {
    return {
      name: p.name,
      extends: p.extends ?? null,
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
      conditions: p.conditions ?? [],
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
      extends: p.extends ?? null,
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
      if (source["kind"] === "webhook" && source["repository"] !== undefined) {
        if (typeof source["repository"] !== "string" || !/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+$/.test(source["repository"])) {
          return refuse(INVALID_PARAMS, "invalid_params", { reason: `source: ${String(source["repository"])} is not a GitHub repository, owner/name` });
        }
        if (!source["label"] && !source["command"]) {
          return refuse(INVALID_PARAMS, "invalid_params", { reason: "source: a GitHub trigger names a label, a command, or both: what on an issue starts a run" });
        }
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
    const hasKey = row.has_key ?? (kind === "webhook" && !(row.source ?? {})["repository"]);
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
      has_key: hasKey,
      key_rotated_at: hasKey ? row.updated_at : null,
      key_rotated_by: hasKey ? row.created_by : null,
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
    if (setting.key === "provisioning_mode") return this.mode;
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
      editable: setting.editable ?? true,
      secret: setting.secret ?? false,
      set: value !== null && value !== "",
      source: this.stored.has(setting.key) ? "stored" : value === null ? "unset" : "deployed",
      // A secret is in the answer as whether it is set, and nothing else.
      ...(setting.secret ? {} : { deployed: shown(deployed), value: shown(value) }),
      ...(setting.type === "enforced" && this.enforceable ? { enforceable: this.enforceable } : {}),
    };
  }

  private parse(setting: Setting, raw: unknown): { value: unknown } | { error: string } {
    const text = typeof raw === "string" ? raw : JSON.stringify(raw);
    switch (setting.type) {
      case "string":
      case "list":
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

  // -- identity ------------------------------------------------------------------------

  /** A principal's row, made from its subject where nothing more was ever said of it. */
  private principalRow(team: FakeTeam, subject: string): FakePrincipal {
    const known = this.principalRows.get(subject);
    if (known) return known;
    const made: FakePrincipal = {
      subject,
      team: team.name,
      name: subject.split("/").at(-1) ?? subject,
      description: null,
      profiles: team.grants.map((g) => g.profile),
      sponsor: team.admins[0] ?? null,
      created_by: "alice@example.com",
      created_at: "2026-10-01T09:30:00Z",
      disabled_at: null,
      disabled_reason: null,
      last_used_at: null,
    };
    this.principalRows.set(subject, made);
    return made;
  }

  /** A principal as `principal_summary/1` answers: three states, said apart. */
  private principalJson(row: FakePrincipal): Record<string, unknown> {
    const team = this.teams.get(row.team);
    const sponsored = row.sponsor !== null && (team?.members.some((m) => m.subject === row.sponsor) ?? false);
    const state = row.disabled_at ? "disabled" : sponsored ? "active" : "needs_sponsor";
    return {
      subject: row.subject,
      name: row.name,
      description: row.description,
      profiles: row.profiles,
      created_by: row.created_by,
      created_at: row.created_at,
      sponsor: row.sponsor,
      disabled_at: row.disabled_at,
      disabled_reason: row.disabled_reason,
      last_used_at: row.last_used_at,
      enabled: state === "active",
      state,
    };
  }

  /** Groups sharing a display name under different ids, as `Identity.group_lookalikes/0` sets them out. */
  private groupsAlike(): Array<Record<string, unknown>> {
    const by = new Map<string, Array<{ external_id: string; display_name: string | null; looks_duplicated?: { others: string[]; likely: string } | null }>>();
    for (const g of this.groups) {
      if (!g.display_name) continue;
      const key = g.display_name.toLowerCase();
      by.set(key, [...(by.get(key) ?? []), g]);
    }
    return [...by.values()]
      .filter((set) => set.length > 1)
      .map((set) => ({
        by: "display_name",
        groups: set.map((g) => ({ external_id: g.external_id, display_name: g.display_name })),
        likely: set.find((g) => g.looks_duplicated)?.looks_duplicated?.likely ?? "the provider sent two groups of this name under different ids",
      }));
  }

  // -- sign-in -------------------------------------------------------------------------

  private baseUrl(): string {
    return String(this.deployed["base_url"] ?? "https://troupe.example.com").replace(/\/+$/, "");
  }

  /** The sign-in settings as the plane reads them now, a secret as whether it is set. */
  private signInValues(): Record<string, string> {
    return Object.fromEntries(
      SETTINGS.filter((s) => s.group === "sign_in" && s.editable !== false).map((s) => {
        const v = this.valueOf(s);
        return [s.key, v === null || v === undefined ? "" : String(v)];
      }),
    );
  }

  /** The non-blank fields of an `attrs`, as strings: what a form changed. */
  private given(attrs: unknown): Record<string, string> {
    const raw = (typeof attrs === "object" && attrs !== null ? attrs : {}) as Record<string, unknown>;
    return Object.fromEntries(
      Object.entries(raw)
        .filter(([k, v]) => SIGN_IN_KEYS.includes(k) && v !== null && v !== undefined && String(v).trim() !== "")
        .map(([k, v]) => [k, String(v).trim()]),
    );
  }

  /** `OIDC.check/1`'s three, against a candidate: discovery answers, its keys can be read, the endpoints given agree with it. */
  private providerChecks(candidate: Record<string, string>): IdentityCheckRow[] {
    const issuer = (candidate["issuer"] ?? "").replace(/\/+$/, "");
    const answers = this.answeringIssuers.has(issuer);
    const disagree = ["authorization_endpoint", "device_authorization_endpoint", "token_endpoint"].filter((k) => candidate[k] && !candidate[k]!.startsWith(issuer));
    return [
      { name: "Discovery", ok: answers, detail: answers ? `${issuer}/.well-known/openid-configuration answered and names itself ${issuer}.` : `${issuer || "No issuer"} did not answer for its discovery document.`, took_ms: 41 },
      { name: "Signing keys", ok: answers, detail: answers ? "The provider's keys could be read: 2 keys." : "Not tried: discovery did not answer.", took_ms: answers ? 23 : 0 },
      {
        name: "Endpoints",
        ok: answers && disagree.length === 0,
        detail: disagree.length ? `${disagree.join(", ")} disagree with what ${issuer} publishes.` : "Every endpoint given agrees with what the provider publishes.",
        took_ms: 0,
      },
    ];
  }

  private providerState(): Record<string, unknown> {
    const base = this.baseUrl();
    return {
      settings: SETTINGS.filter((s) => s.group === "sign_in").map((s) => this.describe(s)),
      urls: {
        redirect: `${base}/admin/callback`,
        discovery: `${base}/.well-known/troupe`,
        jwks: `${base}/.well-known/jwks.json`,
        resource_metadata: `${base}/.well-known/oauth-protected-resource`,
      },
      protocol: "oidc",
      known_people: Object.keys(this.names).length,
    };
  }

  /** The sign-in settings as an audit diff holds them: a secret as `set`, never its value. */
  private comparableSignIn(): Record<string, unknown> {
    return Object.fromEntries(
      SETTINGS.filter((s) => s.group === "sign_in").map((s) => {
        const v = this.valueOf(s);
        return [s.key, s.secret ? (v ? "set" : null) : v];
      }),
    );
  }

  private scimJson(): Record<string, unknown> {
    const deployed = typeof this.deployed["scim_token"] === "string" && this.deployed["scim_token"] !== "";
    const s = this.scimState;
    const status = !s.token_set && !deployed ? "no_token" : s.last_seen_at === null ? "never_pushed" : Date.now() - Date.parse(s.last_seen_at) < 86_400_000 ? "connected" : "quiet";
    return { ...s, base_url: `${this.baseUrl()}/scim/v2`, deployed_token_set: deployed, status };
  }

  // -- integrations --------------------------------------------------------------------

  /** Every MCP server a profile's channel carries, with the profiles that carry it. */
  private serversByProfile(): Array<{ name: string; url: string; credential_mode: string; credential_ref: string | null; profiles: string[] }> {
    const by = new Map<string, { name: string; url: string; credential_mode: string; credential_ref: string | null; profiles: string[] }>();
    for (const p of this.profiles) {
      const servers = (this.current(p.channel ?? "stable")?.content["mcp_servers"] ?? []) as Array<Record<string, unknown>>;
      for (const s of servers) {
        const name = String(s["name"]);
        const entry = by.get(name) ?? { name, url: String(s["url"] ?? ""), credential_mode: String(s["credential_mode"] ?? "profile"), credential_ref: typeof s["credential_ref"] === "string" ? s["credential_ref"] : null, profiles: [] };
        if (!entry.profiles.includes(p.name)) entry.profiles.push(p.name);
        by.set(name, entry);
      }
    }
    return [...by.values()].sort((a, b) => a.name.localeCompare(b.name));
  }

  /** Every host anything dials: a server's, and a profile's declared ones, each once, against the policy. */
  private egressHosts(servers: Array<{ name: string; url: string }>): Array<{ host: string; from: string; allowed: boolean }> {
    const seen = new Map<string, string>();
    for (const s of servers) {
      const host = hostOf(s.url);
      if (host && !seen.has(host)) seen.set(host, s.name);
    }
    for (const p of this.profiles) {
      const fqdns = (((p.spec ?? {})["egress"] ?? {}) as Record<string, unknown>)["fqdns"];
      for (const host of Array.isArray(fqdns) ? fqdns.map(String) : []) if (!seen.has(host)) seen.set(host, p.name);
    }
    return [...seen.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([host, from]) => ({ host, from, allowed: this.egressAllowed(host) }));
  }

  // -- the GitHub App ------------------------------------------------------------------

  private githubJson(): Record<string, unknown> {
    const g = this.github;
    const api = g.api_url ?? "https://api.github.com";
    return {
      configured: g.app_id !== null && g.key !== null && g.installations.length > 0,
      app_id: g.app_id,
      api_url: api,
      git_url: gitUrlOf(api),
      installations: g.installations,
      private_key: { set: g.key !== null, type: g.key?.type ?? null, fingerprint: g.key?.fingerprint ?? null, transit_key: "troupe-github-app", version: g.key?.version ?? null },
      webhook: { path: "/webhook/github", secret: { set: g.webhook_secret_version !== null, transit_key: "troupe-github-webhook", version: g.webhook_secret_version } },
      permissions: { contents: "read" },
      updated_by: g.updated_by,
      updated_at: g.updated_at,
    };
  }

  /** What a diff of the App shows: the key by its fingerprint and version, never more. */
  private githubFields(): Record<string, unknown> {
    const g = this.github;
    return { app_id: g.app_id, api_url: g.api_url, installations: g.installations, fingerprint: g.key?.fingerprint ?? null, transit_version: g.key?.version ?? null, webhook_secret_version: g.webhook_secret_version };
  }

  /** `GitHub.put/3`'s reading of the keys sent: each checked, a refusal naming the field, nothing written on one. */
  private readGithub(app: Record<string, unknown>): { changes: Partial<FakeAdmin["github"]> } | Refusal {
    const fields = ["app_id", "api_url", "installations", "private_key", "webhook_secret"];
    const unknown = Object.keys(app).find((k) => !fields.includes(k));
    if (unknown) return refuse(INVALID_PARAMS, "invalid_params", { field: unknown, reason: `the App takes ${fields.join(", ")}` });
    const changes: Partial<FakeAdmin["github"]> = {};
    if ("app_id" in app) {
      const id = typeof app["app_id"] === "string" && /^\d+$/.test(app["app_id"]) ? Number(app["app_id"]) : app["app_id"];
      if (id !== null && !(Number.isInteger(id) && (id as number) > 0)) return refuse(INVALID_PARAMS, "invalid_params", { field: "app_id", reason: "an App ID is a positive whole number" });
      changes.app_id = id as number | null;
    }
    if ("api_url" in app) {
      const url = app["api_url"];
      if (url === null || url === "") changes.api_url = null;
      else if (typeof url !== "string" || !/^https:\/\/[^/]+/.test(url) || gitUrlOf(url) === null) {
        return refuse(INVALID_PARAMS, "invalid_params", { field: "api_url", reason: "the API URL is GitHub's (https://api.github.com), an Enterprise Cloud one (https://api.<name>.ghe.com) or an Enterprise Server's (https://<host>/api/v3)" });
      } else changes.api_url = url;
    }
    if ("installations" in app) {
      const list = app["installations"] ?? [];
      if (!Array.isArray(list)) return refuse(INVALID_PARAMS, "invalid_params", { field: "installations", reason: "installations is a list of {owner, installation_id}" });
      const read: Array<{ owner: string; installation_id: number }> = [];
      for (const entry of list as Array<Record<string, unknown>>) {
        const owner = typeof entry?.["owner"] === "string" ? entry["owner"] : "";
        const id = typeof entry?.["installation_id"] === "string" && /^\d+$/.test(entry["installation_id"]) ? Number(entry["installation_id"]) : entry?.["installation_id"];
        if (!GITHUB_OWNER.test(owner)) return refuse(INVALID_PARAMS, "invalid_params", { field: "installations", reason: `${JSON.stringify(owner)} is not an organisation or account name` });
        if (!(Number.isInteger(id) && (id as number) > 0)) return refuse(INVALID_PARAMS, "invalid_params", { field: "installations", reason: "an installation_id is a positive whole number" });
        if (read.some((r) => r.owner.toLowerCase() === owner.toLowerCase())) return refuse(INVALID_PARAMS, "invalid_params", { field: "installations", reason: `${owner} is named twice` });
        read.push({ owner, installation_id: id as number });
      }
      changes.installations = read;
    }
    if (typeof app["private_key"] === "string" && app["private_key"] !== "") {
      const pem = app["private_key"];
      if (!/-----BEGIN (RSA )?PRIVATE KEY-----/.test(pem)) return refuse(INVALID_PARAMS, "invalid_params", { field: "private_key", reason: "not a PEM private key" });
      changes.key = { type: "rsa-2048", fingerprint: `SHA256:${hashOf(pem).slice(7, 50)}`, version: (this.github.key?.version ?? 0) + 1 };
    }
    if (typeof app["webhook_secret"] === "string" && app["webhook_secret"] !== "") {
      if (app["webhook_secret"].length < 32) return refuse(INVALID_PARAMS, "invalid_params", { field: "webhook_secret", reason: "a webhook secret is at least 32 characters; openssl rand -hex 32 makes one" });
      changes.webhook_secret_version = (this.github.webhook_secret_version ?? 0) + 1;
    }
    return { changes };
  }

  /** `GitHub.check/1`: four checks, each after the one before it passed. */
  private githubCheck(): Record<string, unknown> {
    const g = this.github;
    const known = this.githubKnows;
    const notTried = (name: string, after: string) => ({ name, ok: false, detail: `Not tried: ${after} did not pass.`, took_ms: 0 });
    if (g.app_id === null) {
      return { ok: false, app: null, checks: [{ name: "App", ok: false, detail: "No App ID is set.", took_ms: 0 }, notTried("Private key", "App"), notTried("GitHub", "App"), notTried("Installations", "App")] };
    }
    const app = { name: "App", ok: true, detail: `App ${g.app_id}, at ${g.api_url ?? "https://api.github.com"}.`, took_ms: 0 };
    if (!g.key) {
      return { ok: false, app: null, checks: [app, { name: "Private key", ok: false, detail: "the App's private key is not in OpenBao", took_ms: 3 }, notTried("GitHub", "Private key"), notTried("Installations", "Private key")] };
    }
    const key = { name: "Private key", ok: true, detail: `Transit signs with version ${g.key.version} (${g.key.fingerprint}).`, took_ms: 4 };
    if (!known || known.app_id !== g.app_id || known.fingerprint !== g.key.fingerprint) {
      const refused = { name: "GitHub", ok: false, detail: `GitHub refused the App's JWT: the key is not App ${g.app_id}'s, or the App ID is wrong.`, took_ms: 87 };
      return { ok: false, app: null, checks: [app, key, refused, notTried("Installations", "GitHub")] };
    }
    const github = { name: "GitHub", ok: true, detail: `GitHub knows the App as ${known.slug}.`, took_ms: 92 };
    const missing = g.installations.filter((i) => !known.installations.some((k) => k.owner === i.owner && k.installation_id === i.installation_id));
    const installations =
      g.installations.length === 0
        ? { name: "Installations", ok: false, detail: "No installation is set, so nothing can be cloned.", took_ms: 61 }
        : missing.length === 0
          ? { name: "Installations", ok: true, detail: `GitHub lists every installation set here: ${g.installations.map((i) => i.owner).join(", ")}.`, took_ms: 61 }
          : { name: "Installations", ok: false, detail: `GitHub lists no installation of the App for ${missing.map((i) => `${i.owner} (${i.installation_id})`).join(", ")}.`, took_ms: 61 };
    return { ok: installations.ok, app: { slug: known.slug, name: known.slug }, checks: [app, key, github, installations] };
  }

  // -- the fleet -----------------------------------------------------------------------

  /** `Gitops.export/0`: every profile, the policy and every trigger as files a repository would hold. */
  private exported(): Record<string, unknown> {
    const profiles = this.profiles.map((p) => {
      const manifest = { apiVersion: "troupe.dev/v1alpha1", kind: "WorkerProfile", metadata: { name: p.name }, spec: { ...Object.fromEntries(Object.entries(p.spec ?? {}).filter(([k]) => k !== "sessionsPerPod")), image: p.image, sizeClass: p.size_class } };
      const notes = p.image === "release" ? ["image: release is pinned to the image it resolves to on this plane"] : [];
      return { name: p.name, path: `profiles/${p.name}.yaml`, notes, yaml: yamlOf(manifest, notes) };
    });
    const policy = { apiVersion: "troupe.dev/v1alpha1", kind: "TroupePolicy", metadata: { name: "troupe" }, spec: { imageRepositories: this.policy.imageRepositories, egress: { fqdns: this.policy.egress } } };
    const triggers = this.triggerRows.map((r) => {
      const manifest = { apiVersion: "troupe.dev/v1alpha1", kind: "Trigger", metadata: { name: `${r.team}.${r.name}` }, spec: { team: r.team, name: r.name, ...this.comparable_trigger(r) } };
      return { name: `${r.team}.${r.name}`, path: `triggers/${r.team}/${r.name}.yaml`, notes: [], yaml: yamlOf(manifest, []) };
    });
    return {
      profiles,
      policy: { name: "troupe", path: "policy/troupe.yaml", notes: [], yaml: yamlOf(policy, []) },
      triggers,
      left_out: ["spec.replicas", "spec.teams", "spec.mcpServers", "metadata.annotations.troupe.dev/drained", "status"],
    };
  }

  /** `Budget.ceilings/2`: the person's own, the team's and the platform's, narrowest first. */
  private ceilings(subject: string, team: FakeTeam | null): Array<Record<string, unknown>> {
    const rows = [...this.teams.values()].flatMap((t) => t.members.filter((m) => m.subject === subject));
    const cap = rows[0]?.budget_micros ?? null;
    const spent = rows.reduce((n, m) => n + m.spent_micros, 0);
    const remaining = (budget: number | null, used: number) => (budget ? Math.max(budget - used, 0) : "unlimited");
    const person = { scope: "person", subject, budget_micros: cap ?? 0, budget_period: "monthly", spent_micros: spent, reserved_micros: 0, remaining_micros: remaining(cap, spent) };
    const teamRung = team
      ? [{ scope: "team", team_id: team.name, budget_micros: team.budget_micros ?? 0, budget_period: team.budget_period, spent_micros: team.spent_micros, reserved_micros: team.reserved_micros, remaining_micros: remaining(team.budget_micros, team.spent_micros + team.reserved_micros) }]
      : [];
    const platformCap = (this.stored.get("platform_budget_micros") as number | undefined) ?? null;
    const all = [...this.teams.values()].reduce((n, t) => n + t.spent_micros, 0);
    const platform = {
      scope: "platform",
      budget_period: "monthly",
      spent_micros: all,
      reserved_micros: 0,
      bound_by: platformCap ? "platform" : null,
      budget_micros: platformCap ?? 0,
      remaining_micros: remaining(platformCap, all),
    };
    return [person, ...teamRung, platform];
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
    github: { repositories: [], max_pushes: null, max_runs: null },
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
    deployed: {
      client_provider: "openai",
      client_base_url: "https://llm-gw.example.com/v1",
      client_auth: "bearer",
      platform_admin_group: "grp-platform",
      issuer: "https://idp.example.com",
      client_id: "troupe-plane",
      client_secret: "deployed-client-secret",
      audience: "troupe",
      base_url: "https://troupe.example.com",
    },
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
        github: { repositories: ["example-org/widgets"], max_pushes: 5, max_runs: null },
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
        conditions: [
          { type: "Ready", status: "True", reason: "Reconciled", message: "14 resources reconciled" },
          {
            type: "PlaneCAMissing",
            status: "True",
            reason: "NotWritten",
            message: "the namespace has no troupe-plane-ca yet: the operator has read no CA from /etc/troupe/plane-control-ca/ca.crt",
          },
        ],
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
  // What core's and design's triggers have done: a run that opened a draft pull request and
  // went round CI twice, one that failed and nobody has read, one the cap skipped, and
  // design's waiting on a person.
  const run = (fields: Partial<FakeRun> & { id: string; team: string; trigger: string; fired_at: string }): FakeRun => ({
    trigger_id: `trg-${fields.team}-${fields.trigger}`,
    idempotency_key: `k-${fields.id}`,
    session_id: `s-${fields.id}`,
    fired_by: "system:scheduler",
    source: "schedule",
    revision: 1,
    revision_hash: "9f2c41aa",
    event: {},
    state: "done",
    status: "done",
    done_reason: "finished",
    failed_reason: null,
    pending_approvals: 0,
    pending_questions: 0,
    cost_micros: 1_250_000,
    repository: null,
    issue: null,
    github: null,
    reviewed_by: null,
    reviewed_at: null,
    ...fields,
  });
  admin.runRows.push(
    run({
      id: "run-fix-7",
      team: "core",
      trigger: "nightly-deps",
      fired_at: "2026-10-15T03:00:00Z",
      fired_by: "github:triager",
      source: "webhook",
      cost_micros: 3_400_000,
      repository: "example-org/widgets",
      issue: { number: 7, url: "https://github.example.com/example-org/widgets/issues/7", title: "Widgets wobble" },
      github: {
        base: "a".repeat(40),
        branch: "troupe/issue-7",
        commit: "2".repeat(40),
        pushes: 2,
        pushed_at: "2026-10-15T03:40:00Z",
        pull_request: { number: 21, url: "https://github.example.com/example-org/widgets/pull/21" },
        rounds: [
          { commit: "1".repeat(40), state: "red", failing: ["test (ubuntu)"], at: "2026-10-15T03:20:00Z" },
          { commit: "2".repeat(40), state: "green", failing: [], at: "2026-10-15T03:50:00Z" },
        ],
      },
    }),
    run({ id: "run-nightly-14", team: "core", trigger: "nightly-deps", fired_at: "2026-10-14T03:00:00Z", state: "failed", status: "interrupted", done_reason: null, failed_reason: "the turn hit its wall clock", cost_micros: 900_000 }),
    run({ id: "run-nightly-13", team: "core", trigger: "nightly-deps", fired_at: "2026-10-13T03:00:00Z", session_id: null, state: "skipped", status: null, done_reason: null, cost_micros: null, reviewed_by: "dan@example.com", reviewed_at: "2026-10-13T09:00:00Z" }),
    run({ id: "run-digest-1", team: "design", trigger: "weekly-digest", fired_at: "2026-10-12T08:00:00Z", source: "webhook", state: "waiting", status: "waiting", done_reason: null, pending_approvals: 1, cost_micros: 200_000 }),
  );
  admin.stored.set("client_model_default", "glm-5.2");
  admin.stored.set("client_enforced", { approvals: "wait", max_turns: 200 });
  admin.stored.set("default_erase_after_days", 180);
  admin.policies["tui"] = { recommended: "0.16.0-beta", minimum: "0.14.0-beta", blocked: ["0.15.0-beta"], updated_by: "alice@example.com", updated_at: "2026-10-11T09:30:00Z" };
  // The GitHub App, set and installed on one organisation, which GitHub knows by the same key.
  Object.assign(admin.github, {
    app_id: 4242,
    api_url: null,
    installations: [{ owner: "example-org", installation_id: 77001 }],
    key: { type: "rsa-2048", fingerprint: "SHA256:qZk3cX9mVb2fT0aLr8Hn1yWp4sEo6uJd7gKi5", version: 1 },
    updated_by: "alice@example.com",
    updated_at: "2026-10-12T10:00:00Z",
  });
  admin.github.webhook_secret_version = 1;
  admin.deliveries.push(
    { id: "7a1e0c00-1", event: "issues", action: "opened", received_at: "2026-10-13T02:58:00Z", outcome: { runs: ["nightly-deps"] } },
    { id: "7a1e0c00-2", event: "pull_request_review", action: "submitted", received_at: "2026-10-13T09:12:00Z", outcome: { resumed: "s-7f3a9c24" } },
    { id: "7a1e0c00-3", event: "push", action: null, received_at: "2026-10-13T09:30:00Z", outcome: { reason: "nothing here acts on a push" } },
  );
  admin.githubKnows = { app_id: 4242, slug: "troupe-example", fingerprint: "SHA256:qZk3cX9mVb2fT0aLr8Hn1yWp4sEo6uJd7gKi5", installations: [{ owner: "example-org", installation_id: 77001 }] };
  // The build box is a machine of somebody's, registered and enrolled; a second never was.
  admin.hostRows.push(
    { name: "build-box-0", profile: "build-box", address: "10.20.0.14", enabled: true, registered_at: "2026-10-03T09:00:00Z", last_enrolled_at: "2026-10-13T06:00:00Z" },
    { name: "build-box-1", profile: "build-box", address: null, enabled: true, registered_at: "2026-10-12T16:00:00Z", last_enrolled_at: null },
  );
  // Dan arrived by sign-in and SCIM under two keys with one email: the provider's two
  // values for him differ.
  admin.peopleAlike.push({
    by: "email",
    people: [
      { id: "u-dan-1", subject: "dan@example.com", external_id: null, user_name: null, email: "dan@example.com", display_name: "Dan", origin: "sign-in" },
      { id: "u-dan-2", subject: "6f1e2d3c-4b5a-4968-8776-1a2b3c4d5e6f", external_id: "6f1e2d3c-4b5a-4968-8776-1a2b3c4d5e6f", user_name: "dan@example.com", email: "dan@example.com", display_name: "Dan", origin: "scim" },
    ],
    likely: "a sign-in keyed one on the sub claim and SCIM the other on its externalId (else its userName), and the two values differ: make them the same at the provider",
  });
  // A person-mode server on dev: each person connects their own credential to it.
  admin.personServers.push({ name: "calendar", slot: "calendar", profiles: ["dev"] });
  admin.connected.add("dan@example.com|calendar");
  Object.assign(admin.scimState, { token_set: true, rotated_at: "2026-10-04T08:00:00Z", rotated_by: "alice@example.com", last_seen_at: new Date(Date.now() - 3_600_000).toISOString(), last_seen_op: "PATCH /Groups/grp-core" });
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
