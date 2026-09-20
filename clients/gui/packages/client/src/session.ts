import type { TroupeConnection } from "./connection.js";
import type {
  BlobResponse,
  DurableEvent,
  FsFile,
  FsListing,
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
  /** The agent's `ask_user`, or the harness's budget question (`call_id` `budget-<n>`). */
  onQuestionAsked?: (data: DurableEvent["data"]) => void;
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
  readonly sessionId: string;
  /**
   * The cursor. It belongs to the view rather than to the socket, which is what makes
   * a reconnection invisible: the new subscription starts from the last seq this view
   * actually processed, and the server answers with no gap and no duplicate.
   */
  lastSeq = 0;
  headSeq = 0;
  subscriptionId: string | null = null;

  private connection: TroupeConnection | null = null;
  private readonly hooks: SessionViewHooks;
  private readonly waiters: Array<(e: TroupeEvent) => boolean> = [];
  private readonly listeners = new Set<(e: TroupeEvent) => void>();

  /**
   * `new SessionView(sessionId, hooks)` leaves the view unbound, for a caller that will
   * replace the socket under it (see `SessionAttachment`). Passing a connection first
   * binds it in one step, which is what a script with one socket wants.
   */
  constructor(connOrId: TroupeConnection | string, sessionIdOrHooks?: string | SessionViewHooks, hooks: SessionViewHooks = {}) {
    if (typeof connOrId === "string") {
      this.sessionId = connOrId;
      this.hooks = (sessionIdOrHooks as SessionViewHooks) ?? {};
    } else {
      this.connection = connOrId;
      this.sessionId = sessionIdOrHooks as string;
      this.hooks = hooks;
    }
  }

  /** The socket this view is speaking over. */
  get conn(): TroupeConnection {
    if (!this.connection) throw new Error(`session ${this.sessionId} is not attached to a connection`);
    return this.connection;
  }

  get bound(): boolean {
    return this.connection !== null;
  }

  /** Point the view at a (new) socket. The cursor is untouched. */
  bind(conn: TroupeConnection): void {
    this.connection = conn;
    this.subscriptionId = null; // subscriptions belong to the socket that made them
  }

  unbind(): void {
    this.connection = null;
    this.subscriptionId = null;
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
      if (e.type === "question_asked") this.hooks.onQuestionAsked?.(e.data);
    } else if (e.type === "llm_delta") {
      this.hooks.onDelta?.(e.data as LlmDeltaData, e.agent);
    }
    this.hooks.onEvent?.(e);
    for (const l of this.listeners) l(e);
    for (let i = this.waiters.length - 1; i >= 0; i--) {
      if (this.waiters[i]!(e)) this.waiters.splice(i, 1);
    }
    return true;
  }

  /**
   * Subscribe. `fromSeq` defaults to the last seq processed, so the same call is both
   * the first subscribe (0 replays everything) and the one made after a disconnect or a
   * `resync_required` — the server promises exactly one event per seq at the boundary,
   * so resuming from the cursor leaves no gap and no duplicate.
   */
  async subscribe(fromSeq: number = this.lastSeq, level: "detail" | "summary" = "detail"): Promise<SubscribeResult> {
    const r = await this.conn.call<SubscribeResult>("subscribe", {
      command_id: this.conn.nextCommandId(),
      topic: this.topic,
      level,
      from_seq: fromSeq,
    });
    this.subscriptionId = r.subscription_id;
    this.headSeq = r.head_seq;
    return r;
  }

  /**
   * Watch the same stream the view is folding, without taking the hook off whoever
   * owns it — a file pane and a transcript are looking at one subscription. Returns the
   * function that stops watching.
   */
  listen(fn: (e: TroupeEvent) => void): () => void {
    this.listeners.add(fn);
    return () => void this.listeners.delete(fn);
  }

  /** Re-subscribe from the cursor. What `resync_required` and a reconnect both want. */
  async resubscribe(level: "detail" | "summary" = "detail"): Promise<SubscribeResult> {
    this.subscriptionId = null;
    return this.subscribe(this.lastSeq, level);
  }

  async unsubscribe(): Promise<void> {
    if (!this.subscriptionId || !this.connection) return;
    await this.conn.call("unsubscribe", { subscription_id: this.subscriptionId });
    this.subscriptionId = null;
  }

  /**
   * Resolve with the first event matching `pred`, or reject after `timeoutMs`.
   * Registered synchronously, so call it *before* the command that causes the event.
   */
  waitFor(
    pred: (e: TroupeEvent) => boolean,
    timeoutMs = 30_000,
    label = "event",
    /** Stop waiting, without waiting out the timeout. See `prompt`. */
    signal?: AbortSignal,
  ): Promise<TroupeEvent> {
    return new Promise((resolve, reject) => {
      const stop = () => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", onAbort);
      };
      // Only for the two paths that end the wait without `handle` knowing about it.
      // When the predicate matches, `handle` removes the waiter by index — removing it
      // here as well would shift the array underneath it and drop somebody else's.
      const forget = () => {
        const i = this.waiters.indexOf(waiter);
        if (i >= 0) this.waiters.splice(i, 1);
      };
      const timer = setTimeout(() => {
        stop();
        forget();
        reject(new Error(`timed out after ${timeoutMs}ms waiting for ${label} on ${this.sessionId}`));
      }, timeoutMs);
      const onAbort = () => {
        stop();
        forget();
        reject(new Error(`no longer waiting for ${label} on ${this.sessionId}`));
      };
      const waiter = (e: TroupeEvent) => {
        if (!pred(e)) return false;
        stop();
        resolve(e);
        return true;
      };
      if (signal?.aborted) {
        clearTimeout(timer);
        reject(new Error(`no longer waiting for ${label} on ${this.sessionId}`));
        return;
      }
      signal?.addEventListener("abort", onAbort, { once: true });
      this.waiters.push(waiter);
    });
  }

  /** `input.send`. The response is an acknowledgement; effects arrive as events. */
  async send(text: string, commandId: string = this.conn.nextCommandId()): Promise<{ commandId: string }> {
    await this.conn.call("input.send", { command_id: commandId, session_id: this.sessionId, text });
    return { commandId };
  }

  /** `approval.respond`. First response wins; a later one is answered with a resolution. */
  async respondApproval(callId: string, decision: "allow" | "deny" | "allow_session"): Promise<void> {
    await this.conn.call("approval.respond", {
      command_id: this.conn.nextCommandId(),
      session_id: this.sessionId,
      call_id: callId,
      decision,
    });
  }

  /**
   * `question.answer`, for the agent's `ask_user` and the harness's budget question
   * alike. Options are answered with their labels, joined with a comma when several were
   * chosen; free text is always allowed. First answer wins.
   */
  async answerQuestion(callId: string, text: string): Promise<void> {
    await this.conn.call("question.answer", {
      command_id: this.conn.nextCommandId(),
      session_id: this.sessionId,
      call_id: callId,
      text,
    });
  }

  /** `turn.cancel`. Valid from any state. */
  async cancel(): Promise<void> {
    await this.conn.call("turn.cancel", { command_id: this.conn.nextCommandId(), session_id: this.sessionId });
  }

  /** `profile.switch`. Applied at the next turn boundary, not immediately. */
  async switchProfile(profile: string): Promise<void> {
    await this.conn.call("profile.switch", {
      command_id: this.conn.nextCommandId(),
      session_id: this.sessionId,
      profile,
    });
  }

  async editTodo(action: "add" | "cancel" | "complete", params: { id?: string; content?: string }): Promise<void> {
    await this.conn.call("todo.edit", {
      command_id: this.conn.nextCommandId(),
      session_id: this.sessionId,
      action,
      ...params,
    });
  }

  /** Say who is looking. Costs a seat and nothing else. */
  async setPresence(state: "viewing" | "typing" | "away"): Promise<void> {
    await this.conn.call("presence.set", { session_id: this.sessionId, state });
  }

  /** `fs.list`, resolved through the session's mounts. `path` defaults to the root. */
  fsList(path = "."): Promise<FsListing> {
    return this.conn.call<FsListing>("fs.list", { session_id: this.sessionId, path });
  }

  fsRead(path: string): Promise<FsFile> {
    return this.conn.call<FsFile>("fs.read", { session_id: this.sessionId, path });
  }

  /**
   * `blob.get`. `range` is inclusive and optional; a server may answer with a shorter
   * range than asked for, and says so, so a caller reading a large blob loops on the
   * range it got back rather than the one it sent.
   */
  blobGet(blob: string, range?: [number, number]): Promise<BlobResponse> {
    const params: Record<string, unknown> = { session_id: this.sessionId, blob };
    if (range) params["range"] = range;
    return this.conn.call<BlobResponse>("blob.get", params);
  }

  /** The bytes of a blob, following the server's caps until it is whole. */
  async blobBytes(blob: string, limit = 4 * 1024 * 1024): Promise<Uint8Array> {
    const chunks: Uint8Array[] = [];
    let at = 0;
    let size = Infinity;
    while (at < Math.min(size, limit)) {
      const end = Math.min(at + 262_143, limit - 1);
      const r = await this.blobGet(blob, [at, end]);
      size = r.size;
      const bytes = decodeBase64(r.data);
      if (bytes.length === 0) break;
      chunks.push(bytes);
      at = (r.range?.[1] ?? at + bytes.length - 1) + 1;
    }
    const total = chunks.reduce((n, c) => n + c.length, 0);
    const out = new Uint8Array(total);
    let o = 0;
    for (const c of chunks) {
      out.set(c, o);
      o += c.length;
    }
    return out;
  }

  /** A blob as text, which is what a tool result that grew past 16 KiB always is. */
  async blobText(blob: string, limit?: number): Promise<string> {
    return new TextDecoder().decode(await this.blobBytes(blob, limit));
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
    // Every waiter below is torn down when the turn ends. Without this, a turn that
    // produced no `llm_delta` — a dropped ephemeral, a tool-only turn, or a model that
    // simply answered fast — would hold this method open for that waiter's own timeout
    // long after the turn was over. The bench calls `prompt`, so the cost lands there.
    const giveUp = new AbortController();
    const t0 = performance.now();
    const marks: TurnResult["marks"] = {};
    let responseText = "";
    let acceptedSeen = false;
    let endTurnSeen = false;

    const accepted = this.waitFor(
      (e) => isDurable(e) && e.type === "input_accepted" && e.data["command_id"] === commandId,
      timeoutMs,
      "input_accepted",
      giveUp.signal,
    ).then(() => {
      acceptedSeen = true;
      marks.accepted = performance.now() - t0;
    });

    const deltaSeen = this.waitFor((e) => !isDurable(e) && e.type === "llm_delta", timeoutMs, "llm_delta", giveUp.signal)
      .then(() => {
        marks.firstDelta = performance.now() - t0;
      })
      .catch(() => undefined); // deltas are best-effort by contract

    const responded = this.waitFor((e) => isDurable(e) && e.type === "llm_response", timeoutMs, "llm_response", giveUp.signal)
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
      giveUp.signal,
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
      // `giveUp` stops this too. When the turn ends durably, `terminal` wins the race
      // and this loop is left running over a connection nobody is waiting on any more:
      // its next `session.get` rejects when that socket eventually closes, into a
      // promise with no handler, which Node reports as an uncaught error in whatever
      // happens to be running at the time.
      while (performance.now() < deadline && !giveUp.signal.aborted) {
        await new Promise((r) => setTimeout(r, waitMs));
        waitMs = Math.min(waitMs * 2, 100);
        if (giveUp.signal.aborted) break;
        let s: { status?: string; state?: string };
        try {
          s = await this.conn.call<{ status?: string; state?: string }>("session.get", { session_id: this.sessionId });
        } catch {
          break; // the socket went, or the session did; `terminal` owns the outcome
        }
        if (s.status && !["thinking", "acting", "compacting", "busy"].includes(s.status)) {
          return { ephemeral: true, type: "agent_state", agent: ["root"], data: { state: s.status, polled: true } };
        }
      }
      return new Promise<never>(() => undefined); // let `terminal` own the timeout
    })();

    const end = await Promise.race([terminal, polled]);
    marks.done = performance.now() - t0;
    // Handlers attached before the abort, or the rejections it causes are unhandled for
    // a tick and Node reports them as an uncaught error.
    const settled = Promise.allSettled([accepted, deltaSeen, responded]);
    giveUp.abort();
    await settled;

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

/** Base64 without assuming `atob` or `Buffer` is the one that exists. */
function decodeBase64(data: string): Uint8Array {
  const g = globalThis as { atob?: (s: string) => string; Buffer?: { from(s: string, enc: string): Uint8Array } };
  if (g.atob) {
    const bin = g.atob(data);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  if (g.Buffer) return new Uint8Array(g.Buffer.from(data, "base64"));
  throw new Error("no base64 decoder available");
}
