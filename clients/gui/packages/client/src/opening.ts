// Opening a session's transcript (troupe #1182): the replay folded at once rather than an
// event at a time, and, where the server keeps checkpoints, from the latest one, with the
// part before it paged in on request.
//
// A checkpoint (PROTOCOL.md, "Checkpoints") says what the session's log comes to at its
// `through`. The transcript starts from its facts and its summary, and the events after
// `through` fold on top of it exactly as they fold on top of an empty transcript. The
// history before it contributes entries only: every scalar of the head (the profile, the
// spend, the goal, the tasks) is the checkpoint's and the tail's.

import { emptyTranscript, fold, foldMany } from "./transcript.js";
import type { EarlierState, Entry, LoopState, TodoItem, TokenUsage, TranscriptState } from "./transcript.js";
import type { DurableEvent, ScratchDocument, TroupeEvent } from "./types.js";
import { isDurable } from "./types.js";

/** The capability a server names at `initialize` when `subscribe` takes `from: "checkpoint"` and it answers `session.events`. */
export const CHECKPOINTS = "checkpoints";

/** The shape of a checkpoint's facts this client reads. One it does not know gives no facts, only the summary. */
export const CHECKPOINT_SHAPE = "session/1";

/** How many events a page of history asks for: the most `session.events` gives. */
export const EARLIER_PAGE = 500;

type Facts = Record<string, unknown>;

const obj = (v: unknown): Record<string, unknown> | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined);
const text = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
const count = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);

function usageOf(v: unknown): TokenUsage | undefined {
  const u = obj(v);
  if (!u) return undefined;
  const usage = { input_tokens: count(u["input_tokens"]), cache_read: count(u["cache_read"]), cache_write: count(u["cache_write"]), output_tokens: count(u["output_tokens"]) };
  return Object.values(usage).some((n) => n > 0) ? usage : undefined;
}

function loopOf(v: unknown): LoopState | undefined {
  const l = obj(v);
  const id = text(l?.["loop_id"]);
  if (!l || !id) return undefined;
  const max = typeof l["max_iterations"] === "number" ? l["max_iterations"] : null;
  const running = l["running"] === true;
  return {
    id,
    state: running ? "running" : "stopped",
    iteration: count(l["iteration"]),
    max,
    reason: running ? undefined : text(l["reason"]),
    detail: undefined,
    summary: undefined,
    iterations: running ? undefined : count(l["iteration"]),
  };
}

function scratchOf(v: unknown, ts: string): ScratchDocument[] {
  const by = obj(v) ?? {};
  return Object.entries(by).map(([name, raw]) => {
    const d = obj(raw) ?? {};
    return { name, path: `scratch:/${name}`, kind: text(d["kind"]) ?? "text", title: text(d["title"]) ?? name, size: 0, hash: "", version: count(d["version"]) || 1, updated_at: ts };
  });
}

/** A waiting approval or question as the checkpoint lists it, as the event that asked it. */
function asked(type: string, raw: unknown, ts: string): DurableEvent | null {
  const w = obj(raw);
  const data = obj(w?.["data"]);
  if (!w || !data || typeof w["seq"] !== "number") return null;
  const agent = Array.isArray(w["agent"]) ? w["agent"].map(String) : ["root"];
  const actor = (obj(w["actor"]) as DurableEvent["actor"] | undefined) ?? { kind: "system" };
  return { seq: w["seq"], prev_hash: null, ts, actor, agent, type, v: 1, data };
}

/** Whether `e` is a checkpoint a transcript can start from: its `through` and, read or not, its facts. */
export function isCheckpoint(e: unknown): e is DurableEvent {
  const d = obj(obj(e)?.["data"]);
  return obj(e)?.["type"] === "checkpoint" && typeof d?.["through"] === "number";
}

/**
 * The transcript at a checkpoint's `through`: its facts as this fold keeps them, the
 * summary as the first entry, and the approvals and questions still open under it. `base`
 * gives what is this client's and not the log's (sends not yet echoed, who is here).
 */
