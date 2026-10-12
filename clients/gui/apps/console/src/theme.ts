// Light or dark, and nothing else: the console is drawn in Afterglow, the product's design,
// and offers no other palette. `data-theme` is fixed in index.html; `data-mode` is this
// person's choice, absent for "follow the system", which tokens.css answers on its own.
//
// Kept in this browser only. A mode carries no meaning and is nobody else's business,
// and a browser that keeps nothing (a private window, blocked storage) still renders,
// following the system.

import { useCallback, useState } from "react";

export type Mode = "system" | "light" | "dark";

const KEY = "troupe.console.mode";

export function storedMode(): Mode {
  try {
    const m = globalThis.localStorage?.getItem(KEY);
    return m === "light" || m === "dark" ? m : "system";
  } catch {
    return "system";
  }
}

export function applyMode(mode: Mode): void {
  const root = globalThis.document?.documentElement;
  if (!root) return;
  if (mode === "system") root.removeAttribute("data-mode");
  else root.setAttribute("data-mode", mode);
}

/** What the page shows now, which "follow the system" leaves to the system. */
export function shownMode(mode: Mode): "light" | "dark" {
  if (mode !== "system") return mode;
  return globalThis.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark";
}

export function useMode(): [Mode, (mode: Mode) => void] {
  const [mode, setMode] = useState<Mode>(storedMode);
  const choose = useCallback((next: Mode) => {
    applyMode(next);
    try {
      if (next === "system") globalThis.localStorage?.removeItem(KEY);
      else globalThis.localStorage?.setItem(KEY, next);
    } catch {
      // Nowhere to keep it; it holds for this page.
    }
    setMode(next);
  }, []);
  return [mode, choose];
}
