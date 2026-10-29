// The profiles a fake plane serves `profile.get` from, and the composition the plane makes
// of one for the person asking (the answer's shape is the plane's `profile.get`).
//
// Each profile is what the plane reads to answer: its bundle's agents, skills and MCP
// servers (each with `credential_mode`, `permission` and `tools`, as a bundle carries
// them), its spec's agent rule, tool rules, egress and model, the organisation's rules,
// its limits and budgets, and the teams granted it with what each grant leaves out. The
// composition is done here once, so the desktop app's and the console's tests see the
// same answer the same plane would give either of them.

import type { ProfileView } from "../../src/profile.js";
import type { FakeProfile } from "./admin.js";

export interface FakeBundleServer {
  name: string;
  url: string;
  credential_mode: "person" | "profile" | "client_credentials";
  permission: "auto" | "ask";
  tools: string[] | "all";
}

export interface FakeProfileSpec {
  name: string;
  channel: string;
  bundle_version: string;
  bundle_hash: string;
  bundle: {
    agents: Array<{ name: string; mode: "primary" | "subagent"; description: string }>;
    skills: string[];
    mcp_servers: FakeBundleServer[];
  };
  /** `spec.agents`: deny over allow, an absent allow is every agent. */
  agentRule?: { allow?: string[]; deny?: string[] };
  /** `spec.permissions`, the profile's own tool rules. */
  permissions?: { allow?: string[]; ask?: string[]; deny?: string[] };
  llm?: { model?: string; smallModel?: string; provider?: string; endpoint?: string; secretRef?: unknown };
  egress?: string[];
  sessions_per_pod: number;
  max_sessions: number | null;
  /** `spec.budget`, monthly, in micros. */
  budget_micros: number | null;
  /** The teams granted it, and what each grant leaves out of it. */
  grants: Record<string, { agents_out?: string[]; servers_out?: string[] }>;
}

/** The built-ins every profile has unless its rule or a grant takes them away. */
export const BUILTINS: Array<{ name: string; mode: "primary" | "subagent"; description: string }> = [
  { name: "build", mode: "primary", description: "Does the work: reads, edits and runs" },
  { name: "plan", mode: "primary", description: "Reads and plans; changes nothing" },
  { name: "explore", mode: "subagent", description: "Searches a codebase and reports back" },
];

/** The organisation's tool rules, which every profile runs under beside its own. */
export const ORGANISATION_RULES = { ask: ["bash(curl *)"], deny: ["bash(sudo *)"] } as const;

/** What the plane's teams may spend, and what a person may, in micros. */
export const TEAM_BUDGETS: Record<string, number | null> = { core: 500_000_000, design: 250_000_000 };
export const PERSON_BUDGET: number | null = 150_000_000;

/**
 * Two profiles: `dev`, the full one, whose `core` grant leaves out the wiki server; and
 * `ux`, a lean one whose rule leaves out `build` and whose `core` grant leaves out `plan`.
 */
export function exampleProfiles(): FakeProfileSpec[] {
  return [
    {
      name: "dev",
      channel: "stable",
      bundle_version: "3",
      bundle_hash: "sha256:abc",
      bundle: {
        agents: [{ name: "reviewer", mode: "subagent", description: "Reads a diff and comments on it" }],
        skills: ["review"],
        mcp_servers: [
          { name: "github", url: "https://api.githubcopilot.com/mcp/", credential_mode: "person", permission: "ask", tools: "all" },
          { name: "jira", url: "https://mcp.example.com/jira", credential_mode: "profile", permission: "auto", tools: ["search_issues", "get_issue"] },
          { name: "wiki", url: "https://wiki.example.com/mcp", credential_mode: "client_credentials", permission: "ask", tools: ["read_page"] },
        ],
      },
      permissions: { ask: ["bash(git push *)"], deny: ["bash(rm -rf *)"], allow: ["webfetch"] },
      llm: { model: "glm-5.2", smallModel: "qwen3.6-35b", provider: "openai", endpoint: "https://llm-gw.example.com/v1", secretRef: { name: "llm-gateway", key: "api-key" } },
      egress: ["github.com", "llm-gw.example.com", "mcp.example.com"],
      sessions_per_pod: 4,
      max_sessions: 12,
      budget_micros: 200_000_000,
      grants: { core: { servers_out: ["wiki"] } },
    },
    {
      name: "ux",
      channel: "stable",
      bundle_version: "3",
      bundle_hash: "sha256:abc",
      bundle: {
        agents: [],
        skills: [],
        mcp_servers: [{ name: "figma", url: "https://figma.example.com/mcp", credential_mode: "person", permission: "auto", tools: "all" }],
      },
      agentRule: { deny: ["build"] },
      egress: ["figma.example.com"],
      sessions_per_pod: 4,
      max_sessions: null,
      budget_micros: null,
      grants: { core: { agents_out: ["plan"] }, design: {} },
    },
  ];
}

const hostOf = (url: string | undefined): string | null => {
  if (!url) return null;
  try {
    return new URL(url).host;
  } catch {
    return null;
  }
};

