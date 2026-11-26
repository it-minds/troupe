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

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { JSX } from "react";
import {
  archiveRefusal,
  claimable,
  claimRefusal,
  filterRows,
  LIFESPAN_CHOICES,
  lifespanItem,
  lifespanMark,
  lifespanOf,
  lifespanRefusal,
  markRefusal,
  mayArchive,
  repositoriesSummary,
} from "@troupe/client";
import type { FleetRow, Lifespan, SessionKind } from "@troupe/client";
import type { Archived, Marks } from "../hooks";
import { useNarrow } from "../narrow";
import { NavSheet } from "../sheet";
import { archiveItem, Cost, RowStatus, statusOf, Sync, Unread, When, Where } from "./bits";
import { inviteLine, presenceWords } from "./Remote";
import { RenameField } from "./Rename";

export function Sessions({
  rows,
  loading,
  error,
  onOpen,
  onStart,
  onClaim,
  archived,
  marks,
  lifespans,
}: {
  rows: FleetRow[];
  loading: boolean;
  error: string | null;
  onOpen: (id: string) => void;
  /** Go and cast a troupe: the start screen is the shell's, not the list's. */
  onStart: () => void;
  /** Take a private session another device holds over on this computer; absent with no daemon to ask. */
  onClaim?: ((id: string) => Promise<void>) | undefined;
  /** The archived sessions, asked for when the filter chooses them, and archiving from a row's ⋯; absent where nothing archives. */
  archived?: Archived | undefined;
  /** Rename a session and keep it at the top, from its row's ⋯: its owner's alone. */
  marks?: Marks | undefined;
  /** Whether a row's server takes a lifespan, so its ⋯ offers to change it (troupe #1209). */
  lifespans?: ((kind: SessionKind) => boolean) | undefined;
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
  // Archived or unarchived from a row's ⋯, as the session's own ⋯ does it: what a refusal
  // said, in the list, until the next try. Done, the row has left the list it was in, and
  // the person stays where they are.
  const [archiveError, setArchiveError] = useState<string | null>(null);
  const archive = archived
    ? async (row: FleetRow, on: boolean): Promise<void> => {
        setArchiveError(null);
        try {
          await archived.set(row, on);
        } catch (e) {
          setArchiveError(`It was not ${on ? "archived" : "unarchived"}. ${archiveRefusal(e, on)}.`);
        }
      }
    : undefined;
  // A name or a place at the top changed from a row's ⋯: what a refusal said, until the next try.
  const [markError, setMarkError] = useState<string | null>(null);
  const mark =
    marks && !showArchived
      ? {
          rename: async (row: FleetRow, title: string): Promise<void> => {
            setMarkError(null);
            try {
              await marks.rename(row, title);
            } catch (e) {
              setMarkError(`It was not renamed. ${markRefusal(e, "rename")}.`);
            }
          },
          keep: async (row: FleetRow, on: boolean): Promise<void> => {
            setMarkError(null);
            try {
              await marks.keep(row, on);
            } catch (e) {
              setMarkError(`It was not ${on ? "kept at the top" : "let go from the top"}. ${markRefusal(e, on ? "keep" : "let go")}.`);
            }
          },
          ...(lifespans
            ? {
                relive: async (row: FleetRow, to: Lifespan): Promise<void> => {
                  setMarkError(null);
                  try {
                    await marks.relive(row, to);
                  } catch (e) {
                    setMarkError(lifespanRefusal(e));
                  }
                },
                lives: lifespans,
              }
            : {}),
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

      {archiveError && (
        <div className="banner error" role="alert">
          <p>{archiveError}</p>
        </div>
      )}

      {markError && (
        <div className="banner error" role="alert">
          <p>{markError}</p>
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
                <Rows rows={waiting} onOpen={onOpen} onClaim={claim} onArchive={archive} mark={mark} />
              </section>
            )}
            {rest.length > 0 && (
              <section className="group">
                {waiting.length > 0 && <h3>Everything else</h3>}
                <Rows rows={rest} onOpen={onOpen} onClaim={claim} onArchive={archive} mark={mark} />
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
  onArchive,
  mark,
}: {
  rows: FleetRow[];
  onOpen: (id: string) => void;
  onClaim?: ((id: string) => Promise<void>) | undefined;
  /** Archive a session (`true`) or put an archived one back, from the row's ⋯: offered on the rows the person owns. Never rejects. */
  onArchive?: ((row: FleetRow, on: boolean) => Promise<void>) | undefined;
  /**
   * Rename it, keep it at the top, and say how long it lasts where its server knows
   * lifespans, from the row's ⋯: offered on the rows the person owns. Never rejects.
   */
  mark?:
    | {
        rename: (row: FleetRow, title: string) => Promise<void>;
        keep: (row: FleetRow, on: boolean) => Promise<void>;
        relive?: (row: FleetRow, to: Lifespan) => Promise<void>;
        lives?: (kind: SessionKind) => boolean;
      }
    | undefined;
}): JSX.Element {
  // The row whose name is a field, one at a time.
  const [renaming, setRenaming] = useState<string | null>(null);
  return (
    <ul className="rows">
      {rows.map((r) => {
        const status = statusOf(r);
        const claim = onClaim && claimable(r);
        const archive = onArchive && mayArchive(r) ? onArchive : undefined;
        const marked = mark && !r.archived && mayArchive(r) ? mark : undefined;
        const relive = marked?.relive && marked.lives?.(r.kind) ? marked.relive : undefined;
        const lasts = lifespanMark(r);
        if (marked && renaming === r.id) {
          return (
            <li key={r.id} className="markable">
              <div className={`row is-${status} renaming`}>
                <RenameField title={r.title ?? ""} onRename={(title) => marked.rename(r, title)} onDone={() => setRenaming(null)} />
              </div>
            </li>
          );
        }
        return (
          <li key={r.id} className={claim ? "claimable" : marked || archive ? "markable" : undefined}>
            <button className={`row is-${status}`} onClick={() => onOpen(r.id)}>
              <span className="subject">
                <span className="title">{r.title ?? r.id}</span>
                <span className="sub">
                  {r.profile && <span>{r.profile}</span>}
                  {r.repositories && r.repositories.length > 0 && (
                    <span className="mono" title={r.repositories.join(", ")}>
                      {repositoriesSummary(r.repositories)}
                    </span>
                  )}
                  <Cost micros={r.costMicros} />
                </span>
              </span>
              <span className="meta">
                {r.pinned && (
                  <span className="micro kept" title="Kept at the top of the session list, for everyone who sees it">
                    Kept
                  </span>
                )}
                {lasts && (
                  <span className="micro lasts" title={lasts === "persistent" ? "Kept until its owner erases it" : "Erased a while after it goes quiet, unless somebody keeps it"}>
                    {lasts}
                  </span>
                )}
                <Unread row={r} />
                <Where kind={r.kind} row={r} />
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
            {(marked || archive) && (
              <RowMenu
                row={r}
                onRename={marked ? () => setRenaming(r.id) : undefined}
                onKeep={marked ? (on) => void marked.keep(r, on) : undefined}
                onRelive={relive ? (to) => void relive(r, to) : undefined}
                onArchive={archive ? (on) => void archive(r, on) : undefined}
              />
            )}
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

/**
 * A row's ⋯, beside it as Claim is: rename it, keep it at the top of the list or let it go,
 * and archive it, or under Archived put it back. Each is the session's for everyone who
 * sees it, and its owner's to change; each is offered where the list was given its way.
 */
function RowMenu({
  row,
  onRename,
  onKeep,
  onRelive,
  onArchive,
}: {
  row: FleetRow;
  onRename?: (() => void) | undefined;
  onKeep?: ((on: boolean) => void) | undefined;
  /** Make it one of the other two lifespans. */
  onRelive?: ((to: Lifespan) => void) | undefined;
  onArchive?: ((on: boolean) => void) | undefined;
}): JSX.Element {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const outside = (e: MouseEvent): void => {
      if (!box.current?.contains(e.target as Node)) setOpen(false);
    };
    const escape = (e: KeyboardEvent): void => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", outside);
    document.addEventListener("keydown", escape);
    return () => {
      document.removeEventListener("mousedown", outside);
      document.removeEventListener("keydown", escape);
    };
  }, [open]);
  const then = (act: () => void) => () => {
    setOpen(false);
    act();
  };
  const name = row.title ?? row.id;
  return (
    <div className="row-menu" ref={box}>
      <button type="button" className="ib" aria-label={`More actions for ${name}`} aria-haspopup="true" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        ⋯
      </button>
      <div className="menu-pop" hidden={!open} aria-label={`Actions for ${name}`}>
        {onRename && (
          <button type="button" className="item" onClick={then(onRename)}>
            <span className="t">Rename</span>
            <span className="d">The name the session list shows, for everyone who sees it</span>
          </button>
        )}
        {onKeep && (
          <button type="button" className="item" onClick={then(() => onKeep(!row.pinned))}>
            <span className="t">{row.pinned ? "Let go from the top" : "Keep at the top"}</span>
            <span className="d">{row.pinned ? "Back among the rest, by when it was last active" : "Listed first, for everyone who sees it"}</span>
          </button>
        )}
        {onRelive &&
          LIFESPAN_CHOICES.filter((c) => c.value !== lifespanOf(row.lifespan)).map((c) => (
            <button key={c.value} type="button" className="item" onClick={then(() => onRelive(c.value))}>
              <span className="t">{lifespanItem(c.value)}</span>
              <span className="d">{c.sentence}</span>
            </button>
          ))}
        {onArchive && (
          <button type="button" className="item" onClick={then(() => onArchive(!row.archived))}>
            <span className="t">{archiveItem(Boolean(row.archived)).title}</span>
            <span className="d">{archiveItem(Boolean(row.archived)).line}</span>
          </button>
        )}
      </div>
    </div>
  );
}
