// The teams: every one for a platform admin, their own for a team admin, which is what
// `admin.teams.list` answers each of them. A team is an identity-provider group the
// platform made a team of; its people are the provider's, its grants, budget and limits
// the plane's.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminTeam } from "@troupe/client";
import { currentConsole } from "../plane";
import { href } from "../route";
import { useConsole, useLoad } from "../console";
import { Empty, Loaded, Status, money } from "./bits";

export function Teams(): JSX.Element {
  const { admin, role, plane } = useConsole();
  const [load, reload] = useLoad(() => admin.teams(), [admin]);
  const [query, setQuery] = useState("");

  return (
    <div className="page">
      <Loaded load={load} what="the teams" retry={reload}>
        {(teams) => {
          if (teams.length === 0) {
            return (
              <Empty title="No teams yet">
                {role === "platform_admin" ? (
                  <>
                    A team is a group from the identity provider that the platform has made one. Enabling a group comes to this console next; until then it
                    is on the <a href={currentConsole(plane.url, "/teams")}>current console's Teams page</a>.
                  </>
                ) : (
                  "You are named an administrator of no team. A platform admin names a team's administrators."
                )}
              </Empty>
            );
          }
          const q = query.trim().toLowerCase();
          const shown = teams.filter((t) => !q || matches(t, q));
          return (
            <>
              <div className="toolbar">
                <input aria-label="Search teams" placeholder="search a team, a group, an admin…" value={query} onChange={(e) => setQuery(e.target.value)} />
                <span className="meta">
                  {shown.length} of {teams.length} {teams.length === 1 ? "team" : "teams"}
                </span>
              </div>
              {shown.length === 0 ? (
                <Empty title={`No team matches "${query.trim()}"`}>Search by a team's name, a group it draws from, or one of its administrators.</Empty>
              ) : (
                <div className="scroll">
                  <table>
                    <thead>
                      <tr>
                        <th>Team</th>
                        <th className="num">People</th>
                        <th>Groups</th>
                        <th>Profiles</th>
                        <th>Admins</th>
                        <th>Spend</th>
                      </tr>
                    </thead>
                    <tbody>
                      {shown.map((t) => (
                        <tr key={t.name}>
                          <td>
                            <a href={href({ page: "teams", team: t.name, tab: "members" })}>{t.name}</a>
                          </td>
                          <td className="num">{t.members.length}</td>
                          <td>{t.groups.map((g) => g.display_name ?? g.external_id).join(", ") || <span className="muted">none</span>}</td>
                          <td>{t.grants.map((g) => g.profile).join(", ") || <span className="muted">none</span>}</td>
                          <td>{t.admins.join(", ") || <span className="muted">none</span>}</td>
                          <td>
                            <Spend team={t} />
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

function matches(t: AdminTeam, q: string): boolean {
  return [t.name, ...t.groups.flatMap((g) => [g.external_id, g.display_name ?? ""]), ...t.admins].some((s) => s.toLowerCase().includes(q));
}

/** What a team has spent against its ceiling, and whether it is past it. */
export function Spend({ team }: { team: AdminTeam }): JSX.Element {
  const budget = team.budget_micros && team.budget_micros > 0 ? team.budget_micros : null;
  const spent = `${money(team.spent_micros)}${budget ? ` of ${money(budget)}` : ""}`;
  if (!budget) return <Status kind="muted" glyph="○">{spent} · no ceiling</Status>;
  const over = team.spent_micros >= budget;
  return (
    <Status kind={over ? "local" : "running"} glyph={over ? "◐" : "●"}>
      {spent} · {Math.round((team.spent_micros / budget) * 100)}%{over ? " · over budget" : ""}
    </Status>
  );
}
