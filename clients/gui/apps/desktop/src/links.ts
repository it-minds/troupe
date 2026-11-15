// What the app does with one of its own `troupe://` links (troupe #959).
//
// A link is an address: which place, on which plane. The app goes there when it is signed
// in to that plane; when it is signed in to none, it goes to the sign-in screen with the
// address filled in and a sentence saying whose it is, and makes no request to that plane
// until the person presses Sign in; when it is signed in to another, it asks before it signs
// out of that one. A link that is not one of the three forms, or one for a plane while the
// app uses this computer only, is said in one line and nothing else happens.

import { appLink, isRefused, parseAppLink, planeAddress, planeHost } from "@troupe/client";

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
  return `This link is for ${planeHost(plane)}. Sign in there?`;
}

export function stepFor(text: string, context: LinkContext): LinkStep {
  const link = parseAppLink(text);
  if (isRefused(link)) return { do: "say", sentence: link.refused };
  if (link.plane === null) return { do: "front" };
  const then: LinkPlace = link.kind === "session" ? { screen: "session", id: link.id } : link.kind === "artifact" ? { screen: "artifacts", artifact: link.id } : null;
  if (context.localOnly) {
    return {
      do: "say",
      sentence: `This link is for ${planeHost(link.plane)}, and this app uses this computer only. Turn Local only off on This computer to follow it.`,
    };
  }
  const here = context.signedIn ? planeAddress(context.signedIn) ?? context.signedIn : null;
  if (here === link.plane) return then ? { do: "go", to: then } : { do: "front" };
  if (here === null) return { do: "sign-in", plane: link.plane, sentence: signInSentence(link.plane), then };
  return {
    do: "switch",
    plane: link.plane,
    sentence: `This link is for ${planeHost(link.plane)}, and this app is signed in to ${planeHost(here)}.`,
    then,
  };
}

/**
 * What "Copy link" on a session puts on the clipboard: its `troupe://` link, and under it
 * the console's page for it where the plane names a console and the session has one there
 * (a private session somebody was invited into). Never a token: both are addresses that
 * sign the reader in themselves.
 */
export function sessionLinkText(id: string, plane: string, console: string | null, privateSession: boolean): string {
  const lines = [appLink({ kind: "session", id, plane })];
  if (console && privateSession) lines.push(`${console.replace(/\/+$/, "")}/#/mine/invited/${encodeURIComponent(id)}`);
  return lines.join("\n");
}
