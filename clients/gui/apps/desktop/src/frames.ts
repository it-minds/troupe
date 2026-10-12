// Frames for rendered output (issue #474), as data: what docs/design/frames.md says a
// transcript is, worked out here so the session screen only draws it. A turn shows its
// answer, not its working. The page is the spec; the terminal client builds the same from
// it (TUI Decision 161), and where the two differ the decision behind this file says why
// (Decision 877).
//
// Nothing here reads the theme or the page: the turns, what each entry is to its turn,
// the strip, every header's grammar and the curtain line's written set are functions of
// the transcript, the level and the time.

import { isBlobRef, isBusy, isRoot, needsYou, rootState } from "@troupe/client";
import type { BlobRef, CurtainPhase, Entry, TranscriptState } from "@troupe/client";

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

/** A count in words: `1 row`, `2 rows`. */
export function counted(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
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

  return turns(entries).flatMap((t) => {
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
}

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

/** `✓` done, `✗` failed, `⋯` running. */
export function glyph(ok: boolean | undefined): string {
  return ok === undefined ? "⋯" : ok ? "✓" : "✗";
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
const oneLine = (s: string): string => s.replace(/\s+/g, " ").trim();

/** What a call is about, in a few words: the path, the command, the URL, the agent delegated to. */
export function target(name: string, args: unknown): string {
  const a = (typeof args === "object" && args !== null && !isBlobRef(args) ? args : {}) as Record<string, unknown>;
  const said = ((): string | undefined => {
    switch (name) {
      case "shell":
        return str(a["command"]);
      case "web_fetch":
        return str(a["url"]);
      case "todo_write":
        return Array.isArray(a["items"]) ? counted(a["items"].length, "item") : undefined;
      case "delegate":
        return str(a["agent"]) && (a["wait"] === false ? `${str(a["agent"])}, in the background` : str(a["agent"]));
      case "stop_child":
        return str(a["child"]);
      case "finish":
        return str(a["summary"])?.slice(0, 60);
      case "ask_user":
        return str(a["question"]);
      default:
        return undefined;
    }
  })();
  if (said) return oneLine(said);
  for (const key of ["path", "file", "pattern", "query", "url", "agent", "child"]) {
    const v = str(a[key]);
    if (v) return oneLine(v);
  }
  return Object.keys(a).length > 0 ? JSON.stringify(a).slice(0, 60) : "";
}

const nonEmpty = (text: string): string[] => text.split("\n").filter((l) => l.trim() !== "");

/**
 * What came back, in a few words: the first line of an error with how many it has, the
 * only line of a short result, or how many lines; nothing for a `finish`, which says
 * itself in the line under it.
 */
export function outcome(entry: ToolEntry): string | null {
  const content = entry.content;
  if (content === undefined) return null;
  if (isBlobRef(content)) return bytes(content.size);
  const lines = content.replace(/\s+$/, "").split("\n");
  if (entry.ok === false) {
    const first = lines.map((l) => l.trim()).find((l) => l !== "") ?? "";
    return first.slice(0, 80) + (lines.length > 1 ? ` (${lines.length} lines)` : "");
  }
  if (entry.name === "finish") return null;
  const kept = nonEmpty(content);
  if (kept.length === 0) return null;
  if (kept.length === 1 && kept[0]!.length <= 60) return kept[0]!.trim();
  return counted(kept.length, "line");
}

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

export function bytes(n: number): string {
  if (n < 1024) return `${n} bytes`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

export type { BlobRef };

// -- fenced blocks ------------------------------------------------------------------------

/** What a fence holds, by its info string's first word, with a second word that looks like a path as its path. */
export interface Fence {
  kind: "code" | "diff" | "data";
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
 * The curtain line's written set (docs/design/frames.md §7), by what it is said over. The
 * n-th time the agent does that in a turn takes the n-th line; past the end of a list the
 * line is its facts alone. Theatre, dry, never sorry and never a person.
 */
export const CURTAIN = {
  starting: ["the house lights go down"],
  thinking: ["the actors are powdering their nose", "running lines in the wings", "the prompter finds the page"],
  acting: ["fetching props", "shifting the scenery", "the stagehands are at it"],
  reading: ["reading the script", "checking the prompt book", "rereading the second act"],
  compacting: ["cutting the second act", "trimming for time"],
} as const;

/** The calls that only read, which have their own list. */
export const READS: ReadonlySet<string> = new Set(["read_file", "grep", "glob", "list_files", "git_read", "read_branch", "read_output", "recall", "web_fetch"]);

/** The line while a turn works: the flourish, or none, then the facts, which are always there. */
export interface CurtainLine {
  /** It waits on a person: the facts alone, in the reserved colour. */
  waiting: boolean;
  flourish: string | null;
  facts: string;
}

/** `mm:ss`, as the terminal client says how long something has gone on. */
export function clock(ms: number): string {
  const s = Math.floor(Math.max(ms, 0) / 1000);
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

/**
 * What the session's own agent is doing, for the line under the transcript; null while it
 * rests. What runs, how many and for how long are always said; a few words from the set
 * go before them, chosen by how many times this turn it has done what it does now.
 */
export function curtainLine(state: TranscriptState, now: number): CurtainLine | null {
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
  const list: readonly string[] | null =
    doing === "thinking"
      ? CURTAIN.thinking
      : doing === "compacting"
        ? CURTAIN.compacting
        : doing === "acting"
          ? names.length > 0 && names.every((name) => READS.has(name))
            ? CURTAIN.reading
            : CURTAIN.acting
          : null;
  return { waiting: false, flourish: list?.[n - 1] ?? null, facts };
}
