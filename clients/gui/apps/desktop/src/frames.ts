// Frames for rendered output (issue #474), as data: what docs/design/frames.md says a
// transcript is, worked out here so the session screen only draws it. A turn shows its
// answer, not its working. The page is the spec; the terminal client builds the same from
// it (TUI Decision 161), and where the two differ the decision behind this file says why
// (Decision 877).
//
// Nothing here reads the theme or the page: the turns, what each entry is to its turn,
// the strip, every header's grammar and the curtain line's written set are functions of
// the transcript, the level and the time.

import { bytes, counted, firstLine, isBlobRef, isBusy, isRoot, needsYou, pickLine, rootState, toolGlyph as glyph, toolOutcome as outcome, toolTarget as target } from "@troupe/client";
import type { BlobRef, CurtainPhase, Entry, LineKind, TranscriptState } from "@troupe/client";

// A call's glyph, target and outcome are the client's, so the console's tool lines say the same.
export { bytes, counted, glyph, outcome, target };

/** How much of a turn is open (`transcript.detail`): the answer alone, its calls too, or nothing collapsed. */
export type Detail = "quiet" | "tools" | "everything";

export const DETAILS: readonly Detail[] = ["quiet", "tools", "everything"];
export const DEFAULT_DETAIL: Detail = "quiet";

export function isDetail(v: unknown): v is Detail {
  return typeof v === "string" && (DETAILS as readonly string[]).includes(v);
}

/** A frame's body past this many lines shows its first `FRAME_KEEP` and a line saying the rest. */
export const FRAME_CAP = 24;
export const FRAME_KEEP = 20;

