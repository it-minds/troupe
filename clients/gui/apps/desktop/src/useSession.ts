// The client-side fold: a transcript is a projection over the session's events, in
// the order the server delivers them. Durable events build the record; ephemeral
// `llm_delta`s only paint the message that is currently being produced.

import { useCallback, useEffect, useRef, useState } from "react";
import { SessionView, TroupeConnection, isDurable } from "@troupe/client";
import type { DurableEvent, TroupeEvent } from "@troupe/client";

export type Entry =
  | { kind: "user"; seq: number; text: string; author?: string | undefined }
  | { kind: "assistant"; seq: number; text: string }
  | { kind: "tool"; seq: number; callId: string; name: string; args: unknown; ok?: boolean; content?: string }
  | { kind: "approval"; seq: number; callId: string; tool: string; args: unknown; decided?: string }
  | { kind: "system"; seq: number; text: string };

export interface SessionState {
  entries: Entry[];
  streaming: string;
  agentState: string;
  lastSeq: number;
  error: string | null;
}

const initial: SessionState = { entries: [], streaming: "", agentState: "idle", lastSeq: 0, error: null };

function textOf(message: unknown): string {
  const content = (message as { content?: Array<{ text?: string }> } | undefined)?.content ?? [];
  return content.map((b) => (typeof b.text === "string" ? b.text : "")).join("");
}

function fold(state: SessionState, e: TroupeEvent): SessionState {
  if (!isDurable(e)) {
    if (e.type === "llm_delta" && e.data["kind"] === "text" && e.agent.length === 1) {
      return { ...state, streaming: state.streaming + String(e.data["text"] ?? "") };
    }
    if (e.type === "agent_state" && e.agent.length === 1) {
      return { ...state, agentState: String(e.data["state"] ?? state.agentState) };
    }
    return state;
  }
  const d = e as DurableEvent;
  const next = { ...state, lastSeq: d.seq };
  switch (d.type) {
    case "user_input":
      return { ...next, entries: [...state.entries, { kind: "user", seq: d.seq, text: String(d.data["text"] ?? ""), author: d.actor.subject }] };
    case "llm_response": {
      const text = textOf(d.data["message"]);
      const entries = text ? [...state.entries, { kind: "assistant" as const, seq: d.seq, text }] : state.entries;
      return { ...next, entries, streaming: "" };
    }
    case "tool_call_started":
      return { ...next, entries: [...state.entries, { kind: "tool", seq: d.seq, callId: String(d.data["call_id"]), name: String(d.data["name"]), args: d.data["args"] }] };
    case "tool_call_completed":
      return {
        ...next,
        entries: state.entries.map((en) =>
          en.kind === "tool" && en.callId === d.data["call_id"] ? { ...en, ok: Boolean(d.data["ok"]), content: String(d.data["content"] ?? "") } : en,
        ),
      };
    case "approval_requested":
      return { ...next, entries: [...state.entries, { kind: "approval", seq: d.seq, callId: String(d.data["call_id"]), tool: String(d.data["tool"]), args: d.data["args"] }] };
    case "approval_decided":
      return {
        ...next,
        entries: state.entries.map((en) => (en.kind === "approval" && en.callId === d.data["call_id"] ? { ...en, decided: String(d.data["decision"]) } : en)),
      };
    case "agent_done":
      return { ...next, agentState: "done", entries: [...state.entries, { kind: "system", seq: d.seq, text: `agent done: ${String(d.data["reason"] ?? "")}` }] };
    case "llm_error":
      return { ...next, error: String(d.data["reason"] ?? "model error") };
    case "cancelled":
    case "budget_exhausted":
    case "compacted":
    case "profile_switched":
    case "session_activated":
    case "session_resumed":
      return { ...next, entries: [...state.entries, { kind: "system", seq: d.seq, text: d.type }] };
    default:
      return next;
  }
}

export function useSession(conn: TroupeConnection | null, sessionId: string | null) {
  const [state, setState] = useState<SessionState>(initial);
  const viewRef = useRef<SessionView | null>(null);

  useEffect(() => {
    setState(initial);
    viewRef.current = null;
    if (!conn || !sessionId) return;
    const view = new SessionView(conn, sessionId, { onEvent: (e) => setState((s) => fold(s, e)) });
    viewRef.current = view;
    view.subscribe(0).catch((err) => setState((s) => ({ ...s, error: String(err) })));
    return () => {
      void view.unsubscribe().catch(() => undefined);
    };
  }, [conn, sessionId]);

  // The connection hands every envelope to whichever view is current.
  useEffect(() => {
    if (!conn) return;
    conn.on({ onEvent: (env) => void viewRef.current?.handle(env) });
  }, [conn]);

  const send = useCallback(async (text: string) => {
    const view = viewRef.current;
    if (!view) throw new Error("no session");
    await view.send(text);
  }, []);

  const respond = useCallback(async (callId: string, decision: "allow" | "deny" | "allow_session") => {
    const view = viewRef.current;
    if (!view) return;
    await view.conn.call("approval.respond", { command_id: view.conn.nextCommandId(), session_id: view.sessionId, call_id: callId, decision });
  }, []);

  const cancel = useCallback(async () => {
    const view = viewRef.current;
    if (!view) return;
    await view.conn.call("turn.cancel", { command_id: view.conn.nextCommandId(), session_id: view.sessionId });
  }, []);

  return { state, send, respond, cancel };
}
