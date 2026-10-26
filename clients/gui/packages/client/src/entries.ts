// A memory document as entries (troupe #55): each `## Topic` section of its text is one
// entry, and on a topic the closest level's entry replaces the lower ones, the organisation's
// lowest, then a team's, then the person's own. What a new session in a team starts knowing
// is the winner on each topic, with what it replaces.
//
// The plane does not yet answer entries of its own; until it does, a client reads them from
// the document's text here and saves the whole text back over the version it read, so what
// the plane keeps is still one document per level, versioned and audited as before.

import type { MemoryBlameLine, MemoryLine } from "./admin.js";

/** One entry of a level: its topic and what it says. A text before the first heading is the topic-less entry, `topic` "". */
export interface MemoryEntry {
  topic: string;
  body: string;
}

/** Where an entry is kept: the organisation's, a team's (`name`), or the person's own. */
export interface EntryLevel {
  scope: "organisation" | "team" | "user";
  name: string | null;
}

/** An entry as it is in force, from its level, with the lower levels' entries on its topic it replaces. */
export interface InEffect {
  topic: string;
  body: string;
  from: EntryLevel;
  replaces: Array<{ from: EntryLevel; body: string }>;
}

const HEADING = /^##\s+(.+?)\s*#*\s*$/;

/** The entries of a document's text, in order: one per `## Topic` section, and one for any text before the first. */
export function parseEntries(text: string): MemoryEntry[] {
  const entries: MemoryEntry[] = [];
  let topic = "";
  let body: string[] = [];
  const flush = (): void => {
    const said = body.join("\n").trim();
    if (topic !== "" || said !== "") entries.push({ topic, body: said });
  };
  for (const line of text.replace(/\r\n/g, "\n").split("\n")) {
    const heading = HEADING.exec(line);
    if (heading) {
      flush();
      topic = heading[1]!.trim();
      body = [];
    } else {
      body.push(line);
    }
  }
  flush();
  return entries;
}

/** The text of a document holding these entries, in this order, as `parseEntries` reads it back. */
export function entriesText(entries: MemoryEntry[]): string {
  return entries
    .map((e) => (e.topic === "" ? e.body : `## ${e.topic.trim()}\n\n${e.body.trim()}`.trimEnd()))
    .filter((part) => part !== "")
    .join("\n\n");
}

/** A topic as two entries are compared by it: its words, case and spacing aside. */
export function topicKey(topic: string): string {
  return topic.trim().replace(/\s+/g, " ").toLowerCase();
}

const RANK: Record<EntryLevel["scope"], number> = { organisation: 0, team: 1, user: 2 };

/**
 * What a new session starts knowing from these levels' entries, lowest level first: on each
 * topic the closest level's entry, and under it the lower levels' it replaces, closest first.
 * A topic-less entry is no topic's, so it replaces nothing and is replaced by nothing.
 */
export function inEffect(levels: Array<{ level: EntryLevel; entries: MemoryEntry[] }>): InEffect[] {
  const ordered = [...levels].sort((a, b) => RANK[a.level.scope] - RANK[b.level.scope]);
  const byTopic = new Map<string, Array<{ from: EntryLevel; entry: MemoryEntry }>>();
  const order: string[] = [];
  let loose = 0;
  for (const { level, entries } of ordered) {
    for (const entry of entries) {
      const key = entry.topic === "" ? `\u0000${loose++}` : topicKey(entry.topic);
      if (!byTopic.has(key)) {
        byTopic.set(key, []);
        order.push(key);
      }
      byTopic.get(key)!.push({ from: level, entry });
    }
  }
  return order.map((key) => {
    const stack = [...byTopic.get(key)!].reverse();
    const top = stack[0]!;
    return { topic: top.entry.topic, body: top.entry.body, from: top.from, replaces: stack.slice(1).map((s) => ({ from: s.from, body: s.entry.body })) };
  });
}

/** The closer levels' entries that replace this one, of `level`, on its topic. */
export function replacedBy(level: EntryLevel, entry: MemoryEntry, levels: Array<{ level: EntryLevel; entries: MemoryEntry[] }>): EntryLevel[] {
  if (entry.topic === "") return [];
  return levels
    .filter((l) => RANK[l.level.scope] > RANK[level.scope] && l.entries.some((e) => e.topic !== "" && topicKey(e.topic) === topicKey(entry.topic)))
    .map((l) => l.level);
}

/** Who last wrote an entry and when: of its lines, the newest by version, from a document's blame. */
export function entryWriter(entry: MemoryEntry, lines: MemoryBlameLine[] | undefined): MemoryBlameLine | null {
  if (!lines || lines.length === 0) return null;
  const said = new Set([...(entry.topic ? [`## ${entry.topic}`] : []), ...entry.body.split("\n").filter((l) => l.trim() !== "")]);
  const mine = lines.filter((l) => said.has(l.text) || (entry.topic !== "" && HEADING.exec(l.text)?.[1]?.trim() === entry.topic));
  return mine.reduce<MemoryBlameLine | null>((newest, l) => (newest === null || l.version > newest.version ? l : newest), null);
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
    if (line.op === "del") gone.push(line.text);
    else if (line.op === "add") came.push(line.text);
    else {
      flush();
      rows.push({ left: line.text, right: line.text, changed: false });
    }
  }
  flush();
  return rows;
}
