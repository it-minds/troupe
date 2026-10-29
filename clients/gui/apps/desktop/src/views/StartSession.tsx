// Starting a session is a question about where the work happens, and then three
// decisions inside that: who it belongs to, what it can reach, and what it may start as.
//
// Each is phrased as a consequence rather than as a setting. `profiles.list` answers the
// middle one *before* anything is created — the agents it may start as, the skills and
// MCP servers the current bundle gives it, and whether there is anywhere to put it right
// now. Choosing blind and finding out afterwards is the thing this avoids.
//
// The local half asks different questions, because a local session has different ones: a
// directory rather than a profile's capacity, whether to branch, whether to act on notes
// left in the files, and whether it should be sealed and follow you to another device.
//
// It is a screen of its own, as the comp draws it — "Cast a troupe" — not a dialog over
// the list: the list's button and the launcher's tile both come here.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import type { AgentRow, AuthSession, DaemonClient, ProfileOffering, SessionKind } from "@troupe/client";
import { useProfiles } from "../hooks";
import { shell } from "../shell";
import { AgentPicker } from "./AgentPicker";

export function StartSession({
  auth,
  daemon,
  linked,
  onClose,
  onCreated,
  onProfile,
}: {
  /** Null in local mode: there is no platform to start one on, so the question is not asked. */
  auth: AuthSession | null;
  daemon: DaemonClient | null;
  linked: boolean;
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
  const [where, setWhere] = useState<"team" | "local">(auth ? "team" : "local");

  return (
    <section className="start" aria-label="Start a session">
      <header className="screen-head">
        <span className="count">New session</span>
        <h1>Cast a troupe</h1>
      </header>

      <div className="body">
        {auth && daemon && (
          <section>
            <span className="screen">Where it runs</span>
            <div className="tiles">
              <button className="option" aria-pressed={where === "team"} onClick={() => setWhere("team")}>
                <span className="kicker">Remote</span>
                <span className="label">On the platform</span>
                <span className="consequence">
                  A machine in the cluster, openable by your team, and still running when this window is closed.
                </span>
              </button>
              <button className="option local" aria-pressed={where === "local"} onClick={() => setWhere("local")}>
                <span className="kicker">Local</span>
                <span className="label">On this computer</span>
                <span className="consequence">Your own checkout and your own files. It stops when the daemon does.</span>
              </button>
            </div>
          </section>
        )}

        {auth && (where === "team" || !daemon) ? (
          <TeamSession auth={auth} onClose={onClose} onCreated={onCreated} onProfile={onProfile} />
        ) : daemon ? (
          <LocalSession daemon={daemon} linked={linked} onClose={onClose} onCreated={onCreated} />
        ) : (
          <>
            <p className="note">
              There is nowhere to start one yet: the daemon on this computer is not connected. Connect it on This computer, then come
              back.
            </p>
            <div className="actions">
              <button onClick={onClose}>Close</button>
            </div>
          </>
        )}
      </div>
    </section>
  );
}

// A profile's agents before any session has them: the offering names them, and each is
// the organisation's, from that profile's bundle, changed in the console. Once a session
// runs, its own `agents.list` says the rest.
function offered(profile: ProfileOffering): AgentRow[] {
  return profile.agents.map((name) => ({
    name,
    description: "",
    source: "bundle",
    layer: "bundle",
    origin: "Your organisation's",
    profile: profile.name,
    editable: false,
    editable_reason: `${name} comes from the profile's bundle; change it in the console`,
  }));
}

function TeamSession({
  auth,
  onClose,
  onCreated,
  onProfile,
}: {
  auth: AuthSession;
  onClose: () => void;
  onCreated: (id: string, kind: SessionKind) => void;
  onProfile?: ((name: string) => void) | undefined;
}): JSX.Element {
  const { profiles, error: profilesError } = useProfiles(auth);
  const [picked, setPicked] = useState<string | null>(null);
  const [agent, setAgent] = useState("");
  const [title, setTitle] = useState("");
  const [prompt, setPrompt] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const chosen: ProfileOffering | undefined = profiles.find((p) => p.name === picked) ?? profiles[0];
  const teams = auth.me?.teams ?? [];
  const free = chosen ? chosen.capacity - chosen.active_sessions : 0;

  const start = async (as: string = agent): Promise<void> => {
    if (!chosen) return;
    setBusy(true);
    setError(null);
    try {
      const created = await auth.rpc<{ session_id: string }>("session.create", {
        profile: chosen.name,
        ...(as ? { agent: as } : {}),
        ...(title.trim() ? { title: title.trim() } : {}),
        ...(prompt.trim() ? { prompt: prompt.trim() } : {}),
      });
      onCreated(created.session_id, "team");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      {profilesError && (
        <div className="banner error">
          <p>Could not read what is available: {profilesError}</p>
        </div>
      )}

      <section>
        <span className="screen">What it can reach</span>
        <div className="options">
          {profiles.map((p) => {
            const spare = p.capacity - p.active_sessions;
            return (
              <button
                key={p.name}
                className="option"
                aria-pressed={chosen?.name === p.name}
                onClick={() => {
                  setPicked(p.name);
                  setAgent("");
                }}
              >
                <span className="label mono">{p.name}</span>
                <span className="consequence">
                  {p.skills.length > 0 ? `Can ${p.skills.map((s) => s.name).join(", ")}. ` : ""}
                  {p.mcp_servers.length > 0 ? `Reaches ${p.mcp_servers.join(", ")}. ` : "Reaches nothing outside its own workspace. "}
                  {spare > 0 ? `Room for ${spare} more right now.` : "Full right now — starting will be refused until one finishes."}
                </span>
              </button>
            );
          })}
          {profiles.length === 0 && !profilesError && <p className="note">Loading what you can use…</p>}
        </div>
        {/* The whole of it, before starting: its agents and what is not there, whose access
            each server is called with, its model, its hosts and its limits. */}
        {chosen && onProfile && (
          <button className="link" onClick={() => onProfile(chosen.name)}>
            What this profile can reach
          </button>
        )}
      </section>

      {chosen && (
        <>
          <section>
            <span className="screen">Who can open it</span>
            <p className="note">
              {teams.length > 0
                ? `Everyone on ${teams.join(" and ")} can open this session and answer its approvals.`
                : "You can open this session. It is billed to your team."}
            </p>
          </section>

          <section>
            <span className="screen">How it should start</span>
            <p className="note">{agent ? `On ${agent}.` : "However this profile normally starts, unless you pick one of its agents."}</p>
            <AgentPicker
              label="The agent it starts as"
              rows={offered(chosen)}
              current={null}
              chosen={agent || null}
              onChoose={setAgent}
              start={(name) => start(name)}
              switchTo="There is no session to switch yet: start one on it."
            />
          </section>

          <div className="fields">
            <label>
              What to call it <small>optional</small>
              <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Rewrite the placement loop" />
            </label>
          </div>

          <label>
            First instruction <small>optional — you can also say it afterwards</small>
            <textarea value={prompt} onChange={(e) => setPrompt(e.target.value)} rows={4} />
          </label>
        </>
      )}

      {error && (
        <div className="banner error">
          <p>{error}</p>
        </div>
      )}

      <div className="actions">
        <button className="primary" onClick={() => void start()} disabled={busy || !chosen || free <= 0}>
          {busy ? "Starting…" : "Start"}
        </button>
        <button onClick={onClose}>Cancel</button>
        {chosen && free <= 0 && <span className="note">Every machine on {chosen.name} is busy. Try another, or wait for one to finish.</span>}
      </div>
    </>
  );
}

/**
 * A session on this computer.
 *
 * The workspace is a directory, which a desktop shell can let somebody choose and a
 * browser can only be told about. Both are offered where both exist, and the recent list
 * is there either way because the answer is almost always one somebody has used before.
 */
function LocalSession({
  daemon,
  linked,
  onClose,
  onCreated,
}: {
  daemon: DaemonClient;
  linked: boolean;
  onClose: () => void;
  onCreated: (id: string, kind: SessionKind, workspace?: string) => void;
}): JSX.Element {
  const [workspace, setWorkspace] = useState("");
  const [recent, setRecent] = useState<Array<{ path: string; sessions: number }>>([]);
  const [worktree, setWorktree] = useState<"auto" | "never" | "always">("auto");
  const [watch, setWatch] = useState(false);
  const [privately, setPrivately] = useState(false);
  const [prompt, setPrompt] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [agent, setAgent] = useState<string | null>(null);
  const agents = useWorkspaceAgents(daemon, workspace.trim());
  const picker = shell()?.pickDirectory;

  useEffect(() => {
    let live = true;
    void daemon
      .recentWorkspaces()
      .then((r) => live && setRecent(r.workspaces.slice(0, 6)))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [daemon]);

  const start = async (as: string | null = agent): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      // `private` beside the workspace, where the daemon reads it: inside `config` it was a
      // setting no client may choose, and the session was made local (issue #365).
      const created = await daemon.createSession({
        workspace: workspace.trim(),
        ...(as ? { profile: as } : {}),
        worktree,
        ...(prompt.trim() ? { prompt: prompt.trim() } : {}),
        config: { watch },
        ...(privately ? { private: true } : {}),
      });
      onCreated(created.session_id, privately ? "private" : "local", created.workspace);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <section>
        <span className="screen local">Which directory</span>
        <div className="inline-form" style={{ marginBottom: 0 }}>
          <input
            value={workspace}
            onChange={(e) => setWorkspace(e.target.value)}
            placeholder={picker ? "Choose one, or type a path" : "/home/you/project"}
            aria-label="Which directory"
            spellCheck={false}
            style={{ flex: 1 }}
          />
          {picker && (
            <button type="button" onClick={() => void picker().then((p) => p && setWorkspace(p))}>
              Choose…
            </button>
          )}
        </div>
        {recent.length > 0 && (
          <div className="chips">
            {recent.map((w) => (
              <button key={w.path} className="chip as-button" onClick={() => setWorkspace(w.path)}>
                {w.path}
              </button>
            ))}
          </div>
        )}
      </section>

      {workspace.trim() && (
        <section>
          <span className="screen local">Which agent</span>
          <p className="note">{agent ? `On ${agent}.` : "The configuration's default agent, unless you pick one."}</p>
          <AgentPicker
            label="The agent it starts as"
            rows={agents.rows}
            error={agents.error}
            current={null}
            chosen={agent}
            onChoose={setAgent}
            start={(name) => start(name)}
            switchTo="There is no session to switch yet: start one on it."
          />
        </section>
      )}

      <label>
        If something is already running there
        <select value={worktree} onChange={(e) => setWorktree(e.target.value as typeof worktree)}>
          <option value="auto">Give this one its own branch and checkout</option>
          <option value="never">Use the same directory anyway</option>
          <option value="always">Always give it its own, even when nothing else is running</option>
        </select>
      </label>

      <section>
        <label className="inline">
          <input type="checkbox" checked={watch} onChange={(e) => setWatch(e.target.checked)} />
          Act on notes I leave in the files
        </label>
        <p className="note">
          Watch mode reads comments you save in the workspace and treats them as input. One session per workspace may do it; a second is
          refused rather than fighting the first.
        </p>
      </section>

      {/* Only where the daemon says it can seal one. A checkbox for something the
          server has never heard of reads as a setting that did not take. It says so at
          `initialize`, which a link made since cannot change: a daemon that knows the
          capability and is linked now can seal one too (#365). */}
      {(daemon.supportsPrivateSessions || (linked && "private_sessions" in daemon.capabilities)) && (
        <section>
          <label className="inline">
            <input type="checkbox" checked={privately} onChange={(e) => setPrivately(e.target.checked)} disabled={!linked} />
            Keep it private, and let it follow me to other devices
          </label>
          <p className="note">
            {linked
              ? "A private session runs here and is sealed under your own key before anything is stored. The platform lists it and can never read it."
              : "This needs your account linked to this computer first — the control is on “This computer”."}
          </p>
        </section>
      )}

      <label>
        First instruction <small>optional — you can also say it afterwards</small>
        <textarea value={prompt} onChange={(e) => setPrompt(e.target.value)} rows={4} />
      </label>

      {error && (
        <div className="banner error">
          <p>{error}</p>
        </div>
      )}

      <div className="actions">
        <button className="primary" onClick={() => void start()} disabled={busy || !workspace.trim()}>
          {busy ? "Starting…" : "Start"}
        </button>
        <button onClick={onClose}>Cancel</button>
      </div>
    </>
  );
}

/**
 * The agents a session in a workspace could run, as the daemon's `agents.list` answers for
 * it (troupe #594), asked once the path has stopped changing for a moment.
 */
function useWorkspaceAgents(daemon: DaemonClient, workspace: string): { rows: AgentRow[] | null; error: string | null } {
  const [rows, setRows] = useState<AgentRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setRows(null);
    setError(null);
    if (!workspace) return;
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