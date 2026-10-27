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
import type { SignedAnswer, TokenStore } from "@troupe/client";

export interface DaemonEndpoint {
  transport: "ws";
  port: number;
  token: string;
}

/** Implemented by the desktop shell and injected on `window` before the app starts. */
export interface TroupeShell {
  readonly name: string;
  readonly version: string;
  /**
   * Where the app runs, in the daemon's words (`windows/x86_64`, `macos/aarch64`,
   * `linux/x86_64`): what its `initialize` to a plane gives as `client_info.platform`, so
   * the plane's record of who runs which version says where. A browser has none to say.
   */
  readonly platform?: string;
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
   * Open an agent's file in the person's own editor, the program their system opens a
   * Markdown file with (troupe #594). Only a person's or a repository's agent file: a `.md`
   * in an `agents` directory of `.troupe` or of Troupe's config, which the shell checks
   * where the file really is, so the page cannot open anything else through it. Rejects
   * with a sentence when it is not one, or nothing opens it.
   */
  openAgentFile?: (path: string) => Promise<void>;
  /**
   * Show an artifact from its own host (troupe #62): a window of the shell's own at `url`,
   * the one-time address `artifact.open` answered, granted nothing and kept on that host, one
   * per `key` (the artifact's id). The app never fetches an artifact into its own origin; a
   * browser build opens the address in a tab of its own instead.
   */
  openArtifactWindow?: (url: string, title: string, key: string) => Promise<void>;
  /**
   * Save a file the agent made for the person (troupe #765): the system's save dialog,
   * named `name` to start with, and `content` written where they chose. Answers the path
   * written, or null when they cancelled. A browser build downloads it instead
   * (`saveFile` below).
   */
  saveFile?: (name: string, content: string) => Promise<string | null>;
  /**
   * The operating system's notifications. A browser has its own `Notification`, and a
   * webview has one that does nothing: WebView2 refuses the permission unless the host
   * answers for it. So a shell brings its own, and `notify.ts` prefers it.
   */
  notifications?: ShellNotifications;
  /**
   * The app's own update (#66, Decision 874): a release whose signed manifest the shell
   * checks against the release keys it was built with, installed by the shell. A browser
   * build is updated where it is served, and has none.
   */
  updater?: ShellUpdater;
}

/** What a plane says may be installed, for the shell to hold an update to (Decision 868). */
export interface UpdatePlane {
  url: string;
  versions: Record<string, { recommended?: string | null; minimum?: string | null; blocked?: string[] }>;
  /**
   * The plane's signed version policy as it came (#657). With it, the shell checks the
   * signature itself against the key the daemon pinned for the plane, and reads the
   * versions and where releases are from it alone; `versions` is then not read.
   */
  signed?: SignedAnswer | null;
}

/** An update the shell found, checked, and can install. */
export interface UpdateOffer {
  version: string;
  current: string;
  /** The release the files come from. */
  source: string;
  /** The daemon the installers put beside the app, replaced with it. */
  daemon: { from: string; to: string; lib: string } | null;
  /** Why the daemon here is left as it is, when it is. */
  daemon_note: string | null;
  /** The terminal client the installers put here, replaced with it (Decision 959). */
  tui: { from: string; to: string; at: string } | null;
  tui_note: string | null;
  /** The VS Code extension `code` lists, installed again from the release. */
  extension: { from: string; to: string; at: string } | null;
  extension_note: string | null;
}

export type UpdateCheck = { state: "current"; version: string; current: string } | ({ state: "offer" } & UpdateOffer);

export interface ShellUpdater {
  /**
   * Find the release to move to — `version`, which a plane recommends, or the latest — and
   * say what an update would replace. Rejects with a sentence where the release cannot be
   * checked, or a plane does not serve it; nothing changes either way.
   */
  check(params: { version: string | null; plane: UpdatePlane | null }): Promise<UpdateCheck>;
  /** Download what the check offered and check it against the release key and the manifest. */
  download(onProgress?: (received: number, total: number | null) => void): Promise<void>;
  /**
   * Install it: the daemon's release swapped in, then the app, which restarts. Called once
   * the person said so and no turn here is at work; `daemonStopped` says the daemon was
   * asked to stop between turns and said it would.
   */
  install(daemonStopped: boolean): Promise<void>;
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

/**
 * Save a file on this computer: the shell's save dialog, or in a browser a download of it
 * under `name`, which the browser puts where it puts downloads. Answers where it went, as
 * far as the page can know, or null when the person cancelled.
 */
export async function saveFile(name: string, content: string): Promise<string | null> {
  const s = shell();
  if (s?.saveFile) return await s.saveFile(name, content);
  const url = URL.createObjectURL(new Blob([content], { type: "application/octet-stream" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  // Let go of it once the browser has had time to start the download.
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
  return name;
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

/**
 * `#daemon=` off the address bar and into this browser's storage, once: at a load, and when
 * the fragment is set in a tab already open (`hashchange`), as a pasted address does.
 */
export function adoptFragment(): DaemonEndpoint | null {
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
