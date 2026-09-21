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

import { useEffect, useState } from "react";
import type { JSX } from "react";
import type { AuthSession, DaemonClient, ProfileOffering } from "@troupe/client";
import { useProfiles } from "../hooks";
import { shell } from "../shell";

export function StartSession({
  auth,
  daemon,
  linked,
  onClose,
  onCreated,
}: {
  auth: AuthSession;
  daemon: DaemonClient | null;
  linked: boolean;
  onClose: () => void;
  onCreated: (id: string) => void;
}): JSX.Element {
  const [where, setWhere] = useState<"team" | "local">("team");

  return (
    <div className="scrim" onClick={onClose}>
      <div className="dialog" role="dialog" aria-modal="true" aria-label="Start a session" onClick={(e) => e.stopPropagation()}>
        <h1>Start a session</h1>

        {daemon && (
          <div className="stack" style={{ gap: "var(--space-2)" }}>
            <h3>Where it runs</h3>
            <div className="options">
              <button className="option" aria-pressed={where === "team"} onClick={() => setWhere("team")}>
                <span className="label">On the platform</span>
                <span className="consequence">
                  A machine in the cluster, openable by your team, and still running when this window is closed.
                </span>
              </button>
              <button className="option" aria-pressed={where === "local"} onClick={() => setWhere("local")}>
                <span className="label">On this computer</span>
                <span className="consequence">Your own checkout and your own files. It stops when the daemon does.</span>
              </button>
            </div>
          </div>
        )}

        {where === "team" || !daemon ? (
          <TeamSession auth={auth} onClose={onClose} onCreated={onCreated} />
        ) : (
          <LocalSession daemon={daemon} linked={linked} onClose={onClose} onCreated={onCreated} />
        )}
      </div>
    </div>
  );
}

