// Connections: who has connected a personal credential to which MCP server, and whose
// identity each session's calls go out as.
//
// A person-mode server is one each person connects their own credential to, in a slot of
// their own. The plane can say whether a slot is filled and nothing more: it holds no
// credential, and there is no method that reads one or removes one, which this screen says
// where somebody would look for it. A session has one identity: whoever owns it, whoever is
// driving.

import type { JSX } from "react";
import type { Connections as ConnectionsAnswer } from "@troupe/client";
import { useConsole, useLoad } from "../console";
import { href } from "../route";
import { Empty, Loaded, Region, Status } from "./bits";

export function Connections(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.connections(), [admin]);
  return (
    <div className="page">
      <p className="lead">Which MCP servers people connect their own credential to, who has, and which identity each session's calls go out as.</p>
      <Loaded load={load} what="the connections" retry={reload}>
        {(answer: ConnectionsAnswer) => (
          <>
            {answer.servers.length === 0 ? (
              <Empty title="No server here asks for a person's own credential">A person-mode server is one a bundle names with credential_mode person.</Empty>
            ) : (
              answer.servers.map((s) => {
                const connected = s.people.filter((p) => p.connected).length;
                return (
                  <section key={`${s.name}/${s.slot}`} aria-label={s.name}>
                    <Region>
                      {s.name} · slot {s.slot ?? "—"}
                    </Region>
                    <p className="note">
                      On {s.profiles.join(", ")}. {connected} of {s.people.length} {s.people.length === 1 ? "person has" : "people have"} connected.
                    </p>
                    {s.people.length === 0 ? (
                      <Empty title="Nobody may use it yet">No team granted these profiles has anybody in it.</Empty>
                    ) : (
                      <table>
                        <thead>
                          <tr>
                            <th>Person</th>
                            <th>Their credential</th>
                          </tr>
                        </thead>
                        <tbody>
                          {s.people.map((p) => (
                            <tr key={p.subject}>
                              <td>
                                {p.display_name ?? p.subject} <span className="mono muted">{p.subject}</span>
                              </td>
                              <td>
                                {p.connected ? (
                                  <Status kind="running" glyph="●">
                                    connected
                                  </Status>
                                ) : (
                                  <Status kind="muted" glyph="○">
                                    not connected
                                  </Status>
                                )}
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}
                  </section>
                );
              })
            )}
            <Region>Whose identity each session carries</Region>
            <p className="note">A session has one identity: every call to a person-mode server goes out as the session's owner, whoever is driving it.</p>
            {answer.sessions.length === 0 ? (
              <Empty title="No session carries one" />
            ) : (
              <div className="scroll">
                <table>
                  <thead>
                    <tr>
                      <th>Session</th>
                      <th>Team</th>
                      <th>Profile</th>
                      <th>Calls go out as</th>
                      <th>State</th>
                    </tr>
                  </thead>
                  <tbody>
                    {answer.sessions.map((x) => (
                      <tr key={x.id}>
                        <td className="mono">{x.id}</td>
                        <td>
                          <a href={href({ page: "teams", team: x.team, tab: "members" })}>{x.team}</a>
                        </td>
                        <td>{x.profile}</td>
                        <td className="mono">{x.owner}</td>
                        <td>{x.state}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <p className="note">
              Nobody here can read or remove a person's credential: the plane holds none, and there is no method for either. A person disconnects their own, from
              their own client.
            </p>
          </>
        )}
      </Loaded>
    </div>
  );
}
