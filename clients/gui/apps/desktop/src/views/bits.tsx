// Small pieces every screen shares.
//
// Two rules from DESIGN.md are enforced here rather than repeated everywhere: a status
// is always a dot *and* a word, never colour on its own; and amber belongs to one
// state — work that has stopped and is waiting for a person — so `waiting` is the only
// status that ever returns it.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import type { FleetRow, SessionKind } from "@troupe/client";

/** The nine states a session can be in, as the design names them. */
export type Status = "running" | "waiting" | "queued" | "allowed" | "denied" | "dormant" | "readonly" | "error" | "offline" | "private";

const WORDS: Record<Status, string> = {
  running: "Working",
  waiting: "Waiting for you",
  queued: "Queued",
  allowed: "Allowed",
  denied: "Denied",
  dormant: "Asleep",
  readonly: "Read only",
  error: "Failed",
  offline: "Offline",
  private: "Private",
};

export function Pill({ status, children, title }: { status: Status; children?: string | undefined; title?: string | undefined }): JSX.Element {
  return (
    <span className={`pill ${status}`} title={title}>
      <span className="dot" aria-hidden="true" />
      {children ?? WORDS[status]}
    </span>
  );
}

/**
 * What a row's state is, in the design's words rather than the protocol's.
 *
 * An approval waiting on somebody outranks everything else — that is the one state the
 * whole colour scheme is built around — and a session that stopped on an error outranks
 * the fact that it is technically idle.
 */
export function statusOf(row: Pick<FleetRow, "state" | "status" | "pendingApprovals" | "doneReason">): Status {
  if (row.pendingApprovals > 0 || row.status === "waiting") return "waiting";
  if (row.state === "read_only") return "readonly";
  if (row.doneReason === "budget_exhausted" || row.doneReason === "llm_error" || row.status === "interrupted") return "error";
  if (row.status && ["thinking", "acting", "compacting"].includes(row.status)) return "running";
  if (row.state === "dormant") return "dormant";
  return "queued";
}

export function RowStatus({ row }: { row: FleetRow }): JSX.Element {
  const status = statusOf(row);
  const detail = row.doneReason ?? row.status ?? row.state;
  return <Pill status={status} title={`${row.state}${row.status ? ` · ${row.status}` : ""}`}>{status === "queued" ? word(detail) : undefined}</Pill>;
}

function word(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1).replace(/_/g, " ");
}

/** Where a session runs. Private is a status colour; the other two are plain. */
export function Where({ kind }: { kind: SessionKind }): JSX.Element {
  if (kind === "private") return <Pill status="private">Private</Pill>;
  return (
    <span className="pill" title={kind === "team" ? "Runs on the platform" : "Runs on this computer"}>
      <span className="dot" aria-hidden="true" />
      {kind === "team" ? "Team" : "This computer"}
    </span>
  );
}

/** Micros as money. Nothing reported is "—", which is not the same as free. */
export function Cost({ micros }: { micros: number | null | undefined }): JSX.Element {
  // Nothing reported is not the same as nothing spent, so the two read differently.
  if (micros === null || micros === undefined) return <span className="when" title="No cost has been reported">—</span>;
  if (micros === 0) return <span className="when">$0.00</span>;
  const dollars = micros / 1_000_000;
  return (
    <span className="when" title={`${micros} micros`}>
      ${dollars < 0.01 ? dollars.toFixed(4) : dollars.toFixed(2)}
    </span>
  );
}

export function When({ iso }: { iso: string | null }): JSX.Element {
  const [, tick] = useState(0);
  useEffect(() => {
    const t = setInterval(() => tick((n) => n + 1), 30_000);
    return () => clearInterval(t);
  }, []);
  if (!iso) return <span className="when">never</span>;
  return (
    <time className="when" dateTime={iso} title={new Date(iso).toLocaleString()}>
      {relative(Date.parse(iso))}
    </time>
  );
}

function relative(at: number): string {
  const seconds = Math.round((Date.now() - at) / 1000);
  if (seconds < 60) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  return `${Math.round(hours / 24)} d ago`;
}

/**
 * A person's colour, by a stable hash of their subject. Amber is not in the set — it
 * belongs to approvals — and it is never the only signal: a name and initials go with
 * it everywhere.
 */
export function personColour(subject: string | undefined, self: string | undefined): string {
  if (!subject || subject === self) return "var(--p-self)";
  let h = 0;
  for (let i = 0; i < subject.length; i++) h = (h * 31 + subject.charCodeAt(i)) >>> 0;
  return `var(--p${(h % 6) + 1})`;
}

export function initials(name: string): string {
  const parts = name.replace(/@.*$/, "").split(/[.\s_-]+/).filter(Boolean);
  return ((parts[0]?.[0] ?? "") + (parts[1]?.[0] ?? "")).toUpperCase() || name.slice(0, 2).toUpperCase();
}

/** Dark is the default; the toggle is in the header, not buried in settings. */
export function ThemeToggle(): JSX.Element {
  const [theme, setTheme] = useState<"dark" | "light">(() => {
    const stored = read("troupe.pref.theme");
    if (stored === "light" || stored === "dark") return stored;
    return globalThis.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark";
  });

  useEffect(() => {
    document.documentElement.dataset["theme"] = theme;
    write("troupe.pref.theme", theme);
  }, [theme]);

  return (
    <button className="link" onClick={() => setTheme(theme === "dark" ? "light" : "dark")}>
      {theme === "dark" ? "Light theme" : "Dark theme"}
    </button>
  );
}

function read(k: string): string | null {
  try {
    return globalThis.localStorage?.getItem(k) ?? null;
  } catch {
    return null;
  }
}
function write(k: string, v: string): void {
  try {
    globalThis.localStorage?.setItem(k, v);
  } catch {
    /* a preference is a convenience */
  }
}

/** Loading says what is coming and in what order. No fake percentage. */
export function Loading({ what }: { what: string }): JSX.Element {
  return (
    <p className="note" aria-busy="true">
      {what}
    </p>
  );
}
