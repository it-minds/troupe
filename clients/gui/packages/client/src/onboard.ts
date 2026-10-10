// Onboarding, then the librarian, at a session's start (troupe #516, Decision 835).
//
// Other tools' files are not read at run time any more: they are onboarded once into
// Troupe's own (`.troupe/`, `AGENTS.md`), through one writer in the daemon (Decision 823),
// and the project brief is the librarian's. A session's start says what is due with
// `onboarding_suggested`, and this is the one place the desktop app turns that into
// questions: it asks the daemon for the plan (`onboard.plan`), asks the person, and hands
// the answers back (`onboard.apply`, `onboard.decline`, `memory.decline`). The plan, the
// writing, the versions and what a "no" is remembered for are the daemon's; the terminal
// client asks the same questions over the same methods, so a workspace answered in one is
// answered in the other.
//
// The order is the maintainer's: onboarding first, then the brief, so a librarian started
// here reads the `AGENTS.md` onboarding wrote. One question for the lot ("Onboard 5 files
// from Claude Code and Cursor into Troupe's own?"), with each file's diff a click away;
// creating an `AGENTS.md` that is not there is always its own question (Decision 827),
// because every coding tool reads that file, not only Troupe.
//
// Then the brief, as the terminal client has it (its Decisions 127, 131 and 154): where
// `memory_auto_refresh` is on, in a git repository, with a model to ask (`memory.ts`), a
// brief an older survey wrote is asked about, and a session this client has just started
// starts the librarian by itself on a missing or stale one when the daemon says it is due,
// saying so in a line. A session opened again starts none: only its start does.

import { TroupeRpcError } from "./connection.js";
import type { DaemonClient } from "./daemon.js";
import { LIBRARIAN_PROMPT, librarianBarred, refreshStep } from "./memory.js";

export { LIBRARIAN_PROMPT };

/** Why onboarding is due: nothing onboarded yet, or onboarded under older rules. */
export type OnboardingDue = "first" | "outdated" | "none";
/** Why the brief is due: none yet, stale (Decisions 696, 127), or written by an older survey. */
export type BriefDue = "first" | "stale" | "outdated" | "none";

/** One file onboarding would write, as `onboard.plan` lists it. */
export interface OnboardItem {
  id: string;
  /** `repo` (the workspace's `.troupe/`), `workspace` (an `AGENTS.md`) or `user` (the config directory). */
  target: string;
  path: string;
  /** The file as a person reads it: `AGENTS.md`, `.troupe/rules/style.md`. */
  shown: string;
  status: "new" | "changed";
  /** `create_agents_md` for an `AGENTS.md` that is not there: asked on its own, never written by `all`. */
  question: "write" | "create_agents_md";
  /** The other tool's file it is made from. */
  source: string;
  /** The other files it is made from too: `.claude/settings.json` beside an agent's file. */
  also_from?: string[];
  /** Where the file there now was onboarded from, when onboarding wrote it; null otherwise. */
  was?: string | null;
  /** One sentence per key left out or changed. */
  notes: string[];
  /** A line diff against what the file holds: `+ `, `- `, `  `; all `+` for a new file. */
  diff: string;
}

/** A file of another tool's the sources found and proposed nothing for, and why. */
export interface OnboardSkipped {
  source: string;
  reason: string;
}

/** What `onboard.plan` answers. */
export interface OnboardPlan {
  onboarding: {
    due: OnboardingDue;
    /** The version of the onboarding rules the workspace was onboarded under, or null. */
    recorded: number | null;
    version: number;
    /** The other tools whose files are here, by name: `Claude Code`, `Cursor`. */
    tools: string[];
    items: OnboardItem[];
    skipped: OnboardSkipped[];
  };
  brief: { due: BriefDue; recorded: number | null; version: number };
  /** The sentence onboarding answers with where it may not run (a pod), or null. */
  refusal: string | null;
}

/** What `onboard.apply` answers. */
export interface OnboardApplied {
  written: Array<{ id: string; shown: string; action: string }>;
  refused: Array<{ id: string; reason: string }>;
}

