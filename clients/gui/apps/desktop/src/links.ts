// What the app does with one of its own `troupe://` links (troupe #959).
//
// A link is an address: which place, on which plane. The app goes there when it is signed
// in to that plane; when it is signed in to none, it goes to the sign-in screen with the
// address filled in and a sentence saying whose it is, and makes no request to that plane
// until the person presses Sign in; when it is signed in to another, it asks before it signs
// out of that one. A link that is not one of the three forms, or one for a plane while the
// app uses this computer only, is said in one line and nothing else happens.

import { TroupeRpcError, errorText, hostOf, isRefused, parseAppLink, planeAddress } from "@troupe/client";
import type { AuthSession } from "@troupe/client";

/** Where a link leads in the app, once it is signed in to the link's plane. */
export type LinkPlace = { screen: "session"; id: string } | { screen: "artifacts"; artifact: string } | null;

export type LinkStep =
  /** One line, and nothing happens. */
  | { do: "say"; sentence: string }
  /** The app is already where the link asks: the shell brought it forward. */
  | { do: "front" }
  | { do: "go"; to: Exclude<LinkPlace, null> }
  /** Sign in to `plane` first, asked in `sentence`; then `then`. */
  | { do: "sign-in"; plane: string; sentence: string; then: LinkPlace }
  /** Signed in to another plane: ask before signing out of it. */
  | { do: "switch"; plane: string; sentence: string; then: LinkPlace };

export interface LinkContext {
  /** The plane the app is signed in to now, or null. */
  signedIn: string | null;
  /** Local only: the app talks to no plane, so no link to one is followed. */
  localOnly: boolean;
}

/** The one sentence a link to a plane the app is not signed in to is asked with. */
export function signInSentence(plane: string): string {
  return `This link is for ${hostOf(plane)}. Sign in there?`;
}

export function stepFor(text: string, context: LinkContext): LinkStep {
  const link = parseAppLink(text);
  if (isRefused(link)) return { do: "say", sentence: link.refused };
  if (link.plane === null) return { do: "front" };
  const then: LinkPlace = link.kind === "session" ? { screen: "session", id: link.id } : link.kind === "artifact" ? { screen: "artifacts", artifact: link.id } : null;
  if (context.localOnly) {
    return {
      do: "say",
      sentence: `This link is for ${hostOf(link.plane)}, and this app uses this computer only. Turn Local only off on This computer to follow it.`,
    };
  }
  const here = context.signedIn ? planeAddress(context.signedIn) ?? context.signedIn : null;
  if (here === link.plane) return then ? { do: "go", to: then } : { do: "front" };
  if (here === null) return { do: "sign-in", plane: link.plane, sentence: signInSentence(link.plane), then };
  return {
    do: "switch",
    plane: link.plane,
    sentence: `This link is for ${hostOf(link.plane)}, and this app is signed in to ${hostOf(here)}.`,
    then,
  };
}

/** What "Copy link" on a session puts on the clipboard; the console's Copy link writes the same. */
export { sessionLinkText } from "@troupe/client";

/** What an artifact's "Open session" says where the plane has no session of that id to show the person. */
export const SESSION_NOT_OPEN = "Published from a session you cannot open: it is gone, or it is not shared with you.";

/**
 * Whether the session an artifact came from can be opened, asked once at the click: null
 * when it is in the app's own lists or the plane answers it, and the sentence otherwise. The
 * plane answers `not_found` alike for a session that is gone and for one not shared with
 * the person, so the sentence says both. Without a plane sign-in it is opened as its link
 * would open it, and the session's own screen says what it finds.
 */
export async function sessionNotOpen(id: string, listed: boolean, auth: AuthSession | null): Promise<string | null> {
  if (listed || !auth) return null;
  try {
    await auth.withToken((plane, token) => plane.getSession(token, id));
    return null;
  } catch (e) {
    if (e instanceof TroupeRpcError && e.code === -32005) return SESSION_NOT_OPEN;
    return `The session could not be opened: ${errorText(e)}`;
  }
}
