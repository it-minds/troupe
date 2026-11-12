// A session starts from a message, not from a form.
//
// The message box comes first, and everything a start needs reads as one sentence under
// it: "Runs [on the platform] with [dev] as [build] · everyone on core can open it". Each
// bracketed word is a chip that opens its picker underneath — where it runs, which folder
// when it runs here, which profile, which agent. There is always a profile, it is just
// never a question: the last one used if it has room, else the first with room, and a line
// under the sentence always says which rule picked it, so the choice is seen and easy to
// change. `@profile`, `#agent`, `/local` and `/platform` typed in the message set the
// chips, win over them, and are taken out before the agent reads it (`messageTokens`,
// `cleanMessage`); clicking a chip's option takes the matching token out, so the last
// thing the person did is what holds.
//
// A full profile is amber and the button says "Queue it": the plane makes such a create
// wait for the next free place and holds its message (`pending`), and the casting screen
// shows that wait and asks again as `retry_after_ms` says, never one reply forever. At the
// administrator's ceiling the button is off and the line says the plane's sentence.
//
// "On this computer" is off, with the reason, until this computer's daemon answers, and
// turns on by itself when it does: on this screen that replaces the "daemon is ready now,
// Refresh" banner, since nothing here was asked of the daemon before it was there.

import { useEffect, useMemo, useRef, useState } from "react";
import type { JSX, KeyboardEvent as ReactKeyboardEvent, ReactNode } from "react";
import {
  LOCAL_DOWN_SENTENCE,
  TroupeRpcError,
  andList,
  autoPickProfile,
  ceilingSentence,
  cleanMessage,
  fullHouseSentence,
  messageTokens,
  profileRoom,
  stripTokens,
  titleFromMessage,
  tokensSentence,
  whoCanOpen,
} from "@troupe/client";
import type { AgentRow, AuthSession, DaemonClient, FleetRow, NewSessionWhere, ProfileOffering, SessionKind } from "@troupe/client";
import { useProfiles } from "../hooks";
import { prefs, shell } from "../shell";
import { relative } from "./bits";
import { Mask } from "./brand";

type DaemonStatus = "unsupported" | "searching" | "absent" | "connected" | "error";
type Picker = "where" | "folder" | "profile" | "agent";

/** The pref the last profile chosen is kept under, which the auto-pick starts from before any session exists. */
const LAST_PROFILE = "newSession.profile";

/** How long the casting screen waits for the first turn to start before it opens the session anyway. */
export const castingTiming = { firstTurnMs: 1500, retryFloorMs: 250 };

// Decoration: one per page load, so it does not flicker while typing. Every line that
// says something stays plain beside it.
const QUIPS = [
  "The stage is set. Give them the plot and step into the wings.",
  "No auditions today. Everyone already knows their lines.",
  "Break a leg. Or a build. Preferably not production.",
  "Every good run starts with a cue line.",
  "The house lights are down. What’s the scene?",
];
const CURTAINS = ["Curtain up.", "Places, everyone.", "Lights, cues, action."];
const pickOne = (xs: string[]): string => xs[Math.floor(Math.random() * xs.length)] ?? xs[0]!;

