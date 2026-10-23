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

/** The rows by where they come from, in the four words' order, any other word after them. */
export function originGroups(rows: AgentRow[]): Array<{ origin: string; rows: AgentRow[] }> {
  const by = new Map<string, AgentRow[]>();
  for (const r of rows) by.set(originOf(r), [...(by.get(originOf(r)) ?? []), r]);
  const order = [...AGENT_ORIGINS, ...[...by.keys()].filter((o) => !(AGENT_ORIGINS as readonly string[]).includes(o))];
  return order.filter((o) => by.has(o)).map((o) => ({ origin: o, rows: by.get(o)! }));
}

/** Where a row comes from, the profile a bundle's came with, and what it stands in for. */
export function fromWords(row: AgentRow): string {
  return (
    `From: ${originOf(row)}` +
    (row.profile ? ` (the ${row.profile} profile)` : "") +
    (row.overrides && row.overrides.length > 0 ? ` · stands in for ${row.overrides.map((o) => o.origin ?? o.layer).join(", ")}` : "")
  );
}

/**
 * Start or Switch on a row: what was refused, said, or null once it is done. A string
 * action is the refusal itself; an agent the daemon says cannot run here, and a subagent,
 * which nothing a person starts runs, are refused with why before anything is asked.
 */
export async function runAgent(row: AgentRow, action: PickerAction): Promise<string | null> {
  if (typeof action === "string") return action;
  if (row.available === false) return `${row.name} cannot run here: ${row.reason ?? "the daemon says so"}`;
  if (row.mode === "subagent") return `${row.name} is a subagent: an agent delegates to it, and no session starts on one`;
  try {
    await action(row.name);
    return null;
  } catch (e) {
    return e instanceof Error ? e.message : String(e);
  }
}

/**
 * The picker's rows, grouped by origin: what the start screen, a session's head and the
 * agents manager all list. The `manager` density says more on each row: whether it is a
 * subagent, its cap on turns, what it stands in for, and the sessions running it here.
 */
export function AgentRows({
  rows,
  current,
  picked,
  onChoose,
  density = "picker",
  running,
}: {
  rows: AgentRow[];
  current: string | null;
  picked: string | null;
  onChoose: (name: string) => void;
  density?: "picker" | "manager";
  /** The sessions here running each agent, for the manager's rows. */
  running?: (name: string) => string[];
}): JSX.Element {
  const groups = useMemo(() => originGroups(rows), [rows]);
  return (
    <div className={`agent-picker-list${density === "manager" ? " manager" : ""}`} role="listbox" aria-label="Agent">
      {groups.map((g) => (
        <div key={g.origin} className="agent-picker-group" role="group" aria-label={g.origin}>
          <span className="screen">{g.origin}</span>
          {g.rows.map((r) => {
            const here = density === "manager" ? (running?.(r.name) ?? []) : [];
            const facts =
              density === "manager"
                ? [
                    r.mode === "subagent" ? "subagent" : "primary",
                    r.model ?? "the session's model",
                    r.read_only ? "read only" : null,
                    typeof r.tool_count === "number" ? `${r.tool_count} tools` : null,
                    typeof r.max_turns === "number" ? `max ${r.max_turns} turns` : null,
                    r.overrides && r.overrides.length > 0 ? `stands in for ${r.overrides.map((o) => o.origin ?? o.layer).join(", ")}` : null,
                    here.length > 0 ? `runs in ${here.join(", ")}` : null,
                  ]
                : [r.model ?? "the session's model", r.read_only ? "read only" : null, typeof r.tool_count === "number" ? `${r.tool_count} tools` : null];
            return (
              <button
                key={r.name}
                type="button"
                role="option"
                aria-selected={r.name === picked}
                aria-disabled={r.available === false}
                className={`agent-option${r.available === false ? " unavailable" : ""}`}
                onClick={() => onChoose(r.name)}
                title={r.available === false ? (r.reason ?? undefined) : r.description}
              >
                <span className="name mono">
                  {r.name}
                  {r.name === current ? " ●" : ""}
                </span>
                <span className="facts">{facts.filter(Boolean).join(" · ")}</span>
                {density === "manager" && r.description && <span className="micro muted agent-description">{r.description}</span>}
                {r.available === false && <span className="why">cannot run here: {r.reason}</span>}
              </button>
            );
          })}
        </div>
      ))}
    </div>
  );
}

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

  const choose = (name: string): void => {
    setOwn(name);
    setSaid(null);
    onChoose?.(name);
  };

  const run = async (action: PickerAction): Promise<void> => {
    if (!row) return;
    setBusy(true);
    setSaid(null);
    const refused = await runAgent(row, action);
    if (refused) setSaid({ text: refused, refused: true });
    setBusy(false);
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
      <AgentRows rows={rows ?? []} current={current} picked={picked} onChoose={choose} />

      {row && (
        <div className="agent-picker-detail" aria-label={`The agent ${row.name}`}>
          <p>{row.description || "No description."}</p>
          <p className="note">{fromWords(row)}</p>
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
