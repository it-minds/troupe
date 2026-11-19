// What the app does with one of its own `troupe://` links (troupe #959).
//
// A link is an address: which place, on which plane. The app goes there when it is signed
// in to that plane; when it is signed in to none, it goes to the sign-in screen with the
// address filled in and a sentence saying whose it is, and makes no request to that plane
// until the person presses Sign in; when it is signed in to another, it asks before it signs
// out of that one. A link that is not one of the three forms, or one for a plane while the
// app uses this computer only, is said in one line and nothing else happens.

import { TroupeRpcError, appLink, errorText, hostOf, isPlaceId, isRefused, parseAppLink, planeAddress } from "@troupe/client";
import type { AuthSession, RefusedLink } from "@troupe/client";

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

// -- the web app's own addresses --------------------------------------------------------
//
// The browser build takes a place from its address as the app takes one from a link: a
// fragment `#/session/<id>` or `#/artifact/<id>` under the app's base, read at load and when
// it changes in an open tab, and written back as the person moves, so the address bar is
// always a link to where they are. It names a place on the plane this web app is signed in
// to, and is followed as that plane's `troupe://` link would be (`stepFor`), so an address
// it will not open says so in the same line.
//
// A fragment that starts with `#/` is a place and nothing else; any other is parameters,
// where `#daemon=<port>:<token>` is the daemon endpoint `troupe-daemon open` hands over
// (`adoptFragment`, which takes it off the address and leaves a place alone). So the two
// never compete for one address: a place is never read out of parameters, and a fragment
// that carries both is not one Troupe writes.

/** A place an address names, or why it names none Troupe will open. */
export type AddressPlace = { kind: "session" | "artifact"; id: string } | RefusedLink;

const NOT_OPENED = "This address was not opened:";

/** The place a fragment names, its refusal, or null for a fragment that is not a place. */
export function placeOfAddress(hash: string): AddressPlace | null {
  if (!hash.startsWith("#/")) return null;
  const [kind, raw, ...rest] = hash.slice(2).split("/");
  if (!kind) return null;
  if ((kind !== "session" && kind !== "artifact") || rest.length > 0 || !raw) return { refused: `${NOT_OPENED} Troupe does not know that place.` };
  let id: string;
  try {
    id = decodeURIComponent(raw);
  } catch {
    return { refused: `${NOT_OPENED} its ${kind} is not an id.` };
  }
  if (!isPlaceId(id)) return { refused: `${NOT_OPENED} its ${kind} is not an id.` };
  return { kind, id };
}

/** The fragment for where the app is: a session, an artifact, or none. */
export function addressOf(place: LinkPlace): string {
  if (!place) return "";
  return place.screen === "session" ? `#/session/${encodeURIComponent(place.id)}` : `#/artifact/${encodeURIComponent(place.artifact)}`;
}

/**
 * What an address leads to, as its plane's link would: `plane` is the one this web app is
 * signed in to or would sign in to, null where it knows none yet, and then the place waits
 * for whichever sign-in comes (`wait`). Under Local only it names a plane all the same, so it
 * is said, as a link to a plane is.
 */
export function stepForAddress(place: AddressPlace, plane: string | null, context: LinkContext): LinkStep | { do: "wait"; then: Exclude<LinkPlace, null> } {
  if ("refused" in place) return { do: "say", sentence: place.refused };
  const then: Exclude<LinkPlace, null> = place.kind === "session" ? { screen: "session", id: place.id } : { screen: "artifacts", artifact: place.id };
  if (!plane) {
    if (context.localOnly) return { do: "say", sentence: `${NOT_OPENED} it is a ${place.kind} on a plane, and this app uses this computer only. Turn Local only off on This computer to open it.` };
    return { do: "wait", then };
  }
  return stepFor(appLink({ kind: place.kind, id: place.id, plane }), context);
}

/** Where an address waits across a sign-in that leaves the page (the browser's redirect), for this tab alone. */
const HELD_PLACE = "troupe.addressPlace";

/** The place this load's address names, or the one an earlier load of this tab held across its sign-in. */
export function takeAddressPlace(): AddressPlace | null {
  const told = placeOfAddress(globalThis.location?.hash ?? "");
  if (told) return told;
  try {
    const held = globalThis.sessionStorage?.getItem(HELD_PLACE);
    return held ? placeOfAddress(held) : null;
  } catch {
    return null;
  }
}

/** Keep `place` for the sign-in that may leave the page, or let go of it (null). */
export function holdAddressPlace(place: LinkPlace): void {
  try {
    if (place) globalThis.sessionStorage?.setItem(HELD_PLACE, addressOf(place));
    else globalThis.sessionStorage?.removeItem(HELD_PLACE);
  } catch {
    /* held for this load only */
  }
}

/**
 * Put where the person is on the address bar, without a new history entry or a load. Only a
 * fragment that is a place, or none, is replaced: anything else there is somebody else's.
 */
export function writeAddress(fragment: string): void {
  const at = globalThis.location;
  if (!at) return;
  if (at.hash && !at.hash.startsWith("#/")) return;
  if ((at.hash || "") === fragment) return;
  try {
    globalThis.history?.replaceState(globalThis.history.state, "", `${at.pathname}${at.search}${fragment}`);
  } catch {
    /* an address that cannot be rewritten stays as it was */
  }
}

/** What "Copy link" on a session puts on the clipboard; the console's Copy link writes the same. */
export { sessionLinkText } from "@troupe/client";

/** What an artifact's "Open session" says where the plane has no session of that id to show the person. */
export const SESSION_NOT_OPEN = "Published from a session you cannot open: it is gone, or it is not shared with you.";

/** What a link or an address to a session says where the plane has none of that id to show the person. */
export const SESSION_GONE = "This session cannot be opened: it is gone, or it is not shared with you.";

/**
 * Whether the session an artifact came from can be opened, asked once at the click: null
 * when it is in the app's own lists or the plane answers it, and the sentence otherwise. The
 * plane answers `not_found` alike for a session that is gone and for one not shared with
 * the person, so the sentence says both. Without a plane sign-in it is opened as its link
 * would open it, and the session's own screen says what it finds.
 */
export async function sessionNotOpen(id: string, listed: boolean, auth: AuthSession | null, gone: string = SESSION_NOT_OPEN): Promise<string | null> {
  if (listed || !auth) return null;
  try {
    await auth.withToken((plane, token) => plane.getSession(token, id));
    return null;
  } catch (e) {
    if (e instanceof TroupeRpcError && e.code === -32005) return gone;
    return `The session could not be opened: ${errorText(e)}`;
  }
}
