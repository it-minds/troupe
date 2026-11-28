// What a member sees of a profile, on the administrator's page of it: the plane's
// `profile.get`, the same answer a member's desktop app draws, read-only and kept to its
// tables, the limits a session there is held to among them, read from the answer's own
// fields. Asked as the administrator it is answered for no team, so it is the profile as
// it stands before any team's grant narrows it, which the rows that a grant leaves out
// say beside the profile's own.

import type { JSX } from "react";
import { FUNCTIONS_HEADING, accessWords, askWords, budgetWords, capacityWords, countWords, durationWords, keyWords, missingWords, ruleAccessWords, teamBudgetWords, whoseWords } from "@troupe/client";
import type { ProfileView, ProfileViewAgent, ProfileViewGitHub, ProfileViewHarnessTool } from "@troupe/client";
import { memberView, useConsole, useLoad } from "../console";
import { Loaded, Region, Status } from "./bits";

// Troupe's output cap of one model call where a profile's `llm.maxTokens` sets none. The
// answer says the cap in effect, not whose it is, so this number is how the table tells the
// two apart: a profile that sets exactly 8192 reads as Troupe's default, which is the same
// cap a session is held to.
const TROUPE_MAX_TOKENS = 8192;

const PROFILE = "the profile";
const TROUPE = "Troupe's default";

/** One row of the limits table: what is held, how much, and whose number it is. */
type LimitRow = { what: string; value: string; from: string };

/**
 * The limits the answer states, a row each; none from a plane before them. The session's
 * allowance is Troupe's own every time, since a pod reads no organisation layer and a
 * profile sets none of it; how long a session rests before it sleeps is its team's, and
 * asked as the administrator, for no team, the platform's. Only a plane from before that
 * answers `null` for no team, and the row says so rather than a number it was not given.
 */
function limitRows(limits: ProfileView["limits"], team: string | null): LimitRow[] {
  const rows: LimitRow[] = [];
  if (limits.max_tokens !== undefined) {
    rows.push({
      what: "Output of one model call",
      value: `at most ${countWords(limits.max_tokens, "token")}`,
      from: limits.max_tokens === TROUPE_MAX_TOKENS ? TROUPE : PROFILE,
    });
  }
  const s = limits.session;
  if (s) {
    rows.push(
      {
        what: "Working time before an agent asks to go on",
        value: `${durationWords(s.wall_clock_seconds * 1000, "long")}; waiting on a person does not count`,
        from: TROUPE,
      },
      {
        what: "Model calls before an agent asks to go on",
        value: countWords(s.max_turns, "model call"),
        from: TROUPE,
      },
      {
        what: "Input tokens before an agent asks to go on",
        value: countWords(s.max_input_tokens, "token"),
        from: TROUPE,
      },
      {
        what: "Output tokens before an agent asks to go on",
        value: countWords(s.max_output_tokens, "token"),
        from: TROUPE,
      },
      {
        what: "Delegation",
        value: `at most ${countWords(s.max_depth, "level")} deep`,
        from: TROUPE,
      },
    );
  }
  if (limits.idle_seconds !== undefined) {
    rows.push({
      what: "Rest before a session sleeps",
      value: limits.idle_seconds === null ? "each team's own; asked for no team, so not said" : durationWords(limits.idle_seconds * 1000, "long"),
      from: team ? "the team" : "the platform",
    });
  }
  return rows;
}

/** An agent's own numbers, where its definition sets them: each only lowers the session's. */
function ownLimitWords(a: ProfileViewAgent): string {
  const said: string[] = [];
  if (a.max_turns !== undefined) said.push(`at most ${countWords(a.max_turns, "model call")}`);
  if (a.max_tokens !== undefined) said.push(`at most ${countWords(a.max_tokens, "token")} a call`);
  return said.join(" · ");
}

const capWords = (n: number | null, one: string, many?: string): string => (n === null ? "no cap" : `at most ${countWords(n, one, many)}`);

/** Whether any agent sets a number of its own: the agents' column of them is there only then. */
const ownLimits = (view: ProfileView): boolean => view.agents.some((a) => a.max_turns !== undefined || a.max_tokens !== undefined);

