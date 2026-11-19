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
// The page answers "can this profile do my job?" first: a head with the sentence the
// bundle's author wrote for it, or else the primary agent's, a rail with the room, the model, the budgets, whose credentials and what asks
// first, the limits a session is held to in sentences, and Start; then what it can do, what it can't, how it behaves (guidance, not
// limits), and the configuration's own tables folded away under the hood. On a narrow
// window the rail comes first; a table scrolls inside itself rather than the page sideways.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import {
  FUNCTIONS_HEADING,
  TroupeRpcError,
  accessWords,
  actsAsWords,
  andList,
  askWords,
  budgetWords,
  capacityWords,
  errorText,
  countWords,
  durationWords,
  keyWords,
  limitSentences,
  missingWords,
  profileSentence,
  profileSummary,
  roomWords,
  ruleAccessWords,
  ruleText,
  teamBudgetWords,
  toolLines,
  toolsAreWhole,
  whoseWords,
} from "@troupe/client";
import type { AuthSession, ProfileView, ProfileViewAgent, ProfileViewServer, ProfileViewSkill } from "@troupe/client";
import { useProfiles } from "../hooks";
import { Loading, Table } from "./bits";
import { ProseFrame } from "./Frames";

/** A profile's answer, or why there is none: one the person may not use is `not_found`. */
type Read = { view: ProfileView } | { missing: true } | { error: string } | null;

