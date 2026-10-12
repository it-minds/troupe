// The console's frame: the map down the side, grouped Watch, Configure, Operate and
// Govern; the screen's place and name across the top; and at the foot of the map who is
// signed in, as which role, to which plane, with the light and dark switch and the way out.

import { useEffect } from "react";
import type { JSX } from "react";
import { area, groupOf, navFor } from "../nav";
import { href, useRoute } from "../route";
import type { Route } from "../route";
import { useConsole } from "../console";
import { shownMode, useMode } from "../theme";
import { Wordmark } from "./brand";
import { ClientVersions } from "./ClientVersions";
import { Organisation } from "./Organisation";
import { Team } from "./Team";
import { Teams } from "./Teams";
import { Unbuilt } from "./Unbuilt";

const START: Route = { page: "teams" };

export function Shell(): JSX.Element {
  const signed = useConsole();
  const route = useRoute(START);
  const [mode, setMode] = useMode();
  const nav = navFor(signed.role);
  // An area this role is not shown is not reachable by its address either.
  const here = nav.some((g) => g.areas.some((a) => a.id === route.page)) ? route : START;
  const current = area(here.page)!;
  const title = here.team ?? current.label;
  const crumb = here.team ? `${groupOf(here.page)} / Teams` : groupOf(here.page);

  useEffect(() => {
    globalThis.document.title = `${title} · Troupe console`;
  }, [title]);

  // A new screen starts at its top, not wherever the last one was scrolled to.
  useEffect(() => {
    globalThis.scrollTo?.(0, 0);
  }, [here.page, here.team, here.tab]);

  return (
    <div className="console">
      <nav className="rail" aria-label="Console">
        <a className="home" href={href(START)} aria-label="Troupe console">
          <Wordmark size={26} />
        </a>
        {nav.map((g) => (
          <div key={g.label} className="group">
            <span className="screen">{g.label}</span>
            {g.areas.map((a) => (
              <a key={a.id} href={href({ page: a.id })} aria-current={a.id === here.page ? "page" : undefined} className={a.built ? "built" : "later"}>
                {a.label}
                {!a.built && (
                  <span className="later-mark" title="In the plane's current console, for now">
                    <span aria-hidden="true"> ↗</span>
                    <span className="visually-hidden"> (in the current console)</span>
                  </span>
                )}
              </a>
            ))}
          </div>
        ))}
        <div className="who">
          <span className="person">{signed.me.display_name ?? signed.me.subject}</span>
          <span className="mono subject">{signed.me.email ?? signed.me.subject}</span>
          <span className={`role ${signed.role}`}>
            {signed.role === "platform_admin" ? "platform admin" : `team admin · ${signed.teams.join(", ")}`}
          </span>
          <span className="mono plane" title={signed.plane.url}>
            {signed.plane.name} · {hostOf(signed.plane.url)}
            {signed.plane.version ? ` · ${signed.plane.version}` : ""}
          </span>
          <div className="who-actions">
            <button type="button" onClick={() => setMode(shownMode(mode) === "dark" ? "light" : "dark")}>
              {shownMode(mode) === "dark" ? "Light" : "Dark"}
            </button>
            <button type="button" onClick={signed.signOut}>
              Sign out
            </button>
          </div>
          <span className="mono version">console {__TROUPE_VERSION__}</span>
        </div>
      </nav>
      <main className="main">
        <header className="head">
          <span className="crumb">{crumb}</span>
          <h1>{title}</h1>
        </header>
        <Screen route={here} />
      </main>
    </div>
  );
}

function Screen({ route }: { route: Route }): JSX.Element {
  if (route.page === "teams" && route.team) return <Team name={route.team} tab={route.tab ?? "members"} />;
  if (route.page === "teams") return <Teams />;
  if (route.page === "clients") return <ClientVersions />;
  if (route.page === "organisation") return <Organisation />;
  return <Unbuilt area={area(route.page)!} />;
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}
