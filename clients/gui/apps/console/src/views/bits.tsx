// The pieces every screen is made of: the three states a read can be in, a status that is
// a glyph and a word as well as a colour, and the one way the console changes anything —
// a preview of what will happen, a plain confirm, and the audit's own note of what moved.

import { useState } from "react";
import type { JSX, ReactNode } from "react";
import type { AuditChanges } from "@troupe/client";
import { describeError, show } from "../console";
import type { Load } from "../console";

export function Loading({ what }: { what: string }): JSX.Element {
  return (
    <div className="state loading" role="status" aria-live="polite">
      <span className="bar" aria-hidden="true" />
      <span>Loading {what}…</span>
    </div>
  );
}

export function Failure({ error, what, retry }: { error: unknown; what: string; retry?: () => void }): JSX.Element {
  return (
    <div className="state failure" role="alert">
      <span className="status denied">✕ Could not load {what}</span>
      <p>{describeError(error)}</p>
      {retry && (
        <button type="button" onClick={retry}>
          Try again
        </button>
      )}
    </div>
  );
}

export function Empty({ title, children }: { title: string; children?: ReactNode }): JSX.Element {
  return (
    <div className="state empty">
      <span className="status muted">○ {title}</span>
      {children && <div className="next">{children}</div>}
    </div>
  );
}

/** A read's three states, and the screen once it has its answer. */
export function Loaded<T>({ load, what, retry, children }: { load: Load<T>; what: string; retry: () => void; children: (data: T) => ReactNode }): JSX.Element {
  if (load.state === "loading") return <Loading what={what} />;
  if (load.state === "error") return <Failure error={load.error} what={what} retry={retry} />;
  return <>{children(load.data)}</>;
}

export type StatusKind = "running" | "waiting" | "denied" | "dormant" | "muted" | "local";

/** A status is a glyph and a word; the colour says it a third time and never alone. */
export function Status({ kind, glyph, children }: { kind: StatusKind; glyph: string; children: ReactNode }): JSX.Element {
  return (
    <span className={`status ${kind}`}>
      <span aria-hidden="true">{glyph}</span> {children}
    </span>
  );
}

/** A region's label, in the screen face: `// LIMITS`. */
export function Region({ children, tone }: { children: ReactNode; tone?: "waiting" }): JSX.Element {
  return <h2 className={`screen${tone ? ` ${tone}` : ""}`}>{children}</h2>;
}

/** One line of a preview's diff: a field, and what it was and will be. */
export interface DiffLine {
  field: string;
  from: unknown;
  to: unknown;
}

/**
 * Preview, then confirm: what will change, field by field, and what that does, in words,
 * before anything is sent. A plain confirm for a change that can be changed back; one
 * that destroys something is confirmed by typing `typeToConfirm`, its subject's name.
 */
export function Preview({
  title,
  lines,
  effects,
  verb,
  typeToConfirm,
  onConfirm,
  onCancel,
}: {
  title: string;
  lines: DiffLine[];
  effects: string[];
  verb: string;
  typeToConfirm?: string | null;
  onConfirm: () => Promise<void>;
  onCancel: () => void;
}): JSX.Element {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [typed, setTyped] = useState("");
  const blocked = Boolean(typeToConfirm) && typed !== typeToConfirm;
  return (
    <section className="preview" aria-label="What will happen">
      <Region tone="waiting">What will happen</Region>
      <div className="box">
        <div className="diff mono">
          <div className="hunk">@@ {title} @@</div>
          {lines.length === 0 && <div className="ctx">nothing changes</div>}
          {lines.map((l) => (
            <div key={l.field} className="change">
              <div className="del">
                <span aria-hidden="true">−</span> {l.field}: {show(l.from)}
              </div>
              <div className="add">
                <span aria-hidden="true">+</span> {l.field}: {show(l.to)}
              </div>
            </div>
          ))}
        </div>
        {effects.length > 0 && (
          <ul className="effects">
            {effects.map((e) => (
              <li key={e}>{e}</li>
            ))}
          </ul>
        )}
        {typeToConfirm && (
          <label className="type-to-confirm">
            Type <code>{typeToConfirm}</code> to confirm
            <input value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" spellCheck={false} />
          </label>
        )}
        {error !== null && (
          <p className="field-error" role="alert">
            {describeError(error)}
          </p>
        )}
        <div className="actions">
          <button
            type="button"
            className="primary"
            disabled={busy || lines.length === 0 || blocked}
            onClick={() => {
              setBusy(true);
              setError(null);
              onConfirm().then(
                () => setBusy(false),
                (e: unknown) => {
                  setBusy(false);
                  setError(e);
                },
              );
            }}
          >
            {busy ? "Applying…" : verb}
          </button>
          <button type="button" onClick={onCancel} disabled={busy}>
            Back to editing
          </button>
          <span className="hint">{blocked ? "The name must match exactly." : `Nothing changes until you ${verb.toLowerCase()}.`}</span>
        </div>
      </div>
    </section>
  );
}

/**
 * What the plane recorded: the audit's own diff for the change just made, as the write
 * answered it, so the person sees the record rather than the console's idea of it.
 */
export function AuditNote({ action, subject, changes }: { action: string; subject: string; changes: AuditChanges }): JSX.Element {
  const moved = Object.entries(changes);
  return (
    <div className="audit-note" role="status">
      <span className="status running">
        <span aria-hidden="true">●</span> Applied
      </span>{" "}
      <span>
        Recorded in the audit as <code>{action}</code> on <code>{subject}</code>
        {moved.length === 0 ? ", with nothing that moved." : ":"}
      </span>
      {moved.length > 0 && (
        <ul>
          {moved.map(([field, { from, to }]) => (
            <li key={field}>
              <code>{field}</code> <span className="from">{show(from)}</span> → <span className="to">{show(to)}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** The fields that differ between what is and what is asked, as a preview shows them. */
export function changed(before: Record<string, unknown>, after: Record<string, unknown>): DiffLine[] {
  return Object.keys(after)
    .filter((k) => JSON.stringify(before[k] ?? null) !== JSON.stringify(after[k] ?? null))
    .map((k) => ({ field: k, from: before[k] ?? null, to: after[k] ?? null }));
}

/** Money in millionths of a currency unit, as the plane keeps it, in units. */
export function money(micros: number | null | undefined): string {
  if (micros === null || micros === undefined) return "—";
  return (micros / 1_000_000).toLocaleString("en", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** A time the plane wrote, as a date and a minute, in UTC like the audit. */
export function when(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : `${d.toISOString().slice(0, 16).replace("T", " ")} UTC`;
}
