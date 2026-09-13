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
// Stage 2's `findDaemon` and `pickDirectory` belong here too; they are named in
// `shell.ts` and deliberately absent until the daemon exists to be found.

import type { TokenStore } from "@troupe/client";
import type { TroupeShell } from "./shell";

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
  };
  (globalThis as { window?: Window }).window!.troupe = shell;
}
