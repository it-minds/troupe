// The fold. A transcript is a projection over the session's events in the order the
// server delivered them, and nothing else: no client state is authoritative, and
// replaying the same events from seq 0 on a second client produces the same list.
//
// Durable events build the record. Ephemerals only paint what is happening right now —
// the message being produced, the agent's state, who else is here — and may be dropped
// under load without changing what the transcript says.

import type { DurableEvent, LlmDeltaData, TroupeEvent } from "./types.js";
import { isDurable } from "./types.js";

/** A `data` field the server replaced with a reference because it ran past 16 KiB. */
export interface BlobRef {
  blob: string;
  size: number;
  preview?: string;
  truncated?: boolean;
}

export function isBlobRef(v: unknown): v is BlobRef {
  return typeof v === "object" && v !== null && typeof (v as BlobRef).blob === "string";
}

export interface TodoItem {
  id: string;
  content: string;
  status: string;
}

/** One thing a person may answer a question with. */
export interface QuestionOption {
  label: string;
  description: string | null;
}

export type Entry =
  /** Something a person (or watch mode) said. `author` is the subject where there is one. */
  | { kind: "user"; seq: number; agent: string[]; text: string; author: string | undefined; source: string }
  /** What the model answered. Empty answers (a pure tool call) produce no entry. */
  | { kind: "assistant"; seq: number; agent: string[]; text: string; model: string | undefined; costMicros: number | undefined }
  | {
      kind: "tool";
      seq: number;
      agent: string[];
      callId: string;
      name: string;
      args: unknown;
      /** Undefined while the call is still running. */
      ok: boolean | undefined;
      content: string | BlobRef | undefined;
    }
  | {
      kind: "approval";
      seq: number;
      agent: string[];
      callId: string;
      tool: string;
      args: unknown;
      /** `allow`, `deny`, `allow_session`, once somebody answered. */
      decision: string | undefined;
      /** Set when another client got there first. */
      resolvedBy: string | undefined;
      /** Set when it ended unanswered: its call was cancelled, or timed out while it waited. */
      closed: boolean;
    }
  | { kind: "delegation"; seq: number; agent: string[]; callId: string; child: string; task: string }
  /**
   * A question for a person: the agent's `ask_user`, or the harness asking whether to
   * spend more once a budget is gone (`asked: "budget"`, troupe-remote Decision 660).
   * Options to pick from, free text always allowed, first answer wins.
   */
  | {
      kind: "question";
      seq: number;
      agent: string[];
      callId: string;
      question: string;
      options: QuestionOption[];
      multiple: boolean;
      asked: "agent" | "budget";
      /**
       * The answer's text once given: for the budget question `allow`, `always` or `deny`,
       * and for the failure guard's `stop` or `continue`, which the harness says itself
       * when nobody is there to ask.
       */
      answer: string | undefined;
      /** Set when it ended unanswered: a cancel reached it, or its call timed out while it waited. */
      closed: boolean;
    }
  | { kind: "todo"; seq: number; agent: string[]; items: TodoItem[]; source: string }
  /** Lifecycle: started, switched, compacted, done, cancelled, dormant, resumed, errors. */
  | { kind: "system"; seq: number; agent: string[]; type: string; text: string };

/** An input this client sent that the server has not yet echoed back. */
export interface PendingInput {
  commandId: string;
  text: string;
  /** `true` once `input_queued` said the server has it but the turn is still running. */
  queued: boolean;
}

export interface TranscriptState {
  entries: Entry[];
  /** Text of the answer currently streaming, root agent only. Cleared by `llm_response`. */
  streaming: string;
  /** Thinking blocks streaming alongside it. */
  thinking: string;
  /** Per-agent-path state from `agent_state` ephemerals; `""` is the root. */
  agentState: Record<string, string>;
  /** Optimistic sends, in send order, keyed by command id. */
  pending: PendingInput[];
  todo: TodoItem[];
  presence: PresenceMember[];
  profile: string | undefined;
  bundleVersion: string | undefined;
  lastSeq: number;
  /** The last `llm_error`, cleared by the next successful response. */
  error: string | undefined;
  /** Set once the agent reports it has finished; `agent_done.reason`. */
  doneReason: string | undefined;
  /** Summed from every `llm_response.gateway.cost_micros`; undefined if none said. */
  costMicros: number | undefined;
}

export interface PresenceMember {
  subject: string;
  display_name?: string;
  [k: string]: unknown;
}

