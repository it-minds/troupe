// The desktop shell's half of the `TroupeShell` contract in `shell.ts`.
//
// This module is the *only* place in the bundle that imports a Tauri API, and it is
// loaded dynamically from `main.tsx` when — and only when — the app is running inside
// the shell. A browser build never evaluates it: Vite splits it into its own chunk that
// is never fetched. So the views go on asking `capabilities()` what is available, and
// nothing branches on which host it is in.
//
// Three things, and a process is needed for each:
//
//   secretStore   the machine's sign-in: `credentials.json` in the Troupe config
//                 directory, the file `troupe login` writes, readable by the person
//                 alone, so the terminal client, this app and the daemon share one
//                 sign-in (Decision 958). A tab's best offer is `localStorage`, which
//                 is the one place a refresh token must not be. The OS credential
//                 store, where earlier releases kept it, is read once to move a
//                 sign-in over.
//   openExternal  a webview does nothing useful with `target="_blank"`, and the device
//                 grant is unusable unless its link reaches a real browser.
//   fetchImpl     HTTP from outside the webview, so a plane needs no CORS entry for
//                 `tauri://localhost` — an origin every installation would otherwise
//                 have to be told about.
//
//   findDaemon    the daemon on this computer publishes its port and token into a file
//   readDaemon    outside anything a page may open, and a page cannot start a program
//   pickDirectory a workspace is a directory, and a browser build can only take a path
//                 somebody typed
//   openAgentFile a person's or a repository's agent file, in the editor their system
//                 opens Markdown with; a page cannot start a program
//   notifications the page's own `Notification` is refused in WebView2, so the OS's are
//                 reached through the notification plugin, and on Windows through the
//                 shell's own toast, whose click is heard
//   updater       the app's own update: a release the shell checks against the release
//                 keys it was built with, then installs, restarting the app

import type { DaemonEndpoint, TokenStore } from "@troupe/client";
import type { NotifyPermission, ShellNotifications, ShellUpdater, TroupeShell, UpdateCheck } from "./shell";

/** True inside a Tauri webview. v2 injects this before any of our code runs. */
export function inTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** The plane a store key names: `AuthSession` keys the refresh token `refresh:<plane>`. */
function planeOf(key: string): string {
  return key.startsWith("refresh:") ? key.slice("refresh:".length) : key;
}

/**
 * The sign-in shared with the TUI, reached through commands rather than a filesystem
 * plugin: a command can hold exactly one plane and no path, which is a narrower thing to
 * have granted than "read and write files".
 *
 * A sign-in an earlier release kept in the OS credential store is moved into the file the
 * first time it is asked for and the file has none, and cleared from the store, so that
 * one copy rotates and no stale one is left to be refused. The lock is the machine's
 * (`credentials.lock`), held by whichever client is refreshing: providers rotate the
 * token on use, and two clients refreshing one token at once would have the second
 * refused, and the sign-in with it.
 */
function signInStore(): TokenStore {
  return {
    async read(key: string) {
      const { invoke } = await import("@tauri-apps/api/core");
      const plane = planeOf(key);
      const shared = await invoke<string | null>("signin_get", { planeUrl: plane });
      if (shared) return shared;
      const kept = await invoke<string | null>("secret_get", { key }).catch(() => null);
      if (!kept) return null;
      await invoke("signin_set", { planeUrl: plane, refreshToken: kept });
      await invoke("secret_delete", { key }).catch(() => undefined);
      return kept;
    },
    async write(key: string, value: string) {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("signin_set", { planeUrl: planeOf(key), refreshToken: value });
    },
    async clear(key: string) {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("signin_clear", { planeUrl: planeOf(key) });
      await invoke("secret_delete", { key }).catch(() => undefined);
    },
    async lock<T>(_key: string, f: () => Promise<T>) {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("signin_lock");
      try {
        return await f();
      } finally {
        await invoke("signin_unlock").catch(() => undefined);
      }
    },
  };
}

/** The plane this machine is signed in to by default: `credentials.json`'s `current`. */
async function signedInPlane(): Promise<string | null> {
  const { invoke } = await import("@tauri-apps/api/core");
  return (await invoke<string | null>("signin_current")) ?? null;
}

/**
 * The daemon on this computer, started if it is not running.
 *
 * Straight to `daemon_start`, which returns a daemon that answers where `daemon.json`
 * says without starting anything, and starts one over a file that names a port nothing
 * listens on. Reading the file first returned that dead port whenever a daemon had been
 * killed or had crashed, since only a clean stop removes the file, and the app dialled
 * it at every launch and at every press of Find. Starting is safe to ask for regardless:
 * the daemon takes a lock, so two callers produce one daemon rather than a race.
 */
async function findDaemon(): Promise<DaemonEndpoint | null> {
  const { invoke } = await import("@tauri-apps/api/core");
  return (await invoke<DaemonEndpoint | null>("daemon_start", { binary: null })) ?? null;
}

/**
 * What `daemon.json` says now, and nothing started or probed: what the client reads
 * before dialling again after the socket dropped, which is how a daemon that restarted
 * on a new port with a new token is found without a person.
 */
async function readDaemon(): Promise<DaemonEndpoint | null> {
  const { invoke } = await import("@tauri-apps/api/core");
  return (await invoke<DaemonEndpoint | null>("daemon_endpoint")) ?? null;
}

