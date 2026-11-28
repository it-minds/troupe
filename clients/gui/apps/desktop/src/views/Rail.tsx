// The rail: the app's destinations grouped by where they live, the state of each side the
// install has, and setup's progress while it is unfinished.
//
// Three groups. The first, with no heading, is the work both kinds of install have:
// Sessions, Waiting for you, Review where there is a plane, Artifacts and Memory. "On the
// platform" is Profiles and Your triggers; "On this computer" is This computer, Agents and
// Tools and skills.
// A group whose side the install does not have is not drawn, so the others never move
// when it comes or goes; a side the install has that is down keeps its group, dimmed, with
// its state beside the heading, and every item in it still opens, because each page says
// what is wrong and how to mend it. Hiding them would make the rail jump at every restart
// of the daemon.
//
// The state of each side is said once, in the rows at the foot, above who you are; the
// signed-in block no longer says it again. Setup is a card at the top until the daemon says
// it is finished, and then a plain item beside Appearance with a check, still there for
// reconnecting or adding the other side later.

import type { JSX, ReactNode } from "react";
import type { DaemonState } from "./Local";

/** The screens the rail leads to. */
export type RailScreen =
  | "sessions"
  | "approvals"
  | "review"
  | "artifacts"
  | "memory"
  | "profiles"
  | "triggers"
  | "local"
  | "agents"
  | "connect"
  | "appearance"
  | "setup";

/** How a side stands: up, on its way, or down. Each is a dot and a word. */
export type SideMood = "ok" | "busy" | "down";

export interface SideState {
  mood: SideMood;
  /** The row's word, as the person reads it: "Connected", "Starting…", "Offline". */
  word: string;
  /** Which of the ways down or on its way it is, for the row's title. */
  why: string;
}

/** The screens that belong to one side, which an install without that side does not offer. */
const PLANE_SCREENS: ReadonlySet<string> = new Set(["review", "profiles", "triggers"]);
const LOCAL_SCREENS: ReadonlySet<string> = new Set(["local", "agents", "connect"]);

/** Whether `screen` belongs to a side this install does not have, so the app goes to Sessions instead. */
export function onAbsentSide(screen: string, sides: { local: boolean; plane: boolean }): boolean {
  return (!sides.plane && PLANE_SCREENS.has(screen)) || (!sides.local && LOCAL_SCREENS.has(screen));
}

/**
 * Whether this install has a local side: a shell finds its daemon, and a browser build has
 * one only once it has been told where a daemon is. A browser told nothing is remote only.
 */
export function hasLocalSide(daemon: Pick<DaemonState, "status" | "endpoint" | "canFind">): boolean {
  return daemon.canFind || daemon.endpoint !== null || daemon.status !== "unsupported";
}

/** This computer's daemon, as the row says it. */
export function localSide(daemon: Pick<DaemonState, "status" | "error">): SideState {
  switch (daemon.status) {
    case "connected":
      return { mood: "ok", word: "Connected", why: "the daemon on this computer is answering" };
    case "searching":
      return { mood: "busy", word: "Starting…", why: "looking for the daemon, and starting it if it is not running" };
    case "absent":
      return { mood: "down", word: "Not running", why: "no daemon is running on this computer" };
    case "unsupported":
      return { mood: "down", word: "Not running", why: "this page is connected to no daemon" };
    default:
      return { mood: "down", word: "Not running", why: daemon.error ? `the daemon did not answer: ${daemon.error}` : "the daemon did not answer" };
  }
}

/**
 * The plane, as the row says it. Signed in, it is connected while the list's last ask of it
 * answered, and reconnecting while it did not, since the next poll asks again. Not signed in
 * with a plane in the install is offline, three ways: not answering, answering again with a
 * sign-in that has ended, and not serving this version.
 */
export function planeSide(p: { signedIn: boolean; listError: string | null; offline: boolean; expired: boolean; refused: boolean }): SideState {
  if (p.refused) return { mood: "down", word: "Offline", why: "the platform needs a newer version of this app" };
  if (p.signedIn && !p.listError) return { mood: "ok", word: "Connected", why: "signed in, and the platform is answering" };
  if (p.signedIn) return { mood: "busy", word: "Reconnecting…", why: `the platform did not answer the last ask (${p.listError}); the list asks again` };
  if (p.expired) return { mood: "down", word: "Offline", why: "the platform is answering again, and this sign-in has ended" };
  return { mood: "down", word: "Offline", why: "the platform is not answering" };
}

/** Setup's progress while it is unfinished: steps done of the steps there are, and the next one's name. */
export interface SetupProgress {
  done: number;
  of: number;
  next: string;
}

function Item({
  screen,
  current,
  go,
  children,
}: {
  screen: RailScreen;
  current: string;
  go: (screen: RailScreen) => void;
  children: ReactNode;
}): JSX.Element {
  return (
    <button type="button" aria-current={current === screen ? "page" : undefined} onClick={() => go(screen)}>
      {children}
    </button>
  );
}

/** A side's group: dimmed while the side is down or on its way, with the state beside the heading. */
function SideGroup({ id, heading, side, children }: { id: string; heading: string; side: SideState; children: ReactNode }): JSX.Element {
  const dim = side.mood !== "ok";
  return (
    <div className={dim ? "rail-group dim" : "rail-group"} role="group" aria-labelledby={id}>
      <div className="rail-head" id={id}>
        {heading}
        {dim && (
          <span className={`rail-state ${side.mood}`} title={side.why}>
            {side.word.toLowerCase()}
          </span>
        )}
      </div>
      {children}
    </div>
  );
}

