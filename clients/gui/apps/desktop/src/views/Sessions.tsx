// Home. Every session the person can see, whatever it is running on.
//
// Anything waiting for a decision is lifted into its own group at the top, and sorting
// never lets a working session outrank a waiting one. That, plus the amber row and its
// left marker, is what makes "something needs you" readable at a glance in a list of
// thirty on a phone.
//
// Stage 1 has one source, so every row says "Team". The column is here from the start
// because stage 2 and 3 add rows beside these, and a column that appears later is a
// surprise.

import { useMemo, useState } from "react";
import type { JSX } from "react";
import { filterRows } from "@troupe/client";
import type { AuthSession, FleetRow, ProfileOffering } from "@troupe/client";
import { useProfiles } from "../hooks";
import { Cost, RowStatus, statusOf, When, Where } from "./bits";

export function Sessions({
  auth,
  rows,
  loading,
  error,
  onOpen,
  onCreated,
}: {
  auth: AuthSession;
  rows: FleetRow[];
  loading: boolean;
  error: string | null;
  onOpen: (id: string) => void;
  onCreated: (id: string) => void;
}): JSX.Element {
  const [query, setQuery] = useState("");
  const [state, setState] = useState("");
  const [profile, setProfile] = useState("");
  const [starting, setStarting] = useState(false);

  const shown = useMemo(
    () => filterRows(rows, { ...(state ? { state } : {}), ...(profile ? { profile } : {}), query }),
    [rows, state, profile, query],
  );
  const waiting = shown.filter((r) => statusOf(r) === "waiting");
  const rest = shown.filter((r) => statusOf(r) !== "waiting");
  const profiles = [...new Set(rows.map((r) => r.profile).filter(Boolean))] as string[];
  const states = [...new Set(rows.map((r) => r.state))];

  return (
    <>
      <header className="toolbar">
        <input
          className="search"
          type="search"
          placeholder="Search sessions"
          aria-label="Search sessions"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <select value={state} onChange={(e) => setState(e.target.value)} aria-label="State">
          <option value="">Any state</option>
          {states.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
        <select value={profile} onChange={(e) => setProfile(e.target.value)} aria-label="Profile">
          <option value="">Any profile</option>
          {profiles.map((p) => (
            <option key={p} value={p}>
              {p}
            </option>
          ))}
        </select>
        <span className="spacer" />
        <span className="count">{loading && rows.length === 0 ? "loading" : `${shown.length} of ${rows.length}`}</span>
        <button className="primary" onClick={() => setStarting(true)}>
          Start a session
        </button>
      </header>

      {error && (
        <div className="banner error">
          <p>The platform did not answer, so this list may be out of date. Sessions already open keep running.</p>
          <span className="micro">{error}</span>
        </div>
      )}

      <div className="listing">
        {rows.length === 0 && !loading ? (
          <div className="empty">
            <h2>No sessions yet</h2>
            <p>
              A session is one piece of work handed to the troupe: you describe it, it works on it, and it asks you before doing anything
              that changes something.
            </p>
            <button className="primary" onClick={() => setStarting(true)}>
              Start a session
            </button>
          </div>
        ) : shown.length === 0 ? (
          <div className="empty">
            <h2>Nothing matches</h2>
            <p>No session matches those filters. Clear them to see all {rows.length}.</p>
          </div>
        ) : (
          <>
            {waiting.length > 0 && (
              <section className="group waiting">
                <h3>Waiting for you</h3>
                <Rows rows={waiting} onOpen={onOpen} />
              </section>
            )}
            {rest.length > 0 && (
              <section className="group">
                {waiting.length > 0 && <h3>Everything else</h3>}
                <Rows rows={rest} onOpen={onOpen} />
              </section>
            )}
          </>
        )}
      </div>

      {starting && (
        <StartSession
          auth={auth}
          onClose={() => setStarting(false)}
          onCreated={(id) => {
            setStarting(false);
            onCreated(id);
          }}
        />
      )}
    </>
  );
}

function Rows({ rows, onOpen }: { rows: FleetRow[]; onOpen: (id: string) => void }): JSX.Element {
  return (
    <ul className="rows">
      {rows.map((r) => {
        const status = statusOf(r);
        return (
          <li key={r.id}>
            <button className={`row is-${status}`} onClick={() => onOpen(r.id)}>
              <span className="subject">{r.title ?? r.id}</span>
              <span className="meta">
                <RowStatus row={r} />
                <Where kind={r.kind} />
                <span className="when">{r.profile}</span>
                <Cost micros={r.costMicros} />
                <When iso={r.lastActiveAt} />
              </span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

/**
 * Starting a session is three decisions, and each is phrased as a consequence rather
 * than a setting: who it belongs to, what it can reach, and what it may start as.
 *
 * `profiles.list` answers the middle one *before* anything is created — the agents it
 * may start as, the skills and MCP servers the current bundle gives it, and whether
 * there is anywhere to put it right now. Choosing blind and finding out afterwards is
 * the thing this avoids.
 */
function StartSession({ auth, onClose, onCreated }: { auth: AuthSession; onClose: () => void; onCreated: (id: string) => void }): JSX.Element {
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
    <div className="scrim" onClick={onClose}>
      <div className="dialog" role="dialog" aria-modal="true" aria-label="Start a session" onClick={(e) => e.stopPropagation()}>
        <h1>Start a session</h1>

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
            {profiles.length === 0 && !profilesError && <p className="note" style={{ padding: "var(--space-3)" }}>Loading what you can use…</p>}
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
      </div>
    </div>
  );
}
