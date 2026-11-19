// What a profile gives a session, as the plane answers `profile.get` for the person asking:
// the agents there and the ones that are not (and why), the tool rules and MCP servers
// with whose access each server is called, the model, the hosts it can reach, its limits
// and which of the person's teams it runs under.
//
// The plane composes it from what it enforces, so a client draws it and composes nothing:
// a client that worked out "which agents" from the bundle and the grant itself would be a
// second reading of the rules, and the first one to drift would show a person a profile
// that is not the one their session gets. The words here are the ones both apps say.

import { countWords, durationWords, moneyWords } from "./words.js";

/** An agent a session on the profile may run. */
export interface ProfileViewAgent {
  name: string;
  mode: "primary" | "subagent" | string;
  description: string | null;
  from: "bundle" | "builtin" | string;
  /** Its own cap on model calls, where its definition sets one: never above the session's. */
  max_turns?: number;
  /** Its own output cap per model call, where its definition sets one: never above the profile's. */
  max_tokens?: number;
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
  /** Its subtitle and a line per tool, in the bundle author's words; absent or null where unsaid. */
  about?: ProfileViewServerAbout | null;
}

/** What a server is, and what each of its tools does, as the bundle's author wrote it. */
export interface ProfileViewServerAbout {
  summary: string | null;
  /** A line per tool, by the tool's name. */
  tools: Record<string, string>;
}

export interface ProfileViewModel {
  model: string | null;
  small_model: string | null;
  provider: string | null;
  /** The gateway's host, never its address with a path or a key. */
  host: string | null;
  key: "profile" | "yours" | null | string;
}

/** What each agent of a session may spend before it asks to go on: Troupe's defaults, which no profile sets. */
export interface ProfileViewAllowance {
  max_turns: number;
  /** Working time: waiting on a person does not count. */
  wall_clock_seconds: number;
  max_input_tokens: number;
  max_output_tokens: number;
  max_depth: number;
}

export interface ProfileViewLimits {
  sessions_per_pod: number | null;
  max_sessions: number | null;
  capacity: number | null;
  active_sessions: number | null;
  /** The output cap of one model call. This and the three below are absent from a plane before them. */
  max_tokens?: number;
  session?: ProfileViewAllowance;
  /** How long a session rests with nothing to do before it sleeps; null with no team. */
  idle_seconds?: number | null;
  /** In micros; null where there is none. `team_period` is what the team's runs over, null with no team. */
  budgets: { profile: number | null; team: number | null; you: number | null; team_period?: "monthly" | "never" | string | null };
}

/** What a session may do on GitHub through the plane's App, where the profile gives it any. */
export interface ProfileViewGitHub {
  /** GitHub's own permission names: `contents`, `pull_requests`, `checks`, `statuses`. */
  permissions: Record<string, string>;
  /** Pushes a run may make; null for no cap. */
  max_pushes: number | null;
  /** Runs on a repository at once; null for no cap. */
  max_runs: number | null;
  /** Runs on one issue a sweep starts before leaving it for a person. */
  max_attempts: number;
}

/** One of the harness's own tools, and whether a rule refuses it whole. */
export interface ProfileViewHarnessTool {
  name: string;
  refused: boolean;
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
  /** What the profile is for, in the bundle author's words; absent or null where unsaid. */
  about?: { summary: string } | null;
  model: ProfileViewModel;
  agents: ProfileViewAgent[];
  /** The function agents the harness may run there; absent from a plane before them. */
  functions?: ProfileViewFunction[];
  agents_not_here: ProfileViewMissing[];
  skills: string[];
  /** The same skills with what each does and its SKILL.md; absent from a plane before them. */
  skill_details?: ProfileViewSkill[];
  tools: { rules: ProfileViewRule[]; mcp: ProfileViewServer[] };
  /** The harness's own tools; absent from a plane before them, as are the three below. */
  harness_tools?: ProfileViewHarnessTool[];
  reach: string[];
  limits: ProfileViewLimits;
  /** Null where the profile gives no GitHub permissions. */
  github?: ProfileViewGitHub | null;
  /** Whether a person may offer a session there their own signed-in tools. */
  personal_tools?: "allow" | "forbid" | string;
  /** Whether its agents may propose to a team's or the organisation's memory. */
  memory_proposals?: boolean;
  terms: Record<string, unknown> | null;
  [k: string]: unknown;
}

