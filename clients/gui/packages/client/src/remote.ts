// A laptop's session steered from another device, through the plane (troupe #58).
//
// The laptop dials the plane and the plane relays the protocol between it and this
// client, so attaching is what attaching to a pod is: an endpoint and a token from the
// plane (`remote.open`, asked again for a fresh token), then the same socket, the same
// subscription and the same commands. What the session may be asked from here is the
// relay's table: its transcript, its approvals and questions, a prompt, a cancel and its
// agent, and nothing of the laptop.

import { TroupeConnection, TroupeRpcError } from "./connection.js";
import type { Attachment } from "./plane.js";

type Rpc = <T = unknown>(method: string, params?: unknown) => Promise<T>;

/**
 * Open a relayed session: `remote.open`, with an endpoint the plane gave as a path taken
 * against the plane it was asked of. A laptop that is offline is refused with a sentence
 * saying since when (`remoteRefusal`), and nothing is queued for it.
 */
export async function openRemote(rpc: Rpc, planeUrl: string, sessionId: string): Promise<Attachment> {
  try {
    const answer = await rpc<Attachment>("remote.open", { session_id: sessionId });
    return { ...answer, endpoint: absolute(answer.endpoint, planeUrl), worker_id: answer.worker_id ?? "relay" };
  } catch (e) {
    throw new Error(remoteRefusal(e));
  }
}

/** Why a relayed session could not be opened, in words a person can act on. */
export function remoteRefusal(e: unknown): string {
  if (e instanceof TroupeRpcError) {
    const since = e.data?.["offline_since"];
    if (e.code === -32010 && typeof since === "string") return `The laptop is offline since ${when(since)}`;
    if (e.code === -32010) return "The laptop is offline";
    if (e.code === -32005) return "It is no longer offered to you";
  }
  return e instanceof Error ? e.message : String(e);
}

/** When, as a person reads it: today's time, or the day and time. */
export function when(iso: string): string {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return iso;
  const sameDay = at.toDateString() === new Date().toDateString();
  return sameDay
    ? at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
    : at.toLocaleString([], { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}

/** A row of the plane's `remote.list`, as it says it. */
export type RemoteListRow = Record<string, unknown>;

export interface RemoteWatchOptions {
  planeUrl: string;
  /** The person's plane token, the one `/rpc` takes; asked again at each dial and renewal. */
  token: () => Promise<string>;
  /** The person's whole list, as `remote.list` answers it: when the watch opens, and at each change. */
  onSessions: (sessions: RemoteListRow[]) => void;
  /**
   * Whether the watch is up: `true` once it opens, `false` each time a dial fails or the
   * socket drops. A list it pushed is news only while it is up; a caller asks again at each
   * `false`, which against a plane from before the watch is a poll at the backoff's pace.
   */
  onLive?: (live: boolean) => void;
  clientInfo?: { name: string; version: string };
  WebSocketImpl?: typeof WebSocket;
  /** The first wait before dialling again, and the longest. */
  backoffMs?: { first: number; most: number };
}

export interface RemoteWatch {
  readonly live: boolean;
  close(): void;
}

/** Where a plane keeps a person's watch: `wss://<plane>/v1/relay/watch`. */
export function watchUrl(planeUrl: string): string {
  return absolute("/v1/relay/watch", planeUrl);
}

/**
 * Hold a person's watch on the laptop sessions offered to them (`/v1/relay/watch`), so a
 * list of them is told what changes, an offer made or withdrawn and a laptop come or gone,
 * rather than asking `remote.list` again on a timer. Dials again when it drops, backing off
 * from a second to a minute, and renews its token on the open socket when the plane says
 * it is ending. A plane from before the watch refuses the socket, and the watch stays down:
 * `onLive(false)` is the caller's word to keep asking as before.
 */
export function watchRemote(opts: RemoteWatchOptions): RemoteWatch {
  const first = opts.backoffMs?.first ?? 1_000;
  const most = opts.backoffMs?.most ?? 60_000;
  let wait = first;
  let closed = false;
  let live = false;
  let conn: TroupeConnection | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let held: string | null = null;

  const say = (up: boolean): void => {
    if (up && live) return;
    live = up;
    opts.onLive?.(up);
  };

  const again = (): void => {
    if (closed || timer) return;
    timer = setTimeout(() => {
      timer = null;
      void dial();
    }, wait);
    wait = Math.min(wait * 2, most);
  };

  const dial = async (): Promise<void> => {
    if (closed) return;
    try {
      held = await opts.token();
      const opened = await TroupeConnection.open(
        { url: watchUrl(opts.planeUrl), token: held, clientInfo: opts.clientInfo, WebSocketImpl: opts.WebSocketImpl },
        {
          onNotification: (method, params) => {
            if (method !== "remote.changed") return;
            const sessions = (params as { sessions?: unknown } | null)?.sessions;
            if (Array.isArray(sessions)) opts.onSessions(sessions as RemoteListRow[]);
          },
          onAuthExpiring: () => {
            void opts
              .token()
              .then((token) => {
                // The same token again would be warned of again at once; the plane closes
                // it at its end, and the watch dials again with whatever is current then.
                if (token === held || !conn || conn.closed) return;
                held = token;
                return conn.refreshAuth(token);
              })
              .catch(() => undefined);
          },
          onClose: () => {
            conn = null;
            if (closed) return;
            say(false);
            again();
          },
        },
      );
      if (closed) return opened.close();
      conn = opened;
      wait = first;
      const sessions = opened.hello["sessions"];
      opts.onSessions(Array.isArray(sessions) ? (sessions as RemoteListRow[]) : []);
      say(true);
    } catch {
      if (closed) return;
      say(false);
      again();
    }
  };

  void dial();

  return {
    get live() {
      return live;
    },
    close() {
      closed = true;
      if (timer) clearTimeout(timer);
      timer = null;
      conn?.close();
      conn = null;
      live = false;
    },
  };
}

function absolute(endpoint: string, planeUrl: string): string {
  if (!endpoint.startsWith("/")) return endpoint;
  const u = new URL(planeUrl);
  u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
  u.pathname = u.pathname.replace(/\/$/, "") + endpoint;
  return u.toString();
}
