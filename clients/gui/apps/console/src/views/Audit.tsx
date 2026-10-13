// Who changed what, and when, with what moved: the audit trail, newest first, from
// `admin.audit.list`. Narrowed at the plane by actor, kind and subject, searched here over
// what came back, and read further a hundred rows at a time.
//
// And whether any of it is still true. A table of rows is only as trustworthy as the
// database it sits in, so a platform admin can have the plane walk the hash chain
// (`admin.audit.verify`) and name the first row that does not verify. On request rather
// than on load: the walk reads the whole trail.

import { useState } from "react";
import type { JSX } from "react";
import type { AuditIntegrity } from "@troupe/client";
import { useConsole, useLoad } from "../console";
import { DetailList, Empty, Failure, Field, Loaded, Loading, Region, Status, when } from "./bits";

const STEP = 100;

interface Filter {
  actor: string;
  kind: string;
  subject_id: string;
}

const NONE: Filter = { actor: "", kind: "", subject_id: "" };

export function Audit(): JSX.Element {
  const { admin, role } = useConsole();
  const [draft, setDraft] = useState<Filter>(NONE);
  const [filter, setFilter] = useState<Filter>(NONE);
  const [limit, setLimit] = useState(STEP);
  const [query, setQuery] = useState("");
  const asked = Object.fromEntries(Object.entries(filter).filter(([, v]) => v.trim() !== "").map(([k, v]) => [k, v.trim()]));
  const [load, reload] = useLoad(() => admin.audit({ ...asked, limit }), [admin, filter.actor, filter.kind, filter.subject_id, limit]);
  const q = query.trim().toLowerCase();

  return (
    <div className="page">
      <p className="lead">Who changed what and when, newest first, with every field that moved. Recorded by the plane on every change, from any client.</p>
      <form
        className="toolbar filters"
        onSubmit={(e) => {
          e.preventDefault();
          setFilter(draft);
          setLimit(STEP);
        }}
      >
        <Field label="Actor">
          {(p) => <input {...p} value={draft.actor} onChange={(e) => setDraft({ ...draft, actor: e.target.value })} autoComplete="off" spellCheck={false} />}
        </Field>
        <Field label="Kind">
          {(p) => <input {...p} value={draft.kind} onChange={(e) => setDraft({ ...draft, kind: e.target.value })} list="audit-kinds" autoComplete="off" spellCheck={false} />}
        </Field>
        <datalist id="audit-kinds">
          {["team", "setting", "clients", "session", "profile", "principal", "trigger", "bundle", "host", "provider", "scim", "pod"].map((k) => (
            <option key={k} value={k} />
          ))}
        </datalist>
        <Field label="Subject">
          {(p) => <input {...p} value={draft.subject_id} onChange={(e) => setDraft({ ...draft, subject_id: e.target.value })} autoComplete="off" spellCheck={false} />}
        </Field>
        <div className="actions">
          <button type="submit" className="primary">
            Filter
          </button>
          {(filter.actor || filter.kind || filter.subject_id) && (
            <button
              type="button"
              onClick={() => {
                setDraft(NONE);
                setFilter(NONE);
                setLimit(STEP);
              }}
            >
              Clear
            </button>
          )}
        </div>
      </form>
      <div className="toolbar">
        <input aria-label="Search the audit" placeholder="search what came back: an action, a subject, a value…" value={query} onChange={(e) => setQuery(e.target.value)} />
      </div>
      <Loaded load={load} what="the audit" retry={reload}>
        {(rows) => {
          const shown = rows.filter((r) => !q || JSON.stringify([r.actor, r.action, r.subject_id, r.detail]).toLowerCase().includes(q));
          if (rows.length === 0) {
            return (
              <Empty title={asked["actor"] || asked["kind"] || asked["subject_id"] ? "Nothing recorded that matches" : "Nothing recorded yet"}>
                {asked["actor"] || asked["kind"] || asked["subject_id"] ? "Clear the filter to see everything." : "Every change anybody makes to this plane lands here."}
              </Empty>
            );
          }
          return (
            <>
              {shown.length === 0 ? (
                <Empty title={`Nothing here matches "${query.trim()}"`}>Search by an action, a subject, an actor or a value that moved.</Empty>
              ) : (
                <div className="scroll">
                  <table className="audit">
                    <thead>
                      <tr>
                        <th>When</th>
                        <th>Who</th>
                        <th>What</th>
                        <th>On</th>
                        <th>Changes</th>
                      </tr>
                    </thead>
                    <tbody>
                      {shown.map((r, i) => (
                        <tr key={`${r.occurred_at}:${r.action}:${r.subject_id ?? ""}:${i}`}>
                          <td className="nowrap">{when(r.occurred_at)}</td>
                          <td className="mono">{r.actor}</td>
                          <td>
                            <code>{r.action}</code>
                          </td>
                          <td className="mono">{r.subject_id ?? "—"}</td>
                          <td>{r.detail && Object.keys(r.detail).length > 0 ? <DetailList detail={r.detail} /> : <span className="muted">—</span>}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              <div className="pager">
                <span className="meta">
                  {shown.length} of the {rows.length} newest
                </span>
                {rows.length >= limit && (
                  <button type="button" onClick={() => setLimit(limit + STEP)}>
                    Show {STEP} more
                  </button>
                )}
              </div>
            </>
          );
        }}
      </Loaded>
      {role === "platform_admin" && <Integrity />}
    </div>
  );
}

/** The chain's check, a platform admin's: the trail is the whole plane's. */
function Integrity(): JSX.Element {
  const { admin } = useConsole();
  const [check, setCheck] = useState<{ state: "idle" } | { state: "running" } | { state: "done"; answer: AuditIntegrity } | { state: "failed"; error: unknown }>({
    state: "idle",
  });
  const run = () => {
    setCheck({ state: "running" });
    admin.verifyAudit().then(
      (answer) => setCheck({ state: "done", answer }),
      (error: unknown) => setCheck({ state: "failed", error }),
    );
  };
  return (
    <section className="card integrity" aria-label="Integrity">
      <Region>Integrity</Region>
      <p className="lead">
        Every row carries a digest of its own content and of the row before it. The plane recomputes both from what is stored and stops at the first one
        that does not match. It changes nothing.
      </p>
      {check.state === "running" && <Loading what="the whole trail, row by row" />}
      {check.state === "failed" && <Failure error={check.error} what="the chain's check" retry={run} />}
      {check.state === "done" && <Verdict answer={check.answer} />}
      {check.state !== "running" && (
        <button type="button" onClick={run}>
          {check.state === "idle" ? "Check the chain" : "Check it again"}
        </button>
      )}
    </section>
  );
}

function Verdict({ answer }: { answer: AuditIntegrity }): JSX.Element {
  const from = answer.from ? ` back to ${when(answer.from)}` : "";
  const unchained = answer.unchained > 0 ? ` ${answer.unchained} written before the chain existed are covered by nothing.` : " Every row is chained.";
  if (answer.result === "ok" && answer.checked === 0) {
    return (
      <div className="verdict">
        <Status kind="muted" glyph="○">
          Nothing is chained yet
        </Status>
        <p>Every row was written before the chain existed. The chain starts at the next change somebody makes.</p>
      </div>
    );
  }
  if (answer.result === "ok") {
    return (
      <div className="verdict">
        <Status kind="running" glyph="●">
          The chain verifies
        </Status>
        <p>
          {answer.checked} chained rows{from}.{unchained}
        </p>
      </div>
    );
  }
  const row = (typeof answer.result === "object" && answer.result !== null ? answer.result : {}) as Record<string, unknown>;
  const bad = (typeof row["error"] === "object" && row["error"] !== null ? row["error"] : row) as Record<string, unknown>;
  return (
    <div className="verdict">
      <Status kind="denied" glyph="✕">
        A row does not verify
      </Status>
      <p>
        <code>{String(bad["action"] ?? "a row")}</code> on <code>{String(bad["subject_id"] ?? "—")}</code> by {String(bad["actor"] ?? "somebody")}
        {bad["occurred_at"] ? `, at ${when(String(bad["occurred_at"]))}` : ""}:{" "}
        {bad["reason"] === "chain_broken" ? "the row before it is not the one that was there; something was removed or inserted." : "its content no longer hashes to what it says."}
      </p>
      <p>Everything before this row still verifies; nothing after it can be trusted until this is explained.</p>
    </div>
  );
}
