import type { TroupeConnection } from "./connection.js";
import type {
  DurableEvent,
  EventEnvelope,
  LlmDeltaData,
  SessionCreateResult,
  SubscribeResult,
  TroupeEvent,
} from "./types.js";
import { isDurable } from "./types.js";

export interface SessionViewHooks {
  /** Every event for this session, durable or ephemeral, in arrival order. */
  onEvent?: (e: TroupeEvent) => void;
  /** Streaming text from the model. Expect to lose some under load. */
  onDelta?: (d: LlmDeltaData, agent: string[]) => void;
  onApprovalRequested?: (data: DurableEvent["data"]) => void;
}

/**
 * A client-side view of one session: subscribes, tracks the last processed `seq`
 * (for resubscribing after a disconnect or `resync_required`), and turns "send a
 * prompt, wait for the turn to finish" into a promise.
 *
 * The connection may be to a local daemon or a worker pod; the session speaks the
 * same protocol on both.
 */
export class SessionView {
  readonly conn: TroupeConnection;
  readonly sessionId: string;
  lastSeq = 0;
  headSeq = 0;
  subscriptionId: string | null = null;

  private readonly hooks: SessionViewHooks;
  private readonly waiters: Array<(e: TroupeEvent) => boolean> = [];

  constructor(conn: TroupeConnection, sessionId: string, hooks: SessionViewHooks = {}) {
    this.conn = conn;
    this.sessionId = sessionId;
    this.hooks = hooks;
  }

  get topic(): string {
    return `session:${this.sessionId}`;
  }

  /** Route an envelope here if it is ours. Returns true if consumed. */
  handle(envelope: EventEnvelope): boolean {
    if (envelope.topic !== this.topic && envelope.session_id !== this.sessionId) return false;
    const e = envelope.event;
    if (isDurable(e)) {
      if (e.seq <= this.lastSeq) return true; // duplicate after a resubscribe
      this.lastSeq = e.seq;
      if (e.type === "approval_requested") this.hooks.onApprovalRequested?.(e.data);
    } else if (e.type === "llm_delta") {
      this.hooks.onDelta?.(e.data as LlmDeltaData, e.agent);
    }
    this.hooks.onEvent?.(e);
    for (let i = this.waiters.length - 1; i >= 0; i--) {
      if (this.waiters[i]!(e)) this.waiters.splice(i, 1);
    }
    return true;
  }

  /** Subscribe at `detail`. `fromSeq` defaults to the last seq processed (0 = replay all). */
  async subscribe(fromSeq: number = this.lastSeq): Promise<SubscribeResult> {
    const r = await this.conn.call<SubscribeResult>("subscribe", {
      command_id: this.conn.nextCommandId(),
      topic: this.topic,
      level: "detail",
      from_seq: fromSeq,
    });
    this.subscriptionId = r.subscription_id;
    this.headSeq = r.head_seq;
    return r;
  }

  async unsubscribe(): Promise<void> {
    if (!this.subscriptionId) return;
    await this.conn.call("unsubscribe", { subscription_id: this.subscriptionId });
    this.subscriptionId = null;
  }

