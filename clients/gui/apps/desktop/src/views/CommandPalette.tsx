// The command palette: one list behind the protocol (`commands.list`, Decision 698),
// drawn as a popup over the session. `/` in an empty composer, Ctrl-K (⌘K) or the
// Commands button opens it; typing filters by name, alias and summary; ↑↓ move, Enter
// runs the row, Esc closes. A command this app cannot run is greyed with the reason
// rather than hidden, because the list is how somebody learns the tool.
//
// The list is the harness's and nothing here is one: this file holds only what running
// each command means in this app, and which ones it cannot run yet. A command a markdown
// file defines (`source` `user` or `project`, Decision 763) is the harness's to run: it
// sends the file's prompt as the session's input, and its detail shows that prompt
// (Decision 814), since a description is only what the file says of itself; a
// workspace's may ask first, in the session, with the prompt in view. It uses the
// theme's tokens and restyles nothing around it, so the app's coming re-skin (#52) can
// take it as a component.
//
// Three kinds of row, each drawn as what it is, as the terminal's palette draws them
// (troupe #565, TUI Decision 156): a `command` Troupe has; an `agent`, which is not a
// command but something a branch or a session runs, with where it comes from, its model,
// whether it is read-only and whether a session on it gets a worktree or works in the
// checkout, from `agents.list` for a session on this computer; and a file's command,
// `repository` or `yours`. A row that cannot run here says why.

import { useEffect, useMemo, useRef, useState } from "react";
import type { JSX } from "react";
import type { AgentLayer, AgentRow, CommandEntry } from "@troupe/client";
import type { SessionHandle } from "../hooks";
import { loopError } from "./Goal";

/** The screens a command can leave the session for; `setup` is also where a refused key sends people. */
export type PaletteScreen = "sessions" | "local" | "appearance" | "setup";

export interface PaletteActions {
  go: (screen: PaletteScreen) => void;
  /** Show the backstage's Files pane. */
  showFiles: () => void;
  /** Show the backstage's Memory pane, the repository's facts, and with `refresh` or `forget` do that there. */
  showMemory: (what?: "refresh" | "forget") => void;
  /** The transcript as text, for /copy. */
  transcript: () => string;
  /**
   * `/detail`: with a level, draw this session's transcript at it (troupe #474); without
   * one, say which it is drawn at. A sentence back is a notice; undefined closes the palette.
   */
  detail: (level: string) => string | undefined;
  /** Open the agents manager on the session's workspace: a session on this computer's (troupe #503). */
  agents?: (() => void) | undefined;
  /** `agents.list`'s rows for the session's workspace, which an agent's row takes its facts from: a session on this computer's. */
  agentRows?: (() => Promise<AgentRow[]>) | undefined;
  /** "Publish…": files from this computer on the plane, through its daemon's sign-in, where there is a daemon. */
  publish?: (() => void) | undefined;
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
  // The memory view, as the terminal client's /memory: refresh has the librarian write the
  // brief again, forget asks before it forgets the whole brief; a fact is forgotten there.
  memory: ({ showMemory }, args) => {
    if (args === "") return void showMemory();
    if (args === "refresh" || args === "forget") return void showMemory(args);
    return `unknown /memory ${args}; use /memory, /memory refresh or /memory forget`;
  },
  detail: ({ detail }, args) => detail(args),
  settings: ({ go }) => void go("local"),
  models: ({ go }) => void go("local"),
  // "Stop using my account here" is on This computer, under who it records.
  unlink: ({ go }) => void go("local"),
  agents: ({ agents }) =>
    agents ? void agents() : "a session on the platform runs its profile bundle's agents, which are changed in the console; the header switches between them",
  // "Publish…", as the terminal client's /publish: a new artifact, or a new version of one of
  // the person's own, from files on this computer, through its daemon's sign-in.
  publish: ({ publish }) => (publish ? void publish() : "publishing goes through this computer's daemon, and there is none here"),
  copy: async ({ transcript }) => {
    await navigator.clipboard.writeText(transcript());
    return "copied the transcript";
  },
  help: () => "",
  quit: () => void window.close(),
};