function LimitsTable({ limits, team }: { limits: ProfileView["limits"]; team: string | null }): JSX.Element | null {
  const rows = limitRows(limits, team);
  if (rows.length === 0) return null;
  return (
    <div className="scroll">
      <table>
        <caption>Limits</caption>
        <thead>
          <tr>
            <th>Limit</th>
            <th>Value</th>
            <th>From</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.what}>
              <td>{r.what}</td>
              <td>{r.value}</td>
              <td>{r.from}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function GitHubTable({ github }: { github: ProfileViewGitHub }): JSX.Element {
  const permissions = Object.entries(github.permissions);
  return (
    <div className="scroll">
      <table>
        <caption>GitHub</caption>
        <tbody>
          <tr>
            <th scope="row">Permissions</th>
            <td className="mono">{permissions.length ? permissions.map(([k, v]) => `${k}: ${v}`).join(", ") : "none"}</td>
          </tr>
          <tr>
            <th scope="row">Pushes a run may make</th>
            <td>{capWords(github.max_pushes, "push", "pushes")}</td>
          </tr>
          <tr>
            <th scope="row">Runs on a repository at once</th>
            <td>{capWords(github.max_runs, "run")}</td>
          </tr>
          <tr>
            <th scope="row">Runs on one issue before a person is asked</th>
            <td>{countWords(github.max_attempts, "run")}</td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

function HarnessToolsTable({ tools }: { tools: ProfileViewHarnessTool[] }): JSX.Element {
  return (
    <div className="scroll">
      <table>
        <caption>The harness's tools</caption>
        <thead>
          <tr>
            <th>Tool</th>
            <th>Here</th>
          </tr>
        </thead>
        <tbody>
          {tools.map((t) => (
            <tr key={t.name} className={t.refused ? "muted" : undefined}>
              <td className="mono">{t.name}</td>
              <td>
                {t.refused ? (
                  <Status kind="denied" glyph="✕">
                    refused by a rule
                  </Status>
                ) : (
                  <Status kind="running" glyph="✓">
                    yes
                  </Status>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function SwitchesTable({ view }: { view: ProfileView }): JSX.Element | null {
  if (view.personal_tools === undefined && view.memory_proposals === undefined) return null;
  return (
    <div className="scroll">
      <table>
        <caption>Switches</caption>
        <tbody>
          {view.personal_tools !== undefined && (
            <tr>
              <th scope="row">A person's own tools</th>
              <td>
                {view.personal_tools === "forbid"
                  ? "off: a person may not offer a session here their own signed-in tools"
                  : view.personal_tools === "allow"
                    ? "on: a person may offer a session here their own signed-in tools"
                    : view.personal_tools}
              </td>
            </tr>
          )}
          {view.memory_proposals !== undefined && (
            <tr>
              <th scope="row">Memory proposals</th>
              <td>{view.memory_proposals ? "on: its agents may propose to a team's or the organisation's memory" : "off: its agents may not propose to a team's or the organisation's memory"}</td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

export function MemberView({ name }: { name: string }): JSX.Element {
  const { auth } = useConsole();
  const [load, reload] = useLoad(() => memberView(auth, name), [auth, name]);
  return (
    <>
      <Region>What a member sees</Region>
      <Loaded load={load} what={`what a member sees of ${name}`} retry={reload}>
        {(view) => (
          <div className="member-view">
            <p className="note">What a session on {name} is given, as the plane answers a member's app: read here, changed in the profile and its bundle.</p>
            <div className="scroll">
              <table>
                <caption>Agents</caption>
                <thead>
                  <tr>
                    <th>Agent</th>
                    <th>Mode</th>
                    <th>From</th>
                    <th>Here</th>
                    {ownLimits(view) && <th>Its own limits</th>}
                  </tr>
                </thead>
                <tbody>
                  {view.agents.map((a) => (
                    <tr key={a.name}>
                      <td>
                        <span className="mono">{a.name}</span>
                        {a.description && <span className="hint"> {a.description}</span>}
                      </td>
                      <td>{a.mode}</td>
                      <td>{whoseWords(a.from)}</td>
                      <td>yes</td>
                      {ownLimits(view) && <td>{ownLimitWords(a) || "the session's"}</td>}
                    </tr>
                  ))}
                  {view.agents_not_here.map((a) => (
                    <tr key={a.name} className="muted">
                      <td className="mono">{a.name}</td>
                      <td>{a.mode}</td>
                      <td>{whoseWords(a.from)}</td>
                      <td>not here: {missingWords(a.why)}</td>
                      {ownLimits(view) && <td />}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {(view.functions ?? []).length > 0 && (
              <div className="scroll">
                <table>
                  <caption>{FUNCTIONS_HEADING}</caption>
                  <thead>
                    <tr>
                      <th>Agent</th>
                      <th>From</th>
                    </tr>
                  </thead>
                  <tbody>
                    {(view.functions ?? []).map((a) => (
                      <tr key={a.name}>
                        <td>
                          <span className="mono">{a.name}</span>
                          {a.description && <span className="hint"> {a.description}</span>}
                        </td>
                        <td>{whoseWords(a.from)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <div className="scroll">
              <table>
                <caption>Tool rules</caption>
                <thead>
                  <tr>
                    <th>Tool</th>
                    <th>Pattern</th>
                    <th>Does</th>
                    <th>From</th>
                  </tr>
                </thead>
                <tbody>
                  {view.tools.rules.map((r, i) => (
                    <tr key={`${r.from}-${r.tool}-${r.pattern ?? ""}-${i}`}>
                      <td className="mono">{r.tool}</td>
                      <td className="mono">{r.pattern ?? "any"}</td>
                      <td>{ruleAccessWords(r.access)}</td>
                      <td>{whoseWords(r.from)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="scroll">
              <table>
                <caption>MCP servers</caption>
                <thead>
                  <tr>
                    <th>Server</th>
                    <th>Host</th>
                    <th>Called</th>
                    <th>Each call</th>
                    <th>Its tools</th>
                  </tr>
                </thead>
                <tbody>
                  {view.tools.mcp.map((s) => (
                    <tr key={s.name} className={s.offered ? undefined : "muted"}>
                      <td>
                        <span className="mono">{s.name}</span>
                        {!s.offered && <span className="hint"> not offered: {missingWords(s.why)}</span>}
                      </td>
                      <td className="mono">{s.host ?? "—"}</td>
                      <td>{accessWords(s.access)}</td>
                      <td>{askWords(s.permission)}</td>
                      <td>{s.tools === "all" ? "every tool it has" : s.tools.join(", ")}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {view.harness_tools && <HarnessToolsTable tools={view.harness_tools} />}
            <div className="scroll">
              <table>
                <caption>Model, reach, limits and who</caption>
                <tbody>
                  <tr>
                    <th scope="row">Model</th>
                    <td className="mono">
                      {view.model.model ?? "not set"} · small {view.model.small_model ?? "not set"} · {view.model.host ?? "no gateway"}
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Key</th>
                    <td>{keyWords(view.model.key)}</td>
                  </tr>
                  <tr>
                    <th scope="row">Reach</th>
                    <td className="mono">{view.reach.length ? view.reach.join(", ") : "no host outside its pod"}</td>
                  </tr>
                  <tr>
                    <th scope="row">Limits</th>
                    <td>
                      {view.limits.sessions_per_pod ?? "?"} per pod · {view.limits.max_sessions === null ? "no cap" : `at most ${view.limits.max_sessions}`} · {capacityWords(view.limits)}
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Budgets</th>
                    <td>
                      profile {budgetWords(view.limits.budgets.profile)} · team {teamBudgetWords(view.limits.budgets)} · person {budgetWords(view.limits.budgets.you)}
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Who</th>
                    <td>{view.teams.length ? `your teams on it: ${view.teams.join(", ")}${view.team ? `; a session runs under ${view.team}` : ""}` : "none of your teams"}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <LimitsTable limits={view.limits} team={view.team} />
            {view.github && <GitHubTable github={view.github} />}
            <SwitchesTable view={view} />
          </div>
        )}
      </Loaded>
    </>
  );
}
