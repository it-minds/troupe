// Which configuration a pod session runs on, in the words both web apps say it (troupe
// #1177): the bundle version it is pinned to, and the channel's current one when it is
// behind. Its owner raises it to the current one (`session.bundle.raise`): at once when its
// agent is at rest, else when the agent is done. The terminal's `/bundle` says the same.

import { TroupeRpcError } from "./connection.js";
import { ErrorCodes } from "./types.js";
import { errorText } from "./words.js";

/** A version number as the plane or the log gives it, or null. */
export function versionOf(value: unknown): number | null {
  const n = typeof value === "number" ? value : typeof value === "string" && value !== "" ? Number(value) : NaN;
  return Number.isInteger(n) && n > 0 ? n : null;
}

/** Whether a version behind the channel's current one may be raised to it. */
export function behind(version: number | null, current: number | null): boolean {
  return version !== null && current !== null && current > version;
}

/** The configuration in a line: `v12 · v14 is current` behind, `v14` when current; null for none. */
export function configurationLine(version: number | null, current: number | null): string | null {
  if (version === null) return null;
  return behind(version, current) ? `v${version} · v${current} is current` : `v${version}`;
}

/** What Update does, under it: at once at rest, or when the agent is done. */
export function updateLine(current: number, busy: boolean): string {
  return busy ? `Moves to v${current} when the agent is done` : `Moves to v${current} now; the conversation stays`;
}

/** A raise the plane keeps for the agent's rest, in a line for the panel. */
export function owedLine(to: number): string {
  return `Moves to v${to} when the agent is done`;
}

/**
 * A refusal the plane answers a raise with that is not a refusal: the agent was working,
 * and the raise is kept for when it is done. The version it moves to, or null.
 */
export function raiseKept(e: unknown): number | null {
  if (!(e instanceof TroupeRpcError) || e.code !== ErrorCodes.conflict) return null;
  return versionOf(e.data?.["raise_to"]);
}

/** Why the plane would not raise it, in words for the view's banner. */
export function raiseRefusal(e: unknown): string {
  const lead = "Its configuration was not updated";
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.method_not_found) return `${lead}: this plane does not update a session's configuration yet.`;
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.forbidden && typeof e.data?.["reason"] !== "string") {
    return `${lead}: only the session's owner updates it.`;
  }
  return `${lead}: ${errorText(e)}.`;
}

/** `config_upgraded`, as a line in the transcript: who raised it, or that its version was retired. */
export function upgradedText(data: Record<string, unknown>): string {
  const from = versionOf(data["from"]);
  const to = versionOf(data["to"]);
  const moved = from !== null ? `from v${from} to v${to ?? "?"}` : `to v${to ?? "?"}`;
  if (data["reason"] === "raised") {
    const who = (typeof data["by_name"] === "string" && data["by_name"]) || (typeof data["by"] === "string" && data["by"]) || "its owner";
    return `Configuration raised ${moved} by ${who}`;
  }
  return `Configuration moved ${moved}: v${from ?? "?"} was retired`;
}
