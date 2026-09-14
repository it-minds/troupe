// The pieces every administrative screen shares.
//
// Two of them are rules rather than conveniences. `AfterTheChange` reads the audit row
// a write produced and shows it: an admin screen that says "saved" is asking to be
// believed, and one that shows the record it wrote is not. `Confirm` makes an
// irreversible action require typing the thing's own name — the same rule the platform
// applies to a model calling the destructive methods over MCP, applied to the person
// who has a dialog to read.

import { useEffect, useState } from "react";
import type { JSX, ReactNode } from "react";
import type { AdminApi, AuditRow } from "@troupe/client";

/** Micros as money, for budgets and spend. */
export function Money({ micros }: { micros: number | null | undefined }): JSX.Element {
  if (micros === null || micros === undefined) return <span className="when">—</span>;
  const dollars = micros / 1_000_000;
  return <span className="when">${dollars < 0.01 && dollars > 0 ? dollars.toFixed(4) : dollars.toFixed(2)}</span>;
}

export function Bytes({ n }: { n: number | null | undefined }): JSX.Element {
  if (n === null || n === undefined) return <span className="when">—</span>;
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return <span className="when">{`${v < 10 && i > 0 ? v.toFixed(1) : Math.round(v)} ${units[i]}`}</span>;
}

/** A plain data table. Scrolls on its own so the page never does, sideways. */
export function Table({ head, children }: { head: string[]; children: ReactNode }): JSX.Element {
  return (
    <div className="table-scroll">
      <table className="table">
        <thead>
          <tr>
            {head.map((h) => (
              <th key={h} scope="col">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  );
}

/**
 * The audit row the last write produced.
 *
 * Re-read whenever `nonce` changes, which a screen bumps after a successful action. The
 * newest row is the one that action wrote, because these methods are audited
 * synchronously with the change they make.
 */
export function AfterTheChange({ api, nonce }: { api: AdminApi; nonce: number }): JSX.Element | null {
  const [row, setRow] = useState<AuditRow | null>(null);

  useEffect(() => {
    if (nonce === 0) return;
    let live = true;
    api
      .audit({ limit: 1 })
      .then((rows) => live && setRow(rows[0] ?? null))
      .catch(() => live && setRow(null));
    return () => {
      live = false;
    };
  }, [api, nonce]);

  if (!row) return null;
  return (
    <p className="note" role="status">
      Recorded: <strong>{row.action}</strong> on {row.subject_id ?? row.subject_kind ?? "the platform"} by {row.actor}.
    </p>
  );
}

/**
 * An irreversible action, gated on typing the thing's own identifier.
 *
 * Not a checkbox and not a second button. The identifier is what the person has to
 * produce, so the action cannot be completed by muscle memory on the wrong row.
 */
export function Confirm({
  what,
  identifier,
  consequence,
  busy,
  onCancel,
  onConfirm,
}: {
  what: string;
  identifier: string;
  consequence: string;
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}): JSX.Element {
  const [typed, setTyped] = useState("");

  return (
    <div className="scrim" onClick={onCancel}>
      <div className="dialog" role="dialog" aria-modal="true" aria-label={what} onClick={(e) => e.stopPropagation()}>
        <h1>{what}</h1>
        <p className="copy">{consequence}</p>
        <label>
          Type <code className="mono">{identifier}</code> to confirm
          <input value={typed} onChange={(e) => setTyped(e.target.value)} autoFocus spellCheck={false} />
        </label>
        <div className="actions">
          <button onClick={onCancel}>Cancel</button>
          <button className="primary danger" disabled={busy || typed !== identifier} onClick={onConfirm}>
            {busy ? "Working…" : what}
          </button>
        </div>
      </div>
    </div>
  );
}

/** A read that failed, said once and in the same place on every screen. */
export function Failed({ error }: { error: string | null }): JSX.Element | null {
  if (!error) return null;
  return (
    <div className="banner error">
      <p>{error}</p>
    </div>
  );
}
