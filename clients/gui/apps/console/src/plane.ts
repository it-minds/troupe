// How the console signs in, and where it keeps the sign-in.
//
// The plane's own sign-in and nothing new: the identity provider's authorization code flow
// with PKCE, the plane's `/auth/exchange`, and the same short-lived plane token every
// client holds. Nothing in that token says "administrator". The plane decides who
// administers what on every `admin.*` call, from the provider's groups and the teams a
// platform admin named somebody on, so a role taken away holds at the next call rather
// than at the token's expiry, and the console cannot claim a role it was not given.
//
// The refresh token is kept in this tab's `sessionStorage`, not `localStorage`: it is an
// administrator's sign-in, and one that ends when the tab does is one fewer thing left
// behind on a shared machine. A reload keeps it; a new tab signs in again, which against a
// provider the person is already signed in to is a redirect and back. Under keys of its
// own, apart from the desktop app's browser build on the same host, so signing out of one
// is not signing out of the other.

import { AuthSession } from "@troupe/client";
import type { TokenStore } from "@troupe/client";

const PLANE_KEY = "troupe.console.planeUrl";

/** A token store over this tab's session storage, or memory where there is none. */
export function tabTokenStore(): TokenStore {
  const held = new Map<string, string>();
  const storage = (): Storage | null => {
    try {
      return globalThis.sessionStorage ?? null;
    } catch {
      return null;
    }
  };
  const key = (k: string) => `troupe.console.auth.${k}`;
  return {
    async read(k) {
      try {
        return storage()?.getItem(key(k)) ?? held.get(k) ?? null;
      } catch {
        return held.get(k) ?? null;
      }
    },
    async write(k, v) {
      held.set(k, v);
      try {
        storage()?.setItem(key(k), v);
      } catch {
        // Memory alone, for this page.
      }
    },
    async clear(k) {
      held.delete(k);
      try {
        storage()?.removeItem(key(k));
      } catch {
        // Nothing kept to clear.
      }
    },
  };
}

/** An `AuthSession` for this plane: the redirect, always, since the console is a page. */
export function newSession(planeUrl: string, store: TokenStore = tabTokenStore()): AuthSession {
  return new AuthSession({ planeUrl, store, flow: "redirect" });
}

/**
 * Where this build is served from, as the identity provider must have it registered:
 * the origin and the path the bundle was built for, without the trailing slash, so
 * `https://plane.example.com/console` rather than the plane's own root.
 */
export function redirectUri(): string {
  const origin = (globalThis as { location?: { origin?: string } }).location?.origin ?? "";
  const base = import.meta.env.BASE_URL || "/";
  return base === "/" ? origin : `${origin}${base}`.replace(/\/+$/, "");
}

/**
 * The plane this console administers. Served at a path on the plane's own host, that is
 * the page's own origin, and there is nothing to ask. Served at its own root (in
 * development), it is the address last signed in to, or nothing yet.
 */
export function likelyPlaneUrl(): string {
  const origin = (globalThis as { location?: { origin?: string } }).location?.origin ?? "";
  if ((import.meta.env.BASE_URL || "/") !== "/") return origin;
  try {
    return globalThis.localStorage?.getItem(PLANE_KEY) ?? "";
  } catch {
    return "";
  }
}

export function rememberPlane(url: string): void {
  if ((import.meta.env.BASE_URL || "/") !== "/") return;
  try {
    globalThis.localStorage?.setItem(PLANE_KEY, url);
  } catch {
    // Asked again next time.
  }
}

const RETURN_KEY = "troupe.console.returnTo";

/**
 * Keep the place a person asked for across the provider's page and back. The redirect URI
 * is registered without a fragment, so the provider sends the browser back to the bare
 * address and a deep link would otherwise land on the first screen. Kept in this tab's
 * storage, as the sign-in's own verifier is.
 */
export function rememberPlace(hash: string): void {
  try {
    if (hash && hash !== "#") globalThis.sessionStorage?.setItem(RETURN_KEY, hash);
    else globalThis.sessionStorage?.removeItem(RETURN_KEY);
  } catch {
    // Lands on the first screen instead.
  }
}

/** Put the kept place back in the address, once, unless the address already names one. */
export function restorePlace(): void {
  try {
    const hash = globalThis.sessionStorage?.getItem(RETURN_KEY);
    globalThis.sessionStorage?.removeItem(RETURN_KEY);
    const { location, history } = globalThis;
    if (!hash || !location || !history?.replaceState || (location.hash && location.hash !== "#")) return;
    history.replaceState(history.state, "", `${location.pathname}${location.search}${hash}`);
  } catch {
    // Lands on the first screen instead.
  }
}

