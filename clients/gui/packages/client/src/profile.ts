// What a profile gives a session, as the plane answers `profile.get` for the person asking:
// the agents there and the ones that are not (and why), the tool rules and MCP servers
// with whose access each server is called, the model, the hosts it can reach, its limits
// and which of the person's teams it runs under.
//
// The plane composes it from what it enforces, so a client draws it and composes nothing:
// a client that worked out "which agents" from the bundle and the grant itself would be a
// second reading of the rules, and the first one to drift would show a person a profile
// that is not the one their session gets. The words here are the ones both apps say.

/** An agent a session on the profile may run. */
export interface ProfileViewAgent {
  name: string;
  mode: "primary" | "subagent" | string;
  description: string | null;
  from: "bundle" | "builtin" | string;
}

/**
 * A function agent the harness may run on the profile for a job of its own (`answer` for an
 * `AI?` comment, the librarian): no session runs one as its agent, so it is in neither of the
 * other lists unless the profile's rule took it away.
 */
export interface ProfileViewFunction {
  name: string;
  description: string | null;
  from: "bundle" | "builtin" | string;
}

/** An agent that is not there, and which rule took it away: the profile's own, or the team's grant. */
export interface ProfileViewMissing {
  name: string;
  mode: "primary" | "subagent" | "function" | string;
  from: "bundle" | "builtin" | string;
  why: "profile" | "grant" | string;
}

export type RuleAccess = "allow" | "ask" | "deny";

/** One tool rule in force, and whose it is. */
export interface ProfileViewRule {
  tool: string;
  pattern: string | null;
  access: RuleAccess | string;
  from: "profile" | "organisation" | string;
}

/** Whose credential an MCP server is called with. */
export type ServerAccess = "yours" | "profile" | "system";

/** An MCP server of the profile's, and whether the person's team is offered it. */
export interface ProfileViewServer {
  name: string;
  host: string | null;
  access: ServerAccess | string;
  permission: "auto" | "ask" | string;
  tools: string[] | "all";
  offered: boolean;
  why: null | "grant" | string;
}

export interface ProfileViewModel {
  model: string | null;
  small_model: string | null;
  provider: string | null;
  /** The gateway's host, never its address with a path or a key. */
  host: string | null;
  key: "profile" | "yours" | null | string;
}

export interface ProfileViewLimits {
  sessions_per_pod: number | null;
  max_sessions: number | null;
  capacity: number | null;
  active_sessions: number | null;
  /** In micros; null where there is none. */
  budgets: { profile: number | null; team: number | null; you: number | null };
}

/** The answer to `profile.get`. Fields the plane cannot fill are null. */
export interface ProfileView {
  name: string;
  channel: string | null;
  bundle_version: string | null;
  bundle_hash: string | null;
  /** The team a session would belong to; null for an administrator asking for no team. */
  team: string | null;
  /** Every team of the caller's that may use it. */
  teams: string[];
  model: ProfileViewModel;
  agents: ProfileViewAgent[];
  /** The function agents the harness may run there; absent from a plane before them. */
  functions?: ProfileViewFunction[];
  agents_not_here: ProfileViewMissing[];
  skills: string[];
  tools: { rules: ProfileViewRule[]; mcp: ProfileViewServer[] };
  reach: string[];
  limits: ProfileViewLimits;
  terms: Record<string, unknown> | null;
  [k: string]: unknown;
}

/** The heading the function agents are shown under, in both apps and the terminal. */
export const FUNCTIONS_HEADING = "What the harness may run here";

/** Whose access a server is called with, as a phrase after "called". */
export function accessWords(access: string): string {
  switch (access) {
    case "yours":
      return "as you, once you connect it";
    case "profile":
      return "as the profile";
    case "system":
      return "as the profile's own identity";
    default:
      return access;
  }
}

/** Micros as money: nothing reported is "—", which is not the same as free. */
export function moneyWords(micros: number | null | undefined): string {
  if (micros === null || micros === undefined) return "—";
  if (micros === 0) return "$0.00";
  const dollars = micros / 1_000_000;
  return `$${dollars < 0.01 ? dollars.toFixed(4) : dollars.toFixed(2)}`;
}

/** A budget: none is no cap of that kind, which is not a cap of nothing. */
export function budgetWords(micros: number | null | undefined): string {
  return micros === null || micros === undefined ? "no cap" : moneyWords(micros);
}

/** What a tool rule does, in a word. */
export function ruleAccessWords(access: string): string {
  return access === "allow" ? "allowed" : access === "ask" ? "asked" : access === "deny" ? "refused" : access;
}

/** Whose rule or server it is. */
export function whoseWords(from: string): string {
  return from === "organisation" ? "the organisation" : from === "profile" ? "the profile" : from === "builtin" ? "built in" : from === "bundle" ? "the bundle" : from;
}

/** Why an agent or a server is not there. */
export function missingWords(why: string | null): string {
  return why === "profile" ? "the profile does not have it" : why === "grant" ? "your team's grant leaves it out" : (why ?? "");
}

/** Whether a server's calls are asked about first. */
export function askWords(permission: string): string {
  return permission === "auto" ? "automatic" : permission === "ask" ? "asked" : permission;
}

/** Whose key the model is reached with. */
export function keyWords(key: string | null): string {
  return key === "profile" ? "the profile's" : key === "yours" ? "yours" : key === null ? "not said" : key;
}

/** Room on the profile now, from its capacity and what is running. */
export function capacityWords(limits: Pick<ProfileViewLimits, "capacity" | "active_sessions">): string {
  if (limits.capacity === null) return "capacity not said";
  const free = Math.max(0, limits.capacity - (limits.active_sessions ?? 0));
  return free > 0 ? `room for ${free} of ${limits.capacity}` : `full: ${limits.capacity} of ${limits.capacity} running`;
}

/** The hosts, two named and the rest counted. */
function hostsWords(hosts: string[]): string {
  if (hosts.length === 0) return "reaches no host";
  const named = hosts.slice(0, 2).join(", ");
  return hosts.length > 2 ? `reads ${named} and ${hosts.length - 2} more` : `reads ${named}`;
}

/** One line for a list of profiles: its agents, the servers it is offered, the hosts it reads. */
export function profileSummary(view: Pick<ProfileView, "agents" | "tools" | "reach">): string {
  const agents = view.agents.length === 1 ? "1 agent" : `${view.agents.length} agents`;
  const servers = view.tools.mcp.filter((s) => s.offered).map((s) => s.name);
  return [agents, servers.length ? servers.join(", ") : "no MCP server", hostsWords(view.reach)].join(" · ");
}
