// What ran while nobody was watching.
//
// A triggered session and an A2A session have the same problem: they started without a
// person, so nothing put them in front of one. This is that queue. It is not a second
// sessions list — it is ordered by what went wrong, grouped by the thing that fired it,
// and its two actions are the two a person actually takes: answer what it is stuck on,
// and say you have looked.
//
// Nothing here replays a log. `sessions.list` answers from the plane's index, which
// already carries status, done reason, cost and how many approvals are open — so a
// hundred unattended runs cost one request. A session is opened only when somebody
// answers an approval on it, because an approval is a command on the machine running
// the work and there is no side door.

import { useCallback, useMemo, useState } from "react";
import type { JSX } from "react";
import { rowFromPlane } from "@troupe/client";
import type { AdminApi, AuthSession, FleetRow, SessionRow, TriggerRun } from "@troupe/client";
import { useAdminQuery } from "../hooks";
import { InlineApprovals } from "./Approvals";
import { Cost, Loading, RowStatus, When } from "./bits";

type Origin = "trigger" | "a2a";

/** The two reasons a run is worth looking at before the ones that merely finished. */
function wentWrong(row: FleetRow): boolean {
  return row.doneReason === "budget_exhausted" || row.doneReason === "llm_error";
}

export function Review({
  auth,
  admin,
  teams,
  onOpen,
}: {
  auth: AuthSession;
  admin: AdminApi | null;
  teams: string[];
  onOpen: (id: string) => void;
}): JSX.Element {
  const [origin, setOrigin] = useState<Origin>("trigger");
  const [showReviewed, setShowReviewed] = useState(false);
  const [reviewed, setReviewed] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const { data, loading, error: listError, reload } = useAdminQuery<SessionRow[]>(
    useCallback(async () => {
      // `needs_review: true` is the plane's own filter, so an already-reviewed run is
      // not fetched and then hidden — it is never sent.
      const r = await auth.rpc<{ sessions: SessionRow[] }>("sessions.list", {
        origin,
        ...(showReviewed ? {} : { needs_review: true }),
      });
      return r.sessions;
    }, [auth, origin, showReviewed]),
    [auth, origin, showReviewed],
  );

  // The run behind each session, for the event that fired it. Administrative, so a
  // person who is not an admin sees every run and the event of none — which is the
  // right trade: the queue is for whoever owns the work, the payload is for whoever
  // runs the platform.
  const loadRuns = useCallback(async (): Promise<TriggerRun[]> => {
    if (!admin) return [];
    const perTeam = await Promise.all(teams.map((team) => admin.runs({ team, limit: 200 }).catch(() => [] as TriggerRun[])));
    return perTeam.flat();
  }, [admin, teams]);
  const { data: runs } = useAdminQuery<TriggerRun[]>(
    admin && teams.length > 0 && origin === "trigger" ? loadRuns : null,
    [loadRuns, origin],
  );

  const rows = useMemo(() => (data ?? []).map((s) => rowFromPlane(s)), [data]);
  const runByKey = useMemo(() => new Map((runs ?? []).map((r) => [r.idempotency_key, r])), [runs]);

  // Grouped by what fired it, and the groups themselves ordered by whether anything in
  // them failed. A group whose runs all finished cleanly can wait.
  const groups = useMemo(() => {
    const by = new Map<string, FleetRow[]>();
    for (const row of rows) {
      const key = (origin === "trigger" ? (row.origin?.["trigger"] as string | undefined) : (row.origin?.["kind"] as string | undefined)) ?? "unattributed";
      by.set(key, [...(by.get(key) ?? []), row]);
    }
    return [...by.entries()]
      .map(([name, members]) => ({ name, rows: members.slice().sort(worstFirst), failed: members.some(wentWrong) }))
      .sort((a, b) => (a.failed === b.failed ? a.name.localeCompare(b.name) : a.failed ? -1 : 1));
  }, [rows, origin]);

  const markReviewed = async (row: FleetRow): Promise<void> => {
    setBusy(row.id);
    setError(null);
    try {
      const updated = await auth.rpc<SessionRow>("session.review", { session_id: row.id });
      setReviewed((r) => ({ ...r, [row.id]: updated.reviewed_by ?? auth.me?.subject ?? "you" }));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const total = rows.length;

  return (
    <>
      <header className="toolbar">
        <h2>Review</h2>
        <select value={origin} onChange={(e) => setOrigin(e.target.value as Origin)} aria-label="What started it">
          <option value="trigger">Started by a trigger</option>
          <option value="a2a">Started by another agent</option>
        </select>
        <label className="inline">
          <input type="checkbox" checked={showReviewed} onChange={(e) => setShowReviewed(e.target.checked)} />
          Include what has been reviewed
        </label>
        <span className="spacer" />
        <span className="count">{loading && total === 0 ? "loading" : `${total}`}</span>
        <button onClick={reload}>Reload</button>
      </header>

      {(listError ?? error) && (
        <div className="banner error">
          <p>{listError ?? error}</p>
        </div>
      )}

      <div className="listing">
        {loading && total === 0 && <Loading what="Reading what ran while you were away…" />}

        {!loading && total === 0 && (
          <div className="empty">
            <h2>Nothing to review</h2>
            <p>
              {origin === "trigger"
                ? "Nothing a trigger started is waiting to be looked at. Runs appear here the moment they finish, and leave when you mark them reviewed."
                : "No session started by another agent is waiting to be looked at."}
            </p>
          </div>
        )}

        {groups.map((group) => (
          <section className={`group${group.failed ? " waiting" : ""}`} key={group.name}>
            <h3>
              {group.name}
              {group.failed && <span className="micro muted"> — something did not finish</span>}
            </h3>
            <ul className="inbox">
              {group.rows.map((row) => (
                <Run
                  key={row.id}
                  auth={auth}
                  row={row}
                  run={runByKey.get(String(row.origin?.["run"] ?? ""))}
                  reviewedBy={reviewed[row.id] ?? row.reviewedBy}
                  busy={busy === row.id}
                  onOpen={onOpen}
                  onReview={() => void markReviewed(row)}
                  onAnswered={reload}
                />
              ))}
            </ul>
          </section>
        ))}
      </div>
    </>
  );
}

/** Failures first, then whatever is waiting on somebody, then most recent. */
function worstFirst(a: FleetRow, b: FleetRow): number {
  if (wentWrong(a) !== wentWrong(b)) return wentWrong(a) ? -1 : 1;
  if ((a.pendingApprovals > 0) !== (b.pendingApprovals > 0)) return a.pendingApprovals > 0 ? -1 : 1;
  return Date.parse(b.lastActiveAt ?? "0") - Date.parse(a.lastActiveAt ?? "0");
}

function Run({
  auth,
  row,
  run,
  reviewedBy,
  busy,
  onOpen,
  onReview,
  onAnswered,
}: {
  auth: AuthSession;
  row: FleetRow;
  run: TriggerRun | undefined;
  reviewedBy: string | null;
  busy: boolean;
  onOpen: (id: string) => void;
  onReview: () => void;
  onAnswered: () => void;
}): JSX.Element {
  const [showEvent, setShowEvent] = useState(false);

  return (
    <li>
      <header>
        <button className="link subject" onClick={() => onOpen(row.id)}>
          {row.title ?? row.id}
        </button>
        <RowStatus row={row} />
        <span className="when">{row.profile}</span>
        <Cost micros={row.costMicros} />
        <span className="spacer" />
        <When iso={run?.fired_at ?? row.lastActiveAt} />
      </header>

      <div className="run">
        <dl className="facts">
          <dt>Fired</dt>
          <dd>
            <When iso={run?.fired_at ?? null} />
            {run?.fired_by ? ` by ${run.fired_by}` : ""}
          </dd>
          <dt>Ended</dt>
          <dd>{row.doneReason ? words(row.doneReason) : row.status ? words(row.status) : "still going"}</dd>
          {run && (
            <>
              <dt>Run</dt>
              <dd className="mono micro">{run.idempotency_key}</dd>
            </>
          )}
        </dl>

        {run?.event && (
          <details open={showEvent} onToggle={(e) => setShowEvent((e.currentTarget as HTMLDetailsElement).open)} className="tool">
            <summary>
              <span className="verb">What fired it</span>
            </summary>
            <pre className="payload">{JSON.stringify(run.event, null, 2)}</pre>
          </details>
        )}
      </div>

      {row.pendingApprovals > 0 && <InlineApprovals auth={auth} row={row} onAnswered={onAnswered} />}

      <footer className="run-actions">
        {reviewedBy ? (
          <p className="note">Reviewed by {reviewedBy}.</p>
        ) : (
          <button onClick={onReview} disabled={busy}>
            {busy ? "Marking…" : "Mark reviewed"}
          </button>
        )}
        <button className="link" onClick={() => onOpen(row.id)}>
          Open the session
        </button>
      </footer>
    </li>
  );
}

function words(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1).replace(/_/g, " ");
}
