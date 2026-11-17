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
//
// The sessions their owners archived are out of it, for everyone who sees them, and are
// one more filter away: chosen, the list is the archived ones, from every source, and the
// other filters narrow those.

import { useCallback, useEffect, useMemo, useState } from "react";
import type { JSX } from "react";
import { archiveRefusal, claimable, claimRefusal, filterRows, mayArchive } from "@troupe/client";
import type { FleetRow, SessionKind } from "@troupe/client";
import type { Archived } from "../hooks";
import { useNarrow } from "../narrow";
import { NavSheet } from "../sheet";
import { Cost, RowStatus, statusOf, Sync, Unread, When, Where } from "./bits";
import { inviteLine, presenceWords } from "./Remote";

export function Sessions({
  rows,
  loading,
  error,
  onOpen,
  onStart,
  onClaim,
  archived,
}: {
  rows: FleetRow[];
  loading: boolean;
  error: string | null;
  onOpen: (id: string) => void;
  /** Go and cast a troupe: the start screen is the shell's, not the list's. */
  onStart: () => void;
  /** Take a private session another device holds over on this computer; absent with no daemon to ask. */
  onClaim?: ((id: string) => Promise<void>) | undefined;
  /** The archived sessions, asked for when the filter chooses them; absent where nothing archives. */
  archived?: Archived | undefined;
}): JSX.Element {
  const [claimError, setClaimError] = useState<string | null>(null);
  const claim = onClaim
    ? async (id: string): Promise<void> => {
        setClaimError(null);
        try {
          await onClaim(id);
        } catch (e) {
          setClaimError(claimRefusal(e));
        }
      }
    : undefined;
  const [query, setQuery] = useState("");
  const [state, setState] = useState("");
  const [status, setStatus] = useState("");
  const [profile, setProfile] = useState("");
  const [kind, setKind] = useState<SessionKind | "">("");
  // The archived ones in place of the list, asked for each time they are chosen.
  const [showArchived, setShowArchived] = useState(false);
  const load = archived?.load;
  useEffect(() => {
    if (showArchived && load) void load();
  }, [showArchived, load]);
  const [unarchiveError, setUnarchiveError] = useState<string | null>(null);
  const unarchive =
    archived && showArchived
      ? async (row: FleetRow): Promise<void> => {
          setUnarchiveError(null);
          try {
            await archived.set(row, false);
          } catch (e) {
            setUnarchiveError(archiveRefusal(e, false));
          }
        }
      : undefined;
  const listed = showArchived && archived ? archived.rows.filter((r) => r.archived) : rows;
  const listing = showArchived && archived ? archived.loading : loading;
  const narrow = useNarrow();
  const [filtering, setFiltering] = useState(false);
  const closeFilters = useCallback(() => setFiltering(false), []);

  const shown = useMemo(
    () =>
      filterRows(listed, {
        ...(state ? { state } : {}),
        ...(status ? { status } : {}),
        ...(profile ? { profile } : {}),
        ...(kind ? { kind } : {}),
        query,
      }),
    [listed, state, status, profile, kind, query],
  );
  const waiting = shown.filter((r) => statusOf(r) === "waiting");
  const rest = shown.filter((r) => statusOf(r) !== "waiting");
  const profiles = [...new Set(listed.map((r) => r.profile).filter(Boolean))] as string[];
  const states = [...new Set(listed.map((r) => r.state))];
  const statuses = [...new Set(listed.map((r) => r.status).filter(Boolean))] as string[];
  const kinds = [...new Set(listed.map((r) => r.kind))];
  // How many are set, for the phone's Filter button.
  const set = [state, status, profile, kind, showArchived ? "archived" : ""].filter(Boolean).length;

  // The filters, inline on a wide window and in a sheet from the Filter button on a phone,
  // where four selects stacked would push the list the person came for below the fold.
  // Choosing one applies it at once, in either place.
  const filters = (
    <>
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
          <option value="remote">On a laptop, through the plane</option>
          <option value="invited">Shared with you</option>
        </select>
      )}
      {archived && (
        <select value={showArchived ? "archived" : ""} onChange={(e) => setShowArchived(e.target.value === "archived")} aria-label="Archived">
          <option value="">Not archived</option>
          <option value="archived">Archived</option>
        </select>
      )}
    </>
  );
  const count = <span className="count">{listing && listed.length === 0 ? "loading" : `${shown.length} of ${listed.length}`}</span>;

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
        {narrow ? (
          <button
            type="button"
            className="filter-open"
            aria-haspopup="dialog"
            aria-expanded={filtering}
            onClick={() => setFiltering(true)}
          >
            {set > 0 ? `Filter · ${set}` : "Filter"}
          </button>
        ) : (
          filters
        )}
        <span className="spacer" />
        {count}
        <button className="primary" onClick={onStart}>
          Start a session
        </button>
      </div>

      {narrow && filtering && (
        <NavSheet label="Filters" title="Filter sessions" closeLabel="Done" onClose={closeFilters}>
          <div className="nav-sheet-body filter-sheet">
            {filters}
            {count}
          </div>
        </NavSheet>
      )}

      {error && (
        <div className="banner error">
          <p>The platform did not answer, so this list may be out of date. Sessions already open keep running.</p>
          <span className="micro">{error}</span>
        </div>
      )}

      {claimError && (
        <div className="banner error" role="alert">
          <p>It was not claimed here. {claimError}.</p>
        </div>
      )}

      {showArchived && archived?.error && (
        <div className="banner error">
          <p>Not every archived session could be listed, so some may be missing.</p>
          <span className="micro">{archived.error}</span>
        </div>
      )}

      {unarchiveError && (
        <div className="banner error" role="alert">
          <p>It was not unarchived. {unarchiveError}.</p>
        </div>
      )}

      <div className="listing">
        {showArchived && listed.length === 0 && !listing ? (
          <div className="empty">
            <h2>Nothing archived</h2>
            <p>A session its owner archives is kept here, whole: anybody who could open it still can, and its owner can unarchive it.</p>
          </div>
        ) : rows.length === 0 && !loading && !showArchived ? (
          <div className="empty">
            <h2>No sessions yet</h2>
            <p>
              A session is one piece of work handed to the troupe: you describe it, it works on it, and it asks you before doing anything
              that changes something.
            </p>
            <button className="primary" onClick={onStart}>
              Start a session
            </button>
          </div>
        ) : shown.length === 0 ? (
          <div className="empty">
            <h2>Nothing matches</h2>
            <p>No session matches those filters. Clear them to see all {listed.length}.</p>
          </div>
        ) : (
          <>
            {waiting.length > 0 && (
              <section className="group waiting">
                <h3>Waiting for you</h3>
                <Rows rows={waiting} onOpen={onOpen} onClaim={claim} onUnarchive={unarchive} />
              </section>
            )}
            {rest.length > 0 && (
              <section className="group">
                {waiting.length > 0 && <h3>Everything else</h3>}
                <Rows rows={rest} onOpen={onOpen} onClaim={claim} onUnarchive={unarchive} />
              </section>
            )}
          </>
        )}
      </div>
    </>
  );
}

