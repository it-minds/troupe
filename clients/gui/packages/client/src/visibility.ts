// Whose a pod session is, in the words both web apps say it (troupe #1169): the team's,
// which every member opens and steers where the team allows, or its owner's, which only
// they and the people they invited open. The owner gives it to the team or takes it back
// after it started (`session.visibility.set`); the terminal's `/share` says the same.

import { TroupeRpcError } from "./connection.js";
import { ErrorCodes } from "./types.js";
import { errorText } from "./words.js";

/** The head's mark: `the team's`, `only you` to its owner, `by invitation` to anybody else; null where nothing says. */
export function sessionWhose(visibility: string | null | undefined, owner: boolean): string | null {
  if (visibility === "team") return "the team's";
  if (visibility === "private") return owner ? "only you" : "by invitation";
  return null;
}

/** The team a session is given to, in words: `the eng team`, or `the team` where the row names none. */
export function teamWords(team: string | null | undefined): string {
  return team ? `the ${team} team` : "the team";
}

/** What giving it to the team does, under the item that does it. */
export function giveLine(team: string | null | undefined): string {
  return `Everyone on ${teamWords(team)} can open it, and steer it where the team allows`;
}

/** What taking it back does, under the item that does it. */
export const TAKE_BACK_LINE = "Only you and the people you invited can open it";

/** Whose it is, in a sentence, for somebody who may not change it. */
export function whoseSentence(visibility: string | null | undefined, team: string | null | undefined): string | null {
  if (visibility === "team") return `Given to ${teamWords(team)}: everyone on it can open it, and steer it where the team allows.`;
  if (visibility === "private") return "Only its owner and the people they invited can open it.";
  return null;
}

/** Why the plane would not give it to the team or take it back, in words for the view's banner. */
export function visibilityRefusal(e: unknown, give: boolean): string {
  const lead = give ? "It was not given to the team" : "It was not taken back";
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.method_not_found) return `${lead}: this plane does not give a session to a team after it started yet.`;
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.forbidden && typeof e.data?.["reason"] !== "string") {
    return `${lead}: only the session's owner gives it to the team or takes it back.`;
  }
  return `${lead}: ${errorText(e)}.`;
}
