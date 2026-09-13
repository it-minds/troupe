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
    }
  | { kind: "delegation"; seq: number; agent: string[]; callId: string; child: string; task: string }
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

function textOf(message: unknown): string {
  const content = (message as { content?: Array<{ type?: string; text?: string }> } | undefined)?.content ?? [];
  let out = "";
  for (const block of content) if (typeof block.text === "string" && block.type !== "thinking") out += block.text;
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
      return "conversation compacted";
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

    case "tool_call_completed": {
      const id = str(d.data["call_id"]);
      return {
        ...next,
        entries: state.entries.map((en) =>
          en.kind === "tool" && en.callId === id ? { ...en, ok: Boolean(d.data["ok"]), content: contentOf(d.data["content"]) } : en,
        ),
      };
    }

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
      if (d.kind === "thinking") return { ...state, thinking: state.thinking + text };
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

/** Approvals in this transcript nobody has answered yet. */
export function openApprovals(state: TranscriptState): Extract<Entry, { kind: "approval" }>[] {
  return state.entries.filter((e): e is Extract<Entry, { kind: "approval" }> => e.kind === "approval" && e.decision === undefined);
}