export const emptyTranscript: TranscriptState = {
  entries: [],
  streaming: "",
  thinking: "",
  agentState: {},
  pending: [],
  todo: [],
  presence: [],
  profile: undefined,
  bundleVersion: undefined,
  lastSeq: 0,
  error: undefined,
  doneReason: undefined,
  costMicros: undefined,
};

/** The root agent is the one-element path; everything deeper is a subagent. */
export const isRoot = (agent: string[]): boolean => agent.length <= 1;
const pathKey = (agent: string[]): string => agent.slice(1).join("/");
/** Whether `agent` is the agent at `path` or one under it. */
const within = (agent: string[], path: string[]): boolean => agent.length >= path.length && path.every((part, i) => agent[i] === part);

function textOf(message: unknown): string {
  const content = (message as { content?: Array<{ type?: string; text?: string }> } | undefined)?.content ?? [];
  let out = "";
  // The model's thinking is not its answer, in either spelling (troupe-remote Decision 658).
  for (const block of content) if (typeof block.text === "string" && block.type !== "thinking" && block.type !== "reasoning") out += block.text;
  return out;
}

function str(v: unknown, fallback = ""): string {
  return typeof v === "string" ? v : v === undefined || v === null ? fallback : String(v);
}

/** `content` is a string, or a blob reference when the result ran past 16 KiB. */
function contentOf(v: unknown): string | BlobRef | undefined {
  if (v === undefined || v === null) return undefined;
  if (isBlobRef(v)) return v;
  return typeof v === "string" ? v : JSON.stringify(v);
}

function systemText(d: DurableEvent): string {
  switch (d.type) {
    case "session_created":
      return `session created on ${str(d.data["profile"], "?")}`;
    case "agent_started":
      return `agent started as ${str(d.data["mode"], str(d.data["profile"], "?"))}`;
    case "agent_restarted":
      return `agent restarted, replaying ${str(d.data["replayed_events"], "0")} events`;
    case "profile_switched":
      return `profile ${str(d.data["from"], "?")} → ${str(d.data["to"], "?")}`;
    case "compacted":
      return d.data["reason"] === "context_overflow"
        ? "conversation compacted, because the prompt no longer fit the model"
        : "conversation compacted";
    case "budget_warning":
      return `nearly out: ${str(d.data["detail"], str(d.data["dimension"], "a limit"))}`;
    case "agent_done":
      return `done: ${str(d.data["reason"], "finished")}`;
    case "input_after_done":
      return "input after the agent had finished; it picked the conversation back up";
    case "cancelled":
      return "turn cancelled";
    case "budget_exhausted":
      return `budget exhausted (${str(d.data["limit"], "limit")})`;
    case "llm_error":
      return `model error: ${str(d.data["reason"], "unknown")}`;
    case "session_dormant":
      return "session went dormant";
    case "session_activated":
      return `session activated on ${str(d.data["pod"], "a pod")}`;
    case "session_resumed":
      return d.data["moved"] ? "session resumed on another device" : "session resumed";
    case "fs_changed":
      return `${str(d.data["path"], "a file")} changed`;
    case "acl_granted":
      return `${str(d.data["subject"], "somebody")} was granted ${str(d.data["role"], "access")}`;
    case "acl_revoked":
      return `${str(d.data["subject"], "somebody")}'s access was revoked`;
    case "session_tainted":
      return `client-hosted tools registered by ${str(d.data["subject"], "a client")}`;
    default:
      return d.type;
  }
}

const SYSTEM_TYPES = new Set([
  "budget_warning",
  "session_created",
  "agent_started",
  "agent_restarted",
  "profile_switched",
  "compacted",
  "agent_done",
  "input_after_done",
  "cancelled",
  "budget_exhausted",
  "llm_error",
  "session_dormant",
  "session_activated",
  "session_resumed",
  "fs_changed",
  "acl_granted",
  "acl_revoked",
  "session_tainted",
]);

/** Add an optimistic entry for an input this client has just sent. */
export function addPending(state: TranscriptState, commandId: string, text: string): TranscriptState {
  return { ...state, pending: [...state.pending, { commandId, text, queued: false }] };
}

/** Drop an optimistic entry whose send failed. */
export function dropPending(state: TranscriptState, commandId: string): TranscriptState {
  return { ...state, pending: state.pending.filter((p) => p.commandId !== commandId) };
}

/**
 * Fold one event into the transcript.
 *
 * Durable events arriving out of order or twice are the caller's problem — route them
 * through `SessionView`, which drops anything at or below the seq it has already seen.
 */
