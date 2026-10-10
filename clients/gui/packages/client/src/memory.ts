// A repository's memory, as a client shows it and as a session's start keeps it up (troupe
// #248 and #516).
//
// What the daemon keeps is facts: a claim, the files it rests on with the hash each had
// when the fact was written, how it was learned (which session, at which commit, by whom),
// and a status the daemon works out whenever it is read: `current` while every file is as
// it was, `moved` or `missing` once one changed or went (both "may no longer be true": a
// changed file is a reason to look again, not proof the claim is wrong), and `unanchored`
// for a fact that rests on no file. `.troupe/memory.md` is written from them. A daemon
// from before facts answers `memory.get` with the brief's text alone, and a client shows
// that.
//
// The librarian keeps the brief up. A session this client starts in a git repository
// starts it by itself, as a branch of the session, when the brief is missing or stale, as
// the terminal client does (its Decisions 127 and 131): only when the workspace's config
// leaves `memory_auto_refresh` on, only with a model to ask, and only when the daemon
// says one is due, which it does not while a try that built nothing is waited out. When
// none starts for a reason a person would want to know, a line says why. A refresh the
// person asks for (`refreshNow`) starts one under the same conditions, less the two that
// only hold back the automatic one.

import { configKey } from "./config.js";
import type { DaemonClient } from "./daemon.js";

export type FactKind = "command" | "convention" | "overview" | "layout" | "note" | "negative";
export type FactStatus = "current" | "moved" | "missing" | "unanchored";

/** A file a fact rests on, and the hash its bytes had when the fact was written. */
export interface FactAnchor {
  path: string;
  hash: string;
}

/** How a fact was learned: in which session and call, at which commit, and by whom. */
export interface FactEvidence {
  session: string | null;
  seq: number | null;
  head: string | null;
  /** How the command a `command` fact names ended when the session ran it. */
  exit_status?: number | null;
  /** `librarian`, `agent:<name>`, `person` (an edit to `memory.md`) or `migrated` (the brief from before facts). */
  by: string;
}

/** One fact as `memory.get` lists it, with its status as the daemon read it. */
export interface MemoryFact {
  id: string;
  kind: FactKind | string;
  claim: string;
  /** The files it is about, as a glob; null for the whole repository. */
  scope: string | null;
  anchors: FactAnchor[];
  evidence: FactEvidence;
  created_at: string;
  verified_at: string;
  status: FactStatus | string;
}

/** What `memory.get` answers. */
export interface MemoryBrief {
  /** `absent`, `stale`, `fresh`, or `disabled` with memory off. */
  status: string;
  path: string;
  built_at: string | null;
  sections: string[];
  /** The brief as `.troupe/memory.md` holds it; null with none. */
  text: string | null;
  /** Whether a client that keeps the brief up by itself should start a librarian now. */
  refresh_due?: boolean;
  /** Until when a librarian's try that built nothing holds the next one off. */
  refresh_held_until?: string | null;
  /** The facts; absent from a daemon from before troupe #248. */
  facts?: MemoryFact[];
  /** `.troupe/memory.md` is written from the facts. */
  generated?: boolean;
}

/** The kinds, in the order a person reads them: what to run and how to write first. */
export const FACT_KINDS: ReadonlyArray<{ kind: FactKind; title: string }> = [
  { kind: "command", title: "Commands" },
  { kind: "convention", title: "Conventions" },
  { kind: "overview", title: "Overview" },
  { kind: "layout", title: "Layout" },
  { kind: "note", title: "Notes" },
  { kind: "negative", title: "What did not work" },
];

/** The facts grouped by kind, in `FACT_KINDS`' order, any other kind after them; no empty group. */
export function factsByKind(facts: MemoryFact[]): Array<{ kind: string; title: string; facts: MemoryFact[] }> {
  const known = FACT_KINDS.map(({ kind, title }) => ({ kind: kind as string, title, facts: facts.filter((f) => f.kind === kind) }));
  const others = [...new Set(facts.map((f) => f.kind).filter((k) => !FACT_KINDS.some((g) => g.kind === k)))].map((kind) => ({
    kind,
    title: kind,
    facts: facts.filter((f) => f.kind === kind),
  }));
  return [...known, ...others].filter((g) => g.facts.length > 0);
}

/** A fact whose file changed or went since it was written. */
export function mayNoLongerBeTrue(fact: Pick<MemoryFact, "status">): boolean {
  return fact.status === "moved" || fact.status === "missing";
}

/** What a fact's status means, in a sentence. */
export function factStatusLine(fact: Pick<MemoryFact, "status">): string {
  switch (fact.status) {
    case "current":
      return "Every file it rests on is as it was when it was written.";
    case "moved":
      return "May no longer be true: a file it rests on has changed since it was written.";
    case "missing":
      return "May no longer be true: a file it rests on is gone.";
    case "unanchored":
      return "It rests on no file, so nothing shows when it stops being true; it ages out as the brief does.";
    default:
      return fact.status;
  }
}

/** Who wrote a fact, in words. */
export function learnedBy(by: string): string {
  if (by === "librarian") return "the librarian";
  if (by === "person") return "a person, in .troupe/memory.md";
  if (by === "migrated") return "the brief from before facts";
  if (by.startsWith("agent:")) return `the ${by.slice("agent:".length)} agent`;
  return by;
}

