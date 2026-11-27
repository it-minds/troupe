// How long a session lasts, in the words both web apps and the terminal say it (troupe
// #1209). `normal` is today's and says nothing; `throwaway` is erased a while after it goes
// quiet, and its row says when; `persistent` is never cleared away by anything but its
// owner. Never "Kept" for persistent: that is the pin's mark, which is the list's order.

import { TroupeRpcError } from "./connection.js";
import { ErrorCodes } from "./types.js";
import { errorText } from "./words.js";

export type Lifespan = "throwaway" | "normal" | "persistent";

/** The three, shortest-lived first: the order a picker offers them in. */
export const LIFESPANS: readonly Lifespan[] = ["throwaway", "normal", "persistent"];

/** A source's word, or `normal` for none: an older server, and every session from before lifespans, is normal. */
export function lifespanOf(value: unknown): Lifespan {
  return value === "throwaway" || value === "persistent" ? value : "normal";
}

/** Each lifespan as a picker offers it: its word, and what it means for the session. */
export const LIFESPAN_CHOICES: ReadonlyArray<{ value: Lifespan; label: string; sentence: string }> = [
  { value: "throwaway", label: "Throwaway", sentence: "Erased a day after it goes quiet" },
  { value: "normal", label: "Normal", sentence: "Sleeps when idle and stays until you erase it" },
  { value: "persistent", label: "Persistent", sentence: "Kept until you erase it" },
];

/** The choice for a lifespan. */
export function lifespanChoice(lifespan: Lifespan): { value: Lifespan; label: string; sentence: string } {
  return LIFESPAN_CHOICES.find((c) => c.value === lifespan)!;
}

/** The ⋯ item that changes a session to `to`: "Make it throwaway". */
export function lifespanItem(to: Lifespan): string {
  return `Make it ${to}`;
}

/** How long until `iso`, short, for a mark: `18 h`, `40 min`, `3 days`; `soon` once it has passed. */
export function untilWords(iso: string, now: number = Date.now()): string {
  const at = new Date(iso).getTime();
  if (!Number.isFinite(at)) return "soon";
  const minutes = Math.floor((at - now) / 60_000);
  if (minutes < 1) return "soon";
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours} h`;
  return `${Math.floor(hours / 24)} days`;
}

/**
 * A row's or a head's mark: `throwaway · goes in 18 h` (or `throwaway` where the source said
 * no time), `persistent`, or null for a normal session, which shows nothing.
 */
export function lifespanMark(row: { lifespan?: Lifespan | null; erasesAt?: string | null }, now: number = Date.now()): string | null {
  if (row.lifespan === "persistent") return "persistent";
  if (row.lifespan !== "throwaway") return null;
  if (!row.erasesAt) return "throwaway";
  const until = untilWords(row.erasesAt, now);
  return until === "soon" ? "throwaway · goes soon" : `throwaway · goes in ${until}`;
}

/** What the head of a throwaway session says beside its Erase now and Keep it. */
export function throwawaySentence(erasesAt: string | null | undefined, now: number = Date.now()): string {
  const when = erasesAt ? (untilWords(erasesAt, now) === "soon" ? "soon" : `in ${untilWords(erasesAt, now)}`) : "a day after it goes quiet";
  return `This session is throwaway: it is erased ${when}, unless it is awake or waits on you. Keep it to make it normal.`;
}

/** Why a lifespan was not changed, in words for the view's banner. */
export function lifespanRefusal(e: unknown): string {
  const lead = "How long it lasts was not changed";
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.method_not_found) return `${lead}: this server does not know lifespans yet.`;
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.forbidden && typeof e.data?.["reason"] !== "string") {
    return `${lead}: only the session's owner says how long it lasts.`;
  }
  return `${lead}: ${errorText(e)}.`;
}

/** Whether a server's `initialize` capabilities say it takes `lifespan`: a client offers the choice only then. */
export function knowsLifespans(capabilities: Record<string, unknown> | null | undefined): boolean {
  return capabilities?.["lifespans"] === true;
}

/** Anything that can ask the plane's `/rpc`, as an `AuthSession` does. */
export interface PlaneAsker {
  rpc<T>(method: string, params?: unknown): Promise<T>;
}

const asked = new WeakMap<PlaneAsker, Promise<boolean>>();

/**
 * Whether the plane takes `lifespan`, from its `initialize`, asked once for each sign-in.
 * Asked naming no client, so it is no client's version the plane records or judges; a plane
 * that could not be asked, or from before lifespans, answers false and nothing is offered.
 */
export function planeKnowsLifespans(auth: PlaneAsker): Promise<boolean> {
  let answer = asked.get(auth);
  if (!answer) {
    answer = auth
      .rpc<{ capabilities?: Record<string, unknown> }>("initialize", { protocol_version: "1" })
      .then((hello) => knowsLifespans(hello?.capabilities))
      .catch(() => false);
    asked.set(auth, answer);
  }
  return answer;
}