/** An agent's file in the person's editor: `agent_file_open`, a command of ours that opens nothing else. */
async function openAgentFile(path: string): Promise<void> {
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("agent_file_open", { path });
}

/** An artifact in a window of its own at its host's one-time address: `artifact_window_open`, which grants that window nothing. */
async function openArtifactWindow(url: string, title: string, key: string): Promise<void> {
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("artifact_window_open", { url, title, key });
}

/** A file saved where the person chose in the system's dialog: `file_save`, a command of ours that writes only that path. */
async function saveFile(name: string, content: string): Promise<string | null> {
  const { invoke } = await import("@tauri-apps/api/core");
  return (await invoke<string | null>("file_save", { name, content })) ?? null;
}

async function pickDirectory(): Promise<string | null> {
  const { open } = await import("@tauri-apps/plugin-dialog");
  const chosen = await open({ directory: true, multiple: false, title: "Choose a workspace" });
  return typeof chosen === "string" ? chosen : null;
}

/**
 * The OS's notifications. On a desktop the plugin grants without asking, since the OS
 * has its own switch for each app; the question is still asked the same way, so a shell
 * that one day must ask is answered by the same code.
 *
 * On Windows the shell shows the toast itself (`notify_show`), so that a click on it is
 * heard and opens its session; elsewhere, and if that fails, the plugin shows it and no
 * click is heard. A second launch of the app that names a session asks the same way.
 */
function notifications(): ShellNotifications {
  const plugin = () => import("@tauri-apps/plugin-notification");
  const state = (s: string): NotifyPermission => (s === "granted" || s === "denied" ? s : "default");
  return {
    // The plugin's page script reads "denied" on Windows at every start until something
    // asks, and asking shows nothing on a desktop, the OS keeping a switch per app. So
    // asking is how to read it: otherwise every launch after the first would wait for
    // an answer it had been given already, and say nothing.
    async permission() {
      const p = await plugin();
      return (await p.isPermissionGranted()) ? "granted" : state(await p.requestPermission());
    },
    async request() {
      return state(await (await plugin()).requestPermission());
    },
    async send(title, body, sessionId) {
      const { invoke } = await import("@tauri-apps/api/core");
      const shown = await invoke<boolean>("notify_show", { title, body, session: sessionId }).catch(() => false);
      if (!shown) (await plugin()).sendNotification({ title, body });
    },
    onOpen(listener) {
      let stop: (() => void) | null = null;
      let stopped = false;
      void import("@tauri-apps/api/event")
        .then(({ listen }) => listen<string>("troupe://open-session", (e) => listener(e.payload)))
        .then((unlisten) => {
          if (stopped) unlisten();
          else stop = unlisten;
        })
        .catch(() => undefined);
      return () => {
        stopped = true;
        stop?.();
      };
    },
  };
}

/**
 * The app's own update, three commands of the shell's (`src-tauri/src/update.rs`): the
 * release and its keys are the shell's to find and check, so none of them takes a URL, a
 * path or a key from the page.
 */
function updater(): ShellUpdater {
  return {
    async check(params) {
      const { invoke } = await import("@tauri-apps/api/core");
      return invoke<UpdateCheck>("update_check", { params });
    },
    async download(onProgress) {
      const [{ invoke }, { listen }] = await Promise.all([import("@tauri-apps/api/core"), import("@tauri-apps/api/event")]);
      const stop = onProgress
        ? await listen<{ received: number; total: number | null }>("troupe://update-progress", (e) => onProgress(e.payload.received, e.payload.total))
        : null;
      try {
        await invoke("update_download");
      } finally {
        stop?.();
      }
    },
    async install(daemonStopped) {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("update_install", { daemonStopped });
    },
  };
}

/**
 * Install the shell on `window.troupe`, which is where `shell.ts` looks for it.
 * Called from `main.tsx` before the app renders, and only inside the shell.
 */
export async function installShell(): Promise<void> {
  if (!inTauri()) return;
  const [{ getVersion }, { fetch: rustFetch }, { openUrl }] = await Promise.all([
    import("@tauri-apps/api/app"),
    import("@tauri-apps/plugin-http"),
    import("@tauri-apps/plugin-opener"),
  ]);

  // Where the app runs, as the daemon's own handshake with a plane says it.
  const platform = await import("@tauri-apps/api/core")
    .then(({ invoke }) => invoke<string>("shell_platform"))
    .catch(() => null);

  const shell: TroupeShell = {
    name: "Troupe Desktop",
    version: await getVersion().catch(() => "0.0.0"),
    ...(platform ? { platform } : {}),
    secretStore: signInStore(),
    secrets: "config-file",
    signedInPlane,
    openExternal: (url) => openUrl(url),
    fetchImpl: rustFetch as typeof fetch,
    // Not inferred: a webview has a `location` and Web Crypto, so it looks like a
    // browser to `AuthSession`, while its origin is one no provider will have
    // registered as a redirect URI.
    signInFlow: "device",
    findDaemon,
    readDaemon,
    pickDirectory,
    openAgentFile,
    openArtifactWindow,
    saveFile,
    notifications: notifications(),
    updater: updater(),
  };
  (globalThis as { window?: Window }).window!.troupe = shell;
}
