// What a member sees of a profile, on the administrator's page of it: the plane's
// `profile.get`, the same answer a member's desktop app draws, read-only and kept to its
// tables. Asked as the administrator it is answered for no team, so it is the profile as
// it stands before any team's grant narrows it, which the rows that a grant leaves out
// say beside the profile's own.

import type { JSX } from "react";
import { FUNCTIONS_HEADING, accessWords, askWords, budgetWords, capacityWords, keyWords, missingWords, ruleAccessWords, whoseWords } from "@troupe/client";
import { memberView, useConsole, useLoad } from "../console";
import { Loaded, Region } from "./bits";

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
                    </tr>
                  ))}
                  {view.agents_not_here.map((a) => (
                    <tr key={a.name} className="muted">
                      <td className="mono">{a.name}</td>
                      <td>{a.mode}</td>
                      <td>{whoseWords(a.from)}</td>
                      <td>not here: {missingWords(a.why)}</td>
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
                      profile {budgetWords(view.limits.budgets.profile)} · team {budgetWords(view.limits.budgets.team)} · person {budgetWords(view.limits.budgets.you)}
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">Who</th>
                    <td>{view.teams.length ? `your teams on it: ${view.teams.join(", ")}${view.team ? `; a session runs under ${view.team}` : ""}` : "none of your teams"}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        )}
      </Loaded>
    </>
  );
}
