// Whether the window is a phone's: narrower than 720px, the width below which the
// stylesheet stacks every track. Most of the narrow layout is CSS alone; this is for the
// few things the markup itself changes there (the rail drawn as a top bar and a sheet,
// the backstage and the scratchpad one at a time). A media query's answer changes only
// when the width crosses the line, so nothing here re-renders on every resize.

import { useSyncExternalStore } from "react";

/** The narrow screen, as the stylesheet's `max-width: 719px` rules have it. */
export const NARROW_QUERY = "(max-width: 719px)";

function query(): MediaQueryList | null {
  return globalThis.matchMedia?.(NARROW_QUERY) ?? null;
}

function subscribe(changed: () => void): () => void {
  const q = query();
  if (!q) return () => undefined;
  q.addEventListener("change", changed);
  return () => q.removeEventListener("change", changed);
}

function narrowNow(): boolean {
  return query()?.matches ?? false;
}

/** True while the window is narrower than 720px. */
export function useNarrow(): boolean {
  return useSyncExternalStore(subscribe, narrowNow, () => false);
}
