// What the browser cannot do, and what a shell around it can.
//
// The GUI is one web bundle. A browser build talks to a plane and stops there; a
// desktop shell adds exactly two things, and this module is the whole of the contract
// between them — so the views never branch on which one they are running in, they ask
// what is available.
//
// 1. The OS credential store, so the refresh token is not sitting in `localStorage`.
// 2. (Stage 2) the local daemon: reading `daemon.json` for its loopback port and token,
//    and starting it on demand. A browser can be *told* those by hand but cannot find
//    them, which is why the browser build offers a dialog instead.

import { memoryTokenStore, webTokenStore } from "@troupe/client";
import type { TokenStore } from "@troupe/client";

export interface DaemonEndpoint {
  transport: "ws";
  port: number;
  token: string;
}

/** Implemented by the desktop shell and injected on `window` before the app starts. */
export interface TroupeShell {
  readonly name: string;
  readonly version: string;
  /** A store backed by the OS keychain. */
  secretStore?: TokenStore;
  /**
   * Open a URL in the person's real browser.
   *
   * A webview does nothing useful with `target="_blank"`, and the device grant is
   * unusable without it: the verification link has to leave this window.
   */
  openExternal?: (url: string) => Promise<void>;
  /**
   * HTTP from outside the webview.
   *
   * A shell has an origin of its own — `tauri://localhost` — so a plane would have to
   * name it in `TROUPE_CORS_ORIGINS`, per installation. A request made outside the
   * webview has no origin and no preflight, so there is nothing to configure.
   */
  fetchImpl?: typeof fetch;
  /**
   * Which sign-in this host can complete. A shell has no redirect worth coming back to,
   * whatever `AuthSession` would otherwise infer from it looking like a browser.
   */
  readonly signInFlow?: "redirect" | "device";
  /** Stage 2: find the daemon this machine is running, starting it if it is not. */
  findDaemon?: () => Promise<DaemonEndpoint | null>;
  /** Stage 2: pick a workspace directory. */
  pickDirectory?: () => Promise<string | null>;
}

declare global {
  interface Window {
    troupe?: TroupeShell;
  }
}

export function shell(): TroupeShell | null {
  return (globalThis as { window?: Window }).window?.troupe ?? null;
}

export interface Capabilities {
  /** How the refresh token is being kept, in words a person can act on. */
  secrets: "os-keychain" | "browser-storage" | "memory";
  /** Whether the local daemon can be found without being told where it is. */
  localSessions: boolean;
  shellName: string | null;
}

export function capabilities(): Capabilities {
  const s = shell();
  const hasStorage = (() => {
    try {
      return Boolean(globalThis.localStorage);
    } catch {
      return false;
    }
  })();
  return {
    secrets: s?.secretStore ? "os-keychain" : hasStorage ? "browser-storage" : "memory",
    localSessions: Boolean(s?.findDaemon),
    shellName: s?.name ?? null,
  };
}

/** The best store this host can offer. Never a worse one without saying so. */
export function tokenStore(): TokenStore {
  const s = shell();
  if (s?.secretStore) return s.secretStore;
  try {
    if (globalThis.localStorage) return webTokenStore();
  } catch {
    /* fall through */
  }
  return memoryTokenStore();
}

/**
 * Where this build is served from, as the identity provider must have it registered.
 *
 * Not `location.origin`: a GUI served at `/app` on the plane's own host shares that
 * origin with the plane, and a redirect URI of the bare origin would send the person to
 * the plane's root instead of back to the app. `BASE_URL` is what Vite was built with,
 * so this is the one string that is right in development and in a deployment.
 *
 * The trailing slash is dropped because a provider matches redirect URIs exactly and
 * `/app` is the address a person would be given.
 */
export function redirectUri(): string {
  const origin = (globalThis as { location?: { origin?: string } }).location?.origin ?? "";
  const base = import.meta.env.BASE_URL || "/";
  return base === "/" ? origin : `${origin}${base}`.replace(/\/+$/, "");
}

/**
 * The plane this build is most likely talking to.
 *
 * A GUI served at a sub-path — `/app` on the plane's own host — is same-origin with the
 * plane, so asking a person to type an address they are already looking at is a
 * question with one possible answer. A build served at its own root has no such
 * knowledge and must ask.
 */
export function likelyPlaneUrl(): string {
  const origin = (globalThis as { location?: { origin?: string } }).location?.origin ?? "";
  const mounted = (import.meta.env.BASE_URL || "/") !== "/";
  return mounted ? origin : "";
}

/** Plain preferences — a plane URL, the last filter. Never a credential. */
export const prefs = {
  get(key: string, fallback = ""): string {
    try {
      return globalThis.localStorage?.getItem(`troupe.pref.${key}`) ?? fallback;
    } catch {
      return fallback;
    }
  },
  set(key: string, value: string): void {
    try {
      globalThis.localStorage?.setItem(`troupe.pref.${key}`, value);
    } catch {
      /* preferences are a convenience */
    }
  },
};
