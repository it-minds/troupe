// The command palette: one list behind the protocol (`commands.list`, Decision 698),
// drawn as a popup over the session. `/` in an empty composer, Ctrl-K (⌘K) or the
// Commands button opens it; typing filters by name, alias and summary; ↑↓ move, Enter
// runs the row, Esc closes. A command this app cannot run is greyed with the reason
// rather than hidden, because the list is how somebody learns the tool.
//
// The list is the harness's and nothing here is one: this file holds only what running
// each command means in this app, and which ones it cannot run yet. It uses the theme's
// tokens and restyles nothing around it, so the app's coming re-skin (#52) can take it
// as a component.

import { useEffect, useMemo, useRef, useState } from "react";
import type { JSX } from "react";
import type { CommandEntry } from "@troupe/client";
import type { SessionHandle } from "../hooks";
import { loopError } from "./Goal";

/** The screens a command can leave the session for. */
export type PaletteScreen = "sessions" | "local" | "appearance";

export interface PaletteActions {
  go: (screen: PaletteScreen) => void;
  /** Show the backstage's Files pane. */
  showFiles: () => void;
  /** The transcript as text, for /copy. */
  transcript: () => string;
}

interface RunContext extends PaletteActions {
  view: SessionHandle;
}

/**
 * What each built-in does here. A string comes back as a notice and the palette stays
 * open; `undefined` closes it. A name with no entry cannot be run from this app and is
 * shown greyed, with the reason from `NOT_HERE`.
 */
const RUNNERS: Record<string, (ctx: RunContext, args: string) => Promise<string | undefined> | string | undefined> = {
  cancel: async ({ view }) => {
    await view.cancel();
    return undefined;
  },
  goal: async ({ view }, args) => {
    const v = view.view;
    if (!v) return "not attached";
    if (args === "") {
      const g = await v.getGoal();
      return g.goal ? `goal: ${g.goal}` : "no goal set; /goal <text> sets one";
    }
    if (args === "clear") {
      await v.clearGoal();
      return "goal cleared";
    }
    await v.setGoal(args);
    return `goal set: ${args}`;
  },
  loop: async ({ view }, args) => {
    const v = view.view;
    if (!v) return "not attached";
    if (args === "stop") {
      await v.stopLoop();
      return "loop stopped";
    }
    const n = args === "" ? undefined : Number(args);
    if (n !== undefined && !(Number.isInteger(n) && n > 0)) return "usage: /loop [n | stop]";
    try {
      const started = await v.startLoop(n);
      return `loop ${started.loop_id} started, up to ${started.max_iterations} turns`;
    } catch (e) {
      return loopError(e);
    }
  },
  sessions: ({ go }) => void go("sessions"),
  hq: ({ go }) => void go("sessions"),
  files: ({ showFiles }) => void showFiles(),
  settings: ({ go }) => void go("local"),
  models: ({ go }) => void go("local"),
  copy: async ({ transcript }) => {
    await navigator.clipboard.writeText(transcript());
    return "copied the transcript";
  },
  help: () => "",
  quit: () => void window.close(),
};

/** Why a built-in has no runner here: said on its row, not hidden. */
const NOT_HERE: Record<string, string> = {
  compact: "a session on this computer compacts by itself",
  merge: "branches and worktrees are the terminal client's: merge there, or in the repository",
  discard: "branches and worktrees are the terminal client's",
  dismiss: "there are no windows to dismiss here",
  observer: "not in the desktop app yet",
  upload: "not in the desktop app yet",
  memory: "not in the desktop app yet",
  watch: "on This computer, under this session's controls",
  mcp: "not in the desktop app yet",
  worktree: "start a branch from the terminal client, or a new session from the list",
  agents: "they are the Agents section of this list",
};

interface Row {
  entry: CommandEntry;
  /** Why it cannot run now, or null when it can. */
  reason: string | null;
}

const SECTION_NAMES: Record<string, string> = {
  session: "Session",
  navigate: "Navigate",
  workspace: "Workspace",
  setup: "Setup",
  agents: "Agents",
  quit: "Quit",
};

function reasonFor(entry: CommandEntry, local: boolean): string | null {
  if (entry.availability === "local" && !local) return "only for a session on this computer";
  if (entry.availability === "plane") return "needs a plane";
  if (entry.source === "agent") return "start a branch on it from the terminal client, or a new session from the list";
  if (!(entry.name in RUNNERS)) return NOT_HERE[entry.name] ?? "not in the desktop app yet";
  return null;
}

