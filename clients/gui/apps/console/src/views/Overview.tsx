// The first screen: what needs attention, first, and then how each profile's fleet is
// doing and what every team has spent against its budget. Scoped by the plane to what the
// person administers, from `admin.overview`, and the runs nobody has read from
// `admin.sessions.list`.
//
// "Needs attention" is everything that is not healthy, worst first, each with where it is
// fixed: a pod that is broken, has never reported or is draining; a profile with fewer
// pods than it asked for; a team at or near its ceiling; runs started with nobody watching
// that nobody has looked at since. An empty list says so in a sentence, because an empty
// region and one that has not loaded look the same. Clients behind the recommended version
// are one line there, linked to Client versions, where there are any (#657). Read again
// every few seconds, keeping what is on the screen until the new answer replaces it.

import { useEffect } from "react";
import type { JSX, ReactNode } from "react";
import type { AdminPod, AdminProfile, ClientVersions, FleetOverview, TeamSpend } from "@troupe/client";
import { href } from "../route";
import { useConsole, useLoad } from "../console";
import { Empty, Loaded, Region, Status, count, money } from "./bits";
import type { StatusKind } from "./bits";
import { Spend } from "./Teams";

const REFRESH_MS = 10_000;

/** Where a team stops being comfortable and starts being worth mentioning. */
const NEAR_BUDGET = 0.8;

type State = "broken" | "unknown" | "degraded" | "draining" | "over" | "near" | "waiting" | "behind" | "healthy";

export const STATES: Record<State, { kind: StatusKind; glyph: string; word: string; rank: number }> = {
  broken: { kind: "denied", glyph: "✕", word: "broken", rank: 0 },
  over: { kind: "denied", glyph: "✕", word: "at ceiling", rank: 0 },
  waiting: { kind: "waiting", glyph: "◆", word: "waiting on you", rank: 1 },
  unknown: { kind: "muted", glyph: "○", word: "unknown", rank: 2 },
  degraded: { kind: "local", glyph: "◐", word: "degraded", rank: 3 },
  near: { kind: "local", glyph: "◐", word: "near ceiling", rank: 3 },
  draining: { kind: "dormant", glyph: "◑", word: "draining", rank: 4 },
  behind: { kind: "local", glyph: "◐", word: "behind", rank: 5 },
  healthy: { kind: "running", glyph: "●", word: "healthy", rank: 9 },
};

interface Item {
  state: State;
  what: string;
  where: string;
  action: string;
}

