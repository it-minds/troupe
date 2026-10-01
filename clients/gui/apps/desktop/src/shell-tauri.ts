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
//   secretStore   the OS credential store — Windows Credential Manager, the macOS
//                 Keychain, the Secret Service on Linux. A tab's best offer is
//                 `localStorage`, which is the one place a refresh token must not be.
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
//   notifications the page's own `Notification` is refused in WebView2, so the OS's are
//                 reached through the notification plugin, and on Windows through the
//                 shell's own toast, whose click is heard

import type { DaemonEndpoint, TokenStore } from "@troupe/client";
import type { NotifyPermission, ShellNotifications, TroupeShell } from "./shell";

/** True inside a Tauri webview. v2 injects this before any of our code runs. */
export function inTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/**
 * The OS credential store, reached through three commands rather than a filesystem
 * plugin: a command can hold exactly one key and no path, which is a narrower thing to
 * have granted than "read and write files".
 */
function keychainStore(): TokenStore {
  return {
    async read(key: string) {
      const { invoke } = await import("@tauri-apps/api/core");
      return await invoke<string | null>("secret_get", { key });
    },
    async write(key: string, value: string) {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("secret_set", { key, value });
    },
    async clear(key: string) {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("secret_delete", { key });
    },
  };
}

/**
 * The daemon on this computer, started if it is not running.
 *
 * Reading first and starting second, because the common case is that it is already up —
 * a `troupe` session in a terminal, or the last time this app was opened. Starting is
 * safe to ask for regardless: the daemon takes a lock, so two callers produce one
 * daemon rather than a race.
 */
async function findDaemon(): Promise<DaemonEndpoint | null> {
  const running = await readDaemon();
  if (running) return running;
  const { invoke } = await import("@tauri-apps/api/core");
  return (await invoke<DaemonEndpoint | null>("daemon_start", { binary: null })) ?? null;
}

/**
 * What `daemon.json` says now, and nothing started: the first half of `findDaemon`, and
 * what the client reads before dialling again after the socket dropped, which is how a
 * daemon that restarted on a new port with a new token is found without a person.
 */
async function readDaemon(): Promise<DaemonEndpoint | null> {
  const { invoke } = await import("@tauri-apps/api/core");
  return (await invoke<DaemonEndpoint | null>("daemon_endpoint")) ?? null;
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

  const shell: TroupeShell = {
    name: "Troupe Desktop",
    version: await getVersion().catch(() => "0.0.0"),
    secretStore: keychainStore(),
    openExternal: (url) => openUrl(url),
    fetchImpl: rustFetch as typeof fetch,
    // Not inferred: a webview has a `location` and Web Crypto, so it looks like a
    // browser to `AuthSession`, while its origin is one no provider will have
    // registered as a redirect URI.
    signInFlow: "device",
    findDaemon,
    readDaemon,
    pickDirectory,
    notifications: notifications(),
  };
  (globalThis as { window?: Window }).window!.troupe = shell;
}
