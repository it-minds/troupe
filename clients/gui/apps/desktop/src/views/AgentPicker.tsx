// The one agent picker (troupe #594): the start screen's and a session's head's, the same
// rows and the same three actions wherever it is.
//
// The rows are the daemon's `agents.list`, for a session (`agents.list` with it named, on
// this computer or on a pod) or for a workspace about to have one, and nothing else: each
// says where its agent comes from in the four words a person uses, grouped by them, what
// it stands in for, its model, whether it is read-only and how many tools it holds, and,
// greyed with the reason, one that cannot run here. The words are the daemon's; a daemon
// from before them is read by its layer (`originOf`).
//
// The actions say what they will do before they do it, and what cannot be done here is
// refused with why rather than hidden: Start a session on the agent, Switch the session to
// it, and Edit its file, which opens a person's or a repository's agent in the editor their
// system opens Markdown with (the shell's `openAgentFile`) and is refused, in the daemon's
// sentence, for one Troupe ships or an organisation's bundle carries.

import { useMemo, useState } from "react";
import type { JSX } from "react";
import { AGENT_ORIGINS, originOf } from "@troupe/client";
import type { AgentRow } from "@troupe/client";
import { shell } from "../shell";

/** What an action does, or why it is not done here. */
export type PickerAction = ((name: string) => Promise<void>) | string;

export function AgentPicker({
  label,
  rows,
  error,
  current,
  chosen,
  onChoose,
  start,
  switchTo,
}: {
  /** What the picker is, for a screen reader and a test: "Agents", "The agent it starts as". */
  label: string;
  /** Null while the daemon is asked. */
  rows: AgentRow[] | null;
  error?: string | null;
  /** The agent running now, marked. */
  current: string | null;
  /**
   * The agent selected, where the screen keeps it (null for none yet); left out, the picker
   * keeps it, starting on the one running now.
   */
  chosen?: string | null;
  onChoose?: (name: string) => void;
  start: PickerAction;
  switchTo: PickerAction;
}): JSX.Element {
  const [own, setOwn] = useState<string | null>(null);
  const [said, setSaid] = useState<{ text: string; refused: boolean } | null>(null);
  const [busy, setBusy] = useState(false);
  const picked = chosen !== undefined ? chosen : (own ?? current ?? rows?.[0]?.name ?? null);
  const row = rows?.find((r) => r.name === picked) ?? null;

  const groups = useMemo(() => {
    const by = new Map<string, AgentRow[]>();
    for (const r of rows ?? []) by.set(originOf(r), [...(by.get(originOf(r)) ?? []), r]);
    const order = [...AGENT_ORIGINS, ...[...by.keys()].filter((o) => !(AGENT_ORIGINS as readonly string[]).includes(o))];
    return order.filter((o) => by.has(o)).map((o) => ({ origin: o, rows: by.get(o)! }));
  }, [rows]);

  const choose = (name: string): void => {
    setOwn(name);
    setSaid(null);
    onChoose?.(name);
  };

  // Start and Switch run an agent: one the daemon says cannot run here is refused with why.
  const run = async (action: PickerAction): Promise<void> => {
    if (!row) return;
    if (typeof action === "string") return setSaid({ text: action, refused: true });
    if (row.available === false) return setSaid({ text: `${row.name} cannot run here: ${row.reason ?? "the daemon says so"}`, refused: true });
    setBusy(true);
    setSaid(null);
    try {
      await action(row.name);
    } catch (e) {
      setSaid({ text: e instanceof Error ? e.message : String(e), refused: true });
    } finally {
      setBusy(false);
    }
  };

  const edit = async (): Promise<void> => {
    if (!row) return;
    if (row.editable === false) return setSaid({ text: row.editable_reason ?? `${row.name} is not changed here`, refused: true });
    const open = shell()?.openAgentFile;
    if (!row.path) return setSaid({ text: `${row.name} has no file to open here`, refused: true });
    if (!open) return setSaid({ text: `Opening ${row.path} in your editor takes the desktop app; the agents manager edits it here`, refused: true });
    setBusy(true);
    try {
      await open(row.path);
      setSaid({ text: `${row.path} is open in your editor: what you save there is read at the next start or switch`, refused: false });
    } catch (e) {
      setSaid({ text: e instanceof Error ? e.message : String(e), refused: true });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="agent-picker" role="group" aria-label={label}>
      {error && (
        <p className="micro error" role="alert">
          {error}
        </p>
      )}
      {rows === null && !error && <p className="note">Asking the daemon for the agents…</p>}
      {rows !== null && rows.length === 0 && <p className="note">The daemon lists no agent here.</p>}
      <div className="agent-picker-list" role="listbox" aria-label="Agent">
        {groups.map((g) => (
          <div key={g.origin} className="agent-picker-group" role="group" aria-label={g.origin}>
            <span className="screen">{g.origin}</span>
            {g.rows.map((r) => (
              <button
                key={r.name}
                type="button"
                role="option"
                aria-selected={r.name === picked}
                aria-disabled={r.available === false}
                className={`agent-option${r.available === false ? " unavailable" : ""}`}
                onClick={() => choose(r.name)}
                title={r.available === false ? (r.reason ?? undefined) : r.description}
              >
                <span className="name mono">
                  {r.name}
                  {r.name === current ? " ●" : ""}
                </span>
                <span className="facts">
                  {[r.model ?? "the session's model", r.read_only ? "read only" : null, typeof r.tool_count === "number" ? `${r.tool_count} tools` : null]
                    .filter(Boolean)
                    .join(" · ")}
                </span>
                {r.available === false && <span className="why">cannot run here: {r.reason}</span>}
              </button>
            ))}
          </div>
        ))}
      </div>

      {row && (
        <div className="agent-picker-detail" aria-label={`The agent ${row.name}`}>
          <p>{row.description || "No description."}</p>
          <p className="note">
            From: {originOf(row)}
            {row.profile ? ` (the ${row.profile} profile)` : ""}
            {row.overrides && row.overrides.length > 0 ? ` · stands in for ${row.overrides.map((o) => o.origin ?? o.layer).join(", ")}` : ""}
          </p>
          <div className="actions">
            <button type="button" className="primary" disabled={busy} onClick={() => void run(start)}>
              Start a session on {row.name}
            </button>
            <button type="button" disabled={busy} onClick={() => void run(switchTo)}>
              Switch to {row.name}
            </button>
            <button type="button" disabled={busy} onClick={() => void edit()}>
              Edit {row.name}'s file
            </button>
          </div>
        </div>
      )}
      {said && (
        <p className={`micro${said.refused ? " error" : ""}`} role={said.refused ? "alert" : "status"}>
          {said.text}
        </p>
      )}
    </div>
  );
}
