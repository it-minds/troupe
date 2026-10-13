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
  sessions: number;
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
  /** The keys the enforced set may hold, as this plane lists them; 
ull is a plane from before it listed any. */
  enforceable: ReadonlyArray<Record<string, unknown> & { key: string }> | null = ENFORCEABLE;

  constructor(opts: { platformAdmins?: string[]; teams?: FakeTeam[]; groups?: Array<{ external_id: string; display_name: string | null }>; deployed?: Record<string, unknown> } = {}) {
    this.platformAdmins = new Set(opts.platformAdmins ?? []);
    for (const t of opts.teams ?? []) this.teams.set(t.name, t);
    this.groups = opts.groups ?? [];
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

      case "admin.team.disable.preview": {
        if (role !== "platform_admin") return notPlatform;
        const found = this.fetchTeam(subject, params["name"]);
        if ("error" in found) return found;
        const t = found.team;
        return {
          result: {
            team: t.name,
            groups: t.groups.map((g) => g.external_id),
            members: t.members.length,
            grants: t.grants.map((g) => g.profile),
            admins: t.admins,
            principals: t.principals,
            triggers: t.triggers,
            sessions_kept: t.sessions,
            confirm: t.name,
          },
        };
      }

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

      case "admin.audit.list":
        return admin ? { result: [...this.audit].reverse() } : notAdmin;

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
    const { principals: _p, triggers: _t, sessions: _s, ...shown } = team;
    return { ...shown, effective: Object.keys(LADDERED).sort().map((key) => this.effective(key, team)) };
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

  private record(actor: string, action: string, subject: string, detail: Changes): void {
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
    sessions: 0,
    ...fields,
  };
}

/**
 * An organisation to look at: Alice administers the platform, Bob the design team, and
 * Carol nothing. Three teams — one with everything set, one over its budget, one with
 * nothing yet — and a gateway the clients default to.
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
          { profile: "dev", volume_mode: "shared" },
          { profile: "ux", volume_mode: null },
        ],
        groups: [{ external_id: "grp-core", display_name: "Core engineering", issuer: "https://idp.example.com", linked_by: "alice@example.com" }],
        members: [member("alice@example.com", "Alice", 80_000_000), member("dan@example.com", "Dan", 120_000_000, 150_000_000), member("erin@example.com", "Erin", 12_400_000)],
        spend_by_model: [{ model: "sonnet", spent_micros: 180_000_000 }],
        principals: ["svc:core/nightly"],
        triggers: ["nightly-deps"],
        sessions: 7,
      }),
      team("design", {
        budget_micros: 250_000_000,
        spent_micros: 261_100_000,
        erase_after_days: 30,
        members_may_control: false,
        admins: ["bob@example.com"],
        grants: [{ profile: "ux", volume_mode: null }],
        groups: [{ external_id: "grp-design", display_name: "Design", issuer: "https://idp.example.com", linked_by: "alice@example.com" }],
        members: [member("bob@example.com", "Bob", 200_000_000), member("fay@example.com", "Fay", 61_100_000)],
        sessions: 3,
      }),
      team("research"),
    ],
  });
  admin.stored.set("client_model_default", "glm-5.2");
  admin.stored.set("client_enforced", { approvals: "wait", max_turns: 200 });
  admin.stored.set("default_erase_after_days", 180);
  admin.policies["tui"] = { recommended: "0.16.0-beta", minimum: "0.14.0-beta", blocked: ["0.15.0-beta"], updated_by: "alice@example.com", updated_at: "2026-10-11T09:30:00Z" };
  return admin;
}
