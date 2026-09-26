// Home. Every session the person can see, whatever it is running on.
//
// Anything waiting for a decision is lifted into its own group at the top, and sorting
// never lets a working session outrank a waiting one. That, plus the amber row and its
// left marker, is what makes "something needs you" readable at a glance in a list of
// thirty on a phone.
//
// Where a session runs is a column rather than a tab, because it is a property of the
// work and not a place to go: the question "what is waiting for me" is never "what is
// waiting for me on the platform". The one list is the whole idea.

import { useMemo, useState } from "react";
import type { JSX } from "react";
import { filterRows } from "@troupe/client";
import type { AuthSession, DaemonClient, FleetRow, SessionKind } from "@troupe/client";
import { StartSession } from "./StartSession";
import { Cost, RowStatus, statusOf, Sync, When, Where } from "./bits";

export function Sessions({
  auth,
  daemon,
  linked,
  rows,
  loading,
  error,
  onOpen,
  onCreated,
}: {
  /** The plane, for team sessions. Null in local mode, which lists this computer's alone. */
  auth: AuthSession | null;
  daemon: DaemonClient | null;
  /** Whether the daemon records this person by name, which a private session needs. */
  linked: boolean;
  rows: FleetRow[];
  loading: boolean;
  error: string | null;
  onOpen: (id: string) => void;
  onCreated: (id: string) => void;
}): JSX.Element {
  const [query, setQuery] = useState("");
  const [state, setState] = useState("");
  const [status, setStatus] = useState("");
  const [profile, setProfile] = useState("");
  const [kind, setKind] = useState<SessionKind | "">("");
  const [starting, setStarting] = useState(false);

  const shown = useMemo(
    () =>
      filterRows(rows, {
        ...(state ? { state } : {}),
        ...(status ? { status } : {}),
        ...(profile ? { profile } : {}),
        ...(kind ? { kind } : {}),
        query,
      }),
    [rows, state, status, profile, kind, query],
  );
  const waiting = shown.filter((r) => statusOf(r) === "waiting");
  const rest = shown.filter((r) => statusOf(r) !== "waiting");
  const profiles = [...new Set(rows.map((r) => r.profile).filter(Boolean))] as string[];
  const states = [...new Set(rows.map((r) => r.state))];
  const statuses = [...new Set(rows.map((r) => r.status).filter(Boolean))] as string[];
  const kinds = [...new Set(rows.map((r) => r.kind))];

  return (
    <>
      <header className="screen-head">
        <span className="count">Sessions · {rows.length} total</span>
        <h1>Everything your troupe is holding</h1>
      </header>

      <div className="toolbar">
        <input
          className="search"
          type="search"
          placeholder="Search sessions"
          aria-label="Search sessions"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <select value={state} onChange={(e) => setState(e.target.value)} aria-label="State">
          <option value="">Any state</option>
          {states.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
        <select value={status} onChange={(e) => setStatus(e.target.value)} aria-label="Status">
          <option value="">Any status</option>
          {statuses.map((x) => (
            <option key={x} value={x}>
              {x}
            </option>
          ))}
        </select>
        <select value={profile} onChange={(e) => setProfile(e.target.value)} aria-label="Profile">
          <option value="">Any profile</option>
          {profiles.map((p) => (
            <option key={p} value={p}>
              {p}
            </option>
          ))}
        </select>
        {kinds.length > 1 && (
          <select value={kind} onChange={(e) => setKind(e.target.value as SessionKind | "")} aria-label="Where it runs">
            <option value="">Anywhere</option>
            <option value="team">On the platform</option>
            <option value="local">On this computer</option>
            <option value="private">Private</option>
          </select>
        )}
        <span className="spacer" />
        <span className="count">{loading && rows.length === 0 ? "loading" : `${shown.length} of ${rows.length}`}</span>
        <button className="primary" onClick={() => setStarting(true)}>
          Start a session
        </button>
      </div>

      {error && (
        <div className="banner error">
          <p>The platform did not answer, so this list may be out of date. Sessions already open keep running.</p>
          <span className="micro">{error}</span>
        </div>
      )}

      <div className="listing">
        {rows.length === 0 && !loading ? (
          <div className="empty">
            <h2>No sessions yet</h2>
            <p>
              A session is one piece of work handed to the troupe: you describe it, it works on it, and it asks you before doing anything
              that changes something.
            </p>
            <button className="primary" onClick={() => setStarting(true)}>
              Start a session
            </button>
          </div>
        ) : shown.length === 0 ? (
          <div className="empty">
            <h2>Nothing matches</h2>
            <p>No session matches those filters. Clear them to see all {rows.length}.</p>
          </div>
        ) : (
          <>
            {waiting.length > 0 && (
              <section className="group waiting">
                <h3>Waiting for you</h3>
                <Rows rows={waiting} onOpen={onOpen} />
              </section>
            )}
            {rest.length > 0 && (
              <section className="group">
                {waiting.length > 0 && <h3>Everything else</h3>}
                <Rows rows={rest} onOpen={onOpen} />
              </section>
            )}
          </>
        )}
      </div>

      {starting && (
        <StartSession
          auth={auth}
          daemon={daemon}
          linked={linked}
          onClose={() => setStarting(false)}
          onCreated={(id) => {
            setStarting(false);
            onCreated(id);
          }}
        />
      )}
    </>
  );
}

/**
 * A row is the title over its facts, then the pills, then when: what the comp's row
 * says, in its order — the profile and the cost are what a session *is*, the pills are
 * where it runs and what it is doing, and the time sits at the edge to be scanned.
 */
function Rows({ rows, onOpen }: { rows: FleetRow[]; onOpen: (id: string) => void }): JSX.Element {
  return (
    <ul className="rows">
      {rows.map((r) => {
        const status = statusOf(r);
        return (
          <li key={r.id}>
            <button className={`row is-${status}`} onClick={() => onOpen(r.id)}>
              <span className="subject">
                <span className="title">{r.title ?? r.id}</span>
                <span className="sub">
                  {r.profile && <span>{r.profile}</span>}
                  <Cost micros={r.costMicros} />
                </span>
              </span>
              <span className="meta">
                <Where kind={r.kind} />
                <Sync state={r.sync} />
                <RowStatus row={r} />
                <When iso={r.lastActiveAt} />
              </span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

