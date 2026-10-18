// A laptop's session steered from another device, through the plane (troupe #58,
// Decision 921).
//
// The laptop dials the plane and the plane relays the protocol between it and this
// client, so attaching is what attaching to a pod is: an endpoint and a token from the
// plane (`remote.open`, asked again for a fresh token), then the same socket, the same
// subscription and the same commands. What the session may be asked from here is the
// relay's table: its transcript, its approvals and questions, a prompt, a cancel and its
// agent, and nothing of the laptop.

import { TroupeRpcError } from "./connection.js";
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

function absolute(endpoint: string, planeUrl: string): string {
  if (!endpoint.startsWith("/")) return endpoint;
  const u = new URL(planeUrl);
  u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
  u.pathname = u.pathname.replace(/\/$/, "") + endpoint;
  return u.toString();
}
