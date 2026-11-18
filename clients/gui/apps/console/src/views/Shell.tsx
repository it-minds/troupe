// The console's frame: the map down the side, Oversee, Watch, Configure, Operate and Govern,
// a member's own four areas among them; the screen's place and name across the top; and at the
// foot of the map who is signed in, as which role, to which plane, with the light and dark
// switch and the way out.
//
// At a narrow width the map goes above the screen, folded behind one button, so the screen
// a person opened is what they see first rather than eighteen links; choosing an area
// folds it again.
//
// A break-glass session carries a banner on every screen. The person is a platform
// administrator because they presented a token, not because anybody named them one, and
// the audit will show the break-glass subject rather than a person: both are worth having
// in front of whoever is acting, on every page, with when the session ends.

import { useEffect, useMemo, useState } from "react";
import type { JSX } from "react";
import { area, groupOf, navFor, startFor } from "../nav";
import type { Role } from "../nav";
import { href, useRoute } from "../route";
import type { Route } from "../route";
import { useConsole } from "../console";
import { shownMode, useMode } from "../theme";
import { hostOf } from "@troupe/client";
import { Wordmark } from "./brand";
import { ArtifactLink, ArtifactOpen, ArtifactPage, Artifacts, artifactPlace } from "./Artifacts";
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
import { Memory, PersonMemoryPage } from "./Memory";
import { Overview } from "./Overview";
import { RunPage, Runs } from "./Runs";
import { InvitedSession } from "./Invited";
import { RemoteSession } from "./Remote";
import { Sessions, SessionsMine } from "./Sessions";
import { Team } from "./Team";
import { Teams } from "./Teams";

/**
 * Addresses of places that moved, kept in bookmarks, open where each is now and become its
 * address: a person's own page, Mine, is the Mine of Sessions now, with the laptops' sessions
 * offered to them and those they were invited into beneath it (`#/mine/remote/<id>`,
 * `#/mine/invited/<id>`); and Published artifacts is every artifact, on Artifacts.
 */
export function moved(route: Route): Route {
  const [first, second] = route.path ?? [];
  if (route.page === "mine") return (first === "remote" || first === "invited") && second ? { page: "sessions", path: [first, second] } : { page: "sessions", path: ["mine"] };
  if (route.page === "published") return { page: "artifacts" };
  return route;
}

/** Who is signed in, as the foot of the map says it. */
function roleWords(role: Role, teams: string[]): string {
  if (role === "platform_admin") return "platform admin";
  if (role === "team_admin") return `team admin · ${teams.join(", ")}`;
  return "member";
}

export function Shell(): JSX.Element {
  const signed = useConsole();
  const START = useMemo<Route>(() => ({ page: startFor(signed.role) }), [signed.role]);
  const asked = useRoute(START);
  const route = useMemo(() => moved(asked), [asked]);
  const [mode, setMode] = useMode();
  const nav = navFor(signed.role);
  // An area this role is not shown is not reachable by its address either.
  const here = nav.some((g) => g.areas.some((a) => a.id === route.page)) ? route : START;
  const current = area(here.page)!;
  const within = here.path ?? [];
  const title = here.team ?? titleWithin(here.page, within, signed.role) ?? current.label;
  // A screen within an area is placed by its group and its area, and the area's name is a
  // way back to it: a laptop's session or one somebody invited you into, back to Mine.
  const group = groupOf(here.page);
  const ofMine = here.page === "sessions" && (within[0] === "remote" || within[0] === "invited");
  const back = here.team
    ? { label: "Teams", to: { page: here.page } }
    : ofMine
      ? { label: current.label, to: { page: here.page, path: ["mine"] } }
      : within.length && !tabOnly(here.page, within)
        ? { label: current.label, to: { page: here.page } }
        : null;
  const crumb = back ? (
    <>
      {back.label === group ? null : `${group} / `}
      <a href={href(back.to)}>{back.label}</a>
    </>
  ) : (
    group
  );
  // The folded map is open on the screen it was opened on, so choosing an area folds it
  // again with nothing to fold it. An effect that folded it on each new screen also ran
  // once the shell first drew, and undid a Menu pressed before that.
  const screen = `${here.page}/${here.team ?? ""}/${here.tab ?? ""}/${within.join("/")}`;
  const [openOn, setOpenOn] = useState<string | null>(null);
  const open = openOn === screen;

  useEffect(() => {
    globalThis.document.title = `${title} · Troupe console`;
  }, [title]);
  // Signed out, the console has no screen to name.
  useEffect(
    () => () => {
      globalThis.document.title = "Troupe console";
    },
    [],
  );

  // An address this role may not open shows where the role starts, says why in one line,
  // and becomes that place's address, so the bar no longer names a page that is not shown.
  const [refused, setRefused] = useState(false);
  useEffect(() => {
    if (here === route) {
      setRefused(false);
      if (route !== asked) globalThis.history?.replaceState?.(globalThis.history.state, "", href(route));
      return;
    }
    setRefused(area(route.page) !== null);
    globalThis.history?.replaceState?.(globalThis.history.state, "", href(START));
  }, [asked, route, here, START]);

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
                <a key={a.id} href={href({ page: a.id })} aria-current={a.id === here.page ? "page" : undefined}>
                  {a.label}
                </a>
              ))}
            </div>
          ))}
          <div className="who">
            <span className="person">{signed.me.display_name ?? signed.me.subject}</span>
            <span className="mono subject">{signed.me.email ?? signed.me.subject}</span>
            <span className={`role ${signed.role}`}>
              {roleWords(signed.role, signed.teams)}
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
        {signed.me.breakglass && <BreakGlassBanner until={signed.auth.me?.expires_at ?? null} />}
        {refused && (
          <section className="banner refused" role="status" aria-label="Not for your role">
            <p>{signed.role === "member" ? "That page is for administrators." : "That page is for platform administrators."}</p>
            <button type="button" onClick={() => setRefused(false)}>
              Dismiss
            </button>
          </section>
        )}
        <header className="head">
          <span className="crumb">{crumb}</span>
          <h1>{title}</h1>
        </header>
        <Screen route={here} />
      </main>
    </div>
  );
}