/** A duration as a header says it: `14s` under a minute, `4m 2s` from one. */
export function seconds(ms: number): string {
  const s = Math.floor(Math.max(ms, 0) / 1000);
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`;
}

/** A duration from a second up; under one it says nothing a person reads for. */
export function took(ms: number | undefined): string | null {
  return ms !== undefined && ms >= 1000 ? seconds(ms) : null;
}

/** What is left of a cut body, said: `… 42 more lines`. */
export function moreLines(n: number, what: [string, string] = ["line", "lines"]): string {
  return `… ${n} more ${n === 1 ? what[0] : what[1]}`;
}

/** How much of `lines` a body shows at `full` or not: all of it, or the first `FRAME_KEEP` past `FRAME_CAP`. */
export function cut<T>(lines: T[], full: boolean): { shown: T[]; more: number } {
  if (full || lines.length <= FRAME_CAP) return { shown: lines, more: 0 };
  return { shown: lines.slice(0, FRAME_KEEP), more: lines.length - FRAME_KEEP };
}

// -- turns ------------------------------------------------------------------------------

/** A turn: entries `start` to `end` (exclusive), keyed by the first, so a click on its strip outlives a redraw. */
export interface Turn {
  key: string;
  start: number;
  end: number;
}

const opensTurn = (e: Entry): boolean => isRoot(e.agent) && (e.kind === "user" || (e.kind === "system" && e.type === "loop_iteration_started"));
const closesTurn = (e: Entry): boolean => isRoot(e.agent) && e.kind === "turn";

/**
 * The transcript as turns: one starts at a person's line or a loop's iteration and ends at
 * the line that says what it cost. What came before the first is a turn of its own.
 */
export function turns(entries: Entry[]): Turn[] {
  const out: Turn[] = [];
  let start = 0;
  let closed = false;
  entries.forEach((e, i) => {
    if (i > start && (closed || opensTurn(e))) {
      out.push({ key: keyOf(entries[start]!), start, end: i });
      start = i;
    }
    closed = closesTurn(e);
  });
  if (entries.length > start) out.push({ key: keyOf(entries[start]!), start, end: entries.length });
  return out;
}

const keyOf = (e: Entry): string => `${e.kind}-${e.seq}`;

/**
 * What an entry is to its turn: the answer (the root's prose after its last call), its
 * working (reasoning, the prose between calls, a call, and a subagent's words, which the
 * call that delegated stands for), a call that failed, or none of these (a person's line,
 * a note, a card, a decision, what a turn cost).
 */
export type Role = "answer" | "narration" | "reasoning" | "step" | "failed" | "other";

function roleOf(e: Entry, i: number, lastCall: number): Role {
  switch (e.kind) {
    case "assistant":
      if (!isRoot(e.agent)) return "narration";
      return i > lastCall ? "answer" : "narration";
    case "reasoning":
      return "reasoning";
    case "tool":
      return e.ok === false ? "failed" : "step";
    case "brief":
      return "narration";
    case "user":
      return isRoot(e.agent) ? "other" : "narration";
    default:
      return "other";
  }
}

/** A turn's working, as one line where it began: `▸ 7 steps · 1 failed · grep, read_file · 14s`. */
export interface Strip {
  turn: string;
  /** Whether the steps it stands for are drawn open under it. */
  open: boolean;
  steps: number;
  failed: number;
  /** The tools used, in the order first used, four at most. */
  tools: string[];
  /** How many more tools than `tools` names. */
  more: number;
  /** From the first call's start to the last one's end, or to now while one runs. */
  ms: number | undefined;
}

/** The strip in words, its glyph first, as the design page writes it. */
export function stripParts(s: Strip): { glyph: string; steps: string; failed: string | null; tools: string; took: string | null } {
  return {
    glyph: s.open ? "▾" : "▸",
    steps: counted(s.steps, "step"),
    failed: s.failed > 0 ? `${s.failed} failed` : null,
    tools: s.tools.join(", ") + (s.more > 0 ? ` and ${s.more} more` : ""),
    took: took(s.ms),
  };
}

/** One entry as the screen draws it. */
export interface Drawn {
  entry: Entry;
  role: Role;
  /** The level it is drawn at: its turn's, or `everything` from a budget stop on. */
  level: Detail;
  /** Folded into its turn's strip, and not drawn. */
  hidden: boolean;
  /** The strip, drawn above this entry. */
  strip: Strip | null;
  /** The turn it is in, by key. */
  turn: string;
}

/** The other way from a level, for a turn a click opened: everything, or quiet from everything. */
export function flip(level: Detail): Detail {
  return level === "everything" ? "quiet" : "everything";
}

/**
 * Every entry with how it is drawn at `detail`, the turns in `opened` the other way (a
 * click on the strip). From the first budget stop on, nothing is collapsed: what happened
 * after the money ran out is all on screen.
 */
export function layout(entries: Entry[], opts: { detail: Detail; opened: ReadonlySet<string>; now: number }): Drawn[] {
  const stop = entries.findIndex((e) => (e.kind === "system" && e.type === "budget_exhausted") || (e.kind === "question" && e.asked === "budget"));
  const openFrom = stop < 0 ? Infinity : stop;

  const drawn = turns(entries).flatMap((t) => {
    const level = opts.opened.has(t.key) ? flip(opts.detail) : opts.detail;
    const at = (i: number): Detail => (i >= openFrom ? "everything" : level);
    const indices = Array.from({ length: t.end - t.start }, (_, k) => t.start + k);

    let lastCall = -1;
    for (const i of indices) {
      const e = entries[i]!;
      if (e.kind === "tool" && isRoot(e.agent) && e.name !== "finish") lastCall = i;
    }
    const roles = indices.map((i) => roleOf(entries[i]!, i, lastCall));

    // The calls it stands for: every call of the turn drawn at its level, `finish` aside,
    // which says itself in the line under it.
    const steps = indices.filter((i) => {
      const e = entries[i]!;
      return e.kind === "tool" && e.name !== "finish" && at(i) === level;
    });
    const strip = steps.length > 0 ? stripOf(t.key, steps.map((i) => entries[i] as ToolEntry), level, opts.now) : null;
    const stripAt = strip ? indices.find((i, k) => at(i) === level && roles[k] !== "other" && roles[k] !== "answer") : undefined;

    return indices.map((i, k): Drawn => {
      const role = roles[k]!;
      const drawnAt = at(i);
      // Quiet folds the working into the strip; a call that worked is shut at quiet even
      // with no strip to stand for it (a `finish` alone), and one that failed never is.
      const hidden = drawnAt === "quiet" && (role === "step" || (strip !== null && (role === "reasoning" || role === "narration")));
      return { entry: entries[i]!, role, level: drawnAt, hidden, strip: i === stripAt ? strip : null, turn: t.key };
    });
  });

  // A run of sleeping and waking notes is its latest line below everything: each wake of a
  // pod session writes four, and only the last says where the session stands.
  return drawn.map((d, i) => (d.level !== "everything" && isLifecycle(d.entry) && isLifecycle(drawn[i + 1]?.entry) ? { ...d, hidden: true } : d));
}

/** The notes a session's sleeping, waking and replaying write, which a run of folds to its latest. */
export const LIFECYCLE_NOTES: ReadonlySet<string> = new Set(["session_dormant", "session_activated", "session_resumed", "agent_restarted"]);

const isLifecycle = (e: Entry | undefined): boolean => e?.kind === "system" && LIFECYCLE_NOTES.has(e.type);

type ToolEntry = Extract<Entry, { kind: "tool" }>;

function stripOf(turn: string, steps: ToolEntry[], level: Detail, now: number): Strip {
  const names = [...new Set(steps.map((s) => s.name))];
  const starts = steps.map((s) => s.startedAt).filter((t): t is number => t !== undefined);
  const ends = steps.map((s) => s.endedAt ?? (s.ok === undefined ? now : undefined)).filter((t): t is number => t !== undefined);
  return {
    turn,
    open: level !== "quiet",
    steps: steps.length,
    failed: steps.filter((s) => s.ok === false).length,
    tools: names.slice(0, 4),
    more: Math.max(names.length - 4, 0),
    ms: starts.length > 0 && ends.length > 0 ? Math.max(...ends) - Math.min(...starts) : undefined,
  };
}

// -- a call's header ----------------------------------------------------------------------

const nonEmpty = (text: string): string[] => text.split("\n").filter((l) => l.trim() !== "");

/** A call's header in its parts: `✓ read_file lib/p.ex · 120 lines · 2s`. */
export function toolHead(entry: ToolEntry): { glyph: string; name: string; target: string; notes: string[] } {
  const span = entry.startedAt !== undefined && entry.endedAt !== undefined ? entry.endedAt - entry.startedAt : undefined;
  return {
    glyph: glyph(entry.ok),
    name: entry.name,
    target: target(entry.name, entry.args),
    notes: [outcome(entry), took(span)].filter((n): n is string => n !== null),
  };
}

/**
 * Whether a call's result says no more than its header already does. A failed call's
 * error is in its body as well as its header, whatever it says.
 */
export function saidInHead(entry: ToolEntry): boolean {
  const content = entry.content;
  if (content === undefined || isBlobRef(content) || entry.ok === false) return false;
  const kept = nonEmpty(content);
  return kept.length === 0 || (kept.length === 1 && kept[0]!.trim() === outcome(entry));
}

/**
 * `read_file`'s numbered lines as source: each line's number and its code, and the lines
 * around them (the range it read, a note that it was cut) as they are; null when the
 * result is not numbered source.
 */
export function numberedSource(content: string): { head: string[]; lines: Array<[string, string]>; tail: string[] } | null {
  const all = content.replace(/\s+$/, "").split("\n");
  const head = all[0]?.startsWith("(lines ") ? [all[0]] : [];
  const rest = all.slice(head.length);
  const lines: Array<[string, string]> = [];
  for (const line of rest) {
    const m = /^(\d+)\t(.*)$/.exec(line) ?? /^(\d+)$/.exec(line);
    if (!m) break;
    lines.push([m[1]!, m[2] ?? ""]);
  }
  const tail = rest.slice(lines.length).filter((l) => l !== "");
  if (lines.length === 0 || tail.some((l) => !l.startsWith("[truncated:"))) return null;
  return { head, lines, tail };
}

export type { BlobRef };

// -- fenced blocks ------------------------------------------------------------------------

/** What a fence holds, by its info string's first word, with a second word that looks like a path as its path. */
export interface Fence {
  kind: "code" | "diff" | "data" | "mermaid";
  /** The fence's first word, or `code` with none. */
  label: string;
  path: string | null;
}

export function fenceOf(info: string | undefined): Fence {
  const [first = "", ...more] = (info ?? "").trim().split(/\s+/);
  const path = more.find((w) => /[/.]/.test(w)) ?? null;
  const word = first.toLowerCase();
  if (word === "diff" || word === "patch") return { kind: "diff", label: "diff", path };
  if (word === "csv" || word === "tsv" || word === "json") return { kind: "data", label: word, path };
  if (word === "mermaid") return { kind: "mermaid", label: "mermaid", path };
  return { kind: "code", label: first || "code", path };
}

/** A diff's lines, each with what it is, and its path and `+n −m` (the minus U+2212). */
export function diffOf(text: string, path: string | null): { note: string; lines: Array<{ kind: "add" | "del" | "hunk" | "ctx"; text: string }> } {
  const lines = text.split("\n");
  const to = path ?? lines.find((l) => l.startsWith("+++ "))?.slice(4).trim().replace(/^b\//, "") ?? null;
  const added = lines.filter((l) => l.startsWith("+") && !l.startsWith("+++")).length;
  const removed = lines.filter((l) => l.startsWith("-") && !l.startsWith("---")).length;
  return {
    note: `${to ? ` · ${to}` : ""} +${added} −${removed}`,
    lines: lines.map((l) => ({
      kind: l.startsWith("@@") || l.startsWith("+++") || l.startsWith("---") ? "hunk" : l.startsWith("+") ? "add" : l.startsWith("-") ? "del" : "ctx",
      text: l,
    })),
  };
}

/** A table a data fence parses as: its columns and rows, or null for the source as written. */
export function dataOf(label: string, text: string): { columns: string[]; rows: string[][] } | null {
  if (label === "json") return jsonTable(text);
  const sep = label === "tsv" ? "\t" : ",";
  const rows = text
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => cells(l, sep));
  const [head, ...rest] = rows;
  if (!head || rest.length === 0 || rest.some((r) => r.length !== head.length)) return null;
  return { columns: head, rows: rest };
}

// A comma- or tab-separated line's cells, with a quoted cell's separators and doubled quotes kept.
function cells(line: string, sep: string): string[] {
  const out: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i]!;
    if (c === '"' && quoted && line[i + 1] === '"') {
      cell += '"';
      i++;
    } else if (c === '"') quoted = !quoted;
    else if (c === sep && !quoted) {
      out.push(cell.trim());
      cell = "";
    } else cell += c;
  }
  out.push(cell.trim());
  return out;
}

// An array of flat objects is a table, its columns the keys in the order they first appear.
function jsonTable(text: string): { columns: string[]; rows: string[][] } | null {
  let items: unknown;
  try {
    items = JSON.parse(text);
  } catch {
    return null;
  }
  if (!Array.isArray(items) || items.length === 0) return null;
  const flat = (v: unknown): v is Record<string, unknown> =>
    typeof v === "object" && v !== null && !Array.isArray(v) && Object.values(v).every((x) => typeof x !== "object" || x === null);
  if (!items.every(flat)) return null;
  const columns = [...new Set(items.flatMap((o) => Object.keys(o)))];
  return { columns, rows: items.map((o) => columns.map((c) => (o[c] === undefined || o[c] === null ? "" : String(o[c])))) };
}

// -- the curtain line ---------------------------------------------------------------------

/**
 * The curtain line's words are docs/design/lines.json's (docs/design/frames.md §7), by what
 * they are said over, taken in an order shuffled from the turn's seed: the n-th time the
 * agent does that in a turn takes the n-th line taken; past the end of a list the line is
 * its facts alone. Theatre, dry, never sorry and never a person. A turn past five minutes
 * says it is a long one in place of the phase's line.
 */
export const LONG_TURN_MS = 300_000;

/** The calls that only read, which have their own list. */
export const READS: ReadonlySet<string> = new Set(["read_file", "grep", "glob", "list_files", "git_read", "read_branch", "read_output", "recall", "web_fetch"]);

/** The seed a turn's lines are taken in the order of: the session's id, else a counter, and the turn's number. */
export function curtainSeed(state: TranscriptState, session = ""): string {
  return `${session}/${state.curtain.turn}`;
}

/** The line while a turn works: the flourish, or none, then the facts, which are always there. */
export interface CurtainLine {
  /** It waits on a person: the facts alone, in the reserved colour. */
  waiting: boolean;
  flourish: string | null;
  facts: string;
}

/**
 * The divider over a session's first event: "CURTAIN UP", and the local time the session
 * began beside it where the event carries one ("CURTAIN UP · 18:54"), with the day in
 * front when it was not today, as the list says a time.
 */
export function curtainUp(startedAt: number | undefined, now: Date = new Date()): string {
  if (startedAt === undefined) return "CURTAIN UP";
  const at = new Date(startedAt);
  if (Number.isNaN(at.getTime())) return "CURTAIN UP";
  const time = `${String(at.getHours()).padStart(2, "0")}:${String(at.getMinutes()).padStart(2, "0")}`;
  const today = at.toDateString() === now.toDateString();
  return `CURTAIN UP · ${today ? time : `${at.toLocaleDateString(undefined, { day: "numeric", month: "short" })} ${time}`}`;
}

/** `mm:ss`, as the terminal client says how long something has gone on. */
export function clock(ms: number): string {
  const s = Math.floor(Math.max(ms, 0) / 1000);
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

/** What the session's own agent is waited on, and for how long: the daemon's model request, or its first byte. */
export interface Waiting {
  on: "request" | "answer";
  ms: number;
}

/**
 * The daemon's model request, while a prompt has drawn none and the agent does nothing
 * else; the request's first byte, while it thinks and nothing has come back; null when
 * nothing is waited on this way — at rest, waiting on a person, an answer under way.
 */
export function waitingOn(state: TranscriptState, now: number): Waiting | null {
  if (needsYou(state)) return null;
  const c = state.curtain;
  if (c.sentAt !== undefined && (c.requestAt === undefined || c.requestAt < c.sentAt) && !isBusy(state)) {
    return { on: "request", ms: Math.max(now - c.sentAt, 0) };
  }
  if (c.requestAt !== undefined && (c.byteAt === undefined || c.byteAt < c.requestAt) && rootState(state) === "thinking" && !state.streaming && !state.thinking) {
    return { on: "answer", ms: Math.max(now - c.requestAt, 0) };
  }
  return null;
}

/**
 * The words for a wait that has become news, in the composer's hint: the daemon's request
 * not sent 10 s after the prompt, nothing back 20 s after the request. Null before that,
 * and whenever nothing is waited on.
 */
export function waitingWords(state: TranscriptState, now: number): string | null {
  const w = waitingOn(state, now);
  if (w === null) return null;
  if (w.on === "request") return w.ms >= 10_000 ? `the daemon has not sent the model request yet (${clock(w.ms)})` : null;
  return w.ms >= 20_000 ? `waiting on the model (${clock(w.ms)}), nothing back yet` : null;
}

/**
 * What the session's own agent is doing, for the line under the transcript; null while it
 * rests. What runs, how many and for how long are always said; a few words from the set
 * go before them, chosen by how many times this turn it has done what it does now.
 */
export function curtainLine(state: TranscriptState, now: number, seed = ""): CurtainLine | null {
  if (needsYou(state)) return { waiting: true, flourish: null, facts: "waiting for you" };
  if (!isBusy(state)) return null;

  const doing = rootState(state);
  const running = state.entries
    .filter((e): e is ToolEntry => e.kind === "tool" && isRoot(e.agent) && e.ok === undefined)
    .map((e) => `${e.name} ${target(e.name, e.args).slice(0, 24)}`.trim());
  const since = `(${clock(now - (state.curtain.since ?? now))})`;
  const facts =
    doing === "thinking"
      ? `thinking ${since}`
      : doing === "compacting"
        ? `compacting context ${since}`
        : doing === "acting" && running.length > 0
          ? `running ${running.length === 1 ? running[0] : `${running.length} tools: ${running.join(", ")}`} ${since}`
          : doing === "acting"
            ? `working ${since}`
            : `${doing} ${since}`;

  const n = state.curtain.phases[doing as CurtainPhase] ?? 1;
  const names = running.map((r) => r.split(" ")[0]!);
  const kind: LineKind | null =
    doing === "thinking"
      ? "thinking"
      : doing === "compacting"
        ? "compacting"
        : doing === "acting"
          ? names.length > 0 && names.every((name) => READS.has(name))
            ? "reading"
            : "acting"
          : null;
  const turnSeed = curtainSeed(state, seed);
  const long = state.curtain.turnAt !== undefined && now - state.curtain.turnAt >= LONG_TURN_MS && kind !== null;
  return { waiting: false, flourish: long ? firstLine("long_turn", turnSeed) : kind ? pickLine(kind, turnSeed, n) : null, facts };
}
