// The command palette: one list behind the protocol (`commands.list`), drawn as a popup
// over the session. `/` in an empty composer, Ctrl-K (⌘K) or the Commands button opens
// it; typing filters by name, alias and summary; ↑↓ move, Enter
// runs the row, Esc closes. A command this app cannot run is greyed with the reason
// rather than hidden, because the list is how somebody learns the tool; a row the table
// marks as the terminal client's alone (`availability` `tui`: leaving it, reading a file
// from where it started, a branch's worktree, a window, the agent tree) is left out, since
// there is nothing here for it to do. Each row
// says what it does in this app's words where the table has some for it (`summaries`,
// `details`), and in the words true in any client where it has none.
//
// The list is the harness's and nothing here is one: this file holds only what running
// each command means in this app, and which ones it cannot run yet. A command a markdown
// file defines (`source` `user` or `project`) is the harness's to run: it
// sends the file's prompt as the session's input, and its detail shows that prompt,
// since a description is only what the file says of itself; a
// workspace's may ask first, in the session, with the prompt in view. It uses the
// theme's tokens and restyles nothing around it, so the app's coming re-skin (#52) can
// take it as a component.
//
// Three kinds of row, each drawn as what it is, as the terminal's palette draws them
// (troupe #565): a `command` Troupe has; an `agent`, which is not a
// command but something a branch or a session runs, with where it comes from, its model,
// whether it is read-only and whether a session on it gets a worktree or works in the
// checkout, from `agents.list` for a session on this computer; and a file's command,
// `repository` or `yours`. A row that cannot run here says why. An agent's row switches
// the session to it, by the head's rule: the session's own listing offers it as a primary
// it can run, and the person may change the session; what is typed after its name is then
// sent as the next message.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { JSX } from "react";
import type { AgentLayer, AgentRow, CommandEntry } from "@troupe/client";
import { ErrorCodes, TroupeRpcError, errorText } from "@troupe/client";
import { copyText } from "../clipboard";
import type { SessionHandle } from "../hooks";
import { switchable } from "./AgentSwitch";
import { loopError } from "./Goal";

/** The screens a command can leave the session for; `setup` is also where a refused key sends people. */
export type PaletteScreen = "sessions" | "local" | "connect" | "appearance" | "setup" | "memory";

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
  /**
   * Whether this computer's daemon is signed in to a plane (`identity.get`'s `linked`), asked
   * once as the palette opens: a command that needs a plane is greyed only where it is known
   * to be signed in to none.
   */
  planeLinked?: (() => Promise<boolean>) | undefined;
  /** The agents the session's own listing offers, which the head's switch offers too. */
  sessionAgents?: (() => Promise<AgentRow[]>) | undefined;
  /** Switch the session to an agent, as the head does: absent where the person may only read it. */
  switchAgent?: ((name: string) => Promise<void>) | undefined;
  /** The agent the session runs now. */
  currentAgent?: string | null | undefined;
  /**
   * `/archive` (`true`) and `/unarchive`: hide this session from the session list, for
   * everyone who sees it, or put it back. A sentence back is a notice; undefined closes the palette.
   */
  archive?: ((on: boolean) => Promise<string | undefined>) | undefined;
  /**
   * `/rename`: name this session, for everyone who sees it; without a name, the title in the
   * head becomes a field. A sentence back is a notice; undefined closes the palette.
   */
  rename?: ((name: string) => Promise<string | undefined>) | undefined;
  /** `/keep` (`true`) and `/keep off`: keep this session at the top of the session list, or let it go. */
  keep?: ((on: boolean) => Promise<string | undefined>) | undefined;
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
  // Compact now, between turns; a refusal (a turn running, too little to compact) is the
  // daemon's own sentence.
  compact: async ({ view }) => {
    const v = view.view;
    if (!v) return "not attached";
    try {
      await v.compact();
      return "compacting the conversation";
    } catch (e) {
      if (e instanceof TroupeRpcError && e.code === ErrorCodes.conflict && typeof e.data?.["reason"] === "string") {
        return `not compacted: ${e.data["reason"]}`;
      }
      throw e;
    }
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
  // Your own servers and skills, as the terminal client's /mcp and /skills pages.
  mcp: ({ go }) => void go("connect"),
  skills: ({ go }) => void go("connect"),
  models: ({ go }) => void go("local"),
  // "Stop using my account here" is on This computer, under who it records.
  unlink: ({ go }) => void go("local"),
  agents: ({ agents }) =>
    agents ? void agents() : "a session on the platform runs its profile bundle's agents, which are changed in the console; the header switches between them",
  // "Publish…", as the terminal client's /publish: a new artifact, or a new version of one of
  // the person's own, from files on this computer, through its daemon's sign-in.
  publish: ({ publish }) => (publish ? void publish() : "publishing goes through this computer's daemon, and there is none here"),
  copy: async ({ transcript }) => {
    await copyText(transcript());
    return "copied the transcript";
  },
  help: () => "",
  archive: ({ archive }) => (archive ? archive(true) : "this session cannot be archived from here"),
  unarchive: ({ archive }) => (archive ? archive(false) : "this session cannot be unarchived from here"),
  rename: ({ rename }, args) => (rename ? rename(args) : "only its owner can rename this session"),
  keep: ({ keep }, args) => {
    if (!keep) return "only its owner can keep this session at the top";
    if (args === "") return keep(true);
    if (args === "off") return keep(false);
    return `unknown /keep ${args}; use /keep or /keep off`;
  },
};