export function fold(state: TranscriptState, e: TroupeEvent): TranscriptState {
  if (!isDurable(e)) return foldEphemeral(state, e);

  const d = e;
  const next: TranscriptState = { ...state, lastSeq: Math.max(state.lastSeq, d.seq) };
  const base = { seq: d.seq, agent: d.agent };

  switch (d.type) {
    case "input_queued": {
      const id = str(d.data["command_id"]);
      return {
        ...next,
        pending: state.pending.map((p) => (p.commandId === id ? { ...p, queued: true, text: str(d.data["text"], p.text) } : p)),
      };
    }

    // The server has taken the input; the `user_input` immediately after it carries the
    // text, so the optimistic copy stops being the one on screen here.
    case "input_accepted": {
      const id = str(d.data["command_id"]);
      return { ...next, pending: state.pending.filter((p) => p.commandId !== id) };
    }

    case "user_input":
      // The note the harness gives a model whose reply was cut or empty (troupe-remote
      // Decision 659) is not something a person typed, and is shown as what it is.
      if (str(d.data["source"]) === "harness") {
        return {
          ...next,
          entries: [...state.entries, { kind: "system", ...base, type: "harness_note", text: `the harness said: ${str(d.data["text"])}` }],
        };
      }
      return {
        ...next,
        entries: [
          ...state.entries,
          { kind: "user", ...base, text: str(d.data["text"]), author: d.actor.subject, source: str(d.data["source"], "user") },
        ],
      };

    case "llm_response": {
      const text = textOf(d.data["message"]);
      const gateway = d.data["gateway"] as { cost_micros?: number } | undefined;
      const cost = typeof gateway?.cost_micros === "number" ? gateway.cost_micros : undefined;
      const entries = text
        ? [
            ...state.entries,
            { kind: "assistant" as const, ...base, text, model: str(d.data["model"]) || undefined, costMicros: cost },
          ]
        : state.entries;
      return {
        ...next,
        entries,
        // Only the root agent's stream is painted, so only it is cleared.
        streaming: isRoot(d.agent) ? "" : next.streaming,
        thinking: isRoot(d.agent) ? "" : next.thinking,
        error: undefined,
        costMicros: cost === undefined ? next.costMicros : (next.costMicros ?? 0) + cost,
      };
    }

    case "tool_call_started":
      return {
        ...next,
        entries: [
          ...state.entries,
          {
            kind: "tool",
            ...base,
            callId: str(d.data["call_id"]),
            name: str(d.data["name"]),
            args: d.data["args"],
            ok: undefined,
            content: undefined,
          },
        ],
      };

    // The call is over, and so is an approval or a question it was still waiting for: a
    // cancel closes each call it stops with one of these, and so does a tool that timed
    // out waiting.
    case "tool_call_completed": {
      const id = str(d.data["call_id"]);
      return {
        ...next,
        entries: state.entries.map((en) =>
          en.kind === "tool" && en.callId === id
            ? { ...en, ok: Boolean(d.data["ok"]), content: contentOf(d.data["content"]) }
            : (en.kind === "approval" || en.kind === "question") && en.callId === id
              ? closeUnanswered(en)
              : en,
        ),
      };
    }

    // A cancel stops the agent it reached and every agent under it, and one it took down
    // never logs another word, so an approval or a question anywhere in that subtree ends
    // here — the rule the TUI keeps. That includes the budget's and the failure guard's
    // question, which no call closes. The entry saying the turn was cancelled goes in as
    // before.
    case "cancelled":
      return {
        ...next,
        entries: [
          ...state.entries.map((en) => ((en.kind === "approval" || en.kind === "question") && within(en.agent, d.agent) ? closeUnanswered(en) : en)),
          { kind: "system", ...base, type: d.type, text: systemText(d) },
        ],
      };

    case "delegation_started":
      return {
        ...next,
        entries: [
          ...state.entries,
          {
            kind: "delegation",
            ...base,
            callId: str(d.data["call_id"]),
            child: str(d.data["agent"]),
            task: str(d.data["task"]),
          },
        ],
      };

    // A question for a person. The harness's budget question rides on the same path under
    // a `budget-<n>` id with an event of its own beside it, so the entry is made from
    // whichever arrives first and the other only fills it in. A question the harness asks
    // at the gate before a model call (the budget's, the failure guard's) is still owed
    // after a cancel ended it, and is asked again under the same id at the next turn: the
    // entry it had is open again.
    case "budget_ask_started": {
      const callId = str(d.data["call_id"]);
      if (hasQuestion(state, callId)) return { ...next, entries: reopen(state.entries, callId) };
      return { ...next, entries: [...state.entries, budgetQuestion(base, callId, str(d.data["detail"], "budget exhausted"))] };
    }

    case "question_asked": {
      const callId = str(d.data["call_id"]);
      if (hasQuestion(state, callId)) return { ...next, entries: reopen(state.entries, callId) };
      if (callId.startsWith("budget-")) {
        return { ...next, entries: [...state.entries, budgetQuestion(base, callId, str(d.data["question"], "budget exhausted"))] };
      }
      return {
        ...next,
        entries: [
          ...state.entries,
          {
            kind: "question",
            ...base,
            callId,
            question: str(d.data["question"]),
            options: optionsOf(d.data["options"]),
            multiple: d.data["multiple"] === true,
            asked: "agent",
            answer: undefined,
            closed: false,
          },
        ],
      };
    }

    // The harness's own word on its question, beside the person's answer or instead of
    // it: under `approvals: deny` nobody is asked, and the budget says `deny` and the
    // failure guard `stop` without a `question_answered`.
    case "question_answered":
    case "budget_ask_answered":
    case "tool_failures_ask_answered": {
      const callId = str(d.data["call_id"]);
      const answer = str(d.data["text"] ?? d.data["decision"]);
      return {
        ...next,
        entries: state.entries.map((en) => (en.kind === "question" && en.callId === callId && en.answer === undefined ? { ...en, answer } : en)),
      };
    }

    // A reply the output cap cut, or one with nothing in it (troupe-remote Decision 659).
    case "truncated":
      return { ...next, entries: [...state.entries, { kind: "system", ...base, type: d.type, text: truncatedText(d) }] };

    case "approval_requested":
      return {
        ...next,
        entries: [
          ...state.entries,
          {
            kind: "approval",
            ...base,
            callId: str(d.data["call_id"]),
            tool: str(d.data["tool"]),
            args: d.data["args"],
            decision: undefined,
            resolvedBy: undefined,
            closed: false,
          },
        ],
      };

    case "approval_decided": {
      const id = str(d.data["call_id"]);
      return {
        ...next,
        entries: state.entries.map((en) =>
          en.kind === "approval" && en.callId === id ? { ...en, decision: str(d.data["decision"]) } : en,
        ),
      };
    }

    // Somebody else answered first. The decision stands; this only names who made it.
    case "approval_resolved": {
      const id = str(d.data["call_id"]);
      return {
        ...next,
        entries: state.entries.map((en) =>
          en.kind === "approval" && en.callId === id ? { ...en, resolvedBy: str(d.data["resolved_by"]) } : en,
        ),
      };
    }

    case "todo_updated": {
      const items = (d.data["items"] as TodoItem[]) ?? [];
      return {
        ...next,
        todo: items,
        entries: [...state.entries, { kind: "todo", ...base, items, source: str(d.data["source"], "agent") }],
      };
    }

    case "session_created":
      return {
        ...next,
        profile: str(d.data["profile"]) || next.profile,
        bundleVersion: str(d.data["bundle_version"]) || next.bundleVersion,
        entries: [...state.entries, { kind: "system", ...base, type: d.type, text: systemText(d) }],
      };

    case "agent_started":
      return {
        ...next,
        bundleVersion: str(d.data["bundle_version"]) || next.bundleVersion,
        doneReason: undefined,
        entries: [...state.entries, { kind: "system", ...base, type: d.type, text: systemText(d) }],
      };

    case "profile_switched":
      return {
        ...next,
        profile: str(d.data["to"]) || next.profile,
        entries: [...state.entries, { kind: "system", ...base, type: d.type, text: systemText(d) }],
      };

    case "agent_done":
      return {
        ...next,
        doneReason: str(d.data["reason"], "finished"),
        agentState: { ...next.agentState, [pathKey(d.agent)]: "done" },
        entries: [...state.entries, { kind: "system", ...base, type: d.type, text: systemText(d) }],
      };

    case "llm_error":
      return {
        ...next,
        error: str(d.data["reason"], "model error"),
        entries: [...state.entries, { kind: "system", ...base, type: d.type, text: systemText(d) }],
      };

    default:
      if (!SYSTEM_TYPES.has(d.type)) return next;
      return { ...next, entries: [...state.entries, { kind: "system", ...base, type: d.type, text: systemText(d) }] };
  }
}

