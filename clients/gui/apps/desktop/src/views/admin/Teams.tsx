// Teams: who they are, what they may use, and what they are spending.
//
// Membership is read-only and always will be. It comes from the identity provider, and
// a control here that changed it would make this a second source of truth for who is in
// a team — which is the kind of thing that is fine until the two disagree at three in
// the morning. Grants are ours, so grants are editable.
//
// A `team_admin` sees their own teams and nothing else, and asking for one they do not
// administer answers `not_found` rather than `forbidden`: whether a team exists is
// itself something they should not learn. So this screen renders what it was given and
// never says "and others you cannot see".
//
// The tab opens on a table — one row per team, its groups, how many people, which
// profiles — because that is the question somebody arriving here has; the card under
// each row answers the next one. Delete is on the row and asks first, with what would go
// and what would stay, in the plane's own numbers.

import { useCallback, useState } from "react";
import type { JSX } from "react";
import type { AdminApi, AdminProfile, AdminTeam, TeamDisableEffect } from "@troupe/client";
import { useAdminQuery } from "../../hooks";
import { Loading } from "../bits";
import { AfterTheChange, Confirm, Failed, Money, Table } from "./bits";

// The sentence in the dialog. Sessions are named as kept rather than left out, because
// "delete" reads as taking everything and the one thing it does not take is the one
// people would miss.
export function consequenceOf(effect: TeamDisableEffect): string {
  const count = (items: string[], noun: string): string => `${items.length} ${noun}${items.length === 1 ? "" : "s"}`;
  return [
    `Removes the team for ${effect.members} ${effect.members === 1 ? "person" : "people"}`,
    `revokes ${count(effect.grants, "profile")}`,
    `deletes ${count(effect.principals, "service principal")} and ${count(effect.triggers, "trigger")}`,
    `unlinks ${count(effect.groups, "group")}.`,
    `${effect.sessions_kept} session${effect.sessions_kept === 1 ? " is" : "s are"} kept, with no team and read-only.`,
  ].join(" ");
}

