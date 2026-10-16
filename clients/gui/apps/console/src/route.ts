// Where in the console a person is, as the address after `#`: a deep link to every screen
// and every team's tab (`#/teams/core/limits`), that a reload, a bookmark and the back
// button all keep. In the fragment rather than the path so it means the same wherever the
// bundle is mounted, and so the server is never asked for a page that only exists here.

import { useEffect, useState } from "react";

export const TEAM_TABS = ["members", "access", "admins", "limits", "github", "danger"] as const;
export type TeamTab = (typeof TEAM_TABS)[number];

export interface Route {
  /** A nav entry's id: `teams`, `clients`, `organisation`, or an area not built yet. */
  page: string;
  team?: string;
  tab?: TeamTab;
  /**
   * What within the area, for an area other than Teams: a profile (`#/profiles/dev`), a
   * channel and a version (`#/bundles/stable/2`), a team's triggers and one of them
   * (`#/triggers/core/nightly-deps`).
   */
  path?: string[];
}

export function parse(hash: string): Route | null {
  const parts = hash
    .replace(/^#\/?/, "")
    .split("/")
    .filter(Boolean)
    .map((p) => decodeURIComponent(p));
  const [page, team, tab] = parts;
  if (!page) return null;
  if (page === "teams" && team) {
    return { page, team, tab: (TEAM_TABS as readonly string[]).includes(tab ?? "") ? (tab as TeamTab) : "members" };
  }
  if (page !== "teams" && parts.length > 1) return { page, path: parts.slice(1) };
  return { page };
}

export function href(route: Route): string {
  const parts = [route.page, route.team, route.team ? (route.tab ?? "members") : undefined, ...(route.team ? [] : (route.path ?? []))].filter((p): p is string => Boolean(p));
  return `#/${parts.map((p) => encodeURIComponent(p)).join("/")}`;
}

export function go(route: Route): void {
  globalThis.location.hash = href(route);
}

/** The route the address says, or `fallback` where it says none. */
export function useRoute(fallback: Route): Route {
  const [route, setRoute] = useState<Route>(() => parse(globalThis.location?.hash ?? "") ?? fallback);
  useEffect(() => {
    const on = () => setRoute(parse(globalThis.location?.hash ?? "") ?? fallback);
    globalThis.addEventListener("hashchange", on);
    return () => globalThis.removeEventListener("hashchange", on);
  }, [fallback]);
  return route;
}
