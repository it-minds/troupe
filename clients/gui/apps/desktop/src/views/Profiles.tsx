// What a profile gives a session, read before starting one: the list of the profiles a
// person may use, and a page per profile.
//
// The plane composes the page's answer (`profile.get`) from what it enforces: the agents
// the profile's rule and the person's team's grant leave, the tool rules beside the
// organisation's, each MCP server with whose credential it is called, the model, the
// hosts its pods may reach, its limits and the teams it runs under. This screen draws it
// and works none of it out, so what it says is what a session gets. A plane is the only
// thing that knows, so the screen is offered only while signed in to one.
//
// Six plain sections in reading order, tables where there are columns to compare; a table
// scrolls inside itself on a narrow window rather than the page sideways.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { TroupeRpcError, accessWords, askWords, budgetWords, capacityWords, keyWords, missingWords, profileSummary, ruleAccessWords, whoseWords } from "@troupe/client";
import type { AuthSession, ProfileView } from "@troupe/client";
import { useProfiles } from "../hooks";
import { Loading, Table } from "./bits";

/** A profile's answer, or why there is none: one the person may not use is `not_found`. */
type Read = { view: ProfileView } | { missing: true } | { error: string } | null;

function useProfileView(auth: AuthSession, name: string): Read {
  const [read, setRead] = useState<Read>(null);
  useEffect(() => {
    let live = true;
    setRead(null);
    auth
      .rpc<ProfileView>("profile.get", { name })
      .then((view) => live && setRead({ view }))
      .catch((e: unknown) => {
        if (!live) return;
        if (e instanceof TroupeRpcError && e.code === -32005) setRead({ missing: true });
        else setRead({ error: e instanceof Error ? e.message : String(e) });
      });
    return () => {
      live = false;
    };
  }, [auth, name]);
  return read;
}