/** Why this person is a platform admin here, and until when. */
function BreakGlassBanner({ until }: { until: number | null }): JSX.Element {
  const ends = until ? new Date(until * 1000).toLocaleString() : null;
  return (
    <section className="banner breakglass" role="note" aria-label="Break-glass session">
      <p>
        <strong>Break-glass session.</strong> You are a platform administrator here because you presented the plane's break-glass token, not because
        anybody named you one; the audit records what you do as the break-glass subject.
        {ends ? ` This session ends at ${ends}, and nothing renews it.` : " Nothing renews this session."}
      </p>
    </section>
  );
}

/** A screen within an area is named by what it shows: a profile, a channel and its version, a trigger. */
function titleWithin(page: string, path: string[], role: Role): string | null {
  const [first, second] = path;
  if (!first) return null;
  if (page === "bundles") return second && /^\d+$/.test(second) ? `${first} v${second}` : first;
  if (page === "triggers") return second ?? null;
  if (page === "runs") return "A run";
  if (page === "sessions") return first === "remote" && second ? "A laptop's session" : null;
  if (page === "artifacts") return "tab" in artifactPlace(path) ? null : "An artifact";
  if (page === "memory") return first === "person" && second && role === "platform_admin" ? `${second}'s own memory` : null;
  return first;
}

/** Whether what is within an area is only one of its tabs, which needs no way back to the area. */
function tabOnly(page: string, path: string[]): boolean {
  if (page === "artifacts") return "tab" in artifactPlace(path);
  return page === "sessions" && path.length === 1 && path[0] === "mine";
}

function Screen({ route }: { route: Route }): JSX.Element {
  const { role } = useConsole();
  const [first, second] = route.path ?? [];
  if (route.page === "profiles") return first && role === "platform_admin" ? <Profile name={first} key={first} /> : <Profiles />;
  if (route.page === "bundles" && first && second && /^\d+$/.test(second)) return <Version channel={first} version={Number(second)} key={`${first}/${second}`} />;
  if (route.page === "bundles" && first && (second === "agent" || second === "copy") && route.path?.[2])
    return <Channel channel={first} opening={{ kind: second, name: route.path[2] }} key={`${first}/${second}/${route.path[2]}`} />;
  if (route.page === "bundles" && first) return <Channel channel={first} key={first} />;
  if (route.page === "bundles") return <Bundles />;
  if (route.page === "triggers" && first && second) return <TriggerPage team={first} name={second} key={`${first}/${second}`} />;
  if (route.page === "triggers") return <Triggers team={first ?? null} />;
  if (route.page === "teams" && route.team) return <Team name={route.team} tab={route.tab ?? "members"} />;
  if (route.page === "teams") return <Teams />;
  if (route.page === "overview") return <Overview />;
  // A laptop's session offered to this person, steered from here as that person, and one they were invited into.
  if (route.page === "sessions" && first === "remote" && second) return <RemoteSession id={second} key={second} />;
  if (route.page === "sessions" && first === "invited" && second) return <InvitedSession id={second} key={second} />;
  if (route.page === "artifacts") {
    const place = artifactPlace(route.path ?? []);
    if ("link" in place) return <ArtifactLink token={place.link} key={place.link} />;
    if ("open" in place) return <ArtifactOpen id={place.open.id} version={place.open.version} key={`${place.open.id}/${place.open.version ?? ""}`} />;
    return "id" in place ? <ArtifactPage id={place.id} key={place.id} /> : <Artifacts tab={place.tab} />;
  }
  // A member's Sessions is their own; an administrator's has Mine as a tab beside every session.
  if (route.page === "sessions") return role === "member" || first === "mine" ? <SessionsMine /> : <Sessions query={first ?? ""} key={first ?? ""} />;
  if (route.page === "runs" && first) return <RunPage id={first} key={first} />;
  if (route.page === "runs") return <Runs />;
  if (route.page === "audit") return <Audit />;
  if (route.page === "clients") return <ClientVersions />;
  if (route.page === "organisation") return <Organisation />;
  if (route.page === "memory" && first === "person" && second && role === "platform_admin") return <PersonMemoryPage person={second} key={second} />;
  if (route.page === "memory") return <Memory />;
  if (route.page === "integrations") return <Integrations />;
  if (route.page === "identity") return <Identity />;
  if (route.page === "signin") return <IdentityProvider />;
  if (route.page === "policy") return <Policy />;
  if (route.page === "pods") return <Pods />;
  if (route.page === "hosts") return <Hosts />;
  if (route.page === "budgets") return <Budgets />;
  if (route.page === "connections") return <Connections />;
  return <p className="page">There is no such page.</p>;
}