/** The built-ins this app asks its arguments of in a dialog of their own, rather than on the line. */
const ASKS_ITSELF = new Set(["publish"]);

/** Why a built-in has no runner here: said on its row, not hidden. */
const NOT_HERE: Record<string, string> = {
  compact: "a session on this computer compacts by itself",
  merge: "branches and worktrees are the terminal client's: merge there, or in the repository",
  discard: "branches and worktrees are the terminal client's",
  dismiss: "there are no windows to dismiss here",
  observer: "not in the desktop app yet",
  upload: "not in the desktop app yet",
  watch: "on This computer, under this session's controls",
  mcp: "not in the desktop app yet",
  worktree: "start a branch from the terminal client, or a new session from the list",
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
  custom: "Custom",
  quit: "Quit",
};

/** A command a file defines, yours or the repository's: the harness runs it. */
function defined(entry: CommandEntry): boolean {
  return entry.source === "user" || entry.source === "project";
}

// The file's prompt goes to the session as input, and the transcript shows it as it
// shows anything typed.
async function runDefined({ view }: RunContext, name: string, args: string): Promise<string | undefined> {
  const v = view.view;
  if (!v) return "not attached";
  await v.runCommand(name, args);
  return undefined;
}

function reasonFor(entry: CommandEntry, local: boolean, agent: AgentRow | undefined): string | null {
  if (entry.availability === "local" && !local) return "only for a session on this computer";
  if (entry.availability === "plane") return "needs a plane";
  // The daemon's own reason first: an agent no session could run here (a model the
  // provider does not serve) cannot run from the terminal client either.
  if (entry.source === "agent" && agent?.available === false) return `${entry.name} cannot run here: ${agent.reason ?? "the daemon says it cannot"}`;
  if (entry.source === "agent") return "start a branch on it from the terminal client, or a new session from the list";
  if (defined(entry)) return null;
  if (!(entry.name in RUNNERS)) return NOT_HERE[entry.name] ?? "not in the desktop app yet";
  return null;
}

/** What kind of row a command is, in the word the terminal's palette uses. */
type Kind = "command" | "agent" | "repository" | "yours";

function kindOf(entry: CommandEntry): Kind {
  switch (entry.source) {
    case "agent":
      return "agent";
    case "project":
      return "repository";
    case "user":
      return "yours";
    default:
      return "command";
  }
}

/** Where an agent comes from, in as few letters as say it. */
function layerBadge(layer: AgentLayer | undefined): string | null {
  switch (layer) {
    case "builtin":
      return "built in";
    case "bundle":
      return "bundle";
    case "user":
      return "yours";
    case "project":
      return "repository";
    default:
      return null;
  }
}

/**
 * An agent's facts on its row: where it comes from, its model (`default` runs on the
 * session's), whether it is read-only, and whether a session on it gets a worktree of its
 * own or works in the checkout, as `agents.list` says it for this workspace.
 */
function agentBadges(agent: AgentRow): string[] {
  return [
    layerBadge(agent.layer),
    agent.model ?? "default",
    agent.read_only ? "read-only" : null,
    agent.worktree === undefined ? null : agent.worktree ? "worktree" : "checkout",
  ].filter((b): b is string => b !== null);
}

/** How many of a command's lines its detail shows before it counts the rest. */
const BODY_LINES = 8;

/**
 * What a command a file defines sends, as its file has it (troupe Decision 814): its
 * description is the file's say-so, so the detail shows the prompt itself — its first
 * lines, and how many more the file holds.
 */
function Sends({ body }: { body: string }): JSX.Element {
  const lines = body.split("\n");
  const more = lines.length - BODY_LINES;
  return (
    <div className="sends">
      <p className="micro muted">sends:</p>
      <pre aria-label="What it sends">{lines.slice(0, BODY_LINES).join("\n")}</pre>
      {more > 0 && (
        <p className="micro muted">
          … {more} more {more === 1 ? "line" : "lines"} in the file
        </p>
      )}
    </div>
  );
}