/** The built-ins this app asks its arguments of in a dialog or a field of their own, rather than on the line. */
const ASKS_ITSELF = new Set(["publish", "rename"]);

/** Why a built-in has no runner here: said on its row, not hidden. */
const NOT_HERE: Record<string, string> = {
  compact: "a session on this computer compacts by itself",
  watch: "on This computer, under this session's controls",
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

/**
 * The row in this app's words, where the table has some for it. This app has no windows,
 * so a command that may name one is typed without it, and an example naming one is not
 * this app's.
 */
function inThisApp(entry: CommandEntry): CommandEntry {
  const windowed = entry.args.some((a) => a.kind === "window");
  // An agent's row switches here, and what follows its name is an optional message.
  if (entry.source === "agent") {
    return { ...entry, usage: entry.usage.replace("<prompt>", "[message]"), args: entry.args.map((a) => ({ ...a, required: false })) };
  }
  // A command typed here with other arguments than the terminal client's (`/hq` names no
  // plane: this app is signed in to one) has its own usage, the arguments it names, and
  // its own example or none.
  const usage = entry.usages?.["desktop"];
  const example = entry.examples && "desktop" in entry.examples ? (entry.examples["desktop"] ?? null) : entry.example;
  return {
    ...entry,
    summary: entry.summaries?.["desktop"] ?? entry.summary,
    detail: entry.details?.["desktop"] ?? entry.detail,
    availability: entry.availabilities?.["desktop"] ?? entry.availability,
    ...(usage === undefined ? {} : { usage, args: entry.args.filter((a) => usage.includes(a.name)) }),
    example,
    ...(windowed
      ? { usage: entry.usage.replace(/\s*\[window\]/, ""), args: entry.args.filter((a) => a.kind !== "window"), example: null }
      : {}),
  };
}

/**
 * What the palette knows of switching the session's agent: whether the person may, and
 * the names its own listing offers as primaries it can run, or null until it answers.
 */
interface Switching {
  may: boolean;
  offered: Set<string> | null;
}

function reasonFor(entry: CommandEntry, local: boolean, agent: AgentRow | undefined, linked: boolean | null, switching: Switching): string | null {
  // An agent's row switches the session to it, wherever the head's switch would: its
  // `local` is the terminal client's branch, which this app does not start.
  if (entry.source === "agent") {
    // The daemon's own reason first: an agent no session could run here (a model the
    // provider does not serve) cannot run from the terminal client either.
    if (agent?.available === false) return `${entry.name} cannot run here: ${agent.reason ?? "the daemon says it cannot"}`;
    if (!switching.may) return "you can read this session, not change the agent it runs";
    // Never while the listing is not in yet: a row greyed for a moment would read as a refusal.
    if (switching.offered && !switching.offered.has(entry.name)) return "start a branch on it from the terminal client, or a new session from the list";
    return null;
  }
  if (entry.availability === "local" && !local) return "only for a session on this computer";
  // Never while it is not known yet: a row greyed for a moment would read as a refusal.
  if (entry.availability === "plane" && linked === false) return "needs a plane: sign in to a Troupe plane first";
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

function sectionName(section: string): string {
  return SECTION_NAMES[section] ?? section;
}

/** What the detail's head names beside the command: whose it is, or for one of Troupe's own, the section it sits under. */
function areaOf(entry: CommandEntry): string {
  const kind = kindOf(entry);
  return kind === "command" ? sectionName(entry.section).toLowerCase() : kind;
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
const BODY_LINES = 12;

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
function AgentAbout({ name, agent, manager, switches }: { name: string; agent: AgentRow | undefined; manager: boolean; switches: boolean }): JSX.Element {
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
      {switches && ` Enter switches this session to ${name} from its next turn, and sends what you type after the name.`}
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

/** Where ↑↓ or the mouse put the cursor, and for which first word; another word has not been moved in. */
type Cursor = { word: string | null; at: number };

const UNMOVED: Cursor = { word: null, at: 0 };

/**
 * The row the cursor stands on in the list a word filters: where it was moved for that
 * word, else the row the word names exactly (so "resume" is /sessions), else the first.
 */
function standing(rows: Row[], word: string, cursor: Cursor): number {
  if (rows.length === 0) return 0;
  if (cursor.word === word) return Math.min(Math.max(cursor.at, 0), rows.length - 1);
  const exact = rows.findIndex((r) => r.entry.name === word || r.entry.aliases.includes(word));
  return exact >= 0 ? exact : 0;
}

export function CommandPalette({
  view,
  local,
  actions,
  onClose,
  anchored = false,
}: {
  view: SessionHandle;
  /** A session on this computer, whose branches and files are here. */
  local: boolean;
  actions: PaletteActions;
  onClose: () => void;
  /**
   * Opened from the composer (its `/` button, or `/` typed on an empty message): drawn as
   * a popover over the composer rather than over the screen, and shut by a press anywhere
   * outside it. Ctrl-K opens it over the screen.
   */
  anchored?: boolean;
}): JSX.Element {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!anchored) return;
    const outside = (e: MouseEvent): void => {
      const target = e.target as Node | null;
      if (!target || box.current?.contains(target)) return;
      if (target instanceof Element && target.closest("[data-palette-toggle]")) return;
      onClose();
    };
    document.addEventListener("mousedown", outside);
    return () => document.removeEventListener("mousedown", outside);
  }, [anchored, onClose]);
  const [commands, setCommands] = useState<CommandEntry[] | null>(null);
  const [agents, setAgents] = useState<Map<string, AgentRow>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState<Cursor>(UNMOVED);
  // The cursor as the keys last left it, for a key read before the palette has drawn it.
  const moved = useRef<Cursor>(UNMOVED);
  const [notice, setNotice] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const [linked, setLinked] = useState<boolean | null>(null);
  const [listed, setListed] = useState<AgentRow[] | null>(null);
  const { agentRows, planeLinked, sessionAgents, switchAgent, currentAgent } = actions;

  useEffect(() => {
    let live = true;
    void planeLinked?.()
      .then((l) => live && setLinked(l))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [planeLinked]);

  // Each read of the list, counted, so an Enter after a refusal can ask again.
  const [reads, setReads] = useState(0);

  // The list is the harness's, read when the palette opens: agents come and go with the
  // workspace, and nothing here is worth caching over that. A palette opened before the
  // session's view has attached waits for it, and reads the list when it comes; a refusal
  // is said until a read succeeds.
  useEffect(() => {
    input.current?.focus();
    const v = view.view;
    if (!v) return;
    let live = true;
    v.commands()
      .then((r) => {
        if (!live) return;
        setCommands(r.commands.map(inThisApp).filter((c) => c.availability !== "tui"));
        setError(null);
      })
      .catch((e: unknown) => live && setError(errorText(e)));
    return () => {
      live = false;
    };
  }, [view.view, reads]);

  // The agents' facts come a moment after the commands, and the list never waits on them:
  // a row without them is still the agent it is. On this computer they are the
  // workspace's `agents.list`; on the platform, the session's own listing.
  useEffect(() => {
    let live = true;
    void agentRows?.()
      .then((rows) => live && setAgents(new Map(rows.map((a) => [a.name, a]))))
      .catch(() => undefined);
    void sessionAgents?.()
      .then((rows) => {
        if (!live) return;
        setListed(rows);
        if (!agentRows) setAgents(new Map(rows.map((a) => [a.name, a])));
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [agentRows, sessionAgents]);

  const switching = useMemo<Switching>(
    () => ({ may: switchAgent !== undefined, offered: listed ? new Set(listed.filter(switchable).map((a) => a.name)) : null }),
    [switchAgent, listed],
  );

  const { word } = split(query);

  // One filter gives both the list drawn and the list a key acts on, so they cannot disagree.
  const listFor = useCallback(
    (w: string): Row[] =>
      (commands ?? [])
        .filter((c) => matches(c, w))
        .map((entry) => ({ entry, reason: reasonFor(entry, local, entry.source === "agent" ? agents.get(entry.name) : undefined, linked, switching) })),
    [commands, local, agents, linked, switching],
  );
  const rows = useMemo<Row[]>(() => listFor(word), [listFor, word]);
  const at = standing(rows, word, cursor);
  const selected = rows[at];

  const place = (next: Cursor): void => {
    moved.current = next;
    setCursor(next);
  };

  /** A line's command and argument, its rows and the row the cursor stands on. */
  const lineOf = (line: string): { word: string; args: string; rows: Row[]; at: number } => {
    const text = split(line);
    const r = text.word === word ? rows : listFor(text.word);
    return { ...text, rows: r, at: standing(r, text.word, moved.current) };
  };

  /**
   * What the line says at the moment a key lands, read from the field itself: a key
   * pressed in the same tick as the last keystroke comes before the palette has drawn it.
   */
  const now = (): ReturnType<typeof lineOf> => lineOf(input.current?.value ?? query);

  // An Enter pressed before the list has come runs the line it was pressed on once it comes.
  const waiting = useRef<string | null>(null);

  useEffect(() => {
    list.current?.querySelector<HTMLElement>('[aria-selected="true"]')?.scrollIntoView({ block: "nearest" });
  }, [at, word]);

  const run = async (row: Row | undefined, args: string): Promise<void> => {
    if (!row) return;
    if (row.reason) {
      setNotice(row.reason);
      return;
    }
    const { entry } = row;
    if (entry.source === "agent") {
      if (entry.name === currentAgent) {
        setNotice(`this session runs ${entry.name} already`);
        return;
      }
      try {
        await switchAgent!(entry.name);
        if (args !== "") await view.send(args);
        onClose();
      } catch (e) {
        setNotice(errorText(e));
      }
      return;
    }
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
      setNotice(errorText(e));
    }
  };

  useEffect(() => {
    const pressed = waiting.current;
    if (commands === null || pressed === null) return;
    waiting.current = null;
    const line = lineOf(pressed);
    void run(line.rows[line.at], line.args);
    // Only the list's coming runs it; the line and the cursor are read as they are then.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [commands]);

  const onKey =(e: React.KeyboardEvent): void => {
    const line = now();
    const last = Math.max(line.rows.length - 1, 0);
    const here = line.at;
    const move = (to: number): void => place({ word: line.word, at: Math.min(Math.max(to, 0), last) });
    const empty = (input.current?.value ?? query) === "";
    switch (e.key) {
      case "Escape":
        e.preventDefault();
        onClose();
        return;
      case "ArrowDown":
        e.preventDefault();
        move(here + 1);
        return;
      case "ArrowUp":
        e.preventDefault();
        move(here - 1);
        return;
      case "PageDown":
        e.preventDefault();
        move(here + 10);
        return;
      case "PageUp":
        e.preventDefault();
        move(here - 10);
        return;
      case "Home":
        if (empty) {
          e.preventDefault();
          move(0);
        }
        return;
      case "End":
        if (empty) {
          e.preventDefault();
          move(last);
        }
        return;
      case "Enter":
        e.preventDefault();
        if (commands === null) {
          // Held until the list comes; after a refusal, the Enter also asks for it again.
          waiting.current = input.current?.value ?? query;
          if (error !== null && view.view) setReads((n) => n + 1);
        } else void run(line.rows[line.at], line.args);
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
    <div
      className={anchored ? "palette-pop" : "palette-scrim"}
      onMouseDown={(e) => !anchored && e.target === e.currentTarget && onClose()}
    >
      <div ref={box} className="palette" role="dialog" aria-label="Commands" onKeyDown={onKey}>
        <input
          ref={input}
          value={query}
          onChange={(e) => {
            // A new first word starts unmoved, on its exact match; an argument typed after it keeps the cursor.
            if (split(e.target.value).word !== moved.current.word) place(UNMOVED);
            setQuery(e.target.value);
            setNotice(null);
          }}
          placeholder="Type a command, or a word from its description"
          aria-label="Command"
          autoComplete="off"
          spellCheck={false}
        />

        <div className="rows" role="listbox" aria-label="Commands" ref={list}>
          {error && (
            <p className="note error">
              Could not read the commands: {error}
              {!commands && " — Enter tries again"}
            </p>
          )}
          {commands && rows.length === 0 && <p className="note">Nothing matches "{word}".</p>}
          {!commands && !error && <p className="note">{view.view ? "Reading the commands…" : "Waiting for the session to connect…"}</p>}

          {grouped.map((group) => (
            <div key={group.section}>
              <div className="section screen">{sectionName(group.section)}</div>
              {group.rows.map(({ row, index }) => {
                const kind = kindOf(row.entry);
                const agent = kind === "agent" ? agents.get(row.entry.name) : undefined;
                return (
                  <div
                    key={row.entry.name}
                    role="option"
                    aria-selected={index === at}
                    aria-disabled={row.reason !== null || undefined}
                    className={`row kind-${kind} ${row.reason ? "unavailable" : ""}`}
                    onMouseMove={() => place({ word, at: index })}
                    onClick={() => void run(row, now().args)}
                  >
                    <span className="name">/{row.entry.name}</span>
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
          <div className={`detail kind-${kindOf(selected.entry)}`}>
            <span className="usage">{selected.entry.usage}</span>
            <span className="area"> · {areaOf(selected.entry)}</span>
            {selected.entry.aliases.length > 0 && <span className="micro muted"> also {selected.entry.aliases.map((a) => `/${a}`).join(", ")}</span>}
            <p>{selected.entry.detail}</p>
            {selected.entry.source === "agent" && <AgentAbout name={selected.entry.name} agent={agents.get(selected.entry.name)} manager={Boolean(actions.agents)} switches={selected.reason === null} />}
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