export function Overview(): JSX.Element {
  const { admin, role } = useConsole();
  const [load, reload] = useLoad(
    () =>
      Promise.all([
        admin.overview(),
        // The runs a person still has to read; their absence takes nothing else away.
        admin.sessions({ needs_review: true }).catch(() => null),
        // Which clients are behind; a plane that cannot say takes nothing else away.
        admin.clients().catch(() => null),
      ]),
    [admin],
  );

  useEffect(() => {
    const t = setInterval(reload, REFRESH_MS);
    return () => clearInterval(t);
  }, [reload]);

  return (
    <div className="page">
      <Loaded load={load} what="the overview" retry={reload}>
        {([overview, unread, clients]) => {
          const items = attention(overview, unread?.length ?? 0, role === "platform_admin", clients);
          const pods = overview.profiles.flatMap((p) => p.pods);
          const healthy = pods.filter((p) => podState(p) === "healthy").length;
          const spent = overview.teams.reduce((n, t) => n + t.spent_micros, 0);
          const committed = overview.teams.reduce((n, t) => n + (t.budget_micros ?? 0), 0);
          return (
            <>
              <div className="metrics">
                <Metric label="Active sessions" value={String(overview.sessions.active)}>
                  {overview.sessions.dormant} dormant, {overview.sessions.read_only} read-only
                </Metric>
                <Metric label="Pods" value={`${healthy} / ${pods.length}`}>
                  healthy, across {count(overview.profiles.length, "profile")}
                </Metric>
                <Metric label="Spent" value={money(spent)}>
                  against {money(committed)} committed across {count(overview.teams.length, "team")}
                </Metric>
                <Metric label="Needs attention" value={String(items.length)}>
                  {items.length === 0 ? "nothing is unhealthy" : "worst first, below"}
                </Metric>
              </div>

              <Region>Needs attention</Region>
              {items.length === 0 ? (
                <Empty title="Nothing needs attention">Nothing is unhealthy, at its ceiling or waiting on a person.</Empty>
              ) : (
                <ul className="attention">
                  {items.map((item) => (
                    <li key={`${item.state}:${item.what}`}>
                      <Status kind={STATES[item.state].kind} glyph={STATES[item.state].glyph}>
                        {STATES[item.state].word}
                      </Status>
                      <span className="what">{item.what}</span>
                      <a href={item.where}>{item.action}</a>
                    </li>
                  ))}
                </ul>
              )}

              <Region>Fleet · per profile</Region>
              {overview.profiles.length === 0 ? (
                <Empty title="No profile you can see">A platform admin makes a profile, and grants it to a team.</Empty>
              ) : (
                <div className="scroll">
                  <table>
                    <thead>
                      <tr>
                        <th>Profile</th>
                        <th>Status</th>
                        <th className="num">Pods</th>
                        <th className="num">Capacity</th>
                        <th className="num">In use</th>
                      </tr>
                    </thead>
                    <tbody>
                      {overview.profiles.map((p) => {
                        const s = STATES[profileState(p)];
                        return (
                          <tr key={p.name}>
                            <td>
                              <a href={href({ page: "profiles", path: [p.name] })}>{p.name}</a>
                            </td>
                            <td>
                              <Status kind={s.kind} glyph={s.glyph}>
                                {s.word}
                              </Status>
                            </td>
                            <td className="num">
                              {p.pods.length} / {p.replicas ?? "—"}
                            </td>
                            <td className="num">{p.capacity}</td>
                            <td className="num">{p.active_sessions}</td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}

              <Region>Spend · per team</Region>
              {overview.teams.length === 0 ? (
                <Empty title="No team you can see">A platform admin enables a group as a team on the Teams screen.</Empty>
              ) : (
                <div className="scroll">
                  <table>
                    <thead>
                      <tr>
                        <th>Team</th>
                        <th>Against its budget</th>
                        <th className="num">Reserved</th>
                      </tr>
                    </thead>
                    <tbody>
                      {overview.teams.map((t) => (
                        <tr key={t.name}>
                          <td>
                            <a href={href({ page: "teams", team: t.name, tab: "limits" })}>{t.name}</a>
                          </td>
                          <td>
                            <Spend team={t} />
                          </td>
                          <td className="num">{money(t.reserved_micros)}</td>
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

/** A number, never without the line that says what it is out of. */
function Metric({ label, value, children }: { label: string; value: string; children: ReactNode }): JSX.Element {
  return (
    <div className="metric">
      <span className="label">{label}</span>
      <span className="value">{value}</span>
      <span className="context">{children}</span>
    </div>
  );
}

/**
 * A pod's state. Silence is unknown, not broken: a pod that has never reported may be
 * starting, and calling it broken cries wolf in a partition.
 */
function podState(pod: AdminPod): State {
  if (pod.draining) return "draining";
  if (!pod.healthy) return pod.last_seen_at ? "broken" : "unknown";
  return "healthy";
}

export function profileState(profile: AdminProfile): State {
  if (profile.replicas !== null && profile.pods.length < profile.replicas) return "degraded";
  if (profile.pods.length === 0) return "unknown";
  return profile.pods.map(podState).sort((a, b) => STATES[a].rank - STATES[b].rank)[0] ?? "healthy";
}

// A pod is looked at where its pods are, which is a platform admin's area; a team admin is
// sent to the profile instead.
function attention(overview: FleetOverview, unread: number, platform: boolean, clients: ClientVersions | null): Item[] {
  const items: Item[] = [];
  for (const profile of overview.profiles) {
    const workers = platform ? href({ page: "pods" }) : href({ page: "profiles", path: [profile.name] });
    for (const pod of profile.pods) {
      const state = podState(pod);
      if (state === "healthy") continue;
      const what =
        state === "unknown"
          ? `${pod.pod} on ${profile.name} has never reported. It may be starting, or it may not be there.`
          : state === "broken"
            ? `${pod.pod} on ${profile.name} reported that it is not healthy.`
            : `${pod.pod} on ${profile.name} is draining: ${count(pod.active_sessions, "session")} still on it.`;
      items.push({ state, what, where: workers, action: `Look at ${profile.name}` });
    }
    if (profile.replicas !== null && profile.pods.length < profile.replicas) {
      items.push({
        state: "degraded",
        what: `${profile.name} asked for ${count(profile.replicas, "pod")} and has ${profile.pods.length}.`,
        where: workers,
        action: `Look at ${profile.name}`,
      });
    }
  }
  for (const team of overview.teams) {
    const state = budgetState(team);
    if (state === "healthy") continue;
    items.push({ state, what: budgetWords(state, team), where: href({ page: "teams", team: team.name, tab: "limits" }), action: `${team.name}'s limits` });
  }
  if (unread > 0) {
    items.push({
      state: "waiting",
      what: `${count(unread, "session")} an unattended run started ${unread === 1 ? "is" : "are"} waiting for a person to look at ${unread === 1 ? "it" : "them"}.`,
      where: href({ page: "runs" }),
      action: "Runs and review",
    });
  }
  const fleet = Object.values(clients?.fleet ?? {});
  const behind = fleet.reduce((n, f) => n + f.behind + f.refused, 0);
  if (behind > 0) {
    const refused = fleet.reduce((n, f) => n + f.refused, 0);
    items.push({
      state: "behind",
      what: `${count(behind, "client")} behind the recommended version${refused > 0 ? `, ${refused} of them refused when ${refused === 1 ? "it next connects" : "they next connect"}` : ""}.`,
      where: href({ page: "clients" }),
      action: "Client versions",
    });
  }
  return items.sort((a, b) => STATES[a.state].rank - STATES[b.state].rank);
}

function budgetState(team: TeamSpend): State {
  if (!team.budget_micros || team.budget_micros <= 0) return "healthy";
  const committed = team.spent_micros + team.reserved_micros;
  if (committed >= team.budget_micros) return "over";
  return committed / team.budget_micros >= NEAR_BUDGET ? "near" : "healthy";
}

// Only a monthly ceiling turns over, on the 1st in UTC; any other is lifted only by raising it.
function budgetWords(state: State, team: TeamSpend): string {
  const monthly = team.budget_period === "monthly";
  if (state === "over") {
    return monthly
      ? `${team.name} is at its monthly ceiling. New sessions are refused until it is raised or the month turns over, on the 1st (UTC).`
      : `${team.name} is at its ceiling, which never turns over. New sessions are refused until it is raised.`;
  }
  const percent = Math.round(((team.spent_micros + team.reserved_micros) / (team.budget_micros ?? 1)) * 100);
  return `${team.name} has spent ${percent}% of its ${monthly ? "monthly " : ""}budget.`;
}
