// The launcher: the front of house, and the first screen.
//
// The app opens on it, as the comp does, and the lockup in the rail opens it from
// anywhere: the screen for the moment before you know which room you want — three tiles
// for the three things there are to do, what was open last, and what this machine is.
// Nothing here is a second copy of any state — every number is read off the same rows the
// list shows, and a recent row carries the list's marker for what happened while nobody
// was reading it. A person who would rather start on the list says so at its foot, or
// beside the appearance, and from the next start the app opens there (Decision 709).

import { useState } from "react";
import type { JSX } from "react";
import { awaitingYou } from "@troupe/client";
import type { AuthSession, FleetRow } from "@troupe/client";
import { capabilities, prefs } from "../shell";
import { Mask } from "./brand";
import { failedTitle, relative, statusOf, Unread } from "./bits";
import type { DaemonState } from "./Local";

/** The one word for where a row runs, as the list's pill says it. */
const KIND: Record<FleetRow["kind"], string> = { team: "Team", local: "This computer", private: "Private" };

/** Whether the app opens here, which it does until the person says the list. */
export function opensOnLauncher(): boolean {
  return prefs.get("start", "launcher") !== "sessions";
}

/**
 * The preference, for the checkbox at the launcher's foot and the one beside the
 * appearance. It is read at start and nowhere else, so changing it moves nothing now.
 */
export function useOpensOnLauncher(): { on: boolean; setOn: (on: boolean) => void } {
  const [on, setOnState] = useState(opensOnLauncher);
  return {
    on,
    setOn: (next) => {
      prefs.set("start", next ? "launcher" : "sessions");
      setOnState(next);
    },
  };
}

export function Launcher({
  rows,
  auth,
  daemon,
  planeUrl,
  offline,
  localOnly,
  onNew,
  onSessions,
  onApprovals,
  onSettings,
  onOpen,
}: {
  rows: FleetRow[];
  auth: AuthSession | null;
  daemon: Pick<DaemonState, "status" | "user">;
  planeUrl: string;
  offline: boolean;
  localOnly: boolean;
  onNew: () => void;
  onSessions: () => void;
  onApprovals: () => void;
  onSettings: () => void;
  onOpen: (id: string) => void;
}): JSX.Element {
  const caps = capabilities();
  const start = useOpensOnLauncher();
  const waiting = awaitingYou(rows);
  const team = rows.filter((r) => r.kind === "team").length;
  const here = rows.length - team;
  // The rows arrive pinned first, then by activity; the three at the top are the recent ones.
  const recent = rows.slice(0, 3);
  const oldest = waiting
    .map((r) => (r.lastActiveAt ? Date.parse(r.lastActiveAt) : NaN))
    .filter(Number.isFinite)
    .sort((a, b) => a - b)[0];

  const platform = auth
    ? { text: `${hostOf(auth.planeUrl)} reachable`, on: true }
    : offline
      ? { text: `${hostOf(planeUrl)} not answering`, on: false }
      : localOnly
        ? { text: "local only", on: false }
        : { text: "not signed in", on: false };
  const runtime = {
    connected: "daemon connected",
    searching: "looking for the daemon",
    absent: "daemon not running",
    error: "daemon not answering",
    unsupported: "no daemon from a browser",
  }[daemon.status];

  return (
    <div className="launcher">
      <div className="strip">
        <span className="lights" aria-hidden="true">
          <span className="brand" />
          <span className="local" />
          <span className="machine" />
        </span>
        <span className="micro">Troupe · {caps.shellName ?? "browser"}</span>
      </div>

      <main>
        <div className="masthead">
          <Mask size={108} label="Troupe" />
          <div className="lead">
            <span className="screen">A company of agents · v{__TROUPE_VERSION__}</span>
            <h1 className="display">
              Trou<span className="lit">pe</span>
            </h1>
          </div>
        </div>

        <div className="tiles">
          <button type="button" className="tile new" onClick={onNew}>
            <span className="kicker">01</span>
            <span className="title">New session</span>
            <span className="copy">Cast a troupe and hand it the first instruction.</span>
          </button>
          <button type="button" className="tile" onClick={onSessions}>
            <span className="kicker">02</span>
            <span className="title">Open a session</span>
            <span className="copy">{auth ? `${team} on the platform · ${here} on this computer` : `${here} on this computer`}</span>
          </button>
          {waiting.length > 0 ? (
            <button type="button" className="tile needs" onClick={onApprovals}>
              <span className="kicker">03 · Needs you</span>
              <span className="title">
                {waiting.length} waiting for you
              </span>
              <span className="copy">{oldest === undefined ? "A decision is waiting." : `The oldest stopped ${relative(oldest)}.`}</span>
            </button>
          ) : (
            <button type="button" className="tile" onClick={onApprovals}>
              <span className="kicker">03</span>
              <span className="title">Nothing waiting</span>
              <span className="copy">Every decision the troupe needs from you lands here.</span>
            </button>
          )}
        </div>

        <div className="below">
          <section className="recent">
            <span className="screen">Recent</span>
            {recent.length === 0 ? (
              <p className="note">No sessions yet.</p>
            ) : (
              <ul>
                {recent.map((r) => (
                  <li key={r.id}>
                    <button type="button" className={`is-${statusOf(r)}`} title={failedTitle(r)} onClick={() => onOpen(r.id)}>
                      <span className="bar" aria-hidden="true" />
                      <span className="title">{r.title ?? r.id}</span>
                      <Unread row={r} />
                      <span className={`kind ${r.kind === "team" ? "" : "local"}`}>{KIND[r.kind]}</span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </section>

          <section className="machine">
            <span className="screen">This machine</span>
            <dl className="facts">
              <dt>Platform</dt>
              <dd className={platform.on ? "on" : ""}>
                {platform.on ? "● " : ""}
                {platform.text}
              </dd>
              <dt>Runtime</dt>
              <dd>{runtime}</dd>
              <dt>Signed in</dt>
              <dd>{auth?.me?.subject ?? daemon.user?.name ?? "—"}</dd>
            </dl>
            <button type="button" onClick={onSettings}>
              Settings
            </button>
          </section>
        </div>
      </main>

      <footer>
        <span>
          troupe {__TROUPE_VERSION__} · {caps.shellName ?? "browser"}
        </span>
        <label title="Appearance, in the rail, brings it back.">
          <input type="checkbox" checked={!start.on} onChange={(e) => start.setOn(!e.target.checked)} />
          Skip this screen when Troupe starts
        </label>
      </footer>
    </div>
  );
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}