function ConnectionRow({ where, side, onOpen }: { where: string; side: SideState; onOpen: () => void }): JSX.Element {
  return (
    <button type="button" className={side.mood} aria-label={`${where}: ${side.word}`} title={side.why} onClick={onOpen}>
      <span className="dot" aria-hidden="true" />
      <span className="where">{where}</span>
      <span className="state">{side.word}</span>
    </button>
  );
}

export interface RailProps {
  /** The screen on show. */
  current: string;
  go: (screen: RailScreen) => void;
  /** This computer's side, or null where the install has none. */
  local: SideState | null;
  /** The plane's side, or null where the install has none. */
  plane: SideState | null;
  sessions: number;
  waiting: number;
  /** The sessions on this computer, counted while its daemon is connected. */
  here: number;
  /** Unfinished setup's progress; `finished` once the daemon says so; null while not known. */
  setup: SetupProgress | "finished" | null;
  /** Each row opens the page that explains its side. The details of a connection (the daemon's version, the plane's URL, who is signed in) are a later issue. */
  onLocalRow: () => void;
  onPlaneRow: () => void;
  /** Who you are, at the foot. */
  me: ReactNode;
}

/** What the rail holds, on a wide window and in the phone's sheet alike. */
export function RailBody({ current, go, local, plane, sessions, waiting, here, setup, onLocalRow, onPlaneRow, me }: RailProps): JSX.Element {
  const unfinished = setup !== null && setup !== "finished" ? setup : null;
  return (
    <>
      {unfinished && (
        <button type="button" className="setup-card" aria-current={current === "setup" ? "page" : undefined} onClick={() => go("setup")}>
          <span className="t">
            Finish setup{" "}
            <span className="of">
              {unfinished.done} of {unfinished.of}
            </span>
          </span>
          <span className="bar" aria-hidden="true">
            {Array.from({ length: unfinished.of }, (_, i) => (
              <i key={i} className={i < unfinished.done ? "on" : undefined} />
            ))}
          </span>
          <span className="next">Next: {unfinished.next}</span>
        </button>
      )}
      <nav aria-label="Main">
        <div className="rail-group">
          <Item screen="sessions" current={current} go={go}>
            Sessions <span className="count">{sessions}</span>
          </Item>
          {/* A count here means a session is blocked on a person, so it is the reserved colour; nothing waiting is no count at all. */}
          <Item screen="approvals" current={current} go={go}>
            Waiting for you
            {waiting > 0 && (
              <span className="count hot" aria-label={`${waiting} waiting`}>
                {waiting}
              </span>
            )}
          </Item>
          {/* Review reads the plane's record of unattended runs: offered where the install has a plane, and nowhere else. */}
          {plane && (
            <Item screen="review" current={current} go={go}>
              Review
            </Item>
          )}
          {/* A person's own things: from the plane signed in to, through this computer's daemon where it is not. */}
          <Item screen="artifacts" current={current} go={go}>
            Artifacts
          </Item>
          <Item screen="memory" current={current} go={go}>
            Memory
          </Item>
        </div>
        {plane && (
          <SideGroup id="rail-plane" heading="On the platform" side={plane}>
            <Item screen="profiles" current={current} go={go}>
              Profiles
            </Item>
            {/* The reruns a yes of yours turned on, which run as you: yours to switch off. */}
            <Item screen="triggers" current={current} go={go}>
              Your triggers
            </Item>
          </SideGroup>
        )}
        {local && (
          <SideGroup id="rail-local" heading="On this computer" side={local}>
            <Item screen="local" current={current} go={go}>
              This computer
              {local.mood === "ok" && <span className="count">{here}</span>}
            </Item>
            <Item screen="agents" current={current} go={go}>
              Agents
            </Item>
            {/* Your own MCP servers and skills, which every session on this computer starts. */}
            <Item screen="connect" current={current} go={go}>
              Tools and skills
            </Item>
          </SideGroup>
        )}
        <span className="spacer" />
        <div className="rail-group rail-foot">
          <Item screen="appearance" current={current} go={go}>
            Appearance
          </Item>
          {!unfinished && (
            <Item screen="setup" current={current} go={go}>
              Setup
              {setup === "finished" && (
                <span className="check" aria-label="finished">
                  ✓
                </span>
              )}
            </Item>
          )}
        </div>
      </nav>
      {(local || plane) && (
        <div className="conn" role="group" aria-label="Connections">
          {local && <ConnectionRow where="This computer" side={local} onOpen={onLocalRow} />}
          {plane && <ConnectionRow where="Platform" side={plane} onOpen={onPlaneRow} />}
        </div>
      )}
      {me}
    </>
  );
}

/** Review or Profiles opened while the plane is not connected: the page says so, and the banner above says what to do. */
export function PlaneAway({ what, side }: { what: string; side: SideState }): JSX.Element {
  return (
    <div className="centred">
      <p className="copy">
        {what} come from the platform, which is offline now: {side.why}.
      </p>
    </div>
  );
}