export function fromCheckpoint(checkpoint: DurableEvent, base: TranscriptState = emptyTranscript): TranscriptState {
  const data = checkpoint.data;
  const through = count(data["through"]);
  const facts: Facts = data["shape"] === CHECKPOINT_SHAPE ? (obj(data["facts"]) ?? {}) : {};
  const done = obj(facts["done"]);
  const startedAt = text(facts["started_at"]);
  const started = startedAt === undefined ? NaN : Date.parse(startedAt);
  const cost = count(facts["cost_micros"]);
  const used = obj(facts["context"])?.["used"];
  const agentState: Record<string, string> = {};
  for (const [path, a] of Object.entries(obj(facts["agents"]) ?? {})) {
    if (obj(a)?.["done"]) agentState[path.split("/").slice(1).join("/")] = "done";
  }
  const earlier: Entry = { kind: "earlier", seq: through, agent: ["root"], summary: typeof data["summary"] === "string" ? data["summary"] : "", at: checkpoint.ts };
  const waiting = [
    ...(Array.isArray(facts["open_approvals"]) ? facts["open_approvals"] : []).map((a) => asked("approval_requested", a, checkpoint.ts)),
    ...(Array.isArray(facts["open_questions"]) ? facts["open_questions"] : []).map((q) => asked("question_asked", q, checkpoint.ts)),
  ]
    .filter((e): e is DurableEvent => e !== null)
    .sort((a, b) => a.seq - b.seq);
  const history: EarlierState = { through, from: through + 1, more: through > 0, events: [], drawn: 0, late: [], seeded: waiting.map((e) => String(e.data["call_id"] ?? "")) };
  const start: TranscriptState = {
    ...emptyTranscript,
    pending: base.pending,
    presence: base.presence,
    agentState,
    curtain: { ...emptyTranscript.curtain, turn: count(facts["turns"]) },
    entries: [earlier],
    todo: Array.isArray(facts["todos"]) ? (facts["todos"] as TodoItem[]) : [],
    profile: text(facts["profile"]) ?? text(facts["agent"]),
    bundleVersion: text(facts["bundle_version"]),
    lastSeq: through,
    startedAt: Number.isFinite(started) ? started : undefined,
    error: text(obj(facts["error"])?.["reason"]),
    doneReason: done ? (text(done["reason"]) ?? "finished") : undefined,
    doneLimit: done ? text(done["limit"]) : undefined,
    limits: (obj(facts["limits"]) as Record<string, number> | undefined) ?? {},
    costMicros: cost > 0 ? cost : undefined,
    usage: usageOf(facts["usage"]),
    context: typeof used === "number" && used > 0 ? { used, window: undefined } : undefined,
    goal: text(facts["goal"]),
    loop: loopOf(facts["loop"]),
    scratch: scratchOf(facts["scratch"], checkpoint.ts),
    ...(text(facts["visibility"]) ? { visibility: text(facts["visibility"]) } : {}),
    ...(text(facts["lifespan"]) ? { lifespan: text(facts["lifespan"]) } : {}),
    earlier: history,
  };
  // The waiting ones are drawn as the events that asked them are, and only here: the
  // history's own copies are left out of it when it comes.
  const seeded = foldMany(start, waiting);
  return { ...seeded, lastSeq: through, earlier: history };
}

/**
 * A page of history, the events `session.events` gave before `earlier.from`, drawn above
 * what is there: every page so far folded again from the start, so a call one page started
 * and the next ended is drawn ended, with the tail's late answers on top. `more` is the
 * page's own word on whether there is history before it.
 */
export function withEarlier(state: TranscriptState, page: readonly DurableEvent[], more: boolean): TranscriptState {
  const earlier = state.earlier;
  if (!earlier) return state;
  const fresh = page.filter((e) => e.seq < earlier.from);
  const events = [...fresh, ...earlier.events];
  const seeded = new Set(earlier.seeded);
  const drawn = foldMany(emptyTranscript, [...events, ...earlier.late]).entries.filter(
    (en) => !((en.kind === "approval" || en.kind === "question") && seeded.has(en.callId)),
  );
  return {
    ...state,
    entries: [...drawn, ...state.entries.slice(earlier.drawn)],
    earlier: { ...earlier, events, from: events[0]?.seq ?? earlier.from, more: more && fresh.length > 0, drawn: drawn.length },
  };
}

/** What a subscription's answer says the replay comes to, as a feed reads it. */
export interface Subscribed {
  head_seq: number;
  checkpoint?: unknown;
}

/**
 * The transcript of one open session, fed the session's stream: the replay held until it
 * reaches the head the subscription answered with, then folded at once (from the
 * checkpoint, when it started at one) and set once; after that each event as it comes.
 * `apply` is how the screen takes a change, React's `setState` with an updater.
 *
 * A replay that stops short of the head, or a view joined after its replay was sent, is
 * folded once nothing has arrived for `idleMs`, so nothing waits on a head that never comes.
 */
export class TranscriptFeed {
  // Each held event with the time it arrived, which it folds with, as it would have live.
  private held: Array<[TroupeEvent, number]> | null = [];
  private target: number | null = null;
  private seen = 0;
  private checkpoint: DurableEvent | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private heard = 0;

  constructor(
    private readonly apply: (update: (s: TranscriptState) => TranscriptState) => void,
    private readonly idleMs = 300,
  ) {}

  /** Whether the replay is folded and each event now goes in as it comes. */
  get live(): boolean {
    return this.held === null;
  }

  /** One event of the session's stream, in the order it arrived. */
  push(e: TroupeEvent, now = Date.now()): void {
    if (this.held === null) return this.apply((s) => fold(s, e, { now }));
    this.held.push([e, now]);
    if (isDurable(e)) this.seen = Math.max(this.seen, e.seq);
    this.settle();
  }

  /** The subscription's answer: the head its replay runs to, and the checkpoint it starts from. */
  subscribed(answer: Subscribed): void {
    if (this.held === null) return;
    this.target = answer.head_seq;
    this.checkpoint = isCheckpoint(answer.checkpoint) ? answer.checkpoint : null;
    this.settle();
  }

  /** Let go: nothing more is folded. */
  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.held = null;
    this.target = null;
  }

  private settle(): void {
    this.heard = Date.now();
    if (this.target === null || this.held === null) return;
    if (this.seen >= this.target) return this.flush();
    if (!this.timer) this.arm(this.idleMs);
  }

  // One timer for the whole replay, put off while events still arrive.
  private arm(ms: number): void {
    this.timer = setTimeout(() => {
      this.timer = null;
      const quiet = Date.now() - this.heard;
      if (quiet >= this.idleMs) this.flush();
      else this.arm(this.idleMs - quiet);
    }, ms);
  }

  private flush(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const events = this.held;
    if (events === null) return;
    this.held = null;
    const checkpoint = this.checkpoint;
    this.apply((s) => {
      let state = checkpoint ? fromCheckpoint(checkpoint, s) : s;
      for (const [e, now] of events) state = fold(state, e, { now });
      return state;
    });
  }
}
