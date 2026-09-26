// Keeping one session's socket alive.
//
// A pod token is good for at most fifteen minutes and a session outlives it, so two
// things have to happen without the person noticing. Before `exp`, the pod says
// `auth.expiring` and the client mints a fresh token at the plane and hands it over on
// the socket that is already open — a turn in progress is not interrupted, because
// nothing is reconnected. And if the socket goes anyway, the view reopens it and
// resubscribes *from its own cursor*, which the server answers with no gap and no
// duplicate at the boundary.
//
// Neither token is written down. The pod token lives in this object and dies with it.
//
// A session is not tied to its pod: a drain, a replaced pod or another client's activation
// leaves it somewhere else (PROTOCOL.md §6, "A session that moves"). Every reconnection
// asks the plane again, so a socket that goes follows the session by itself; a pod that is
// still up and answers `not_found` for the session is followed with `retrying`.

import { TroupeConnection, TroupeRpcError } from "./connection.js";
import { normalizeEndpoint } from "./plane.js";
import type { Attachment } from "./plane.js";
import { SessionView } from "./session.js";
import type { SessionViewHooks } from "./session.js";
import type { EventEnvelope, TroupeEvent } from "./types.js";

export interface AttachOptions {
  sessionId: string;
  /** Ask the plane for an endpoint and a pod token. `session.open` with the mode wanted. */
  open: (mode: "read" | "activate") => Promise<Attachment>;
  /** Ask the plane for a fresh pod token for the same connection. `token.mint`. */
  mint: () => Promise<Attachment>;
  mode?: "read" | "activate";
  hooks?: SessionViewHooks;
  /** Called on every state change, for a status line. */
  onStatus?: (status: AttachStatus, detail?: string) => void;
  WebSocketImpl?: typeof WebSocket | undefined;
  /** Backoff between reconnection attempts, in milliseconds. */
  backoffMs?: number[];
  clientInfo?: { name: string; version: string };
}

export type AttachStatus = "connecting" | "live" | "refreshing" | "reconnecting" | "closed" | "failed";

const DEFAULT_BACKOFF = [250, 500, 1_000, 2_000, 5_000, 10_000];

/**
 * Whether a pod refused a command because it does not hold the session: `not_found`
 * naming the session, which a pod answers before it runs anything.
 */
export function notHere(e: unknown): boolean {
  return e instanceof TroupeRpcError && e.code === -32005 && e.data?.["kind"] === "session";
}

/**
 * One live session: a connection, a view, and the policy that keeps them.
 *
 * `attachment.view` is stable across reconnections — it owns the cursor, which is the
 * thing that must survive — while `attachment.conn` is replaced each time the socket is.
 */
export class SessionAttachment {
  view: SessionView;
  conn: TroupeConnection | null = null;
  attachment: Attachment | null = null;
  status: AttachStatus = "connecting";

  private readonly opts: Required<Pick<AttachOptions, "mode" | "backoffMs">> & AttachOptions;
  private stopped = false;
  private reconnecting: Promise<void> | null = null;

  private constructor(opts: AttachOptions) {
    this.opts = { mode: opts.mode ?? "read", backoffMs: opts.backoffMs ?? DEFAULT_BACKOFF, ...opts };
    this.view = new SessionView(opts.sessionId, this.opts.hooks ?? {});
  }

  static async open(opts: AttachOptions): Promise<SessionAttachment> {
    const a = new SessionAttachment(opts);
    await a.connect();
    return a;
  }

  get sessionId(): string {
    return this.opts.sessionId;
  }

  /** Route an envelope. Exposed because a connection may carry more than one session. */
  handle(envelope: EventEnvelope): boolean {
    return this.view.handle(envelope);
  }

  /**
   * Run a command, and when the pod says it does not hold the session, reopen through the
   * plane and run it once more. The pod ran nothing, so a command that reuses its
   * `command_id` is not run twice; a second refusal is the answer.
   */
  async retrying<T>(command: () => Promise<T>): Promise<T> {
    try {
      return await command();
    } catch (e) {
      if (!notHere(e) || this.stopped) throw e;
      await this.follow("the pod no longer holds the session");
      if (this.status !== "live") throw e;
      return command();
    }
  }

  /** Leave the socket that is up and reopen through the plane, as a drop would. */
  private async follow(reason: string): Promise<void> {
    const old = this.conn;
    const reopened = this.reconnecting ?? this.reconnect(reason);
    old?.close();
    await reopened;
  }

  async close(): Promise<void> {
    this.stopped = true;
    try {
      await this.view.unsubscribe();
    } catch {
      /* the socket is going anyway */
    }
    this.conn?.close();
    this.set("closed");
  }

  private set(status: AttachStatus, detail?: string): void {
    this.status = status;
    this.opts.onStatus?.(status, detail);
  }

  private async connect(): Promise<void> {
    this.set("connecting");
    const attachment = await this.opts.open(this.opts.mode);
    if (!attachment.token) throw new Error(`the plane minted no token for ${this.sessionId}`);
    this.attachment = attachment;

    // Only the socket in use reconnects when it closes: one left behind on purpose, for
    // a pod that no longer holds the session, closes after its successor is up.
    const conn: TroupeConnection = await TroupeConnection.open(
      {
        url: normalizeEndpoint(attachment.endpoint),
        token: attachment.token,
        clientInfo: this.opts.clientInfo ?? { name: "troupe-gui", version: "0.1.0" },
        WebSocketImpl: this.opts.WebSocketImpl,
      },
      {
        onEvent: (env) => void this.view.handle(env),
        // The cursor is the client's, so resubscribing from it is the whole answer.
        onResyncRequired: () => void this.view.resubscribe().catch(() => this.reconnect("resync failed")),
        onAuthExpiring: () => void this.refresh(),
        onClose: (reason) => {
          if (this.conn === conn) void this.reconnect(reason);
        },
      },
    );

    this.conn = conn;
    this.view.bind(conn);
    await this.view.subscribe();
    this.set("live");
  }

  /** Mint a new pod token and hand it over without reconnecting. */
  private async refresh(): Promise<void> {
    if (this.stopped || !this.conn) return;
    this.set("refreshing");
    try {
      const fresh = await this.opts.mint();
      if (!fresh.token) throw new Error("the plane minted no token");
      await this.conn.refreshAuth(fresh.token);
      this.attachment = fresh;
      this.set("live");
    } catch (e) {
      // Not fatal on its own: the socket is still open until `exp`, and the close that
      // follows is what triggers the reconnect. Say so rather than tearing it down now.
      this.set("live", `could not refresh the token: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private async reconnect(reason: string): Promise<void> {
    if (this.stopped || this.reconnecting) return;
    this.reconnecting = (async () => {
      this.conn = null;
      this.view.unbind();
      for (const [i, wait] of this.opts.backoffMs.entries()) {
        if (this.stopped) return;
        this.set("reconnecting", `${reason}; attempt ${i + 1}`);
        await new Promise((r) => setTimeout(r, wait));
        try {
          await this.connect();
          return;
        } catch (e) {
          reason = e instanceof Error ? e.message : String(e);
        }
      }
      this.set("failed", reason);
    })().finally(() => {
      this.reconnecting = null;
    });
    return this.reconnecting;
  }
}

/** Convenience for a caller that only wants to wait for something on the view. */
export function waitOn(a: SessionAttachment, pred: (e: TroupeEvent) => boolean, timeoutMs?: number): Promise<TroupeEvent> {
  return a.view.waitFor(pred, timeoutMs);
}