/** A skill the grant leaves: what it does, and the body of its SKILL.md after the front matter. */
export interface ProfileViewSkill {
  name: string;
  description: string | null;
  /** Null for a skill whose bundle entry has no SKILL.md. */
  body: string | null;
  /** The body was cut, at 64 KiB. */
  truncated: boolean;
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

const plural = (n: number, one: string, many: string): string => `${n} ${n === 1 ? one : many}`;

/**
 * Room on the profile now and its ceiling, in two sentences: "3 of 4 places free. Up to 8
 * sessions at once." A profile with no place up and nothing running starts one for a new
 * session; one with every place taken has a new session wait for one.
 */
export function roomWords(limits: Pick<ProfileViewLimits, "capacity" | "active_sessions" | "max_sessions">): string {
  const active = limits.active_sessions ?? 0;
  const now =
    limits.capacity === null
      ? "Room not said."
      : limits.capacity <= 0 && active <= 0
        ? "No place is up; a new session starts one."
        : limits.capacity - active > 0
          ? `${limits.capacity - active} of ${plural(limits.capacity, "place", "places")} free.`
          : "Every place is taken: a new session waits for one.";
  const most = limits.max_sessions === null ? "No cap on sessions at once." : `Up to ${plural(limits.max_sessions, "session", "sessions")} at once.`;
  return `${now} ${most}`;
}

/** Whose credential a server is called with, as the rail's "acts as" says it. */
function actorWords(access: string): string {
  return access === "yours" ? "you, once you connect it" : access === "profile" ? "the profile" : access === "system" ? "the profile's own identity" : access;
}

/** Whose credentials the offered servers are called with, each said once in the order first met. */
export function actsAsWords(servers: readonly Pick<ProfileViewServer, "access" | "offered">[]): string {
  const seen = [...new Set(servers.filter((s) => s.offered).map((s) => s.access))];
  if (seen.length === 0) return "No server to call.";
  return seen.map(actorWords).join("; ");
}

/** A tool rule as it is written: `bash(git push *)`, or the bare tool. */
export function ruleText(rule: Pick<ProfileViewRule, "tool" | "pattern">): string {
  return rule.pattern === null ? rule.tool : `${rule.tool}(${rule.pattern})`;
}

/** The hosts, two named and the rest counted. */
function hostsWords(hosts: string[]): string {
  if (hosts.length === 0) return "reaches no host";
  const named = hosts.slice(0, 2).join(", ");
  return hosts.length > 2 ? `reads ${named} and ${hosts.length - 2} more` : `reads ${named}`;
}

/**
 * The sentence under a profile's name: what its bundle's author says it is for, else what
 * its first primary agent says it does; null where neither says anything.
 */
export function profileSentence(view: Pick<ProfileView, "about" | "agents">): string | null {
  return view.about?.summary ?? view.agents.find((a) => a.mode === "primary")?.description ?? null;
}

/**
 * A server's tools as its card lists them: each with the author's line for it where there is
 * one. The allowlist's order, or, for a server with every tool, the tools the author wrote a
 * line for; empty for such a server with none.
 */
export function toolLines(server: Pick<ProfileViewServer, "tools" | "about">): { name: string; line: string | null }[] {
  const lines = server.about?.tools ?? {};
  const names = server.tools === "all" ? Object.keys(lines).sort() : server.tools;
  return names.map((name) => ({ name, line: lines[name] ?? null }));
}

/** One line for a list of profiles: its agents, the servers it is offered, the hosts it reads. */
export function profileSummary(view: Pick<ProfileView, "agents" | "tools" | "reach">): string {
  const agents = view.agents.length === 1 ? "1 agent" : `${view.agents.length} agents`;
  const servers = view.tools.mcp.filter((s) => s.offered).map((s) => s.name);
  return [agents, servers.length ? servers.join(", ") : "no MCP server", hostsWords(view.reach)].join(" · ");
}

/**
 * The limits a session on the profile is held to, a sentence each: the output cap of one
 * model call, each agent's working time and model calls before it asks to go on, how deep
 * it delegates, how long it rests before it sleeps, and how many pushes a run makes. Each
 * is said only where the plane states it; a plane before them says none.
 */
export function limitSentences(view: Pick<ProfileView, "limits" | "github">): string[] {
  const { max_tokens, session, idle_seconds } = view.limits;
  const said: string[] = [];
  if (max_tokens !== undefined) said.push(`Each model call writes at most ${countWords(max_tokens, "token")}.`);
  if (session) {
    said.push(`An agent works for at most ${durationWords(session.wall_clock_seconds * 1000, "long")} before it asks to go on; time waiting on you does not count.`);
    said.push(`At most ${countWords(session.max_turns, "model call")} before it asks.`);
    said.push(`Delegates at most ${countWords(session.max_depth, "level")} deep.`);
  }
  if (idle_seconds !== undefined && idle_seconds !== null) said.push(`Sleeps after ${durationWords(idle_seconds * 1000, "long")} with nothing to do, and wakes with its history.`);
  const pushes = view.github?.max_pushes;
  if (pushes !== undefined && pushes !== null) said.push(`Pushes at most ${countWords(pushes, "time")}, then stops and says so on its pull request.`);
  return said;
}

/** A team's budget with the period it runs over: `$500.00 a month`, `$500.00 in all`. */
export function teamBudgetWords(budgets: ProfileViewLimits["budgets"]): string {
  const amount = budgetWords(budgets.team);
  if (budgets.team === null) return amount;
  return budgets.team_period === "monthly" ? `${amount} a month` : budgets.team_period === "never" ? `${amount} in all` : amount;
}

/**
 * Whether the tools the page lists are every tool a session there has: none of a person's
 * own may be offered, no GitHub tools come with a repository, and neither a shell nor a web
 * fetch is on to reach past them. A plane that does not say is never whole.
 */
export function toolsAreWhole(view: Pick<ProfileView, "harness_tools" | "personal_tools" | "github">): boolean {
  const tools = view.harness_tools;
  if (!tools || view.personal_tools !== "forbid" || view.github !== null) return false;
  const on = (name: string): boolean => tools.some((t) => t.name === name && !t.refused);
  return !on("shell") && !on("web_fetch");
}
