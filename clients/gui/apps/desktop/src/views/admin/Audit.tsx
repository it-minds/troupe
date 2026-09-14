// Who changed what.
//
// Every administrative write records one of these, keyed by the path it changed
// (`spec.llm.model`), so a diff reads as a sentence rather than as two documents to
// compare. The rows are the platform's, not this screen's — nothing here derives,
// aggregates or interprets; the closest it comes is folding a detail map into
// `path: from → to`, which is the shape the platform wrote it in.

import { useCallback, useState } from "react";
import type { JSX } from "react";
import type { AdminApi, AuditRow } from "@troupe/client";
import { useAdminQuery } from "../../hooks";
import { Loading, When } from "../bits";
import { Failed, Table } from "./bits";

export function AdminAudit({ api }: { api: AdminApi }): JSX.Element {
  const [team, setTeam] = useState("");
  const [limit, setLimit] = useState(50);

  const load = useCallback(() => api.audit({ limit, ...(team ? { team } : {}) }), [api, limit, team]);
  const { data, loading, error, reload } = useAdminQuery<AuditRow[]>(load, [load]);

  return (
    <>
      <section className="group">
        <h3>Audit</h3>
        <form
          className="inline-form"
          onSubmit={(e) => {
            e.preventDefault();
            reload();
          }}
        >
          <input value={team} onChange={(e) => setTeam(e.target.value)} placeholder="Any team" aria-label="Team" />
          <select value={limit} onChange={(e) => setLimit(Number(e.target.value))} aria-label="How many">
            <option value={25}>25</option>
            <option value={50}>50</option>
            <option value={200}>200</option>
          </select>
          <button type="submit">Show</button>
        </form>
      </section>

      <Failed error={error} />
      {loading && !data && <Loading what="Reading the audit…" />}

      {data && data.length === 0 && !loading && (
        <div className="empty">
          <h2>Nothing recorded</h2>
          <p>No administrative change matches that.</p>
        </div>
      )}

      {data && data.length > 0 && (
        <section className="group">
          <Table head={["When", "Who", "What", "To what", "Change"]}>
            {data.map((row, i) => (
              <tr key={`${row.occurred_at}-${i}`}>
                <td>
                  <When iso={row.occurred_at} />
                </td>
                <td className="micro">{row.actor}</td>
                <td>{row.action}</td>
                <td className="mono micro">
                  {row.subject_kind ? `${row.subject_kind} ` : ""}
                  {row.subject_id ?? "—"}
                </td>
                <td>
                  <Diff detail={row.detail} />
                </td>
              </tr>
            ))}
          </Table>
        </section>
      )}
    </>
  );
}

/**
 * The change, as the platform keyed it.
 *
 * A detail whose values are `{from, to}` is a diff and reads as one. Anything else is
 * whatever the method chose to record, and is shown as it was written rather than
 * guessed at.
 */
function Diff({ detail }: { detail: Record<string, unknown> | null }): JSX.Element {
  if (!detail || Object.keys(detail).length === 0) return <span className="when">—</span>;

  const entries = Object.entries(detail);
  const diffs = entries.filter(([, v]) => isFromTo(v));
  if (diffs.length === 0) {
    return (
      <span className="micro mono">
        {entries
          .map(([k, v]) => `${k}: ${short(v)}`)
          .join(", ")}
      </span>
    );
  }

  return (
    <ul className="diff">
      {diffs.map(([path, v]) => {
        const { from, to } = v as { from?: unknown; to?: unknown };
        return (
          <li key={path}>
            <code className="mono micro">{path}</code> <span className="was">{short(from)}</span> → <span className="now">{short(to)}</span>
          </li>
        );
      })}
    </ul>
  );
}

function isFromTo(v: unknown): boolean {
  return typeof v === "object" && v !== null && !Array.isArray(v) && ("from" in v || "to" in v);
}

function short(v: unknown): string {
  if (v === null || v === undefined) return "nothing";
  if (typeof v === "string") return v.length > 40 ? `${v.slice(0, 40)}…` : v;
  const s = JSON.stringify(v);
  return s.length > 40 ? `${s.slice(0, 40)}…` : s;
}