/** One question the start asks, with the words it is asked in. */
export type StartQuestion =
  | {
      kind: "onboard";
      due: "first" | "outdated";
      text: string;
      /** What else the question says: what onboarding is, or what changed. */
      detail: string;
      items: OnboardItem[];
      skipped: OnboardSkipped[];
    }
  | { kind: "review"; text: string; item: OnboardItem; index: number; total: number }
  | { kind: "create"; text: string; item: OnboardItem }
  | { kind: "brief"; text: string; detail: string };

/** How a question is answered. */
export type StartAnswer =
  | "onboard" // write them all (the one question's yes, or the re-run)
  | "review" // each file's diff, one at a time
  | "decline" // not now: remembered for this version
  | "write" // this file
  | "skip" // not this file
  | "create" // the new AGENTS.md
  | "rerun"; // the brief: start the librarian

/** Where the start's questions stand, for a screen to draw. */
export interface StartState {
  /** The question waiting for the person, or null. */
  asking: StartQuestion | null;
  /** Between an answer and what follows it. */
  busy: boolean;
  /** What happened, a sentence each, in order. */
  said: string[];
  /** Where onboarding may not run (a pod): the daemon's sentence, and nothing is asked. */
  refusal: string | null;
  error: string | null;
}

export interface StartOptions {
  /** The workspace the session started in, as the event names it. */
  workspace: string;
  /** The session that started: the librarian is started as a branch of it. */
  sessionId: string;
  onState?: (state: StartState) => void;
  /**
   * This client has just started the session (`session.create`), rather than opened one
   * that was there: the librarian starts by itself on a missing or stale brief, once.
   */
  started?: boolean;
}

/** The lines a session's start says about the librarian it started. */
export const LIBRARIAN_WRITING = "The librarian is writing the project brief, in a session of its own.";
export const LIBRARIAN_REWRITING = "The librarian is rewriting the project brief, in a session of its own.";

const METHOD_NOT_FOUND = -32601;

