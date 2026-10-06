// What the browser cannot do, and what a shell around it can.
//
// The GUI is one web bundle. A browser build talks to a plane and stops there; a
// desktop shell adds exactly two things, and this module is the whole of the contract
// between them — so the views never branch on which one they are running in, they ask
// what is available.
//
// 1. The OS credential store, so the refresh token is not sitting in `localStorage`.
// 2. (Stage 2) the local daemon: reading `daemon.json` for its loopback port and token,
//    and starting it on demand. A browser cannot find them and has to be *told*:
//    `troupe-daemon open` puts them on the address it opens, or a person types them.

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
  /**
   * Where the daemon says it is now, starting nothing: what a dial after a dropped socket
   * reads, since a daemon that restarted serves a new port with a new token. Starting one
   * is `findDaemon`'s, which a person asks for; a daemon somebody stopped stays stopped.
   */
  readDaemon?: () => Promise<DaemonEndpoint | null>;
  /** Stage 2: pick a workspace directory. */
  pickDirectory?: () => Promise<string | null>;
  /**
   * The operating system's notifications. A browser has its own `Notification`, and a
   * webview has one that does nothing: WebView2 refuses the permission unless the host
   * answers for it. So a shell brings its own, and `notify.ts` prefers it.
   */
  notifications?: ShellNotifications;
}

export type NotifyPermission = "granted" | "denied" | "default";

export interface ShellNotifications {
  permission(): Promise<NotifyPermission>;
  request(): Promise<NotifyPermission>;
  /** Show one about `sessionId`, which a click on it opens where the shell hears clicks. */
  send(title: string, body: string, sessionId: string): Promise<void>;
  /**
   * Hear the shell ask for a session: a click on one of its notifications, or a second
   * launch that named one. Returns the function that stops listening. A shell that hears
   * no clicks, or a click it missed, leaves the window coming back as the answer.
   */
  onOpen?(listener: (sessionId: string) => void): () => void;
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
    // A shell finds the daemon; a browser build may have been told where it is
    // (`daemonHint`). Either way there are local sessions to show.
    localSessions: Boolean(s?.findDaemon) || daemonHint() !== null,
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

/** Where a browser build keeps the daemon's port and token between loads (Decision 797). */
const DAEMON_KEY = "troupe.daemon";

/**
 * The daemon endpoint a browser build was told.
 *
 * A page cannot read `daemon.json`, so it is told. `troupe-daemon open` opens the app at
 * `#daemon=<port>:<token>` (troupe #449): read here once, taken off the address bar so it
 * is neither bookmarked nor left on screen, and kept in `localStorage`, so a reload or a
 * new tab connects again. That is the one exception to the rule that the GUI persists
 * exactly one secret (Decision 797): the token changes every time the daemon starts, and
 * a stale one fails and the page says to run `troupe-daemon open` again. In development
 * `VITE_TROUPE_DAEMON=<port>:<token>` in `apps/desktop/.env.local` names one too, and wins:
 * it is the developer's file, not the app's storage.
 */
export function daemonHint(): DaemonEndpoint | null {
  const told = adoptFragment();
  const fromEnv = parseEndpoint((import.meta.env["VITE_TROUPE_DAEMON"] as string | undefined) ?? null);
  return fromEnv ?? told ?? storedDaemon();
}

/** `#daemon=` off the address bar and into this browser's storage, once. */
function adoptFragment(): DaemonEndpoint | null {
  const at = (globalThis as { location?: Location }).location;
  if (!at?.hash) return null;
  const params = new URLSearchParams(at.hash.replace(/^#/, ""));
  if (!params.has("daemon")) return null;
  const told = parseEndpoint(params.get("daemon"));
  params.delete("daemon");
  const rest = params.toString();
  try {
    globalThis.history?.replaceState(globalThis.history.state, "", `${at.pathname}${at.search}${rest ? `#${rest}` : ""}`);
  } catch {
    /* an address that cannot be rewritten keeps it; the connection is the same */
  }
  if (told) rememberDaemon(told);
  return told;
}

/** Keep where the daemon is for the next load, in a browser build. */
export function rememberDaemon(endpoint: DaemonEndpoint): void {
  try {
    globalThis.localStorage?.setItem(DAEMON_KEY, `${endpoint.port}:${endpoint.token}`);
  } catch {
    /* kept for this load only */
  }
}

/** Disconnecting forgets it, for this load and the next. */
export function forgetDaemon(): void {
  try {
    globalThis.localStorage?.removeItem(DAEMON_KEY);
  } catch {
    /* nothing was kept */
  }
}

function storedDaemon(): DaemonEndpoint | null {
  try {
    return parseEndpoint(globalThis.localStorage?.getItem(DAEMON_KEY) ?? null);
  } catch {
    return null;
  }
}

function parseEndpoint(value: string | null): DaemonEndpoint | null {
  const match = /^(\d+):(.+)$/.exec((value ?? "").trim());
  if (!match) return null;
  const port = Number(match[1]);
  if (!Number.isInteger(port) || port <= 0 || port > 65_535) return null;
  return { transport: "ws", port, token: match[2]! };
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