/** An agent's row is not a command: the detail says what it is, and where it is changed. */
function AgentAbout({ name, agent, manager }: { name: string; agent: AgentRow | undefined; manager: boolean }): JSX.Element {
  const facts = agent
    ? [
        agent.model ? `model ${agent.model}` : "the session's model",
        agent.tool_count === undefined ? null : `${agent.tool_count} tools`,
        agent.read_only ? "read-only" : null,
        agent.max_turns ? `at most ${agent.max_turns} turns` : null,
        agent.worktree === undefined ? null : agent.worktree ? "a session on it gets a worktree of its own" : "a session on it works in this checkout",
      ].filter((f): f is string => f !== null)
    : [];
  const from = agent?.layer ? `, from ${LAYER_PLACES[agent.layer]}` : "";
  return (
    <p className="micro">
      An agent, not a command{from}
      {facts.length > 0 ? `: ${facts.join(" · ")}` : ""}. A branch or a session runs {name}
      {manager ? "; /agents reads, edits and copies it." : "."}
    </p>
  );
}

const LAYER_PLACES: Record<AgentLayer, string> = {
  builtin: "the built-ins",
  bundle: "the profile's bundle",
  user: "your agents",
  project: "this repository",
};

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
  const [agents, setAgents] = useState<Map<string, AgentRow>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(0);
  const [notice, setNotice] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const { agentRows } = actions;

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

  // The agents' facts come a moment after the commands, and the list never waits on them:
  // a row without them is still the agent it is.
  useEffect(() => {
    let live = true;
    void agentRows?.()
      .then((rows) => live && setAgents(new Map(rows.map((a) => [a.name, a]))))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [agentRows]);

  const { word, args } = split(query);

  const rows = useMemo<Row[]>(
    () =>
      (commands ?? [])
        .filter((c) => matches(c, word))
        .map((entry) => ({ entry, reason: reasonFor(entry, local, entry.source === "agent" ? agents.get(entry.name) : undefined) })),
    [commands, word, local, agents],
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
    if (entry.args.some((a) => a.required) && args === "" && !ASKS_ITSELF.has(entry.name)) {
      // It wants an argument: leave the name on the line to finish typing.
      setQuery(`${entry.name} `);
      setNotice(`usage: ${entry.usage}`);
      input.current?.focus();
      return;
    }
    try {
      const ctx = { view, ...actions };
      const result = defined(entry) ? await runDefined(ctx, entry.name, args) : await RUNNERS[entry.name]!(ctx, args);
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
              {group.rows.map(({ row, index }) => {
                const kind = kindOf(row.entry);
                const agent = kind === "agent" ? agents.get(row.entry.name) : undefined;
                return (
                  <div
                    key={row.entry.name}
                    role="option"
                    aria-selected={index === cursor}
                    aria-disabled={row.reason !== null || undefined}
                    className={`row kind-${kind} ${row.reason ? "unavailable" : ""}`}
                    onMouseMove={() => setCursor(index)}
                    onClick={() => void run(row)}
                  >
                    <span className="name">/{row.entry.name}</span>
                    <span className="kind">{kind}</span>
                    <span className="summary">
                      {agent && <span className="badges">{agentBadges(agent).join(" · ")}</span>}
                      {row.entry.summary}
                      {row.reason && <span className="micro"> — {row.reason}</span>}
                    </span>
                  </div>
                );
              })}
            </div>
          ))}
        </div>

        {selected && (
          <div className="detail">
            <span className="usage">{selected.entry.usage}</span>
            {selected.entry.aliases.length > 0 && <span className="micro muted"> also {selected.entry.aliases.map((a) => `/${a}`).join(", ")}</span>}
            <p>{selected.entry.detail}</p>
            {selected.entry.source === "agent" && <AgentAbout name={selected.entry.name} agent={agents.get(selected.entry.name)} manager={Boolean(actions.agents)} />}
            {typeof selected.entry.body === "string" && <Sends body={selected.entry.body} />}
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