  /**
   * Resolve with the first event matching `pred`, or reject after `timeoutMs`.
   * Registered synchronously, so call it *before* the command that causes the event.
   */
  waitFor(pred: (e: TroupeEvent) => boolean, timeoutMs = 30_000, label = "event"): Promise<TroupeEvent> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const i = this.waiters.indexOf(waiter);
        if (i >= 0) this.waiters.splice(i, 1);
        reject(new Error(`timed out after ${timeoutMs}ms waiting for ${label} on ${this.sessionId}`));
      }, timeoutMs);
      const waiter = (e: TroupeEvent) => {
        if (!pred(e)) return false;
        clearTimeout(timer);
        resolve(e);
        return true;
      };
      this.waiters.push(waiter);
    });
  }

  /** `input.send`. The response is an acknowledgement; effects arrive as events. */
  async send(text: string, commandId: string = this.conn.nextCommandId()): Promise<{ commandId: string }> {
    await this.conn.call("input.send", { command_id: commandId, session_id: this.sessionId, text });
    return { commandId };
  }

  /**
   * Send a prompt and wait for the turn to end. Returns timings for each milestone.
   *
   * A turn ends in one of two ways. Durably: `agent_done`, `cancelled`,
   * `budget_exhausted` or `llm_error`. Or quietly: a text-only answer leaves the agent
   * `idle` with no durable marker, announced only by an ephemeral `agent_state` — which
   * may be dropped under load, so after an `llm_response` that ends the turn we also
   * poll `session.get` until its status is no longer busy.
   */
  async prompt(text: string, timeoutMs = 60_000): Promise<TurnResult> {
    const commandId = this.conn.nextCommandId();
    const t0 = performance.now();
    const marks: TurnResult["marks"] = {};
    let responseText = "";
    let acceptedSeen = false;
    let endTurnSeen = false;

    const accepted = this.waitFor(
      (e) => isDurable(e) && e.type === "input_accepted" && e.data["command_id"] === commandId,
      timeoutMs,
      "input_accepted",
    ).then(() => {
      acceptedSeen = true;
      marks.accepted = performance.now() - t0;
    });

    const deltaSeen = this.waitFor((e) => !isDurable(e) && e.type === "llm_delta", timeoutMs, "llm_delta")
      .then(() => {
        marks.firstDelta = performance.now() - t0;
      })
      .catch(() => undefined); // deltas are best-effort by contract

    const responded = this.waitFor((e) => isDurable(e) && e.type === "llm_response", timeoutMs, "llm_response")
      .then((e) => {
        marks.response = performance.now() - t0;
        const data = (e as DurableEvent).data;
        const msg = data["message"] as { content?: Array<{ type?: string; text?: string }> } | undefined;
        for (const block of msg?.content ?? []) if (typeof block.text === "string") responseText += block.text;
        if (data["stop_reason"] === "end_turn") endTurnSeen = true;
      })
      .catch(() => undefined);

    const isRoot = (e: TroupeEvent) => e.agent.length === 1;
    const terminal = this.waitFor(
      (e) =>
        (isDurable(e) && ["agent_done", "cancelled", "budget_exhausted", "llm_error"].includes(e.type) && isRoot(e)) ||
        (!isDurable(e) && e.type === "agent_state" && isRoot(e) && acceptedSeen && ["idle", "done"].includes(String(e.data["state"]))),
      timeoutMs,
      "end of turn",
    );

    await this.send(text, commandId);
    marks.acked = performance.now() - t0;

    // The fallback: once the model has answered with end_turn, ask the server whether
    // the agent is still busy. Cheap, and immune to a dropped ephemeral.
    let wakePoller: (() => void) | null = null;
    const endTurn = new Promise<void>((r) => {
      wakePoller = r;
    });
    void responded.then(() => {
      if (endTurnSeen) wakePoller?.();
    });
    const polled = (async (): Promise<TroupeEvent> => {
      await endTurn;
      const deadline = t0 + timeoutMs;
      // Give the live `agent_state` a moment to arrive, then ask; a `session.get` round
      // trip is cheap, so this costs a few milliseconds when the ephemeral was dropped.
      let waitMs = 5;
      while (performance.now() < deadline) {
        await new Promise((r) => setTimeout(r, waitMs));
        waitMs = Math.min(waitMs * 2, 100);
        const s = await this.conn.call<{ status?: string; state?: string }>("session.get", { session_id: this.sessionId });
        if (s.status && !["thinking", "acting", "compacting", "busy"].includes(s.status)) {
          return { ephemeral: true, type: "agent_state", agent: ["root"], data: { state: s.status, polled: true } };
        }
      }
      return new Promise<never>(() => undefined); // let `terminal` own the timeout
    })();

    const end = await Promise.race([terminal, polled]);
    marks.done = performance.now() - t0;
    await Promise.allSettled([accepted, deltaSeen, responded]);

    const endType = isDurable(end) ? end.type : `agent_state:${String(end.data["state"])}`;
    return { commandId, endType, reason: String(end.data["reason"] ?? end.data["done_reason"] ?? ""), text: responseText, marks };
  }
}

/** Whether a turn result means the agent finished its turn normally. */
export function turnCompleted(t: TurnResult): boolean {
  return t.endType === "agent_done" || t.endType.startsWith("agent_state:");
}

export interface TurnResult {
  commandId: string;
  endType: string;
  reason: string;
  text: string;
  /** Milliseconds from just before `input.send` was written. */
  marks: { acked?: number; accepted?: number; firstDelta?: number; response?: number; done?: number };
}

/**
 * Create a session *on the connection's own server* (a local daemon, or a worker
 * reached with an admin-scope token). Against a plane-fronted deployment prefer
 * `PlaneClient.createSession`, which places the session and returns the endpoint.
 */
export async function createLocalSession(
  conn: TroupeConnection,
  params: { workspace: string; profile?: string; prompt?: string; worktree?: "auto" | "never" | "always"; config?: Record<string, unknown> },
): Promise<SessionCreateResult> {
  return conn.call<SessionCreateResult>("session.create", { command_id: conn.nextCommandId(), ...params });
}