export function AdminTeams({ api, platform }: { api: AdminApi; platform: boolean }): JSX.Element {
  const [wrote, setWrote] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [revoking, setRevoking] = useState<{ team: string; profile: string } | null>(null);
  const [disabling, setDisabling] = useState<{ team: string; effect: TeamDisableEffect } | null>(null);

  const loadTeams = useCallback(() => api.teams(), [api]);
  const { data: teams, loading, error: readError, reload } = useAdminQuery<AdminTeam[]>(loadTeams, [loadTeams, wrote]);
  const loadProfiles = useCallback(() => api.profiles(), [api]);
  const { data: profiles } = useAdminQuery<AdminProfile[]>(platform ? loadProfiles : null, [loadProfiles, platform]);

  const after = (): void => {
    setWrote((n) => n + 1);
    reload();
  };

  const grant = async (team: string, profile: string): Promise<void> => {
    setBusy(`${team}/${profile}`);
    setError(null);
    try {
      await api.grantTeam(team, profile);
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const revoke = async (team: string, profile: string): Promise<void> => {
    setBusy(`${team}/${profile}`);
    setError(null);
    try {
      await api.revokeTeam(team, profile);
      setRevoking(null);
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  // The count before the deed: the dialog opens with the plane's answer, not a guess.
  const askDisable = async (team: string): Promise<void> => {
    setBusy(team);
    setError(null);
    try {
      const effect = await api.disableTeamPreview(team);
      setDisabling({ team, effect });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const disable = async (team: string): Promise<void> => {
    setBusy(team);
    setError(null);
    try {
      await api.disableTeam(team);
      setDisabling(null);
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const setBudget = async (team: AdminTeam, micros: number): Promise<void> => {
    setBusy(team.name);
    setError(null);
    try {
      await api.updateTeam(team.name, { budget_micros: micros });
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <>
      <Failed error={readError ?? error} />
      {loading && !teams && <Loading what="Reading the teams…" />}

      {teams && teams.length === 0 && !loading && (
        <div className="empty">
          <h2>No teams</h2>
          <p>A team is an identity-provider group the platform has been told about. Until one is enabled, nothing can be billed.</p>
        </div>
      )}

      {teams && teams.length > 0 && (
        <section className="group">
          <h3>Every team</h3>
          <Table head={["Team", "Groups", "Members", "Profiles", "Administrators", ...(platform ? ["  "] : [])]}>
            {teams.map((team) => (
              <tr key={team.name}>
                <th scope="row">
                  <a href={`#team-${team.name}`}>{team.name}</a>
                </th>
                <td>
                  {team.groups.length > 0 ? (
                    team.groups.map((g) => g.display_name ?? g.external_id).join(", ")
                  ) : (
                    <span className="muted">none</span>
                  )}
                </td>
                <td>{team.members.length}</td>
                <td>
                  {team.grants.length > 0 ? team.grants.map((g) => g.profile).join(", ") : <span className="muted">none</span>}
                </td>
                <td>{team.admins.length}</td>
                {platform && (
                  <td>
                    <button className="link" disabled={busy !== null} onClick={() => void askDisable(team.name)}>
                      Delete
                    </button>
                  </td>
                )}
              </tr>
            ))}
          </Table>
        </section>
      )}

      {(teams ?? []).map((team) => {
        const granted = new Set(team.grants.map((g) => g.profile));
        const ungranted = (profiles ?? []).map((p) => p.name).filter((n) => !granted.has(n));
        return (
          <section className="group" key={team.name} id={`team-${team.name}`}>
            <h3>{team.name}</h3>

            <dl className="facts wide">
              <dt>Spending</dt>
              <dd>
                <Money micros={team.spent_micros} />
                {team.budget_micros ? (
                  <>
                    {" of "}
                    <Money micros={team.budget_micros} />
                    {team.budget_period ? ` per ${team.budget_period}` : ""}
                  </>
                ) : (
                  " — no ceiling set"
                )}
                {team.reserved_micros > 0 && (
                  <span className="micro muted">
                    {" "}
                    (<Money micros={team.reserved_micros} /> promised to sessions running now)
                  </span>
                )}
              </dd>
              <dt>Administrators</dt>
              <dd>{team.admins.length > 0 ? team.admins.join(", ") : "none — only platform administrators"}</dd>
              <dt>Members</dt>
              <dd>
                {team.members.length} from the identity provider
                <span className="micro muted"> — membership is not editable here</span>
              </dd>
              <dt>Sessions it keeps</dt>
              <dd>
                {team.erase_after_days ? `erased after ${team.erase_after_days} days` : "kept until erased by hand"}
                {team.cache_eviction_days ? `, workspace cache dropped after ${team.cache_eviction_days}` : ""}
              </dd>
            </dl>

            <h4>What it may use</h4>
            {team.grants.length === 0 ? (
              <p className="note">No profile is granted to this team, so nobody on it can start a session.</p>
            ) : (
              <Table head={["Profile", "Volumes", ...(platform ? ["  "] : [])]}>
                {team.grants.map((g) => (
                  <tr key={g.profile}>
                    <th scope="row">{g.profile}</th>
                    <td>{g.volume_mode ?? "none"}</td>
                    {platform && (
                      <td>
                        <button className="link" onClick={() => setRevoking({ team: team.name, profile: g.profile })}>
                          Revoke
                        </button>
                      </td>
                    )}
                  </tr>
                ))}
              </Table>
            )}

            {platform && ungranted.length > 0 && (
              <form
                className="inline-form"
                onSubmit={(e) => {
                  e.preventDefault();
                  const picked = new FormData(e.currentTarget).get("profile");
                  if (typeof picked === "string" && picked) void grant(team.name, picked);
                }}
              >
                <select name="profile" aria-label={`Grant a profile to ${team.name}`} defaultValue={ungranted[0]}>
                  {ungranted.map((n) => (
                    <option key={n} value={n}>
                      {n}
                    </option>
                  ))}
                </select>
                <button type="submit" disabled={busy !== null}>
                  Grant
                </button>
              </form>
            )}

            <form
              className="inline-form"
              onSubmit={(e) => {
                e.preventDefault();
                const dollars = Number(new FormData(e.currentTarget).get("budget"));
                if (Number.isFinite(dollars) && dollars >= 0) void setBudget(team, Math.round(dollars * 1_000_000));
              }}
            >
              <label className="inline">
                Ceiling, in dollars
                <input
                  name="budget"
                  type="number"
                  min="0"
                  step="1"
                  defaultValue={team.budget_micros ? team.budget_micros / 1_000_000 : ""}
                  aria-label={`Budget for ${team.name}`}
                />
              </label>
              <button type="submit" disabled={busy === team.name}>
                {busy === team.name ? "Saving…" : "Set the ceiling"}
              </button>
            </form>
          </section>
        );
      })}

      <AfterTheChange api={api} nonce={wrote} />

      {disabling && (
        <Confirm
          what="Delete this team"
          identifier={disabling.team}
          consequence={consequenceOf(disabling.effect)}
          busy={busy !== null}
          onCancel={() => setDisabling(null)}
          onConfirm={() => void disable(disabling.team)}
        />
      )}

      {revoking && (
        <Confirm
          what="Revoke this grant"
          identifier={revoking.profile}
          consequence={`Nobody on ${revoking.team} will be able to start a session on ${revoking.profile}. Sessions already running on it are untouched.`}
          busy={busy !== null}
          onCancel={() => setRevoking(null)}
          onConfirm={() => void revoke(revoking.team, revoking.profile)}
        />
      )}
    </>
  );
}