/** The first word filters; the rest is the command's argument. */
function split(query: string): { word: string; args: string } {
  const trimmed = query.replace(/^\//, "").trimStart();
  const at = trimmed.indexOf(" ");
  return at < 0 ? { word: trimmed, args: "" } : { word: trimmed.slice(0, at), args: trimmed.slice(at + 1).trim() };
}

function matches(entry: CommandEntry, word: string): boolean {
  if (word === "") return true;
  const q = word.toLowerCase();
  return entry.name.includes(q) || entry.aliases.some((a) => a.includes(q)) || entry.summary.toLowerCase().includes(q);
}

export function CommandPalette({
  view,
  local,
  actions,
  onClose,
}: {
  view: SessionHandle;
  /** A session on this computer, whose branches and files are here. */
  local: boolean;
  actions: PaletteActions;
  onClose: () => void;
}): JSX.Element {
  const [commands, setCommands] = useState<CommandEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(0);
  const [notice, setNotice] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);

  // The list is the harness's, read when the palette opens: agents come and go with the
  // workspace, and nothing here is worth caching over that.
  useEffect(() => {
    let live = true;
    const v = view.view;
    if (!v) {
      setError("not attached");
      return;
    }
    v.commands()
      .then((r) => live && setCommands(r.commands))
      .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)));
    input.current?.focus();
    return () => {
      live = false;
    };
  }, [view.view]);

  const { word, args } = split(query);

  const rows = useMemo<Row[]>(
    () => (commands ?? []).filter((c) => matches(c, word)).map((entry) => ({ entry, reason: reasonFor(entry, local) })),
    [commands, word, local],
  );

  // A new filter starts on the row that matches it exactly, so "q" + Enter is /quit.
  useEffect(() => {
    const exact = rows.findIndex((r) => r.entry.name === word || r.entry.aliases.includes(word));
    setCursor(exact >= 0 ? exact : 0);
  }, [word, rows]);

  useEffect(() => {
    list.current?.querySelector<HTMLElement>('[aria-selected="true"]')?.scrollIntoView({ block: "nearest" });
  }, [cursor]);

  const selected = rows[Math.min(cursor, Math.max(rows.length - 1, 0))];

  const run = async (row: Row | undefined): Promise<void> => {
    if (!row) return;
    if (row.reason) {
      setNotice(row.reason);
      return;
    }
    const { entry } = row;
    if (entry.args.some((a) => a.required) && args === "") {
      // It wants an argument: leave the name on the line to finish typing.
      setQuery(`${entry.name} `);
      setNotice(`usage: ${entry.usage}`);
      input.current?.focus();
      return;
    }
    try {
      const result = await RUNNERS[entry.name]!({ view, ...actions }, args);
      if (result === undefined) onClose();
      else if (result === "") setQuery("");
      else setNotice(result);
    } catch (e) {
      setNotice(e instanceof Error ? e.message : String(e));
    }
  };

  const onKey = (e: React.KeyboardEvent): void => {
    const last = Math.max(rows.length - 1, 0);
    const move = (to: number): void => setCursor(Math.min(Math.max(to, 0), last));
    switch (e.key) {
      case "Escape":
        e.preventDefault();
        onClose();
        return;
      case "ArrowDown":
        e.preventDefault();
        move(cursor + 1);
        return;
      case "ArrowUp":
        e.preventDefault();
        move(cursor - 1);
        return;
      case "PageDown":
        e.preventDefault();
        move(cursor + 10);
        return;
      case "PageUp":
        e.preventDefault();
        move(cursor - 10);
        return;
      case "Home":
        if (query === "") {
          e.preventDefault();
          move(0);
        }
        return;
      case "End":
        if (query === "") {
          e.preventDefault();
          move(last);
        }
        return;
      case "Enter":
        e.preventDefault();
        void run(selected);
        return;
      default:
        return;
    }
  };

  // Rows grouped under their section, in the table's order.
  const grouped: Array<{ section: string; rows: Array<{ row: Row; index: number }> }> = [];
  rows.forEach((row, index) => {
    const section = row.entry.section;
    const group = grouped.at(-1);
    if (group && group.section === section) group.rows.push({ row, index });
    else grouped.push({ section, rows: [{ row, index }] });
  });

  return (
    <div className="palette-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="palette" role="dialog" aria-label="Commands" onKeyDown={onKey}>
        <input
          ref={input}
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setNotice(null);
          }}
          placeholder="Type a command, or a word from its description"
          aria-label="Command"
          autoComplete="off"
          spellCheck={false}
        />

        <div className="rows" role="listbox" aria-label="Commands" ref={list}>
          {error && <p className="note error">Could not read the commands: {error}</p>}
          {commands && rows.length === 0 && <p className="note">Nothing matches "{word}".</p>}
          {!commands && !error && <p className="note">Reading the commands…</p>}

          {grouped.map((group) => (
            <div key={group.section}>
              <div className="section">{SECTION_NAMES[group.section] ?? group.section}</div>
              {group.rows.map(({ row, index }) => (
                <div
                  key={row.entry.name}
                  role="option"
                  aria-selected={index === cursor}
                  aria-disabled={row.reason !== null || undefined}
                  className={`row ${row.reason ? "unavailable" : ""}`}
                  onMouseMove={() => setCursor(index)}
                  onClick={() => void run(row)}
                >
                  <span className="name">/{row.entry.name}</span>
                  <span className="summary">
                    {row.entry.summary}
                    {row.reason && <span className="micro"> — {row.reason}</span>}
                  </span>
                </div>
              ))}
            </div>
          ))}
        </div>

        {selected && (
          <div className="detail">
            <span className="usage">{selected.entry.usage}</span>
            {selected.entry.aliases.length > 0 && <span className="micro muted"> also {selected.entry.aliases.map((a) => `/${a}`).join(", ")}</span>}
            <p>{selected.entry.detail}</p>
            {selected.entry.example && (
              <p className="micro muted">
                for example: <span className="mono">{selected.entry.example}</span>
              </p>
            )}
            {selected.reason && <p className="micro">Not here: {selected.reason}.</p>}
          </div>
        )}

        {notice && (
          <div className="notice" aria-live="polite">
            {notice}
          </div>
        )}

        <div className="keys micro muted">↑↓ move · Enter runs · Esc closes · Ctrl-K opens</div>
      </div>
    </div>
  );
}
