// A memory document as entries (troupe #55): each `## Topic` section of its text is one
// entry, as the plane reads it and answers it (`entries` beside a document's `text` in
// `me.memory`, `admin.memory.get`), each with who last changed it and when and in how many
// sessions it was used. On a topic the closest level's entry replaces the lower ones, the
// organisation's lowest, then a team's, then a worker profile's, then the person's own: what
// a new session in a team starts knowing is the plane's `memory.in_effect`, one list of topics.
//
// The client reads both as the plane answers them and computes neither; a save sends the
// entries back (`me.memory.put {entries, version}`), which the plane writes as sections.

import type { MemoryBlameLine, MemoryLine } from "./admin.js";

/** One entry of a level, as the plane answers it: its topic and what it says, and who last changed it. */
export interface MemoryEntry {
  topic: string;
  body: string;
  /** False for the text before the document's first heading, the entry called "General". */
  heading?: boolean;
  /** The version its newest line came in, who saved that version and when. */
  version?: number | null;
  by?: string | null;
  at?: string | null;
  /** An agent's entry: the session and the agent it came from. */
  session?: string;
  agent?: string;
  /** How many sessions read a version holding it since it came in, approximately. */
  used?: number;
}

/** Where an entry is kept: the organisation's, a team's or a worker profile's (`name`), or the person's own. */
export interface EntryLevel {
  scope: "organisation" | "team" | "profile" | "user";
  name: string | null;
}

/** An entry as it is in force, from its level, with the lower levels' entries on its topic it replaces, closest first. */
export interface InEffect extends MemoryEntry {
  level: EntryLevel;
  replaces: Array<{ level: EntryLevel; topic: string; body: string }>;
}

/** What a new session of the person's in a team reads (`memory.in_effect`): the levels, lowest first, and the entries in effect. */
export interface MemoryInEffect {
  team: string | null;
  profile: string | null;
  organisation?: { name: string } | null;
  levels: Array<EntryLevel & { version: number; entries: number }>;
  entries: InEffect[];
  plane_url?: string;
}

/** An entry as a save sends it: its topic and body, and `heading: false` for the text before the first heading. */
export type EntryDraft = { topic?: string | null; body?: string; heading?: boolean };

/**
 * The text of a document holding these entries, as the plane writes them: each as
 * `## Topic`, a blank line and its body, a blank line between two, General (no topic, or
 * `heading: false`) as its body alone; a body's blank lines at either end go, and an entry
 * with nothing in it goes. The plane's own rule (`Troupe.Protocol.Memory.Entries.render/1`),
 * line for line, so a client that must send `text` to a plane from before entries sends what
 * a newer one would have written.
 */
export function renderEntries(entries: EntryDraft[]): string {
  const blank = (line: string): boolean => line.trim() === "";
  return entries
    .map((entry) => {
      const lines = (typeof entry.body === "string" ? entry.body : "").split("\n");
      let from = 0;
      let to = lines.length;
      while (from < to && blank(lines[from]!)) from++;
      while (to > from && blank(lines[to - 1]!)) to--;
      const body = lines.slice(from, to).join("\n");
      const heading = entry.heading !== false && typeof entry.topic === "string";
      if (!heading) return body;
      const topic = (entry.topic as string).trim();
      return body === "" ? `## ${topic}` : `## ${topic}\n\n${body}`;
    })
    .filter((part) => part !== "")
    .join("\n\n");
}

/** A topic as two entries are compared by it: its words, case and spacing aside, as the plane compares them. */
export function topicKey(topic: string): string {
  return topic.trim().replace(/\s+/g, " ").toLowerCase();
}

const RANK: Record<EntryLevel["scope"], number> = { organisation: 0, team: 1, profile: 2, user: 3 };

/** The closer levels that have an entry on this one's topic, of `level`: where the badge says what replaces it. */
export function replacedBy(level: EntryLevel, entry: MemoryEntry, levels: Array<{ level: EntryLevel; entries: MemoryEntry[] }>): EntryLevel[] {
  if (entry.heading === false) return [];
  return levels
    .filter((l) => RANK[l.level.scope] > RANK[level.scope] && l.entries.some((e) => e.heading !== false && topicKey(e.topic) === topicKey(entry.topic)))
    .map((l) => l.level);
}

/** The plane's line diff as two columns: a line kept on both sides, a run of lines gone beside the run that came. */
export function besideRows(lines: MemoryLine[]): Array<{ left: string | null; right: string | null; changed: boolean }> {
  const rows: Array<{ left: string | null; right: string | null; changed: boolean }> = [];
  let gone: string[] = [];
  let came: string[] = [];
  const flush = (): void => {
    for (let i = 0; i < Math.max(gone.length, came.length); i++) rows.push({ left: gone[i] ?? null, right: came[i] ?? null, changed: true });
    gone = [];
    came = [];
  };
  for (const line of lines) {
    if (line.op === "same") {
      flush();
      rows.push({ left: line.text, right: line.text, changed: false });
    } else if (line.op === "del") {
      // A line gone after lines that came starts a run of its own: it was not their pair.
      if (came.length > 0) flush();
      gone.push(line.text);
    } else came.push(line.text);
  }
  flush();
  return rows;
}

/** A line's side column: the version and who saved it, or the agent and session of an agent's entry. */
export function writtenBy(line: MemoryBlameLine): string {
  if (line.agent) return `v${line.version} ${line.agent} in ${line.session ?? "a session"}`;
  if (line.session) return `v${line.version} an agent in ${line.session}`;
  return `v${line.version} ${line.by ?? ""}`.trim();
}
