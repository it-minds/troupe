// The preferences that follow a person from one client to the other (troupe #57): the
// theme, light or dark, and notifications. The daemon keeps them as the `ui` keys of the
// user's `config.yaml`, beside the model settings, and acts on none of them; they are
// there so that a choice made in one window is the choice in the next.
//
// This window still keeps each in `prefs`, which is what draws the first frame before a
// daemon has answered and what a browser with no daemon has. The daemon's word wins when
// it has one: what a file sets is copied into `prefs` when the daemon is reached, and
// again whenever `config.changed` names a `ui` key, a key taken out included. A choice
// made here is written there too. What belongs to this device alone — the window, the
// plane it last used — stays in `prefs` and nowhere else.
//
// A daemon from before #57 is asked nothing: it would read a `config.set` with no
// provider as the model panel's, and write a provider nobody chose.

import { useEffect } from "react";
import { configKey, servesKeys } from "@troupe/client";
import type { DaemonClient, ModelConfig } from "@troupe/client";
import { prefs } from "./shell";

export type SharedPref = "theme" | "mode" | "notify";

const KEYS: Record<SharedPref, string> = { theme: "ui.theme", mode: "ui.mode", notify: "ui.notifications" };

// A pref is a string; `ui.notifications` is a boolean.
function asPref(name: SharedPref, value: unknown): string | null {
  if (name === "notify") return typeof value === "boolean" ? (value ? "on" : "off") : null;
  return typeof value === "string" ? value : null;
}

function asSetting(name: SharedPref, value: string): unknown {
  return name === "notify" ? value !== "off" : value;
}

/** The daemon reached, when it keeps these. */
let keeper: DaemonClient | null = null;
const listeners = new Set<() => void>();

/** Hear that the daemon changed one of these; read them again from `prefs`. */
export function onSharedChange(listener: () => void): () => void {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

/** A choice made in this window: kept here, and by the daemon when one keeps these. */
export function share(name: SharedPref, value: string): void {
  prefs.set(name, value);
  void keeper?.setSetting(KEYS[name], asSetting(name, value)).catch(() => undefined);
}

/**
 * Take what the daemon says. On first reaching it, only what a file sets: a choice made
 * here before there was anywhere to share it is not undone by a default. After that a
 * default too, since it means somebody took the choice out.
 */
function adopt(config: ModelConfig, defaults: boolean): void {
  let changed = false;
  for (const name of Object.keys(KEYS) as SharedPref[]) {
    const entry = configKey(config, KEYS[name]);
    if (!entry || (entry.layer === "default" && !defaults)) continue;
    const value = asPref(name, entry.value);
    if (value !== null && prefs.get(name) !== value) {
      prefs.set(name, value);
      changed = true;
    }
  }
  if (changed) for (const l of listeners) l();
}

/** The app's half: read when the daemon is reached, and again whenever a `ui` key changes. */
export function useSharedPrefs(client: DaemonClient | null): void {
  useEffect(() => {
    if (!client) return;
    let live = true;
    const read = (defaults: boolean): void => {
      client
        .modelConfig()
        .then((config) => {
          if (!live) return;
          keeper = servesKeys(config) ? client : null;
          if (keeper) adopt(config, defaults);
        })
        .catch(() => undefined);
    };
    read(false);
    const stop = client.onConfigChanged((changed) => {
      if (changed.keys.some((k) => k === "ui" || k.startsWith("ui."))) read(true);
    });
    return () => {
      live = false;
      stop();
      if (keeper === client) keeper = null;
    };
  }, [client]);
}