/** The profiles a person may use, a line each saying what it gives and how much room it has. */
export function Profiles({ auth, onOpen }: { auth: AuthSession; onOpen: (name: string) => void }): JSX.Element {
  const { profiles, error } = useProfiles(auth);
  return (
    <>
      <header className="screen-head">
        <span className="count">{profiles.length === 0 && !error ? "Loading" : `${profiles.length} you may use`}</span>
        <h1>Profiles</h1>
        <p>What a session on each gets: its agents, its tools and servers, its model, what it can reach and its limits.</p>
      </header>
      {error && (
        <div className="banner error">
          <p>Could not read the profiles you may use: {error}</p>
        </div>
      )}
      <div className="listing">
        <ul className="rows profiles">
          {profiles.map((p) => (
            <li key={p.name}>
              <button className="row" onClick={() => onOpen(p.name)}>
                <span className="subject">
                  <span className="title mono">{p.name}</span>
                  <Summary auth={auth} name={p.name} />
                </span>
                <span className="when">{capacityWords(p)}</span>
              </button>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}

function Summary({ auth, name }: { auth: AuthSession; name: string }): JSX.Element {
  const read = useProfileView(auth, name);
  const line = !read ? "…" : "view" in read ? profileSummary(read.view) : "missing" in read ? "not yours to use" : "could not be read";
  return <span className="micro muted">{line}</span>;
}

/** One profile, in six sections: agents, tools, model, reach, limits and who. */
export function ProfilePage({ auth, name, onBack }: { auth: AuthSession; name: string; onBack: () => void }): JSX.Element {
  const read = useProfileView(auth, name);
  return (
    <>
      <header className="screen-head">
        <span className="count">
          <button className="link" onClick={onBack}>
            All profiles
          </button>
        </span>
        <h1 className="mono">{name}</h1>
        {read && "view" in read && <p>{profileSummary(read.view)}</p>}
      </header>
      <div className="listing profile-view">
        {!read ? (
          <Loading what="Reading what this profile gives a session…" />
        ) : "missing" in read ? (
          <p className="note">There is no profile called {name} that you may use: none of your teams is granted it.</p>
        ) : "error" in read ? (
          <div className="banner error">
            <p>Could not read what {name} gives a session: {read.error}</p>
          </div>
        ) : (
          <ProfileSections view={read.view} />
        )}
      </div>
    </>
  );
}

function ProfileSections({ view }: { view: ProfileView }): JSX.Element {
  const { model, limits } = view;
  const offered = view.tools.mcp.filter((s) => s.offered);
  const withheld = view.tools.mcp.filter((s) => !s.offered);
  return (
    <>
      <section className="group">
        <h3>Agents</h3>
        {view.agents.length === 0 ? (
          <p className="note">No agent: a session cannot start on it.</p>
        ) : (
          <Table head={["Agent", "Mode", "What it does", "From"]}>
            {view.agents.map((a) => (
              <tr key={a.name}>
                <td className="mono">{a.name}</td>
                <td>{a.mode}</td>
                <td>{a.description ?? ""}</td>
                <td>{whoseWords(a.from)}</td>
              </tr>
            ))}
          </Table>
        )}
        {view.agents_not_here.length > 0 && (
          <>
            <p className="note">Not here</p>
            <Table head={["Agent", "Mode", "Why not"]}>
              {view.agents_not_here.map((a) => (
                <tr key={a.name} className="muted">
                  <td className="mono">{a.name}</td>
                  <td>{a.mode}</td>
                  <td>{missingWords(a.why)}</td>
                </tr>
              ))}
            </Table>
          </>
        )}
        {view.skills.length > 0 && <p className="note">Skills: {view.skills.join(", ")}</p>}
      </section>

      <section className="group">
        <h3>Tools</h3>
        {view.tools.rules.length === 0 ? (
          <p className="note">No rule of the profile's or the organisation's: every tool asks as Troupe's own defaults say.</p>
        ) : (
          <Table head={["Tool", "Pattern", "Does", "From"]}>
            {view.tools.rules.map((r, i) => (
              <tr key={`${r.from}-${r.tool}-${r.pattern ?? ""}-${i}`}>
                <td className="mono">{r.tool}</td>
                <td className="mono">{r.pattern ?? "any"}</td>
                <td>{ruleAccessWords(r.access)}</td>
                <td>{whoseWords(r.from)}</td>
              </tr>
            ))}
          </Table>
        )}
        {view.tools.mcp.length === 0 ? (
          <p className="note">No MCP server.</p>
        ) : (
          <Table head={["Server", "Host", "Called", "Each call", "Its tools"]}>
            {[...offered, ...withheld].map((s) => (
              <tr key={s.name} className={s.offered ? undefined : "muted"}>
                <td>
                  <span className="mono">{s.name}</span>
                  {!s.offered && <div className="micro">not offered: {missingWords(s.why)}</div>}
                </td>
                <td className="mono">{s.host ?? "—"}</td>
                <td>{accessWords(s.access)}</td>
                <td>{askWords(s.permission)}</td>
                <td className="wrap">{s.tools === "all" ? "every tool it has" : s.tools.join(", ")}</td>
              </tr>
            ))}
          </Table>
        )}
      </section>

      <section className="group">
        <h3>Model</h3>
        <dl className="facts wide">
          <dt>Model</dt>
          <dd className="mono">{model.model ?? "not set by the profile"}</dd>
          <dt>Small model</dt>
          <dd className="mono">{model.small_model ?? "not set by the profile"}</dd>
          <dt>Gateway</dt>
          <dd className="mono">{model.host ?? "not set by the profile"}</dd>
          <dt>Key</dt>
          <dd>{keyWords(model.key)}</dd>
        </dl>
      </section>

      <section className="group">
        <h3>Reach</h3>
        {view.reach.length === 0 ? (
          <p className="note">No host outside its own pod.</p>
        ) : (
          <ul className="chips">
            {view.reach.map((h) => (
              <li key={h} className="chip mono">
                {h}
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="group">
        <h3>Limits</h3>
        <dl className="facts wide">
          <dt>Per pod</dt>
          <dd>{limits.sessions_per_pod === null ? "not said" : `${limits.sessions_per_pod} sessions`}</dd>
          <dt>At most</dt>
          <dd>{limits.max_sessions === null ? "no cap" : `${limits.max_sessions} sessions`}</dd>
          <dt>Now</dt>
          <dd>{capacityWords(limits)}</dd>
          <dt>Profile's budget</dt>
          <dd>{budgetWords(limits.budgets.profile)}</dd>
          <dt>Team's budget</dt>
          <dd>{budgetWords(limits.budgets.team)}</dd>
          <dt>Your budget</dt>
          <dd>{budgetWords(limits.budgets.you)}</dd>
        </dl>
      </section>

      <section className="group">
        <h3>Who</h3>
        <p className="note">
          {view.team === null
            ? "No team of yours: an administrator's view."
            : `A session you start runs under ${view.team}${view.teams.length > 1 ? `; ${view.teams.filter((t) => t !== view.team).join(", ")} may use it too` : ""}.`}
        </p>
      </section>
    </>
  );
}
