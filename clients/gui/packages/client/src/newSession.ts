// The rules of the prompt-first new-session screen, apart from any screen: the inline
// tokens a message carries, the title its first line gives, which profile is picked when
// nobody picked one and why, how full a profile is, and who can open what it starts.
//
// The desktop app's screen and its tests read these, and the console can; the terminal
// has its own copy of the same rules in Elixir (`Troupe.UI.NewSession`), and the two are
// held to the same examples by their suites.

/** Where a session runs: a pod on the platform, or this computer's daemon. */
export type NewSessionWhere = "platform" | "local";

/** What the tokens in a message set, each only where it names something that exists. */
export interface MessageTokens {
  profile?: string;
  agent?: string;
  where?: NewSessionWhere;
}

/** The names a token may name: the profiles the person may use and the agents on offer. */
export interface TokenNames {
  profiles: readonly string[];
  agents: readonly string[];
}

const PROFILE = /(^|\s)@([\w.-]+)/g;
const AGENT = /(^|\s)#([\w.-]+)/g;
const WHERE = /(^|\s)\/(local|platform)(?=\s|$)/g;

function first(re: RegExp, text: string, known: readonly string[] | null): string | undefined {
  for (const m of text.matchAll(re)) {
    const name = m[2]!;
    if (!known || known.includes(name)) return name;
  }
  return undefined;
}

/**
 * The tokens in `text`: `@profile`, `#agent`, `/local` or `/platform`, at the start or
 * after whitespace. A `@` or `#` word that names nothing on offer is not a token and stays
 * in the message, so "#123" and "@someone" are what they were.
 */
export function messageTokens(text: string, names: TokenNames): MessageTokens {
  const out: MessageTokens = {};
  const profile = first(PROFILE, text, names.profiles);
  if (profile) out.profile = profile;
  const agent = first(AGENT, text, names.agents);
  if (agent) out.agent = agent;
  const where = first(WHERE, text, null);
  if (where === "local" || where === "platform") out.where = where;
  return out;
}

function strip(text: string, re: RegExp, known: readonly string[] | null): string {
  return text.replace(re, (whole, lead: string, name: string) => (!known || known.includes(name) ? lead : whole));
}

/** The message with its tokens taken out, spaces closed up: what the agent reads. */
export function cleanMessage(text: string, names: TokenNames): string {
  let t = strip(text, PROFILE, names.profiles);
  t = strip(t, AGENT, names.agents);
  t = strip(t, WHERE, null);
  return t
    .replace(/[ \t]+/g, " ")
    .replace(/ *\n */g, "\n")
    .trim();
}

/**
 * The message with the tokens of the kinds a chip was just picked for taken out, so the
 * chip the person clicked is what holds: the last thing they did wins. Left as typed
 * otherwise, trailing spaces aside.
 */
export function stripTokens(text: string, picked: { profile?: unknown; agent?: unknown; where?: unknown }, names: TokenNames): string {
  let t = text;
  if ("profile" in picked) t = strip(t, PROFILE, names.profiles);
  if ("agent" in picked) t = strip(t, AGENT, names.agents);
  if ("where" in picked) t = strip(t, WHERE, null);
  return t.replace(/[ \t]{2,}/g, " ").replace(/[ \t]+$/gm, "").replace(/^[ \t]+/, "");
}

/** The title the cleaned message gives: its first sentence or line, at most 60 characters. */
export function titleFromMessage(cleaned: string): string {
  return (cleaned.split(/\.\s|\.$|\n/)[0] ?? "").trim().slice(0, 60);
}

/** What a create would meet on a profile, from its `profiles.list` row. */
export interface ProfileRoom {
  free: number;
  capacity: number;
  /** No room now, and below the ceiling: a create waits for the next place. */
  full: boolean;
  /** No pod at all and nothing running: scaled to zero, so a create starts a pod. Not full. */
  idle: boolean;
  /** At the administrator's ceiling: a create is refused. */
  atCeiling: boolean;
  maxSessions: number | null;
}

/** The fields of a `profiles.list` row the room is read from. */
export interface ProfileRoomRow {
  name: string;
  capacity: number;
  active_sessions: number;
  max_sessions?: number | null;
}

