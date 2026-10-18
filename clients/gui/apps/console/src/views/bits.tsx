// The pieces every screen is made of: the three states a read can be in, a status that is
// a glyph and a word as well as a colour, and the one way the console changes anything —
// a preview of what will happen, a plain confirm, and the audit's own note of what moved.

import { useEffect, useId, useRef, useState } from "react";
import type { JSX, ReactNode } from "react";
import { describeError, recorded, show, useConsole } from "../console";
import type { Load } from "../console";

/** What a field's control is given, so its label names it and its hint describes it. */
export interface FieldProps {
  id: string;
  "aria-describedby"?: string;
  "aria-invalid"?: boolean;
}

/**
 * A form field named by its label, for a screen reader as for the eye: the label's words
 * are the control's name, the hint beside it is its description rather than part of the
 * name, and a placeholder is never what names it.
 */
export function Field({
  label,
  hint,
  error,
  children,
}: {
  label: ReactNode;
  hint?: ReactNode;
  error?: string | null;
  children: (props: FieldProps) => ReactNode;
}): JSX.Element {
  const id = useId();
  const described = [hint ? `${id}-hint` : null, error ? `${id}-error` : null].filter(Boolean).join(" ");
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      {children({ id, ...(described ? { "aria-describedby": described } : {}), ...(error ? { "aria-invalid": true } : {}) })}
      {hint && (
        <span id={`${id}-hint`} className="hint">
          {hint}
        </span>
      )}
      {error && (
        <span id={`${id}-error`} className="field-error">
          {error}
        </span>
      )}
    </div>
  );
}

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
  // Asked for from a row far down a list, the preview is where the eye and the keyboard go
  // next, not somewhere above the fold.
  const here = useRef<HTMLElement>(null);
  useEffect(() => {
    here.current?.scrollIntoView?.({ block: "nearest" });
    here.current?.focus({ preventScroll: true });
  }, []);
  return (
    <section className="preview" aria-label="What will happen" ref={here} tabIndex={-1}>
      <Region tone="waiting">What will happen</Region>
      <div className="box">
        <Diff title={title} lines={lines} />
        {effects.length > 0 && (
          <ul className="effects">
            {effects.map((e) => (
              <li key={e}>{e}</li>
            ))}
          </ul>
        )}
        {typeToConfirm && (
          <div className="type-to-confirm">
            <Field
              label={
                <>
                  Type <code>{typeToConfirm}</code> to confirm
                </>
              }
            >
              {(p) => <input {...p} value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" spellCheck={false} />}
            </Field>
          </div>
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

/** A diff in the one shape the console shows every diff in: a hunk header, then each field from and to. */
export function Diff({ title, lines }: { title: string; lines: DiffLine[] }): JSX.Element {
  return (
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
  );
}

/** The audit's diff (a dotted path per field that moved) as a preview's lines, in path order. */
export function linesOf(changes: Record<string, { from: unknown; to: unknown }>): DiffLine[] {
  return Object.entries(changes)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([field, c]) => ({ field, from: c.from, to: c.to }));
}

/** A change once made, as the audit recorded it. */
export interface Done {
  action: string;
  subject: string;
  detail: Record<string, unknown> | null;
}

/**
 * Make a change and show it as recorded: send it, take the audit's diff from the answer
 * where the write gives one or read the audit's row back where it does not, tell the
 * person, and read the screen again. A refusal throws, and the preview shows it where the
 * change was asked for.
 */
export function useChange(onApplied: () => void): {
  done: Done | null;
  clear: () => void;
  apply: (action: string, subject: string, write: () => Promise<unknown>, said: string, changes?: (answer: unknown) => Record<string, unknown> | undefined) => Promise<void>;
} {
  const { admin, me, notify } = useConsole();
  const [done, setDone] = useState<Done | null>(null);
  const apply = async (action: string, subject: string, write: () => Promise<unknown>, said: string, changes?: (answer: unknown) => Record<string, unknown> | undefined): Promise<void> => {
    const answer = await write();
    const given = changes?.(answer);
    setDone({ action, subject, detail: given ?? (await recorded(admin, me.subject, action, subject)) });
    notify(said);
    onApplied();
  };
  return { done, clear: () => setDone(null), apply };
}

/**
 * What a plane in `gitops` mode holds in a repository rather than here: said first, with
 * where the repository is, because a screen with nothing to press and no reason given reads
 * as a broken one. The plane refuses a write to any of it, so nothing here offers one.
 */
export function Locked({ things, source, children }: { things: string; source: string | null | undefined; children?: ReactNode }): JSX.Element {
  return (
    <section className="banner locked" role="note" aria-label="Held in a repository">
      <Status kind="dormant" glyph="◆">
        Held in a repository
      </Status>
      <p>
        This plane is in <code>gitops</code> mode: its {things} are resources a repository holds{source ? <> (<code>{source}</code>)</> : null}, and a change
        to one is a commit there. The plane refuses a write from here, so nothing on this screen offers one.
      </p>
      {children}
    </section>
  );
}

/** What the last pass made of something a repository holds, when it was not simply used. */
export function GitopsProblem({ gitops }: { gitops: { problem: string | null; reasons?: string[]; generation?: number | null } | null | undefined }): JSX.Element | null {
  if (!gitops?.problem) return null;
  const words: Record<string, string> = {
    refused: "The plane refused the resource, and does not use it",
    missing: "The cluster has no resource for it: the plane kept the row from before it read the cluster",
    plane_only: "Nothing applies it from a repository yet",
    unwritten: "The plane has not written it to the cluster",
    unknown_teams: "It names teams this plane does not have; the rest of it is used",
  };
  return (
    <div className="gitops-problem" role="status">
      <Status kind={gitops.problem === "refused" ? "denied" : "waiting"} glyph={gitops.problem === "refused" ? "✕" : "◆"}>
        {gitops.problem.replace("_", " ")}
      </Status>{" "}
      <span>{words[gitops.problem] ?? gitops.problem}.</span>
      {gitops.reasons && gitops.reasons.length > 0 && (
        <ul className="plain">
          {gitops.reasons.map((r) => (
            <li key={r}>{r}</li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** How a plane provisions, from `admin.provisioning.mode`'s answer, whichever shape it takes. */
export function modeOf(answer: unknown): string | null {
  if (typeof answer === "string") return answer;
  if (typeof answer === "object" && answer !== null && typeof (answer as { mode?: unknown }).mode === "string") return (answer as { mode: string }).mode;
  return null;
}

/** A title block: what a thing is configured as, a labelled field each, in a fixed order. */
export function Fields({ rows, paths = false }: { rows: Array<[string, ReactNode]>; paths?: boolean }): JSX.Element {
  return (
    <dl className={paths ? "fields paths" : "fields"}>
      {rows.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}

/**
 * What the plane recorded: the audit's own detail for the change just made, as the write
 * answered it or as `admin.audit.list` reads it back, so the person sees the record rather
 * than the console's idea of it. A field that moved reads from → to; one that names what
 * the change was about (a group, a profile, a person) reads as itself. `detail` is null
 * where the record could not be read back, which is said rather than hidden.
 */
export function AuditNote({ action, subject, detail }: { action: string; subject: string; detail: Record<string, unknown> | null }): JSX.Element {
  const entries = Object.entries(detail ?? {});
  return (
    <div className="audit-note" role="status">
      <span className="status running">
        <span aria-hidden="true">●</span> Applied
      </span>{" "}
      {detail === null ? (
        <span>
          The plane applied it as <code>{action}</code> on <code>{subject}</code>; its audit record could not be read back here.
        </span>
      ) : (
        <span>
          Recorded in the audit as <code>{action}</code> on <code>{subject}</code>
          {entries.length === 0 ? ", with nothing that moved." : ":"}
        </span>
      )}
      {entries.length > 0 && <DetailList detail={detail ?? {}} />}
    </div>
  );
}

/** An audit row's detail, a line per field: from → to where it moved, else what it named. */
export function DetailList({ detail }: { detail: Record<string, unknown> }): JSX.Element {
  return (
    <ul className="detail">
      {Object.entries(detail).map(([field, value]) => (
        <li key={field}>
          <code>{field}</code>{" "}
          {moved(value) ? (
            <>
              <span className="from">{show(value.from)}</span> → <span className="to">{show(value.to)}</span>
            </>
          ) : (
            <span className="to">{show(value)}</span>
          )}
        </li>
      ))}
    </ul>
  );
}

function moved(value: unknown): value is { from: unknown; to: unknown } {
  return typeof value === "object" && value !== null && "from" in value && "to" in value;
}

/**
 * A secret the plane minted and answers once: shown here, with a way to copy it, and in no
 * later answer. Leaving the screen loses it, which is said beside it rather than found out.
 */
export function ShownOnce({ label, value, children }: { label: string; value: string; children?: ReactNode }): JSX.Element {
  const [copied, setCopied] = useState(false);
  return (
    <section className="banner shown-once" role="status" aria-label={label}>
      <Status kind="waiting" glyph="◆">
        {label}, shown once
      </Status>
      <pre className="mono secret">{value}</pre>
      <div className="actions">
        <button
          type="button"
          onClick={() => {
            void globalThis.navigator?.clipboard?.writeText(value).then(
              () => setCopied(true),
              () => setCopied(false),
            );
          }}
        >
          {copied ? "Copied" : "Copy"}
        </button>
        <span className="hint">The plane keeps only a hash of it: no answer shows it again, and leaving this screen loses it.</span>
      </div>
      {children}
    </section>
  );
}

/** A set of named checks, each passed or not with what it found: a provider's, an App's, a group's. */
export function Checks({ checks }: { checks: Array<{ name: string; ok: boolean; detail?: string; took_ms?: number }> }): JSX.Element {
  return (
    <ul className="plain checks">
      {checks.map((c) => (
        <li key={c.name}>
          <Status kind={c.ok ? "running" : "denied"} glyph={c.ok ? "●" : "✕"}>
            {c.name}
          </Status>{" "}
          <span>{c.detail}</span>
        </li>
      ))}
    </ul>
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

/** Bytes, in binary units, as a volume and a disk are measured and `kubectl` shows them. */
export function bytes(count: number | null | undefined): string {
  if (count === null || count === undefined) return "—";
  if (count < 1024) return `${count} B`;
  const units = ["KiB", "MiB", "GiB", "TiB"];
  let n = count / 1024;
  let unit = 0;
  while (n >= 1024 && unit < units.length - 1) {
    n /= 1024;
    unit += 1;
  }
  return `${n.toFixed(1)} ${units[unit]}`;
}

/** How many of something, with the word in the right number: `1 fork`, `3 forks`. */
export function count(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

/** A time the plane wrote, as a date and a minute, in UTC like the audit. */
export function when(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : `${d.toISOString().slice(0, 16).replace("T", " ")} UTC`;
}