/** `bash(git push *)` as its tool and its pattern; a bare tool has no pattern. */
function ruleParts(rule: string): { tool: string; pattern: string | null } {
  const m = /^([^(]+)\((.*)\)$/.exec(rule);
  return m ? { tool: m[1]!, pattern: m[2]! } : { tool: rule, pattern: null };
}

const ACCESS = { person: "yours", profile: "profile", client_credentials: "system" } as const;

/**
 * The plane's answer for a caller in `teams`, or null where none of their teams is granted
 * it and they are no administrator (`not_found`). An administrator asking is answered for
 * no team: nothing a grant leaves out, and no team's budget.
 */
export function composeProfile(
  spec: FakeProfileSpec,
  caller: { teams: string[]; admin?: boolean },
  live: { capacity: number; active_sessions: number },
): ProfileView | null {
  const mine = caller.teams.filter((t) => t in spec.grants).sort();
  if (mine.length === 0 && !caller.admin) return null;
  // An administrator is answered for no team and lists none, as the plane answers one who
  // is in no team that may use it: the console's view, which no grant narrows.
  const teams = caller.admin ? [] : mine;
  const team = caller.admin ? null : (teams[0] ?? null);
  const grant = team ? spec.grants[team]! : {};
  const rule = spec.agentRule ?? {};
  const every = [...spec.bundle.agents.map((a) => ({ ...a, from: "bundle" as const })), ...BUILTINS.filter((b) => !spec.bundle.agents.some((a) => a.name === b.name)).map((b) => ({ ...b, from: "builtin" as const }))];
  const byRule = (name: string) => !(rule.deny ?? []).includes(name) && (rule.allow === undefined || rule.allow.includes(name));
  const byGrant = (name: string) => !(grant.agents_out ?? []).includes(name);
  const rules = (from: "profile" | "organisation", set: { allow?: readonly string[]; ask?: readonly string[]; deny?: readonly string[] }) =>
    (["deny", "ask", "allow"] as const).flatMap((access) => (set[access] ?? []).map((r) => ({ ...ruleParts(r), access, from })));
  return {
    name: spec.name,
    channel: spec.channel,
    bundle_version: spec.bundle_version,
    bundle_hash: spec.bundle_hash,
    team,
    teams,
    model: {
      model: spec.llm?.model ?? null,
      small_model: spec.llm?.smallModel ?? null,
      provider: spec.llm?.provider ?? null,
      host: hostOf(spec.llm?.endpoint),
      // The profile's key only where it names an endpoint and a Secret; no profile setting
      // gives a person's own key, so the plane never answers "yours".
      key: spec.llm?.endpoint && spec.llm.secretRef ? "profile" : null,
    },
    agents: every.filter((a) => byRule(a.name) && byGrant(a.name)).map((a) => ({ name: a.name, mode: a.mode, description: a.description, from: a.from })),
    agents_not_here: every
      .filter((a) => !byRule(a.name) || !byGrant(a.name))
      .map((a) => ({ name: a.name, mode: a.mode, from: a.from, why: byRule(a.name) ? "grant" : "profile" })),
    skills: spec.bundle.skills,
    tools: {
      // A pod reads no organisation layer, so every rule the plane lists is the profile's.
      rules: rules("profile", spec.permissions ?? {}),
      mcp: spec.bundle.mcp_servers.map((s) => {
        const out = (grant.servers_out ?? []).includes(s.name);
        return { name: s.name, host: hostOf(s.url), access: ACCESS[s.credential_mode], permission: s.permission, tools: s.tools, offered: !out, why: out ? "grant" : null };
      }),
    },
    // What the operator derives: the egress list, the model's host and each server's host.
    reach: [...new Set([...(spec.egress ?? []), hostOf(spec.llm?.endpoint), ...spec.bundle.mcp_servers.map((s) => hostOf(s.url))].filter((h): h is string => Boolean(h)))].sort(),
    limits: {
      sessions_per_pod: spec.sessions_per_pod,
      max_sessions: spec.max_sessions,
      capacity: live.capacity,
      active_sessions: live.active_sessions,
      budgets: { profile: spec.budget_micros, team: team ? (TEAM_BUDGETS[team] ?? null) : null, you: PERSON_BUDGET },
    },
    terms: null,
  };
}

/**
 * A profile the administrative half knows and the examples do not, read from its spec as
 * the plane would: no bundle, its rules, model, egress, limits and budget, and the teams
 * granted it, each leaving nothing out.
 */
export function specOfAdminProfile(p: FakeProfile, granted: string[]): FakeProfileSpec {
  const spec = (p.spec ?? {}) as {
    agents?: FakeProfileSpec["agentRule"];
    permissions?: FakeProfileSpec["permissions"];
    llm?: FakeProfileSpec["llm"];
    egress?: { fqdns?: string[] };
  };
  return {
    name: p.name,
    channel: p.channel ?? "stable",
    bundle_version: "1",
    bundle_hash: "sha256:0",
    bundle: { agents: [], skills: [], mcp_servers: [] },
    ...(spec.agents ? { agentRule: spec.agents } : {}),
    ...(spec.permissions ? { permissions: spec.permissions } : {}),
    ...(spec.llm ? { llm: spec.llm } : {}),
    egress: spec.egress?.fqdns ?? [],
    sessions_per_pod: p.sessions_per_pod,
    max_sessions: p.max_sessions ?? null,
    budget_micros: p.budget_micros ?? null,
    grants: Object.fromEntries(granted.map((t) => [t, {}])),
  };
}
