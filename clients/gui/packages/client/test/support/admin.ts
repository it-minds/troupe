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
  readonly groups: Array<{ external_id: string; display_name: string | null }>;
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

  constructor(
    opts: {
      platformAdmins?: string[];
      teams?: FakeTeam[];
      groups?: Array<{ external_id: string; display_name: string | null }>;
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
          triggers: t.triggers,
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
        triggers: ["nightly-deps"],
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
      },
      {
        name: "heavy",
        size_class: "heavy",
        replicas: 2,
        sessions_per_pod: 2,
        channel: "stable",
        image: "registry.example.com/troupe/worker:0.17.0-beta",
        provisioner: "kubernetes",
        missing_guarantees: [],
        unenforced: false,
        pods: [pod("troupe-w-heavy-0", 0, { capacity: 2 })],
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
      session("s-7f3a9c23", "erin@example.com", "core", "ux", { last_active_at: "2026-10-13T08:40:00Z", workspace_bytes: 64_000_000 }),
      session("s-7f3a9c24", "svc:core/nightly", "core", "dev", { origin: "trigger", visibility: "team", last_active_at: "2026-10-13T03:05:00Z" }),
      session("s-7f3a9c25", "dan@example.com", "core", "dev", { state: "dormant", parent: "s-7f3a9c22", last_active_at: "2026-10-11T15:00:00Z" }),
      session("s-7f3a9c26", "erin@example.com", "core", "dev", { state: "read_only", last_active_at: "2026-10-09T11:20:00Z", object_bytes: 9_800_000 }),
      session("s-7f3a9c27", "alice@example.com", "core", "ux", { state: "dormant", visibility: "private", last_active_at: "2026-10-10T09:45:00Z" }),
      session("s-4b81d003", "bob@example.com", "design", "ux", { last_active_at: "2026-10-13T08:30:00Z", last_seq: 97 }),
      session("s-4b81d004", "fay@example.com", "design", "ux", { state: "dormant", last_active_at: "2026-10-12T14:00:00Z" }),
      session("s-4b81d005", "bob@example.com", "design", "ux", { state: "dormant", last_active_at: "2026-10-08T10:00:00Z" }),
    ],
  });
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
