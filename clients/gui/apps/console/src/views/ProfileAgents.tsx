// A profile's agents, profile first (troupe #594): what its sessions may run, from the
// bundle it has in effect, with where each came from, its model and what it may do, which of
// the profile's teams may run it, and the one button that changes it: the builder, on the
// channel the agent was published on. A built-in the profile offers because its bundle has
// none of that name is not changed in a channel; it is copied into the profile's own, which
// is where a profile's agent starts when there is none to start from.

import type { JSX } from "react";
import type { ProfileAgent } from "@troupe/client";
import { href } from "../route";
import { show, useConsole, useLoad } from "../console";
import { Empty, Loaded, Region } from "./bits";

function teamsWords(agent: ProfileAgent): string {
  if (agent.teams.length === 0) return "no team is granted the profile";
  const may = agent.teams.filter((t) => t.may).map((t) => t.team);
  const not = agent.teams.filter((t) => !t.may).map((t) => t.team);
  return [may.length ? may.join(", ") : null, not.length ? `not ${not.join(", ")}: a grant narrows it` : null].filter(Boolean).join("; ") || "—";
}

function mayWords(agent: ProfileAgent): string {
  const autos = Object.entries(agent.permissions)
    .filter(([, p]) => p === "auto")
    .map(([t]) => t);
  return autos.length ? `runs ${autos.join(", ")} without asking` : "asks before what its tools ask for";
}

export function ProfileAgentsList({ name }: { name: string }): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.profileAgents(name), [admin, name]);
  return (
    <>
      <Region>Its agents</Region>
      <Loaded load={load} what={`${name}'s agents`} retry={reload}>
        {(answer) => {
          const primaries = answer.agents.filter((a) => a.mode !== "subagent");
          const subagents = answer.agents.filter((a) => a.mode === "subagent");
          return answer.agents.length === 0 ? (
            <Empty title="No agent">Its bundle has none, and it offers none of Troupe's.</Empty>
          ) : (
            <>
              <p className="note">
                What a session on {name} may run, from the bundle it has in effect: a primary agent, and the subagents it delegates to. Each is changed in the builder, on the channel it
                was published on, and reaches {name}'s pods once that channel publishes.
              </p>
              <div className="scroll">
                <table className="profile-agents">
                  <thead>
                    <tr>
                      <th>Agent</th>
                      <th>Mode</th>
                      <th>Model</th>
                      <th>From</th>
                      <th>May</th>
                      <th>Who may run it</th>
                      <th />
                    </tr>
                  </thead>
                  <tbody>
                    {[...primaries, ...subagents].map((a) => (
                      <tr key={a.name}>
                        <td>
                          <span className="mono">{a.name}</span>
                          {a.description && <span className="hint"> {a.description}</span>}
                        </td>
                        <td>
                          {a.mode}
                          {a.mode === "primary" && a.delegate && a.delegate.length > 0 && <span className="hint"> · delegates to {a.delegate.join(", ")}</span>}
                          {typeof a.max_turns === "number" && <span className="hint"> · at most {a.max_turns} turns</span>}
                        </td>
                        <td className="mono">{show(a.model ?? "the session's")}</td>
                        <td>{a.builtin ? "Shipped with Troupe" : `${a.channel ?? "?"}${a.from && a.from !== name ? ` (${a.from}'s)` : ""}`}</td>
                        <td>{mayWords(a)}</td>
                        <td>{teamsWords(a)}</td>
                        <td>
                          {a.builtin ? (
                            answer.channel ? (
                              <a href={href({ page: "bundles", path: [answer.channel, "copy", a.name] })}>Copy {a.name} into {answer.channel}</a>
                            ) : (
                              <span className="muted">no channel to copy it into</span>
                            )
                          ) : a.channel ? (
                            <a href={href({ page: "bundles", path: [a.channel, "agent", a.name] })}>Open {a.name} in the builder</a>
                          ) : null}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {answer.channel && (
                <p className="note">
                  <a href={href({ page: "bundles", path: [answer.channel] })}>{answer.channel}</a> is the channel {name} follows: a new agent of its own is published there.
                </p>
              )}
            </>
          );
        }}
      </Loaded>
    </>
  );
}