function TeamSession({
  auth,
  onClose,
  onCreated,
}: {
  auth: AuthSession;
  onClose: () => void;
  onCreated: (id: string) => void;
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

  const start = async (): Promise<void> => {
    if (!chosen) return;
    setBusy(true);
    setError(null);
    try {
      const created = await auth.rpc<{ session_id: string }>("session.create", {
        profile: chosen.name,
        ...(agent ? { agent } : {}),
        ...(title.trim() ? { title: title.trim() } : {}),
        ...(prompt.trim() ? { prompt: prompt.trim() } : {}),
      });
      onCreated(created.session_id);
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

      <div className="stack" style={{ gap: "var(--space-2)" }}>
        <h3>What it can reach</h3>
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
                <span className="label">{p.name}</span>
                <span className="consequence">
                  {p.skills.length > 0 ? `Can ${p.skills.map((s) => s.name).join(", ")}. ` : ""}
                  {p.mcp_servers.length > 0 ? `Reaches ${p.mcp_servers.join(", ")}. ` : "Reaches nothing outside its own workspace. "}
                  {spare > 0 ? `Room for ${spare} more right now.` : "Full right now — starting will be refused until one finishes."}
                </span>
              </button>
            );
          })}
          {profiles.length === 0 && !profilesError && (
            <p className="note" style={{ padding: "var(--space-3)" }}>
              Loading what you can use…
            </p>
          )}
        </div>
      </div>

      {chosen && (
        <>
          <div className="stack" style={{ gap: "var(--space-2)" }}>
            <h3>Who can open it</h3>
            <p className="note">
              {teams.length > 0
                ? `Everyone on ${teams.join(" and ")} can open this session and answer its approvals.`
                : "You can open this session. It is billed to your team."}
            </p>
          </div>

          <label>
            How it should start
            <select value={agent} onChange={(e) => setAgent(e.target.value)}>
              <option value="">However this profile normally starts</option>
              {chosen.agents.map((a) => (
                <option key={a} value={a}>
                  {a}
                </option>
              ))}
            </select>
          </label>

          <label>
            What to call it <small>optional</small>
            <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Rewrite the placement loop" />
          </label>

          <label>
            What you want done <small>optional — you can also say it afterwards</small>
            <textarea value={prompt} onChange={(e) => setPrompt(e.target.value)} rows={3} />
          </label>
        </>
      )}

      {error && (
        <div className="banner error">
          <p>{error}</p>
        </div>
      )}

      <div className="actions">
        <button onClick={onClose}>Cancel</button>
        <button className="primary" onClick={() => void start()} disabled={busy || !chosen || free <= 0}>
          {busy ? "Starting…" : "Start"}
        </button>
      </div>
      {chosen && free <= 0 && <p className="note">Every machine on {chosen.name} is busy. Try another, or wait for one to finish.</p>}
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
  onCreated: (id: string) => void;
}): JSX.Element {
  const [workspace, setWorkspace] = useState("");
  const [recent, setRecent] = useState<Array<{ path: string; sessions: number }>>([]);
  const [worktree, setWorktree] = useState<"auto" | "never" | "always">("auto");
  const [watch, setWatch] = useState(false);
  const [privately, setPrivately] = useState(false);
  const [prompt, setPrompt] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
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

  const start = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const created = await daemon.createSession({
        workspace: workspace.trim(),
        worktree,
        ...(prompt.trim() ? { prompt: prompt.trim() } : {}),
        config: { watch, ...(privately ? { private: true } : {}) },
      });
      onCreated(created.session_id);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <label>
        Which directory
        <div className="inline-form" style={{ marginBottom: 0 }}>
          <input
            value={workspace}
            onChange={(e) => setWorkspace(e.target.value)}
            placeholder={picker ? "Choose one, or type a path" : "/home/you/project"}
            spellCheck={false}
            style={{ flex: 1 }}
          />
          {picker && (
            <button type="button" onClick={() => void picker().then((p) => p && setWorkspace(p))}>
              Choose…
            </button>
          )}
        </div>
      </label>

      {recent.length > 0 && (
        <div className="stack" style={{ gap: "var(--space-2)" }}>
          <h3>Recently</h3>
          <div className="chips">
            {recent.map((w) => (
              <button key={w.path} className="chip as-button" onClick={() => setWorkspace(w.path)}>
                {w.path}
              </button>
            ))}
          </div>
        </div>
      )}

      <label>
        If something is already running there
        <select value={worktree} onChange={(e) => setWorktree(e.target.value as typeof worktree)}>
          <option value="auto">Give this one its own branch and checkout</option>
          <option value="never">Use the same directory anyway</option>
          <option value="always">Always give it its own, even when nothing else is running</option>
        </select>
      </label>

      <label className="inline">
        <input type="checkbox" checked={watch} onChange={(e) => setWatch(e.target.checked)} />
        Act on notes I leave in the files
      </label>
      <p className="note">
        Watch mode reads comments you save in the workspace and treats them as input. One session per workspace may do it; a second is
        refused rather than fighting the first.
      </p>

      {/* Only where the daemon says it can seal one. A checkbox for something the
          server has never heard of reads as a setting that did not take. */}
      {daemon.supportsPrivateSessions && (
        <>
          <label className="inline">
            <input type="checkbox" checked={privately} onChange={(e) => setPrivately(e.target.checked)} disabled={!linked} />
            Keep it private, and let it follow me to other devices
          </label>
          <p className="note">
            {linked
              ? "A private session runs here and is sealed under your own key before anything is stored. The platform lists it and can never read it."
              : "This needs your account linked to this computer first — the control is on “This computer”."}
          </p>
        </>
      )}

      <label>
        What you want done <small>optional — you can also say it afterwards</small>
        <textarea value={prompt} onChange={(e) => setPrompt(e.target.value)} rows={3} />
      </label>

      {error && (
        <div className="banner error">
          <p>{error}</p>
        </div>
      )}

      <div className="actions">
        <button onClick={onClose}>Cancel</button>
        <button className="primary" onClick={() => void start()} disabled={busy || !workspace.trim()}>
          {busy ? "Starting…" : "Start"}
        </button>
      </div>
    </>
  );
}