export function StartSession({
  auth,
  daemon,
  daemonStatus = daemon ? "connected" : "absent",
  linked,
  rows = [],
  onClose,
  onCreated,
  onProfile,
}: {
  /** Null in local mode: there is no platform to start one on, so the question is not asked. */
  auth: AuthSession | null;
  daemon: DaemonClient | null;
  /** Whether this computer's daemon answers now; "On this computer" is off until it does. */
  daemonStatus?: DaemonStatus;
  linked: boolean;
  /** The sessions the app already lists: the last profile used, and "start like last time". */
  rows?: FleetRow[];
  onClose: () => void;
  /**
   * With where it was made, which the list may not know yet when the session opens, and
   * for one on this computer the workspace the daemon started it in: its start goes on to
   * the brief's librarian there.
   */
  onCreated: (id: string, kind: SessionKind, workspace?: string) => void;
  /** Open the page saying what a profile gives a session. */
  onProfile?: ((name: string) => void) | undefined;
}): JSX.Element {
  const [quip] = useState(() => pickOne(QUIPS));
  const [curtain] = useState(() => pickOne(CURTAINS));
  const { profiles, error: profilesError } = useProfiles(auth);
  const localReady = daemon !== null && daemonStatus === "connected";

  const [text, setText] = useState("");
  const [title, setTitle] = useState("");
  const [titleTouched, setTitleTouched] = useState(false);
  const [whereChip, setWhereChip] = useState<NewSessionWhere | null>(null);
  const [profileChip, setProfileChip] = useState<string | null>(null);
  const [agentChip, setAgentChip] = useState<string | null>(null);
  const [folder, setFolder] = useState("");
  const [worktree, setWorktree] = useState<"auto" | "never" | "always">("auto");
  const [watch, setWatch] = useState(false);
  const [privately, setPrivately] = useState(false);
  const [open, setOpen] = useState<Picker | null>(null);
  const [ceilingSaid, setCeilingSaid] = useState<Record<string, string>>({});
  const [casting, setCasting] = useState<Casting | null>(null);
  const recentFolders = useRecentFolders(daemon);

  const me = auth?.me?.subject ?? null;
  const lastUsed = useMemo(() => {
    const mine = rows
      .filter((r) => r.kind === "team" && r.profile && (me === null || r.owner === null || r.owner === me))
      .sort((a, b) => (b.lastActiveAt ?? "").localeCompare(a.lastActiveAt ?? ""));
    return mine[0]?.profile ?? (prefs.get(LAST_PROFILE) || null);
  }, [rows, me]);
  const auto = autoPickProfile(profiles, lastUsed);

  // Where it runs before any token: the chip, else the platform where there is one.
  const chosenWhere: NewSessionWhere = whereChip ?? (auth ? "platform" : "local");
  const localAgents = useWorkspaceAgents(daemon, chosenWhere === "local" || text.includes("/local") ? folder.trim() : "");
  const profileNames = profiles.map((p) => p.name);
  const preProfile = profiles.find((p) => p.name === (profileChip ?? auto.name));
  const agentNames = [...(preProfile?.agents ?? []), ...(localAgents.rows ?? []).filter((r) => (r.mode ?? "primary") === "primary").map((r) => r.name)];
  const names = { profiles: profileNames, agents: agentNames };

  const tokens = messageTokens(text, names);
  // A token wins over the chip, and `@profile` without `/local` means the platform.
  const where: NewSessionWhere = auth ? (tokens.where ?? (tokens.profile ? "platform" : chosenWhere)) : "local";
  const local = where === "local";
  const profileName = tokens.profile ?? profileChip ?? auto.name;
  const prof = profiles.find((p) => p.name === profileName);
  const room = prof ? profileRoom(prof) : null;
  const defaultAgent = local ? (localAgents.rows?.find((r) => (r.mode ?? "primary") === "primary")?.name ?? "build") : (prof?.agents.includes("build") ? "build" : (prof?.agents[0] ?? "build"));
  const namedAgent = tokens.agent ?? agentChip;
  const agent = namedAgent ?? defaultAgent;
  const cleaned = cleanMessage(text, names);
  const shownTitle = titleTouched ? title : titleFromMessage(cleaned);
  const localDown = local && !localReady;
  const full = !local && room?.full === true;
  // At the ceiling by the listing, or by the plane's own refusal since it was read.
  const atCeiling = !local && (room?.atCeiling === true || (prof !== undefined && ceilingSaid[prof.name] !== undefined));
  // A plane answers its teams as rows with a name, though the credential types them as
  // names: either way they are said by name, never as "[object Object]".
  const myTeams = (auth?.me?.teams ?? []).map((t: unknown) => (typeof t === "string" ? t : String((t as { name?: unknown } | null)?.name ?? ""))).filter(Boolean);
  const who = whoCanOpen(where, { teams: prof?.teams ?? myTeams, private: privately });

  let why = "";
  let warn = false;
  if (!local && !profileChip && !tokens.profile) why = auto.why;
  why = tokensSentence(tokens) ?? why;
  if (full && prof) {
    why = fullHouseSentence(prof.name, prof.capacity);
    warn = true;
  }
  if (atCeiling && prof) {
    why = ceilingSaid[prof.name] ?? ceilingSentence(prof.name, room?.maxSessions ?? 0);
    warn = true;
  }
  if (localDown) {
    why = LOCAL_DOWN_SENTENCE;
    warn = true;
  }
  if (local && localReady && !folder.trim()) why = why || "Choose the folder it works in.";
  const blocked = local ? localDown || !folder.trim() : !prof || atCeiling;

  // The folder's picker opens while there is none, since a session here needs one, and
  // stays open while the path is typed.
  const needsFolder = local && localReady && !folder.trim();
  useEffect(() => {
    if (needsFolder && open === null) setOpen("folder");
  }, [needsFolder, open]);
  const shownPicker: Picker | null = open;

  // Escape closes an open picker.
  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === "Escape") setOpen(null);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  const toggle = (k: Picker): void => setOpen(shownPicker === k ? null : k);

  // Which start is the one on show: a step of an earlier one, or of one the person went
  // back from, changes nothing.
  const run = useRef(0);
  useEffect(
    () => () => {
      run.current += 1;
    },
    [],
  );

  /** A chip's option picked: it holds, and the matching token leaves the message. */
  const pick = (patch: { where?: NewSessionWhere; profile?: string; agent?: string; folder?: string }): void => {
    setText((t) => stripTokens(t, patch, names));
    if (patch.where) setWhereChip(patch.where);
    if (patch.profile) {
      setProfileChip(patch.profile);
      prefs.set(LAST_PROFILE, patch.profile);
    }
    if (patch.agent) setAgentChip(patch.agent);
    if (patch.folder !== undefined) setFolder(patch.folder);
    setOpen(null);
  };

  const start = (as: string | null = namedAgent): void => {
    if (blocked) return;
    const startedTitle = shownTitle.trim();
    const base: Casting = {
      title: startedTitle || "Untitled session",
      where,
      folder: folder.trim(),
      profile: prof?.name ?? "",
      agent: as ?? agent,
      hasText: cleaned.length > 0,
      queued: full,
      done: 0,
      waiting: false,
      failed: null,
      id: null,
      kind: null,
      workspace: null,
    };
    setOpen(null);
    setCasting(base);
    run.current += 1;
    const mine = run.current;
    const alive = (): boolean => run.current === mine;
    const set = (patch: Partial<Casting>): void => {
      if (alive()) setCasting((c) => (c ? { ...c, ...patch } : c));
    };
    if (!local && prof) {
      prefs.set(LAST_PROFILE, prof.name);
      void castOnPlatform(auth!, prof, { agent: as, title: startedTitle, prompt: cleaned }, set, alive, (reason) => setCeilingSaid((c) => ({ ...c, [prof.name]: reason })));
    } else if (daemon) {
      void castHere(daemon, { workspace: folder.trim(), agent: as, worktree, watch, privately, title: startedTitle, prompt: cleaned }, set);
    }
  };

  // Ctrl+Enter or Cmd+Enter starts, from anywhere in the composer.
  const onKeyDown = (e: ReactKeyboardEvent): void => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      start();
    }
  };

  if (casting) {
    return (
      <CastingScreen
        casting={casting}
        curtain={curtain}
        rows={rows}
        onRoute={(c) => onCreated(c.id!, c.kind!, c.workspace ?? undefined)}
        onBack={() => {
          run.current += 1;
          setCasting(null);
        }}
      />
    );
  }

  const recents = recentSessions(rows, me).slice(0, 3);
  const otherTeams = prof?.teams && myTeams.length > prof.teams.length ? prof.teams : null;

  return (
    <section className="start new-session" aria-label="Start a session" onKeyDown={onKeyDown}>
      <div className="ns-brand">
        <Mask size={28} label="Troupe" />
        <span className="ns-word" aria-hidden="true">
          troupe
        </span>
      </div>

      <div className="body">
        <div className="ns-hero">
          <div className="ns-hero-mask">
            <Mask size={84} />
          </div>
          <div>
            <span className="screen">New session · Act I</span>
            <h1>What should the troupe do?</h1>
            <p className="ns-quip">{quip}</p>
          </div>
        </div>

        {profilesError && (
          <div className="banner error">
            <p>Could not read what is available: {profilesError}</p>
          </div>
        )}

        <form
          className="ns-composer"
          onSubmit={(e) => {
            e.preventDefault();
            start();
          }}
        >
          <div className="ns-stripe" aria-hidden="true" />
          <label htmlFor="ns-ask" className="sr-only">
            First instruction
          </label>
          <textarea
            id="ns-ask"
            className="ns-ask"
            rows={5}
            value={text}
            onChange={(e) => setText(e.target.value)}
            placeholder="Rewrite the placement loop in dps.py so it tries corners first. Add @dev or #plan to change how it starts."
          />

          <div className="ns-sentence">
            Runs{" "}
            <Chip label="Where it runs" expanded={shownPicker === "where"} onClick={() => toggle("where")} tone={local ? "local" : "running"}>
              {local ? "on this computer" : "on the platform"}
            </Chip>{" "}
            {local ? (
              <>
                in{" "}
                <Chip label="Which folder" mono expanded={shownPicker === "folder"} onClick={() => toggle("folder")}>
                  {folder.trim() || "a folder"}
                </Chip>{" "}
              </>
            ) : (
              <>
                with{" "}
                <Chip label="Which profile" mono expanded={shownPicker === "profile"} onClick={() => toggle("profile")} tone={full || atCeiling ? "queued" : undefined}>
                  {prof?.name ?? "no profile"}
                </Chip>{" "}
              </>
            )}
            as{" "}
            <Chip label="Which agent" expanded={shownPicker === "agent"} onClick={() => toggle("agent")}>
              {agent}
            </Chip>{" "}
            <span>· {who}</span>
          </div>

          {why && (
            <p className={warn ? "ns-why warn" : "ns-why"} role="status">
              {warn && <span aria-hidden="true">▲ </span>}
              {why}
            </p>
          )}

          {shownPicker === "where" && (
            <PickerPanel title="WHERE IT RUNS" hint="/local · /platform">
              {auth && (
                <Option
                  label="On the platform"
                  tag="REMOTE"
                  tone="running"
                  pressed={!local}
                  detail="Keeps running when you close this window. Your team can open it."
                  onClick={() => pick({ where: "platform" })}
                />
              )}
              <Option
                label="On this computer"
                tag={localReady ? "LOCAL" : "APP NOT RUNNING"}
                tone={localReady ? "local" : "offline"}
                pressed={local}
                disabled={!localReady}
                detail="Uses your own checkout and files. Stops when the Troupe app on this computer stops."
                onClick={() => pick({ where: "local" })}
              />
            </PickerPanel>
          )}

          {shownPicker === "folder" && local && daemon && (
            <PickerPanel title="WHICH FOLDER" hint="RECENT">
              <LocalControls
                daemon={daemon}
                linked={linked}
                folder={folder}
                recent={recentFolders}
                worktree={worktree}
                watch={watch}
                privately={privately}
                onFolder={setFolder}
                onPick={(f) => pick({ folder: f })}
                onWorktree={setWorktree}
                onWatch={setWatch}
                onPrivately={setPrivately}
              />
            </PickerPanel>
          )}

          {shownPicker === "profile" && !local && (
            <PickerPanel title="WHAT IT CAN REACH" hint="@profile">
              {profiles.map((p) => {
                const r = profileRoom(p);
                const reach = p.mcp_servers.length > 0 ? `Reaches ${p.mcp_servers.join(", ")}.` : "Nothing outside its own workspace.";
                const only = p.teams && myTeams.length > p.teams.length && p.teams.length > 0 ? ` Only for ${andList(p.teams)}.` : "";
                return (
                  <Option
                    key={p.name}
                    label={p.name}
                    mono
                    tag={r.atCeiling ? "AT ITS LIMIT" : r.full ? "FULL" : `${r.free} OF ${r.capacity} FREE`}
                    tone={r.full || r.atCeiling ? "queued" : "running"}
                    pressed={p.name === prof?.name}
                    detail={reach + only}
                    onClick={() => pick({ profile: p.name })}
                  />
                );
              })}
              {profiles.length === 0 && !profilesError && <p className="note">Loading what you can use…</p>}
              {prof && onProfile && (
                <button type="button" className="link" onClick={() => onProfile(prof.name)}>
                  What {prof.name} can reach
                </button>
              )}
            </PickerPanel>
          )}

          {shownPicker === "agent" && (
            <PickerPanel title="HOW IT STARTS" hint="#agent">
              {agentOptions(local ? localAgents.rows : (prof?.agents ?? []).map((name) => ({ name, description: "" }))).map((a) => (
                <Option
                  key={a.name}
                  label={a.name}
                  {...(a.name === defaultAgent ? { tag: local ? "DEFAULT" : "PROFILE DEFAULT" } : {})}
                  tone="agent"
                  pressed={a.name === agent}
                  {...(a.description ? { detail: a.description } : {})}
                  onClick={() => pick({ agent: a.name })}
                />
              ))}
              {local && localAgents.error && <p className="note">Could not read the agents here: {localAgents.error}</p>}
              {local && !localAgents.rows && !localAgents.error && <p className="note">Reading the agents here…</p>}
            </PickerPanel>
          )}

          <div className="ns-foot">
            <label className="ns-called">
              <span>CALLED</span>
              <input
                type="text"
                value={shownTitle}
                onChange={(e) => {
                  setTitle(e.target.value);
                  setTitleTouched(true);
                }}
                placeholder="Named from your first line"
                aria-label="What to call it"
              />
            </label>
            <span className="ns-chord" aria-hidden="true">
              Ctrl ↵ · curtain up
            </span>
            <button type="submit" className={full ? "ns-start queue" : "ns-start"} disabled={blocked}>
              {full ? "Queue it" : cleaned ? "Start" : "Start empty"}
            </button>
          </div>
        </form>

        <p className="ns-hint">
          Type <code>@profile</code>, <code>#agent</code> or <code>/local</code> in the message to change these without leaving the keyboard. They’re
          removed before the troupe reads it.
        </p>

        {recents.length > 0 && (
          <section aria-labelledby="ns-recent">
            <h2 id="ns-recent" className="screen">
              Encore · start like last time
            </h2>
            <ul className="ns-recents">
              {recents.map((r) => (
                <li key={r.id}>
                  <button
                    type="button"
                    className="ns-recent"
                    onClick={() => {
                      if (r.where === "local" ? localReady : Boolean(auth)) setWhereChip(r.where);
                      if (r.folder) setFolder(r.folder);
                      if (r.profile && r.where === "platform") setProfileChip(r.profile);
                      if (r.agent) setAgentChip(r.agent);
                      setOpen(null);
                    }}
                  >
                    <span className="ns-recent-title">{r.title}</span>
                    <span className="ns-recent-facts">
                      {[r.where === "local" ? "THIS COMPUTER" : "PLATFORM", r.where === "local" ? r.folder : r.profile, r.agent ?? "its default", r.when].filter(Boolean).join(" · ")}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          </section>
        )}

        {otherTeams && <p className="note">{prof!.name} is only for {andList(otherTeams)}.</p>}

        <div className="actions">
          <button type="button" onClick={onClose}>
            Cancel
          </button>
        </div>
      </div>
    </section>
  );
}

function Chip({
  label,
  expanded,
  onClick,
  mono,
  tone,
  children,
}: {
  label: string;
  expanded: boolean;
  onClick: () => void;
  mono?: boolean;
  tone?: "running" | "local" | "queued" | undefined;
  children: string;
}): JSX.Element {
  return (
    <button
      type="button"
      className={["ns-chip", mono ? "mono" : "", tone ? `tone-${tone}` : ""].filter(Boolean).join(" ")}
      aria-expanded={expanded}
      aria-label={`${label}: ${children}`}
      onClick={onClick}
    >
      {(tone === "running" || tone === "local") && (
        <span className="ns-dot" aria-hidden="true">
          ●
        </span>
      )}
      {children}
      <span className="ns-caret" aria-hidden="true">
        ▾
      </span>
    </button>
  );
}

function PickerPanel({ title, hint, children }: { title: string; hint: string; children: ReactNode }): JSX.Element {
  return (
    <div className="ns-picker" role="group" aria-label={title.toLowerCase()}>
      <div className="ns-picker-head">
        <span className="screen">{title}</span>
        <span className="ns-picker-hint">{hint}</span>
      </div>
      <div className="ns-picker-grid">{children}</div>
    </div>
  );
}

function Option({
  label,
  tag,
  tone,
  detail,
  pressed,
  disabled,
  mono,
  onClick,
}: {
  label: string;
  tag?: string;
  tone?: "running" | "local" | "queued" | "offline" | "agent";
  detail?: string;
  pressed: boolean;
  disabled?: boolean;
  mono?: boolean;
  onClick: () => void;
}): JSX.Element {
  return (
    <button type="button" className={tone ? `ns-opt tone-${tone}` : "ns-opt"} aria-pressed={pressed} disabled={disabled ?? false} onClick={onClick}>
      <span className="ns-opt-dot" aria-hidden="true" />
      <span className="ns-opt-body">
        <span className="ns-opt-head">
          <span className={mono ? "ns-opt-label mono" : "ns-opt-label"}>{label}</span>
          {tag && <span className="ns-opt-tag">{tag}</span>}
        </span>
        {detail && <span className="ns-opt-detail">{detail}</span>}
      </span>
    </button>
  );
}

/**
 * A session on this computer: the folder (recent ones, Choose…, a typed path), whether it
 * gets its own checkout, watch mode, and private where the daemon can seal one.
 */
function LocalControls({
  daemon,
  linked,
  folder,
  recent,
  worktree,
  watch,
  privately,
  onFolder,
  onPick,
  onWorktree,
  onWatch,
  onPrivately,
}: {
  daemon: DaemonClient;
  linked: boolean;
  folder: string;
  recent: string[];
  worktree: "auto" | "never" | "always";
  watch: boolean;
  privately: boolean;
  onFolder: (f: string) => void;
  onPick: (f: string) => void;
  onWorktree: (w: "auto" | "never" | "always") => void;
  onWatch: (w: boolean) => void;
  onPrivately: (p: boolean) => void;
}): JSX.Element {
  const chooser = shell()?.pickDirectory;
  // Only where the daemon says it can seal one; a link made since cannot change what it
  // said at `initialize`, but a daemon that knows the capability and is linked now can.
  const canSeal = daemon.supportsPrivateSessions || (linked && "private_sessions" in daemon.capabilities);
  return (
    <div className="ns-local">
      <div className="ns-folder">
        <input value={folder} onChange={(e) => onFolder(e.target.value)} placeholder={chooser ? "Choose one, or type a path" : "/home/you/project"} aria-label="Which directory" spellCheck={false} />
        {chooser && (
          <button type="button" onClick={() => void chooser().then((p) => p && onPick(p))}>
            Choose…
          </button>
        )}
      </div>
      {recent.length > 0 && (
        <div className="chips">
          {recent.map((path) => (
            <button key={path} type="button" className="chip as-button" aria-pressed={folder === path} onClick={() => onPick(path)}>
              {path}
            </button>
          ))}
        </div>
      )}
      <label className="ns-small">
        If something is already running there
        <select value={worktree} onChange={(e) => onWorktree(e.target.value as typeof worktree)}>
          <option value="auto">Give this one its own branch and checkout</option>
          <option value="never">Use the same directory anyway</option>
          <option value="always">Always give it its own, even when nothing else is running</option>
        </select>
      </label>
      <label className="inline ns-small">
        <input type="checkbox" checked={watch} onChange={(e) => onWatch(e.target.checked)} />
        Act on notes I leave in the files
      </label>
      {canSeal && (
        <label className="inline ns-small">
          <input type="checkbox" checked={privately} onChange={(e) => onPrivately(e.target.checked)} disabled={!linked} />
          {linked ? "Keep it private, and let it follow me to other devices" : "Keep it private (needs your account linked to this computer first)"}
        </label>
      )}
    </div>
  );
}

// The agents a session could start as, before there is one: the primaries, by name and what
// each does. Nothing to switch or edit yet; that is a running session's picker.
function agentOptions(rows: Array<Pick<AgentRow, "name" | "description" | "mode">> | null): Array<{ name: string; description: string }> {
  return (rows ?? []).filter((r) => (r.mode ?? "primary") === "primary").map((r) => ({ name: r.name, description: r.description }));
}

interface Recent {
  id: string;
  title: string;
  where: NewSessionWhere;
  folder: string | null;
  profile: string | null;
  agent: string | null;
  when: string;
}

/**
 * The newest sessions to start another like: the person's own on the platform and those on
 * this computer, not a branch. A plane row's agent is the one it runs as; a daemon row's
 * `profile` is its agent, and its folder its workspace.
 */
function recentSessions(rows: FleetRow[], me: string | null): Recent[] {
  return rows
    .filter((r) => r.kind === "team" || r.kind === "local" || r.kind === "private")
    .filter((r) => !(r.raw as { parent?: unknown } | null)?.parent)
    .filter((r) => r.kind !== "team" || me === null || r.owner === null || r.owner === me)
    .sort((a, b) => (b.lastActiveAt ?? "").localeCompare(a.lastActiveAt ?? ""))
    .map((r) => {
      const raw = (r.raw ?? {}) as { workspace?: unknown; agent?: unknown };
      const local = r.kind !== "team";
      const folder = local && typeof raw.workspace === "string" ? raw.workspace : null;
      const at = r.lastActiveAt ? Date.parse(r.lastActiveAt) : NaN;
      return {
        id: r.id,
        title: r.title ?? folder ?? r.id,
        where: local ? "local" : "platform",
        folder,
        profile: local ? null : r.profile,
        agent: local ? r.profile : typeof raw.agent === "string" ? raw.agent : null,
        when: Number.isNaN(at) ? "" : relative(at),
      };
    });
}

/** What the casting screen shows, as the start goes. */
interface Casting {
  title: string;
  where: NewSessionWhere;
  folder: string;
  profile: string;
  agent: string;
  hasText: boolean;
  /** Started on a full profile: step two is the wait for a free place. */
  queued: boolean;
  /** How many of the three steps are done. */
  done: number;
  /** The plane said it waits for a place, and is being asked again. */
  waiting: boolean;
  failed: string | null;
  id: string | null;
  kind: SessionKind | null;
  workspace: string | null;
}

type SetCasting = (patch: Partial<Casting>) => void;

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

interface PlaneCreate {
  session_id: string;
  state?: string;
  retry_after_ms?: number;
  token?: string;
}

/**
 * A start on the platform: the create, and while the plane says the session waits for a
 * place, `token.mint` again each `retry_after_ms` until it is placed. The wait is shown,
 * and stopped by going back to the form; the session then waits on by itself.
 */
async function castOnPlatform(
  auth: AuthSession,
  prof: ProfileOffering,
  ask: { agent: string | null; title: string; prompt: string },
  set: SetCasting,
  alive: () => boolean,
  onCeiling: (reason: string) => void,
): Promise<void> {
  let answer: PlaneCreate;
  try {
    answer = await auth.rpc<PlaneCreate>("session.create", {
      profile: prof.name,
      // The sentence says everyone on the profile's team can open it, so it is a team's.
      visibility: "team",
      ...(ask.agent ? { agent: ask.agent } : {}),
      ...(ask.title ? { title: ask.title } : {}),
      ...(ask.prompt ? { prompt: ask.prompt } : {}),
    });
  } catch (e) {
    const reason = refusal(e);
    // `capacity` (-32008): the administrator's ceiling, in the plane's own sentence.
    if (e instanceof TroupeRpcError && e.code === -32008 && typeof e.data?.["reason"] === "string") onCeiling(e.data["reason"]);
    set({ failed: reason });
    return;
  }
  const id = answer.session_id;
  set({ id, kind: "team", done: 1, queued: answer.state === "pending", waiting: answer.state === "pending" });
  while (answer.state === "pending") {
    await sleep(Math.max(castingTiming.retryFloorMs, answer.retry_after_ms ?? 2000));
    if (!alive()) return;
    try {
      answer = await auth.rpc<PlaneCreate>("token.mint", { session_id: id });
    } catch (e) {
      set({ failed: refusal(e), waiting: false });
      return;
    }
  }
  set({ done: 2, waiting: false });
}

/** A start on this computer: the daemon's create, which answers once the session is made. */
async function castHere(
  daemon: DaemonClient,
  ask: { workspace: string; agent: string | null; worktree: "auto" | "never" | "always"; watch: boolean; privately: boolean; title: string; prompt: string },
  set: SetCasting,
): Promise<void> {
  try {
    // `private` beside the workspace, where the daemon reads it: inside `config` it was a
    // setting no client may choose, and the session was made local (issue #365).
    const created = await daemon.createSession({
      workspace: ask.workspace,
      ...(ask.agent ? { profile: ask.agent } : {}),
      worktree: ask.worktree,
      ...(ask.prompt ? { prompt: ask.prompt } : {}),
      ...(ask.title ? { title: ask.title } : {}),
      config: { watch: ask.watch },
      ...(ask.privately ? { private: true } : {}),
    });
    set({ id: created.session_id, kind: ask.privately ? "private" : "local", workspace: created.workspace ?? ask.workspace, done: 2 });
  } catch (e) {
    set({ failed: refusal(e) });
  }
}

/** A refusal in one line: the plane's or the daemon's own sentence where it gave one. */
function refusal(e: unknown): string {
  if (e instanceof TroupeRpcError) {
    const reason = e.data?.["reason"];
    if (typeof reason === "string" && reason) return reason.charAt(0).toUpperCase() + reason.slice(1);
  }
  return e instanceof Error ? e.message : String(e);
}

/**
 * Casting: three steps in the design's words, fed by what the create answers and by the
 * session's row. Step three is the first turn starting where a message was given, which
 * the row's status says; it is not waited on longer than `castingTiming.firstTurnMs`, and
 * then the session opens by itself.
 */
function CastingScreen({
  casting: c,
  curtain,
  rows,
  onRoute,
  onBack,
}: {
  casting: Casting;
  curtain: string;
  rows: FleetRow[];
  onRoute: (c: Casting) => void;
  onBack: () => void;
}): JSX.Element {
  const row = c.id ? rows.find((r) => r.id === c.id) : undefined;
  const turned = Boolean(row && row.status && row.status !== "idle");
  const [waited, setWaited] = useState(false);
  const routed = useRef(false);
  const ready = c.done >= 2 && c.failed === null && (!c.hasText || turned || waited);
  const done = ready ? 3 : c.done;

  useEffect(() => {
    if (c.done < 2 || !c.hasText) return;
    const t = setTimeout(() => setWaited(true), castingTiming.firstTurnMs);
    return () => clearTimeout(t);
  }, [c.done, c.hasText]);

  useEffect(() => {
    if (ready && !routed.current && c.id) {
      routed.current = true;
      onRoute(c);
    }
  }, [ready, c, onRoute]);

  const steps: Array<[string, string]> = [
    [c.where === "local" ? `Opening ${c.folder} on this computer` : "Finding a machine on the platform", "building the set"],
    [c.queued ? `Waiting for a free place in ${c.profile}` : `Setting up ${c.where === "local" ? c.agent : `${c.profile} as ${c.agent}`}`, c.queued ? "waiting in the wings" : "handing out scripts"],
    [c.hasText ? "Handing over your instruction" : "Ready for your first message", "cue line"],
  ];

  return (
    <section className="start new-session casting" aria-label="Casting">
      <div className="body">
        <div className="ns-hero">
          <div className="ns-hero-mask">
            <Mask size={84} />
          </div>
          <div>
            <span className="screen">Casting</span>
            <h1>{c.title}</h1>
            <p className="ns-quip">{c.failed ? "The curtain stuck." : done >= 3 ? curtain : "The troupe is getting into costume…"}</p>
          </div>
        </div>
        <ol className="ns-steps" role="status">
          {steps.map(([label, aside], i) => (
            <li key={label} className={i < done ? "done" : i === done && !c.failed ? "now" : "later"}>
              <span className="ns-step-dot" aria-hidden="true" />
              <span className="ns-step-word">{i < done ? "done" : i === done && !c.failed ? (c.waiting && i === 1 ? "waiting" : "now") : "next"}</span>
              {label}
              <span className="ns-aside">// {aside}</span>
            </li>
          ))}
        </ol>
        {c.failed && (
          <p className="ns-why warn" role="alert">
            <span aria-hidden="true">▲ </span>
            Could not start: {c.failed}
          </p>
        )}
        <div className="actions">
          {ready && c.id && (
            <button type="button" className="primary" onClick={() => onRoute(c)}>
              Open the session
            </button>
          )}
          {(c.failed || c.waiting) && (
            <button type="button" onClick={onBack}>
              {c.waiting ? "Stop waiting: it starts by itself when a place frees" : "Back to the form"}
            </button>
          )}
        </div>
      </div>
    </section>
  );
}

/** The folders sessions here worked in lately, as the daemon lists them. */
function useRecentFolders(daemon: DaemonClient | null): string[] {
  const [recent, setRecent] = useState<string[]>([]);
  useEffect(() => {
    if (!daemon) return;
    let live = true;
    void daemon
      .recentWorkspaces()
      .then((r) => live && setRecent(r.workspaces.slice(0, 6).map((w) => w.path)))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [daemon]);
  return recent;
}

/**
 * The agents a session in a workspace could run, as the daemon's `agents.list` answers for
 * it (troupe #594): the one list every picker reads, asked once the path has stopped
 * changing for a moment.
 */
function useWorkspaceAgents(daemon: DaemonClient | null, workspace: string): { rows: AgentRow[] | null; error: string | null } {
  const [rows, setRows] = useState<AgentRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setRows(null);
    setError(null);
    if (!workspace || !daemon) return;
    let live = true;
    const asked = setTimeout(() => {
      void daemon
        .listAgents(workspace)
        .then((r) => live && setRows(r.agents))
        .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)));
    }, 250);
    return () => {
      live = false;
      clearTimeout(asked);
    };
  }, [daemon, workspace]);
  return { rows, error };
}