function useProfileView(auth: AuthSession, name: string): Read {
  const [read, setRead] = useState<Read>(null);
  useEffect(() => {
    let live = true;
    setRead(null);
    auth
      .withToken((plane, token) => plane.profile(token, name))
      .then((view) => live && setRead({ view }))
      .catch((e: unknown) => {
        if (!live) return;
        if (e instanceof TroupeRpcError && e.code === -32005) setRead({ missing: true });
        else setRead({ error: errorText(e) });
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

/** The agents a session may run as or call: primaries first, then the rest by mode. */
function byMode(agents: readonly ProfileViewAgent[]): ProfileViewAgent[] {
  const rank = (a: ProfileViewAgent): number => (a.mode === "primary" ? 0 : 1);
  return [...agents].sort((a, b) => rank(a) - rank(b) || a.mode.localeCompare(b.mode));
}

/** One profile: a head, the rail, what it can and can't do, how it behaves, and under the hood. */
export function ProfilePage({
  auth,
  name,
  onBack,
  onStart,
}: {
  auth: AuthSession;
  name: string;
  onBack: () => void;
  /** Open the new-session screen with this profile chosen. */
  onStart?: ((name: string) => void) | undefined;
}): JSX.Element {
  const read = useProfileView(auth, name);
  const sentence = read && "view" in read ? profileSentence(read.view) : null;
  return (
    <>
      <header className="screen-head">
        <span className="count">
          <button className="link" onClick={onBack}>
            All profiles
          </button>
        </span>
        <h1 className="mono">{name}</h1>
        {sentence && <p className="profile-sentence">{sentence}</p>}
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
          <div className="profile-layout">
            <Rail view={read.view} onStart={onStart} />
            <div className="profile-main">
              <CanDo view={read.view} />
              <CannotDo view={read.view} />
              <Behaves view={read.view} />
              <UnderTheHood view={read.view} />
            </div>
          </div>
        )}
      </div>
    </>
  );
}

/** Who may use it: the person's teams on it, and what Start does where there are several. */
function whoWords(view: ProfileView): string {
  if (view.teams.length === 0) return "No team of yours: an administrator's view.";
  if (view.teams.length === 1) return view.teams[0]!;
  return `${andList(view.teams)}. A session is for one of them, said when you start it.`;
}

/** What a session asks before doing: a server whose calls ask, and every `ask` rule. */
function asksFirst(view: ProfileView): string[] {
  const servers = view.tools.mcp.filter((s) => s.offered && s.permission === "ask").map((s) => `${s.name}'s tools`);
  const rules = view.tools.rules.filter((r) => r.access === "ask").map(ruleText);
  return [...servers, ...rules];
}

function Rail({ view, onStart }: { view: ProfileView; onStart?: ((name: string) => void) | undefined }): JSX.Element {
  const asks = asksFirst(view);
  const limits = limitSentences(view);
  return (
    <aside className="profile-rail" aria-label="At a glance">
      <dl className="facts wide">
        <dt>Room</dt>
        <dd>{roomWords(view.limits)}</dd>
        <dt>Model</dt>
        <dd className={view.model.model ? "mono" : undefined}>{view.model.model ?? "the plane's default model"}</dd>
        <dt>Profile's budget</dt>
        <dd>{budgetWords(view.limits.budgets.profile)}</dd>
        <dt>Team's budget</dt>
        <dd>{teamBudgetWords(view.limits.budgets)}</dd>
        <dt>Your budget</dt>
        <dd>{budgetWords(view.limits.budgets.you)}</dd>
        <dt>Acts as</dt>
        <dd>{actsAsWords(view.tools.mcp)}</dd>
        <dt>Asks first</dt>
        <dd>{asks.length === 0 ? "only what Troupe asks by default" : andList(asks)}</dd>
        <dt>Who can use it</dt>
        <dd>{whoWords(view)}</dd>
      </dl>
      {limits.length > 0 && (
        <div className="profile-limits">
          <h4>Limits</h4>
          <ul className="plain">
            {limits.map((line) => (
              <li key={line}>{line}</li>
            ))}
          </ul>
          <p className="note">An agent may set fewer.</p>
        </div>
      )}
      {view.agents.length === 0 ? (
        <p className="note">No agent: a session cannot start on it.</p>
      ) : (
        onStart && (
          <button type="button" className="primary" onClick={() => onStart(view.name)}>
            Start a session on {view.name}
          </button>
        )
      )}
    </aside>
  );
}

function CanDo({ view }: { view: ProfileView }): JSX.Element {
  const offered = view.tools.mcp.filter((s) => s.offered);
  return (
    <section className="group can-do">
      <h3>What it can do</h3>
      <ul className="profile-cards">
        {offered.map((s) => (
          <li key={s.name} className="profile-card">
            <h4 className="mono">{s.name}</h4>
            {s.about?.summary && <p className="profile-subtitle">{s.about.summary}</p>}
            <dl className="facts wide">
              <dt>Host</dt>
              <dd className="mono">{s.host ?? "not said"}</dd>
              <dt>Called</dt>
              <dd>{accessWords(s.access)}</dd>
              <dt>Each call</dt>
              <dd>{askWords(s.permission)}</dd>
              <dt>Its tools</dt>
              <ServerTools server={s} />
            </dl>
          </li>
        ))}
        <TroupeCard view={view} />
      </ul>
    </section>
  );
}

/**
 * A server's tools on its card: the names, as the allowlist gives them, until the bundle's
 * author writes a line for one, which then says what it does, its name in a small tail.
 */
function ServerTools({ server }: { server: ProfileViewServer }): JSX.Element {
  const tools = toolLines(server);
  if (!tools.some((t) => t.line !== null)) {
    return <dd className={server.tools === "all" ? undefined : "mono"}>{server.tools === "all" ? "every tool it has" : tools.map((t) => t.name).join(", ")}</dd>;
  }
  return (
    <dd>
      {server.tools === "all" && <p className="micro">Every tool it has, among them:</p>}
      <ul className="tool-lines">
        {tools.map((t) =>
          t.line === null ? (
            <li key={t.name} className="mono">
              {t.name}
            </li>
          ) : (
            <li key={t.name} title={t.name}>
              {t.line} <span className="tool-name">{t.name}</span>
            </li>
          ),
        )}
      </ul>
    </dd>
  );
}

/**
 * Troupe's own card: the harness's tools, each one a rule refuses whole struck through. A
 * plane before the list names only what the rules turn off, and says the others are on.
 */
function TroupeCard({ view }: { view: ProfileView }): JSX.Element {
  const tools = view.harness_tools;
  if (!tools) {
    const off = view.tools.rules.filter((r) => r.access === "deny" && r.pattern === null);
    return (
      <li className="profile-card troupe">
        <h4>Troupe</h4>
        {off.length > 0 && (
          <>
            <p className="micro">Turned off here</p>
            <ul className="struck">
              {off.map((r, i) => (
                <li key={`${r.tool}-${i}`}>
                  <s className="mono">{r.tool}</s>
                </li>
              ))}
            </ul>
          </>
        )}
        <p className="note">{off.length > 0 ? "The harness's other tools are on." : "The harness's own tools are on."}</p>
      </li>
    );
  }
  const refused = tools.some((t) => t.refused);
  return (
    <li className="profile-card troupe">
      <h4>Troupe</h4>
      <p className="micro">Its own tools</p>
      <ul className="tool-list">
        {tools.map((t) => (
          <li key={t.name}>
            {t.refused ? (
              <>
                <s className="mono">{t.name}</s>
                <span className="visually-hidden"> (turned off here)</span>
              </>
            ) : (
              <span className="mono">{t.name}</span>
            )}
          </li>
        ))}
      </ul>
      <p className="note">{refused ? "Struck through: turned off here." : "Every one is on."}</p>
    </li>
  );
}

function CannotDo({ view }: { view: ProfileView }): JSX.Element {
  const refused = view.tools.rules.filter((r) => r.access === "deny");
  const withheld = view.tools.mcp.filter((s) => !s.offered);
  return (
    <section className="group cannot-do">
      <h3>What it can't do</h3>
      <div className="banner">
        <p>{toolsAreWhole(view) ? "Nothing but the tools above: no tool of your own, no shell, no web fetch, and nothing outside the hosts listed." : "The tools below, and nothing outside the hosts listed."}</p>
      </div>
      {refused.length > 0 && (
        <div className="part">
          <h4>Refused</h4>
          <ul className="plain">
            {refused.map((r, i) => (
              <li key={`${ruleText(r)}-${i}`}>
                <span className="mono">{ruleText(r)}</span>
                <span className="muted"> · refused by {whoseWords(r.from)}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
      {withheld.length > 0 && (
        <div className="part">
          <h4>Withheld</h4>
          <ul className="plain">
            {withheld.map((s) => (
              <li key={s.name}>
                <span className="mono">{s.name}</span>
                <span className="muted"> · not offered: {missingWords(s.why)}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
      <div className="part">
        {view.reach.length === 0 ? (
          <p>Reaches no host outside the plane.</p>
        ) : (
          <>
            <h4>Reaches only these hosts</h4>
            <ul className="chips">
              {view.reach.map((h) => (
                <li key={h} className="chip mono">
                  {h}
                </li>
              ))}
            </ul>
          </>
        )}
      </div>
    </section>
  );
}

/**
 * The skills the grant leaves, each with what it does, and its SKILL.md to read in place,
 * rendered as a reply is. A plane before the details sends the names alone.
 */
function Skills({ view }: { view: ProfileView }): JSX.Element {
  const details: ProfileViewSkill[] = view.skill_details ?? view.skills.map((name) => ({ name, description: null, body: null, truncated: false }));
  return (
    <div className="part skills">
      <h4>Skills</h4>
      {details.length === 0 ? (
        <p className="note">No skill.</p>
      ) : (
        <ul className="skill-list">
          {details.map((s) => (
            <li key={s.name}>
              {s.body === null ? (
                <p>
                  <span className="mono">{s.name}</span>
                  {s.description && <span className="muted"> · {s.description}</span>}
                </p>
              ) : (
                <details className="skill">
                  <summary>
                    <span className="mono">{s.name}</span>
                    {s.description && <span className="muted"> · {s.description}</span>}
                  </summary>
                  <ProseFrame text={s.body} full />
                  {s.truncated && <p className="note">The rest of its SKILL.md is past what the page shows.</p>}
                </details>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function Behaves({ view }: { view: ProfileView }): JSX.Element {
  const functions = view.functions ?? [];
  return (
    <section className="group behaves">
      <h3>How it behaves</h3>
      <p className="copy">Guidance, not limits: an agent follows these; the sections above are what it is allowed.</p>
      <div className="part agents">
        <h4>Agents</h4>
        {view.agents.length === 0 ? (
          <p className="note">No agent: a session cannot start on it.</p>
        ) : (
          <ul className="plain">
            {byMode(view.agents).map((a) => (
              <li key={a.name}>
                <span className="mono">{a.name}</span>
                <span className="muted"> · {a.mode === "primary" ? "a session runs as it" : "an agent calls it"}</span>
                {a.description && <span> · {a.description}</span>}
              </li>
            ))}
          </ul>
        )}
      </div>
      {functions.length > 0 && (
        <div className="part functions">
          <h4>{FUNCTIONS_HEADING}</h4>
          <ul className="plain">
            {functions.map((a) => (
              <li key={a.name}>
                <span className="mono">{a.name}</span>
                {a.description && <span> · {a.description}</span>}
              </li>
            ))}
          </ul>
        </div>
      )}
      <Skills view={view} />
    </section>
  );
}

/** The configuration's own tables, for whoever is checking a bundle: folded away. */
function UnderTheHood({ view }: { view: ProfileView }): JSX.Element {
  const { model, limits } = view;
  const offered = view.tools.mcp.filter((s) => s.offered);
  const withheld = view.tools.mcp.filter((s) => !s.offered);
  return (
    <details className="group under-hood">
      <summary>Under the hood</summary>
      <div className="part">
        <h4>Agents</h4>
        {view.agents.length === 0 ? (
          <p className="note">No agent.</p>
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
      </div>

      <div className="part">
        <h4>Tools</h4>
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
      </div>

      <div className="part">
        <h4>Model</h4>
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
      </div>

      <div className="part">
        <h4>Limits</h4>
        <dl className="facts wide">
          <dt>Sharing a machine</dt>
          <dd>{limits.sessions_per_pod === null ? "not said" : `up to ${limits.sessions_per_pod} sessions`}</dd>
          <dt>At most</dt>
          <dd>{limits.max_sessions === null ? "no cap" : `${limits.max_sessions} sessions`}</dd>
          <dt>Now</dt>
          <dd>{capacityWords(limits)}</dd>
          {limits.max_tokens !== undefined && (
            <>
              <dt>Each model call</dt>
              <dd>{`at most ${countWords(limits.max_tokens, "token")} written`}</dd>
            </>
          )}
          {limits.session && (
            <>
              <dt>Each agent</dt>
              <dd>{`${countWords(limits.session.max_turns, "model call")}, ${durationWords(limits.session.wall_clock_seconds * 1000, "long")} of work, ${countWords(limits.session.max_input_tokens, "token")} read and ${countWords(limits.session.max_output_tokens, "token")} written, ${countWords(limits.session.max_depth, "level")} of delegation`}</dd>
            </>
          )}
          {view.personal_tools !== undefined && (
            <>
              <dt>Your own tools</dt>
              <dd>{view.personal_tools === "forbid" ? "not offered here" : "you may offer them"}</dd>
            </>
          )}
          {view.memory_proposals !== undefined && (
            <>
              <dt>Memory proposals</dt>
              <dd>{view.memory_proposals ? "an agent may propose to a team's or the organisation's memory" : "switched off"}</dd>
            </>
          )}
        </dl>
      </div>

      {view.github && (
        <div className="part">
          <h4>GitHub</h4>
          <dl className="facts wide">
            <dt>Permissions</dt>
            <dd className="mono">
              {Object.entries(view.github.permissions)
                .map(([what, level]) => `${what}: ${level}`)
                .join(", ") || "clone only"}
            </dd>
            <dt>Pushes a run</dt>
            <dd>{view.github.max_pushes === null ? "no cap" : `at most ${view.github.max_pushes}`}</dd>
            <dt>Runs at once</dt>
            <dd>{view.github.max_runs === null ? "no cap" : `at most ${view.github.max_runs} on a repository`}</dd>
            <dt>Tries on an issue</dt>
            <dd>{`${countWords(view.github.max_attempts, "run")} before a person is asked`}</dd>
          </dl>
        </div>
      )}

      <div className="part">
        <h4>Who</h4>
        <p className="note">
          {view.team === null
            ? whoWords(view)
            : `A session you start runs under ${view.team}${view.teams.length > 1 ? `; ${view.teams.filter((t) => t !== view.team).join(", ")} may use it too` : ""}.`}
        </p>
      </div>
    </details>
  );
}
