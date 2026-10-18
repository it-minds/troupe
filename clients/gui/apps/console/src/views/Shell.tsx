// The console's frame: the map down the side, grouped Watch, Configure, Operate and
// Govern; the screen's place and name across the top; and at the foot of the map who is
// signed in, as which role, to which plane, with the light and dark switch and the way out.
//
// At a narrow width the map goes above the screen, folded behind one button, so the screen
// a person opened is what they see first rather than eighteen links; choosing an area
// folds it again.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { area, groupOf, navFor } from "../nav";
import { href, useRoute } from "../route";
import type { Route } from "../route";
import { useConsole } from "../console";
import { shownMode, useMode } from "../theme";
import { Wordmark } from "./brand";
import { Audit } from "./Audit";
import { Budgets } from "./Budgets";
import { Bundles, Channel, Version } from "./Bundles";
import { ClientVersions } from "./ClientVersions";
import { Connections } from "./Connections";
import { Hosts } from "./Hosts";
import { Identity } from "./Identity";
import { IdentityProvider } from "./IdentityProvider";
import { Integrations } from "./Integrations";
import { Pods } from "./Pods";
import { Policy } from "./Policy";
import { Profile, Profiles } from "./Profiles";
import { TriggerPage, Triggers } from "./Triggers";
import { Organisation } from "./Organisation";
import { Overview } from "./Overview";
import { RunPage, Runs } from "./Runs";
import { RemoteSession } from "./Remote";
import { Sessions } from "./Sessions";
import { Team } from "./Team";
import { Teams } from "./Teams";
import { Unbuilt } from "./Unbuilt";

const START: Route = { page: "overview" };

export function Shell(): JSX.Element {
  const signed = useConsole();
  const route = useRoute(START);
  const [mode, setMode] = useMode();
  const nav = navFor(signed.role);
  // An area this role is not shown is not reachable by its address either.
  const here = nav.some((g) => g.areas.some((a) => a.id === route.page)) ? route : START;
  const current = area(here.page)!;
  const within = here.path ?? [];
  const title = here.team ?? titleWithin(here.page, within) ?? current.label;
  const crumb = here.team ? `${groupOf(here.page)} / Teams` : within.length ? `${groupOf(here.page)} / ${current.label}` : groupOf(here.page);
  // The folded map is open on the screen it was opened on, so choosing an area folds it
  // again with nothing to fold it. An effect that folded it on each new screen also ran
  // once the shell first drew, and undid a Menu pressed before that.
  const screen = `${here.page}/${here.team ?? ""}/${here.tab ?? ""}/${within.join("/")}`;
  const [openOn, setOpenOn] = useState<string | null>(null);
  const open = openOn === screen;

  useEffect(() => {
    globalThis.document.title = `${title} · Troupe console`;
  }, [title]);

  // A new screen starts at its top, not wherever the last one was scrolled to.
  useEffect(() => {
    globalThis.scrollTo?.(0, 0);
  }, [here.page, here.team, here.tab, within.join("/")]);

  return (
    <div className="console">
      <nav className={`rail${open ? " open" : ""}`} aria-label="Console">
        <div className="top">
          <a className="home" href={href(START)} aria-label="Troupe console">
            <Wordmark size={26} />
          </a>
          <button type="button" className="menu" aria-expanded={open} aria-controls="console-map" onClick={() => setOpenOn(open ? null : screen)}>
            {open ? "Close" : "Menu"}
            <span className="visually-hidden"> the console's map</span>
          </button>
        </div>
        <div className="map" id="console-map">
          {nav.map((g) => (
            <div key={g.label} className="group">
              <span className="screen">{g.label}</span>
              {g.areas.map((a) => (
                <a key={a.id} href={href({ page: a.id })} aria-current={a.id === here.page ? "page" : undefined} className={a.built ? "built" : "later"}>
                  {a.label}
                  {!a.built && (
                    <span className="later-mark" title="Not in this console yet">
                      <span aria-hidden="true"> ○</span>
                      <span className="visually-hidden"> (not in this console yet)</span>
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

/** A screen within an area is named by what it shows: a profile, a channel and its version, a trigger. */
function titleWithin(page: string, path: string[]): string | null {
  const [first, second] = path;
  if (!first) return null;
  if (page === "bundles") return second ? `${first} v${second}` : first;
  if (page === "triggers") return second ?? null;
  if (page === "runs") return "A run";
  if (page === "sessions") return null;
  return first;
}

function Screen({ route }: { route: Route }): JSX.Element {
  const { role } = useConsole();
  const [first, second] = route.path ?? [];
  if (route.page === "profiles") return first && role === "platform_admin" ? <Profile name={first} key={first} /> : <Profiles />;
  if (route.page === "bundles" && first && second && /^\d+$/.test(second)) return <Version channel={first} version={Number(second)} key={`${first}/${second}`} />;
  if (route.page === "bundles" && first) return <Channel channel={first} key={first} />;
  if (route.page === "bundles") return <Bundles />;
  if (route.page === "triggers" && first && second) return <TriggerPage team={first} name={second} key={`${first}/${second}`} />;
  if (route.page === "triggers") return <Triggers team={first ?? null} />;
  if (route.page === "teams" && route.team) return <Team name={route.team} tab={route.tab ?? "members"} />;
  if (route.page === "teams") return <Teams />;
  if (route.page === "overview") return <Overview />;
  // A laptop's session offered to this person, steered from here (Decision 921).
  if (route.page === "sessions" && first === "remote" && second) return <RemoteSession id={second} key={second} />;
  if (route.page === "sessions") return <Sessions query={first ?? ""} key={first ?? ""} />;
  if (route.page === "runs" && first) return <RunPage id={first} key={first} />;
  if (route.page === "runs") return <Runs />;
  if (route.page === "audit") return <Audit />;
  if (route.page === "clients") return <ClientVersions />;
  if (route.page === "organisation") return <Organisation />;
  if (route.page === "integrations") return <Integrations />;
  if (route.page === "identity") return <Identity />;
  if (route.page === "signin") return <IdentityProvider />;
  if (route.page === "policy") return <Policy />;
  if (route.page === "pods") return <Pods />;
  if (route.page === "hosts") return <Hosts />;
  if (route.page === "budgets") return <Budgets />;
  if (route.page === "connections") return <Connections />;
  return <Unbuilt area={area(route.page)!} />;
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}