/** `a`, `a and b`, `a, b and c`. */
function listed(names: string[]): string {
  return names.length <= 1 ? (names[0] ?? "") : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

function files(n: number): string {
  return n === 1 ? "1 file" : `${n} files`;
}

/** The one question: "Onboard 5 files from Claude Code and Cursor into Troupe's own?" */
export function onboardQuestion(plan: OnboardPlan["onboarding"]): string {
  if (plan.due === "outdated") {
    const was = plan.recorded === null ? "an older version" : `v${plan.recorded}`;
    return `Onboarding rules changed since this repository was onboarded (${was} to v${plan.version}). Re-run now?`;
  }
  const from = plan.tools.length > 0 ? listed(plan.tools) : "other tools";
  return `Onboard ${files(plan.items.length)} from ${from} into Troupe's own?`;
}

/** The brief's question, when an older survey wrote it. */
export function briefQuestion(brief: OnboardPlan["brief"]): string {
  const was = brief.recorded === null ? "an older version" : `v${brief.recorded}`;
  return `The librarian's survey changed (${was} to v${brief.version}): rewrite the brief now?`;
}

/**
 * What a file is to what is there, and what it is made from, in `troupe onboard`'s words
 * (`Troupe.CLI.Onboard.describe/1`): "adds to the one that is there, from web/CLAUDE.md".
 */
export function describeItem(item: OnboardItem): string {
  const status =
    item.question === "create_agents_md"
      ? "new, and not there yet"
      : item.status === "new"
        ? "new"
        : !item.was
          ? item.target === "workspace"
            ? "adds to the one that is there"
            : "replaces a file onboarding did not write"
          : "its source has changed";
  const also = item.also_from && item.also_from.length > 0 ? ` with ${item.also_from.join(", ")}` : "";
  const was = item.was && item.was !== item.source ? `, was from ${item.was}` : "";
  return `${status}, from ${item.source}${also}${was}`;
}

/** A new `AGENTS.md`, asked in Decision 827's words. */
export function createQuestion(item: OnboardItem): string {
  return `${item.shown} is not there. Create it? Every coding tool reads AGENTS.md, not only Troupe.`;
}

/**
 * The start's questions for one session: `start` once the session is started here or its
 * `onboarding_suggested` arrives, then `answer` each question the state asks. The plan is
 * asked for once: every later question (a new `AGENTS.md` after Onboard, each file under
 * Review) is about the first plan's items, by id, since after the first write the daemon's
 * plan says nothing is due and lists nothing. A daemon too old to plan leaves the event's
 * own line to say it, and nothing is asked; a session started here goes on to the brief,
 * as the terminal client does with such a daemon.
 */
export class StartQuestions {
  private state: StartState = { asking: null, busy: false, said: [], refusal: null, error: null };
  private readonly listeners = new Set<(state: StartState) => void>();
  private plan: OnboardPlan | null = null;
  // The files still to ask about one at a time: every file under Review, the new
  // `AGENTS.md`s after Onboard.
  private queue: OnboardItem[] = [];
  private readonly written: string[] = [];
  private readonly left: string[] = [];
  private readonly refused: string[] = [];

  constructor(
    private readonly daemon: DaemonClient,
    private readonly opts: StartOptions,
  ) {}

  get current(): StartState {
    return this.state;
  }

  /** Hear every change of state, besides `onState`; the function returned stops it. */
  subscribe(listener: (state: StartState) => void): () => void {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  async start(): Promise<void> {
    await this.step(async () => {
      let plan: OnboardPlan;
      try {
        plan = await this.daemon.onboardPlan(this.opts.workspace);
      } catch (e) {
        if (e instanceof TroupeRpcError && e.code === METHOD_NOT_FOUND) return this.brief();
        throw e;
      }
      this.plan = plan;
      if (plan.refusal) return this.set({ refusal: plan.refusal });
      const onboarding = plan.onboarding;
      if (onboarding.due === "first" || onboarding.due === "outdated") {
        return this.ask({
          kind: "onboard",
          due: onboarding.due,
          text: onboardQuestion(onboarding),
          detail:
            onboarding.due === "first"
              ? "Troupe reads its own files, AGENTS.md and .agents/, and no longer reads other tools' at run time. Onboarding copies what they say into Troupe's own files, once. Nothing is written until you choose."
              : "What the newer rules would write differs from what is there. Each file can be read as a diff first.",
          items: onboarding.items,
          skipped: onboarding.skipped,
        });
      }
      return this.brief();
    });
  }

  /** Answer the question the state asks. An answer it does not ask is ignored. */
  async answer(answer: StartAnswer): Promise<void> {
    const asking = this.state.asking;
    if (!asking || this.state.busy) return;
    await this.step(async () => {
      switch (asking.kind) {
        case "onboard":
          if (answer === "onboard") return this.onboardAll(asking.items);
          if (answer === "review") {
            this.queue = [...asking.items];
            return this.next();
          }
          if (answer === "decline") {
            await this.daemon.onboardDecline(this.opts.workspace, "all");
            this.say(
              asking.due === "first"
                ? "Onboarding: not now. You are asked again when the onboarding rules change; troupe onboard brings the files in whenever you like."
                : "Onboarding: not re-run. The files stay as they are until the rules change again.",
            );
            return this.brief();
          }
          return;
        case "review":
          if (answer === "write") return this.write(asking.item);
          if (answer === "skip") return this.skip(asking.item);
          return;
        case "create":
          if (answer === "create") return this.write(asking.item);
          if (answer === "skip") return this.skip(asking.item);
          return;
        case "brief":
          if (answer === "rerun") {
            await this.daemon.startLibrarian({ workspace: this.opts.workspace, parent: this.opts.sessionId, prompt: LIBRARIAN_PROMPT });
            this.say(LIBRARIAN_REWRITING);
            return this.set({ asking: null });
          }
          if (answer === "decline") {
            await this.daemon.declineBrief(this.opts.workspace);
            this.say("The brief stays as it is; you are asked again when the librarian's survey changes.");
            return this.set({ asking: null });
          }
          return;
      }
    });
  }

  /** Every file that is only a write, then each new `AGENTS.md` asked on its own. */
  private async onboardAll(items: OnboardItem[]): Promise<void> {
    const applied = await this.daemon.onboardApply(this.opts.workspace, "all");
    this.record(applied, items);
    this.queue = items.filter((i) => i.question === "create_agents_md");
    return this.next();
  }

  private async write(item: OnboardItem): Promise<void> {
    const applied = await this.daemon.onboardApply(this.opts.workspace, [item.id]);
    this.record(applied, [item]);
    return this.next();
  }

  private async skip(item: OnboardItem): Promise<void> {
    await this.daemon.onboardDecline(this.opts.workspace, [item.id]);
    this.left.push(item.shown);
    return this.next();
  }

  private record(applied: OnboardApplied, items: OnboardItem[]): void {
    const shown = (id: string): string => items.find((i) => i.id === id)?.shown ?? id;
    for (const w of applied.written) this.written.push(w.shown || shown(w.id));
    for (const r of applied.refused) this.refused.push(`${shown(r.id)}: ${r.reason}`);
  }

  /** The next file to ask about, or what onboarding came to and then the brief. */
  private async next(): Promise<void> {
    const item = this.queue.shift();
    if (item) {
      const total = this.plan?.onboarding.items.length ?? 0;
      if (item.question === "create_agents_md") return this.ask({ kind: "create", text: createQuestion(item), item });
      return this.ask({ kind: "review", text: `Write ${item.shown}?`, item, index: total - this.queue.length, total });
    }
    this.say(this.outcome());
    return this.brief();
  }

  /** What onboarding did, in one sentence. */
  private outcome(): string {
    const parts: string[] = [];
    if (this.written.length > 0) parts.push(`wrote ${listed(this.written)}`);
    if (this.left.length > 0) parts.push(`did not write ${listed(this.left)}`);
    if (this.refused.length > 0) parts.push(`could not write ${this.refused.join("; ")}`);
    return parts.length > 0 ? `Onboarding: ${parts.join("; ")}.` : "Onboarding: nothing to write.";
  }

  /**
   * The brief, once onboarding is answered (`Start.brief_step` in the terminal client): the
   * question when an older survey wrote it, and for a session started here the librarian
   * on a missing or stale one; neither where the librarian may not start by itself, with a
   * line when the reason is one a person would want.
   */
  private async brief(): Promise<void> {
    const brief = this.plan?.brief;
    const outdated = brief?.due === "outdated";
    if (!outdated && !this.opts.started) return this.set({ asking: null });

    const barred = await librarianBarred(this.daemon, this.opts.workspace);
    if (barred) {
      if (barred.say) this.say(`No librarian for the project brief: ${barred.why}.`);
      return this.set({ asking: null });
    }
    if (brief && outdated) {
      return this.ask({
        kind: "brief",
        text: briefQuestion(brief),
        detail: "The librarian surveys the repository again and rewrites .troupe/memory.md, in a session of its own beside this one.",
      });
    }

    const step = await refreshStep(this.daemon, this.opts.workspace);
    if (step.start !== undefined) {
      try {
        await this.daemon.startLibrarian({ workspace: this.opts.workspace, parent: this.opts.sessionId, prompt: step.start });
        this.say(step.status === "absent" ? LIBRARIAN_WRITING : LIBRARIAN_REWRITING);
      } catch (e) {
        this.say(`No librarian for the project brief: the daemon did not start it: ${e instanceof Error ? e.message : String(e)}.`);
      }
    } else if (step.say) {
      this.say(`No librarian for the project brief: ${step.why}.`);
    }
    this.set({ asking: null });
  }

  private ask(question: StartQuestion): void {
    this.set({ asking: question });
  }

  private say(sentence: string): void {
    this.set({ said: [...this.state.said, sentence] });
  }

  /** Run one step with the state busy, and say a failure rather than throw it. */
  private async step(run: () => Promise<void>): Promise<void> {
    this.set({ busy: true, error: null });
    try {
      await run();
    } catch (e) {
      this.set({ error: e instanceof Error ? e.message : String(e) });
    } finally {
      this.set({ busy: false });
    }
  }

  private set(change: Partial<StartState>): void {
    this.state = { ...this.state, ...change };
    this.opts.onState?.(this.state);
    for (const listener of this.listeners) listener(this.state);
  }
}