/** What the librarian is asked when there is no brief yet; the terminal client's words. */
export const LIBRARIAN_FIRST_PROMPT = "There is no project brief yet. Survey this repository and write one.";
/** What it is asked when the brief is out of date; the terminal client's words. */
export const LIBRARIAN_PROMPT = "The project brief is out of date. Revise it against the repository as it is now.";

/** Why no librarian starts by itself here, and whether that is something to say. */
export interface LibrarianBarred {
  why: string;
  say: boolean;
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/**
 * Whether a librarian may start by itself in `workspace`, decided as the terminal client
 * decides it (`Troupe.Client.Daemon.Start`): memory and `memory_auto_refresh` on in the
 * workspace's config, a git repository (`worktree.list` names a checkout for it), and a
 * model to ask (the first run's `setup.get`: questions still needed, or a settings file
 * through which no model can be asked, is none). Null when it may. A daemon that cannot
 * say about the config or a model leaves those as they default; one that cannot say
 * whether the directory is a repository starts nothing. `asked`: a refresh the person
 * asked for (`/memory refresh`), which `memory_auto_refresh` does not hold back, and
 * whose every reason is said.
 */
export async function librarianBarred(daemon: DaemonClient, workspace: string, opts: { asked?: boolean } = {}): Promise<LibrarianBarred | null> {
  const config = await daemon.modelConfig(workspace).catch(() => null);
  if (config && configKey(config, "memory")?.value === false) return { why: "memory is off (memory: false in the workspace's config)", say: opts.asked === true };
  // A refresh the person asked for is not the automatic one the key turns off.
  if (!opts.asked && config && configKey(config, "memory_auto_refresh")?.value === false) return { why: "memory_auto_refresh is off", say: false };
  const repository = await daemon
    .worktrees(workspace)
    .then((r) => r.worktrees.length > 0)
    .catch(() => false);
  if (!repository) return { why: "this is not a git repository, which is what a brief describes", say: opts.asked === true };
  const setup = await daemon.setup().catch(() => null);
  if (setup && (setup.needed || (setup.detected?.config?.exists && !setup.detected.config.usable))) {
    return { why: "no model can be asked with this computer's settings; This computer > Models sets one up", say: true };
  }
  return null;
}

/** What `memory.get` says about starting one: start it, with which words, or why not. */
export type RefreshStep = { start: string; status: "absent" | "stale" } | { start?: undefined; why: string; say: boolean };

/**
 * Whether the daemon says a librarian is due now (`refresh_due`, the terminal client's
 * Decision 127): on a missing or stale brief, unless a try that built nothing is waited
 * out, which is said with its day. A daemon from before the field leaves it to the status.
 */
export async function refreshStep(daemon: DaemonClient, workspace: string): Promise<RefreshStep> {
  let brief: MemoryBrief;
  try {
    brief = await daemon.memory(workspace);
  } catch (e) {
    return { why: `the daemon did not say whether one is due: ${message(e)}`, say: true };
  }
  const due = brief.status === "absent" || brief.status === "stale";
  if (brief.refresh_due === false) {
    if (!due) return { why: `the brief is ${brief.status}`, say: false };
    const until = brief.refresh_held_until ? `until ${brief.refresh_held_until.slice(0, 10)}` : "a while";
    return { why: `the last one built none, so the next waits ${until}; the terminal client's /memory refresh starts one now`, say: true };
  }
  if (brief.status === "absent") return { start: LIBRARIAN_FIRST_PROMPT, status: "absent" };
  if (brief.status === "stale") return { start: LIBRARIAN_PROMPT, status: "stale" };
  return { why: `the brief is ${brief.status}`, say: false };
}

/** What a refresh the person asked for came to: the librarian's session, and the line that says so or why not. */
export interface Refreshed {
  librarian: string | null;
  said: string;
}

/**
 * A refresh the person asked for (`/memory refresh` in the terminal client): the librarian
 * as a branch of `parent`, in the checkout, writing the brief where there is none and
 * rewriting it otherwise. Under the start's conditions, less `memory_auto_refresh` and a
 * try being waited out, which hold back only the refresh nobody asked for (Decision 127).
 */
export async function refreshNow(daemon: DaemonClient, workspace: string, parent: string): Promise<Refreshed> {
  const barred = await librarianBarred(daemon, workspace, { asked: true });
  if (barred) return { librarian: null, said: `No librarian for the project brief: ${barred.why}.` };
  let status: string;
  try {
    status = (await daemon.memory(workspace)).status;
  } catch (e) {
    return { librarian: null, said: `No librarian for the project brief: the daemon did not say where the brief stands: ${message(e)}.` };
  }
  if (status === "disabled") return { librarian: null, said: "No librarian for the project brief: memory is off (memory: false in the workspace's config)." };
  try {
    const prompt = status === "absent" ? LIBRARIAN_FIRST_PROMPT : LIBRARIAN_PROMPT;
    const created = await daemon.startLibrarian({ workspace, parent, prompt });
    return {
      librarian: created.session_id,
      said: `The librarian is ${status === "absent" ? "writing" : "rewriting"} the project brief, in a session of its own.`,
    };
  } catch (e) {
    return { librarian: null, said: `No librarian for the project brief: the daemon did not start it: ${message(e)}.` };
  }
}

/** Whether an event ends the librarian's work: its root agent finished, or its turn ended and it rests. */
export function librarianDone(e: { type: string; agent?: string[] }): boolean {
  return (e.type === "agent_done" || e.type === "turn_ended") && (e.agent?.length ?? 1) <= 1;
}
