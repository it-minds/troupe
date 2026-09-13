// The desktop shell's half of the `TroupeShell` contract in `shell.ts`.
//
// This module is the *only* place in the bundle that imports a Tauri API, and it is
// loaded dynamically from `main.tsx` when — and only when — the app is running inside
// the shell. A browser build never evaluates it: Vite splits it into its own chunk that
// is never fetched. So the views go on asking `capabilities()` what is available, and
// nothing branches on which host it is in.
//
// What the shell adds, and why each one needs a process rather than a tab:
//
//   secretStore   the OS credential store — Windows Credential Manager, the macOS
//                 Keychain, the Secret Service on Linux. A tab's best offer is
//                 `localStorage`, which is the one place a refresh token must not be.
//   openExternal  a webview does nothing useful with `target="_blank"`, and the device
//                 grant is unusable unless its link reaches a real browser.
//   deep links    `troupe://enrol?plane=…`, so the web client can hand this app a plane
//                 URL after the person has already signed in there.
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

/** Open a URL in the person's real browser, not in this window. */
export async function openExternal(url: string): Promise<void> {
  const { openUrl } = await import("@tauri-apps/plugin-opener");
  await openUrl(url);
}

/**
 * A `troupe://enrol?plane=…` link, from the OS.
 *
 * Untrusted: any web page can cause one to fire. The caller is expected to *show* the
 * plane rather than sign in to it, so this validates the shape and hands back a URL to
 * put in a field — never anything that authenticates by itself.
 */
export function readEnrolment(raw: string): { planeUrl: string } | { error: string } {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return { error: `not a URL: ${raw}` };
  }
  if (url.protocol !== "troupe:") return { error: `not a troupe link: ${url.protocol}` };
  // `troupe://enrol?plane=…` parses with "enrol" as the host, not the path.
  const action = url.host || url.pathname.replace(/^\/+/, "");
  if (action !== "enrol" && action !== "enroll") return { error: `unknown troupe link: ${action}` };

  const plane = url.searchParams.get("plane");
  if (!plane) return { error: "the link carried no plane URL" };
  let parsed: URL;
  try {
    parsed = new URL(plane);
  } catch {
    return { error: `the link's plane URL is not a URL: ${plane}` };
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
    return { error: `a plane URL must be http or https, not ${parsed.protocol}` };
  }
  return { planeUrl: parsed.origin + parsed.pathname.replace(/\/+$/, "") };
}

/** The `troupe://` URL this process was launched with, if any. */
export async function initialEnrolment(): Promise<string | null> {
  const { getCurrent } = await import("@tauri-apps/plugin-deep-link");
  const urls = await getCurrent();
  return urls?.[0] ?? null;
}

/** `troupe://` URLs delivered while the app is already running. Returns an unsubscribe. */
export async function onEnrolment(handler: (raw: string) => void): Promise<() => void> {
  const { onOpenUrl } = await import("@tauri-apps/plugin-deep-link");
  return await onOpenUrl((urls) => {
    const first = urls?.[0];
    if (first) handler(first);
  });
}

/**
 * Install the shell on `window.troupe`, which is where `shell.ts` looks for it.
 * Called from `main.tsx` before the app renders, and only inside the shell.
 */
export async function installShell(): Promise<void> {
  if (!inTauri()) return;
  const { getVersion } = await import("@tauri-apps/api/app");
  const shell: TroupeShell = {
    name: "Troupe Desktop",
    version: await getVersion().catch(() => "0.0.0"),
    secretStore: keychainStore(),
  };
  (globalThis as { window?: Window }).window!.troupe = shell;
}
