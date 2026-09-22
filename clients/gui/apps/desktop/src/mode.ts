// Whether this app talks to a plane at all.
//
// Two modes, and every screen reads which one it is in rather than inferring it from
// whether somebody happens to be signed in:
//
//   plane   signed in to an organisation's Troupe. Team sessions, review, and the
//           sessions on this computer beside them.
//   local   the daemon on this computer and nothing else. No discovery document, no
//           token refresh, no plane call of any kind; the one thing that leaves the
//           machine is the daemon's own call to the model provider.
//
// Local is reached two ways. *Local only* is a setting a person turns on — the third door
// on the sign-in screen, or the switch on "This computer" — and it is remembered, so the
// next launch skips sign-in. *Offline* is plane mode with the plane not answering: the
// person chose to carry on here for now, the setting is untouched, and the app goes back
// to the plane by itself when it answers again.
//
// The setting lives in this browser's preferences for now, beside the theme. Shared
// settings (issue #57) are where it moves, so the TUI and the GUI agree about it.

import { prefs } from "./shell";

export type AppMode = "local" | "plane";

const KEY = "localOnly";

/**
 * Whether *Local only* is on.
 *
 * What the person chose wins. With no choice stored, a build can say what it starts in:
 * `pnpm dev:local` sets `VITE_TROUPE_LOCAL_ONLY=1`, so a development build against a
 * daemon opens on the session list instead of on a sign-in nobody can complete.
 */
export function storedLocalOnly(): boolean {
  const chosen = prefs.get(KEY);
  if (chosen === "yes") return true;
  if (chosen === "no") return false;
  return (import.meta.env["VITE_TROUPE_LOCAL_ONLY"] as string | undefined) === "1";
}

/** Remember the choice. Turning it on never touches a stored plane sign-in. */
export function chooseLocalOnly(on: boolean): void {
  prefs.set(KEY, on ? "yes" : "no");
}