export function profileRoom(row: ProfileRoomRow): ProfileRoom {
  const maxSessions = typeof row.max_sessions === "number" ? row.max_sessions : null;
  const free = Math.max(0, row.capacity - row.active_sessions);
  const atCeiling = maxSessions !== null && row.active_sessions >= maxSessions;
  const idle = !atCeiling && row.capacity <= 0 && row.active_sessions <= 0;
  return { free, capacity: row.capacity, full: !atCeiling && !idle && free <= 0, idle, atCeiling, maxSessions };
}

/**
 * The agent a session on a profile starts as when none is named: `build` where the profile
 * offers it, else the first it offers, the plane's own rule. `null` where `profiles.list`
 * offers none: the create then names none, and the plane chooses or says why it cannot.
 */
export function defaultProfileAgent(agents: readonly string[] | null | undefined): string | null {
  const offered = agents ?? [];
  return offered.includes("build") ? "build" : (offered[0] ?? null);
}

/** Which profile is picked when nobody picked one, and the sentence that says why. */
export interface AutoPick {
  name: string | null;
  rule: "last" | "instead" | "first" | "none";
  why: string;
}

/**
 * The last-used profile if it has room, else the first with room, in the order the list
 * gives. With none that has room, the last-used one (or the first) all the same, so the
 * screen can offer to queue on it; with no profiles at all, none.
 */
export function autoPickProfile(rows: readonly ProfileRoomRow[], lastUsed: string | null): AutoPick {
  const last = lastUsed ? rows.find((r) => r.name === lastUsed) : undefined;
  // A profile scaled to zero has room: a create there starts a pod rather than waiting.
  const roomy = (r: ProfileRoomRow): boolean => {
    const room = profileRoom(r);
    return (room.free > 0 || room.idle) && !room.atCeiling;
  };
  if (last && roomy(last)) return { name: last.name, rule: "last", why: `Picked ${last.name} because you used it last.` };
  const any = rows.find(roomy);
  if (any && last) return { name: any.name, rule: "instead", why: `Picked ${any.name}: ${last.name} is full right now.` };
  if (any) return { name: any.name, rule: "first", why: `Picked ${any.name}: the first profile with room right now.` };
  const fallback = last ?? rows[0];
  if (fallback) return { name: fallback.name, rule: "none", why: "Every profile is full right now." };
  return { name: null, rule: "none", why: "There is no profile you may start a session on." };
}

/** "A", "A and B", "A, B and C". */
export function andList(names: readonly string[]): string {
  if (names.length <= 1) return names[0] ?? "";
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
}

/** Who can open the session, as the sentence ends: it follows from where it runs. */
export function whoCanOpen(where: NewSessionWhere, opts: { teams?: readonly string[] | null; private?: boolean } = {}): string {
  if (where === "local" || opts.private) return "only you can open it";
  const teams = (opts.teams ?? []).filter((t) => typeof t === "string" && t);
  return teams.length > 0 ? `everyone on ${andList(teams)} can open it` : "your team can open it";
}

/** "Set from your message: /local @dev #plan." */
export function tokensSentence(tokens: MessageTokens): string | null {
  const said = [tokens.where && `/${tokens.where}`, tokens.profile && `@${tokens.profile}`, tokens.agent && `#${tokens.agent}`].filter(Boolean);
  return said.length > 0 ? `Set from your message: ${said.join(" ")}.` : null;
}

/** The line under the sentence for a full profile. */
export function fullHouseSentence(name: string, capacity: number): string {
  return `Full house: ${name} has ${capacity} of ${capacity} running. Pick another, or queue it for the next free place.`;
}

/** The line for a profile at its ceiling, until the plane's own sentence is known. */
export function ceilingSentence(name: string, maxSessions: number): string {
  return `${name} allows ${maxSessions} session${maxSessions === 1 ? "" : "s"} at once.`;
}

/** The line while this computer's daemon is not there. */
export const LOCAL_DOWN_SENTENCE = "This computer’s Troupe app isn’t running yet. Start it, and this switches on by itself.";