function foldEphemeral(state: TranscriptState, e: TroupeEvent): TranscriptState {
  switch (e.type) {
    case "llm_delta": {
      if (!isRoot(e.agent)) return state; // a subagent's stream is not what is on screen
      const d = e.data as LlmDeltaData;
      const text = str(d.text ?? d.fragment);
      // Two spellings of the model's thinking: Anthropic's, and the daemon's own
      // (`reasoning`, troupe-remote Decision 658).
      if (d.kind === "thinking" || d.kind === "reasoning") return { ...state, thinking: state.thinking + text };
      if (d.kind === "text") return { ...state, streaming: state.streaming + text };
      return state;
    }
    case "agent_state":
      return { ...state, agentState: { ...state.agentState, [pathKey(e.agent)]: str(e.data["state"], "idle") } };
    case "presence":
      return { ...state, presence: (e.data["members"] as PresenceMember[]) ?? state.presence };
    default:
      return state;
  }
}

/** The root agent's state, which is what a session header shows. */
export function rootState(state: TranscriptState): string {
  return state.agentState[""] ?? "idle";
}

/** Whether the root agent is working, and a composer should say so. */
export function isBusy(state: TranscriptState): boolean {
  return ["thinking", "acting", "compacting", "busy"].includes(rootState(state));
}