/**
 * A row is the title over its facts, then the pills, then when: what the comp's row
 * says, in its order — the profile and the cost are what a session *is*, the pills are
 * where it runs and what it is doing, and the time sits at the edge to be scanned.
 */
function Rows({
  rows,
  onOpen,
  onClaim,
  onUnarchive,
}: {
  rows: FleetRow[];
  onOpen: (id: string) => void;
  onClaim?: ((id: string) => Promise<void>) | undefined;
  /** Put an archived session back in the list: offered on the rows the person owns. */
  onUnarchive?: ((row: FleetRow) => Promise<void>) | undefined;
}): JSX.Element {
  return (
    <ul className="rows">
      {rows.map((r) => {
        const status = statusOf(r);
        const claim = onClaim && claimable(r);
        const unarchive = onUnarchive && r.archived && mayArchive(r);
        return (
          <li key={r.id} className={claim ? "claimable" : unarchive ? "unarchivable" : undefined}>
            <button className={`row is-${status}`} onClick={() => onOpen(r.id)}>
              <span className="subject">
                <span className="title">{r.title ?? r.id}</span>
                <span className="sub">
                  {r.profile && <span>{r.profile}</span>}
                  <Cost micros={r.costMicros} />
                </span>
              </span>
              <span className="meta">
                <Unread row={r} />
                <Where kind={r.kind} />
                {r.kind === "remote" && r.remote && r.remote.state !== "online" && (
                  <span className="micro muted">{presenceWords(r.remote)}</span>
                )}
                {r.invitation && <span className="micro muted">{inviteLine(r.invitation)}</span>}
                <Sync state={r.sync} device={r.device} />
                <RowStatus row={r} />
                <When iso={r.lastActiveAt} />
              </span>
            </button>
            {claim && <Claim row={r} onClaim={onClaim} />}
            {unarchive && <Unarchive row={r} onUnarchive={onUnarchive} />}
          </li>
        );
      })}
    </ul>
  );
}

/**
 * Take a private session another device holds over on this computer (troupe Decision
 * 785). Beside the row rather than in it: the row opens the session, and a button inside
 * a button is neither.
 */
function Claim({ row, onClaim }: { row: FleetRow; onClaim: (id: string) => Promise<void> }): JSX.Element {
  const [busy, setBusy] = useState(false);
  return (
    <button
      className="claim"
      disabled={busy}
      title={`Seal it from this computer from now on; ${row.device ?? "the other device"} stops sealing it`}
      onClick={() => {
        setBusy(true);
        void onClaim(row.id).finally(() => setBusy(false));
      }}
    >
      {busy ? "Claiming" : "Claim"}
    </button>
  );
}

/** Put an archived session back in the list, beside its row as Claim is: its owner's alone. */
function Unarchive({ row, onUnarchive }: { row: FleetRow; onUnarchive: (row: FleetRow) => Promise<void> }): JSX.Element {
  const [busy, setBusy] = useState(false);
  return (
    <button
      className="claim"
      disabled={busy}
      aria-label={`Unarchive ${row.title ?? row.id}`}
      title="Put it back in the session list, for everyone who sees it"
      onClick={() => {
        setBusy(true);
        void onUnarchive(row).finally(() => setBusy(false));
      }}
    >
      {busy ? "Unarchiving" : "Unarchive"}
    </button>
  );
}