/** Approvals in this transcript nobody has answered yet, and that are still waiting. */
export function openApprovals(state: TranscriptState): Extract<Entry, { kind: "approval" }>[] {
  return state.entries.filter((e): e is Extract<Entry, { kind: "approval" }> => e.kind === "approval" && e.decision === undefined && !e.closed);
}

/** Questions in this transcript nobody has answered yet, and that are still waiting — the agent's and the harness's. */
export function openQuestions(state: TranscriptState): Extract<Entry, { kind: "question" }>[] {
  return state.entries.filter((e): e is Extract<Entry, { kind: "question" }> => e.kind === "question" && e.answer === undefined && !e.closed);
}

/**
 * Whether a person is being waited on: an open approval or question, or a root agent
 * that says it is `waiting` — which is the daemon's word for the budget question.
 */
export function needsYou(state: TranscriptState): boolean {
  return rootState(state) === "waiting" || openApprovals(state).length > 0 || openQuestions(state).length > 0;
}

const BUDGET_OPTIONS: QuestionOption[] = [
  { label: "allow", description: "one more slice: the same budget again, then ask again" },
  // The limit the question names, and no other (troupe-remote Decision 687).
  { label: "always", description: "lift this limit for the rest of the session; the others still ask" },
  { label: "deny", description: "stop here" },
];

/** An approval or a question that ended without an answer. One somebody answered stays as it was. */
function closeUnanswered(en: Extract<Entry, { kind: "approval" | "question" }>): Entry {
  if (en.kind === "approval") return en.decision === undefined ? { ...en, closed: true } : en;
  return en.answer === undefined ? { ...en, closed: true } : en;
}

function hasQuestion(state: TranscriptState, callId: string): boolean {
  return state.entries.some((en) => en.kind === "question" && en.callId === callId);
}

/** The question under `callId` asked again: open, unless somebody has answered it. */
function reopen(entries: Entry[], callId: string): Entry[] {
  return entries.map((en) => (en.kind === "question" && en.callId === callId && en.closed && en.answer === undefined ? { ...en, closed: false } : en));
}

function budgetQuestion(base: { seq: number; agent: string[] }, callId: string, detail: string): Entry {
  return { kind: "question", ...base, callId, question: detail, options: BUDGET_OPTIONS, multiple: false, asked: "budget", answer: undefined, closed: false };
}

function optionsOf(v: unknown): QuestionOption[] {
  if (!Array.isArray(v)) return [];
  return v.flatMap((o): QuestionOption[] => {
    if (typeof o === "string") return [{ label: o, description: null }];
    if (typeof o === "object" && o !== null && typeof (o as { label?: unknown }).label === "string") {
      const description = (o as { description?: unknown }).description;
      return [{ label: (o as { label: string }).label, description: typeof description === "string" ? description : null }];
    }
    return [];
  });
}

function truncatedText(d: DurableEvent): string {
  const what = d.data["reason"] === "empty" ? "the reply had no text and no tool call" : "the reply was cut at the output cap";
  if (d.data["final"] === true) return `${what}; giving up`;
  if (typeof d.data["calls"] === "number") return `${what}; ${d.data["calls"]} tool call(s) answered with an error`;
  if (typeof d.data["note"] === "string") return `${what}; asking again`;
  return what;
}
