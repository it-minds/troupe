// The teams: every one for a platform admin, their own for a team admin, which is what
// `admin.teams.list` answers each of them. A team is an identity-provider group the
// platform made a team of; its people are the provider's, its grants, budget and limits
// the plane's. A platform admin enables a group as a team here.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminTeam } from "@troupe/client";
import { href } from "../route";
import { recorded, useConsole, useLoad } from "../console";
import { AuditNote, Empty, Field, Loaded, Preview, Status, money } from "./bits";

export function Teams(): JSX.Element {
  const { admin, role } = useConsole();
  const [load, reload] = useLoad(() => admin.teams(), [admin]);
  const [query, setQuery] = useState("");
  const platform = role === "platform_admin";

  return (
    <div className="page">
      {/* Outside the read's states, so what was just enabled stays on the screen while the list is read again. */}
      {platform && load.state === "ready" && <Enable teams={load.data} onApplied={reload} />}
      <Loaded load={load} what="the teams" retry={reload}>
        {(teams) => {
          if (teams.length === 0) {
            return (
              <Empty title="No teams yet">
                {platform
                  ? "A team is a group from the identity provider that the platform has made one. Enable a group as a team to begin."
                  : "You are named an administrator of no team. A platform admin names a team's administrators."}
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
export function Spend({ team }: { team: Pick<AdminTeam, "budget_micros" | "spent_micros"> }): JSX.Element {
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

// -- enabling a group as a team ----------------------------------------------------------

/** A team's name, as the plane holds it to. */
const TEAM_NAME = /^[a-z0-9]([a-z0-9-]{0,56}[a-z0-9])?$/;

/** The name the plane makes from a group's when none is given: its display name, as a label. */
function nameFrom(group: { external_id: string; display_name: string | null }): string {
  return (group.display_name ?? group.external_id)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 58)
    .replace(/-+$/g, "");
}

/**
 * Make a group a team. The plane keys a team on its name and, given a name that is
 * already a team's, links the group into that team and changes it rather than making a
 * new one; so a name already taken is refused here, before anything is sent.
 */
function Enable({ teams, onApplied }: { teams: AdminTeam[]; onApplied: () => void }): JSX.Element {
  const { admin, me, notify } = useConsole();
  const [form, setForm] = useState<{ group: string; name: string; named: boolean } | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [done, setDone] = useState<{ name: string; detail: Record<string, unknown> | null } | null>(null);
  const [groups, reloadGroups] = useLoad(() => (form !== null ? admin.groups() : Promise.resolve([])), [admin, form !== null]);
  const taken = form ? teams.some((t) => t.name === form.name) : false;
  const malformed = form ? form.name !== "" && !TEAM_NAME.test(form.name) : false;
  const groupOf = (id: string) => (groups.state === "ready" ? groups.data.find((g) => g.external_id === id) : undefined);

  return (
    <div className="enable">
      {done && (
        <>
          <AuditNote action="team.enable" subject={done.name} detail={done.detail} />
          <p>
            <a href={href({ page: "teams", team: done.name, tab: "access" })}>Open {done.name}</a> to grant it a profile.
          </p>
        </>
      )}
      {!form && (
        <button
          type="button"
          onClick={() => {
            setDone(null);
            setForm({ group: "", name: "", named: false });
          }}
        >
          Enable a group as a team
        </button>
      )}
      {form && !previewing && (
        <Loaded load={groups} what="the identity provider's groups" retry={reloadGroups}>
          {(all) => (
            <form
              className="edit"
              onSubmit={(e) => {
                e.preventDefault();
                setPreviewing(true);
              }}
            >
              <Field label="Group" hint="A group the identity provider has told the plane about. Its members stay the provider's.">
                {(p) => (
                  <select
                    {...p}
                    value={form.group}
                    onChange={(e) => {
                      const g = all.find((x) => x.external_id === e.target.value);
                      setForm({ ...form, group: e.target.value, name: form.named || !g ? form.name : nameFrom(g) });
                    }}
                  >
                    <option value="">choose a group</option>
                    {all.map((g) => {
                      const drawing = teams.filter((t) => t.groups.some((x) => x.external_id === g.external_id)).map((t) => t.name);
                      return (
                        <option key={g.external_id} value={g.external_id}>
                          {g.display_name ? `${g.display_name} (${g.external_id})` : g.external_id}
                          {drawing.length ? ` · ${drawing.join(", ")} ${drawing.length === 1 ? "draws" : "draw"} on it` : ""}
                        </option>
                      );
                    })}
                  </select>
                )}
              </Field>
              <Field
                label="Team name"
                hint="Lowercase letters, digits and dashes, starting and ending with a letter or digit, at most 58 characters: it becomes part of a Kubernetes name."
                error={
                  taken
                    ? `There is already a team called ${form.name}: enabling would link this group into it and change it. Pick another name.`
                    : malformed
                      ? "Not a name a team may have."
                      : null
                }
              >
                {(p) => <input {...p} value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value, named: true })} autoComplete="off" spellCheck={false} />}
              </Field>
              <div className="actions">
                <button type="submit" className="primary" disabled={!form.group || !form.name || taken || malformed}>
                  Preview
                </button>
                <button type="button" onClick={() => setForm(null)}>
                  Cancel
                </button>
              </div>
            </form>
          )}
        </Loaded>
      )}
      {form && previewing && (
        <Preview
          title={`team/${form.name}`}
          lines={[
            { field: "team", from: null, to: form.name },
            { field: "groups", from: null, to: [form.group] },
          ]}
          effects={[
            `${groupOf(form.group)?.display_name ?? form.group} becomes the team ${form.name}. Its people may use Troupe once a platform admin grants it a profile.`,
            `${form.name} starts with the platform's team defaults; its Limits tab changes them.`,
          ]}
          verb="Enable"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            await admin.enableTeam(form.group, { name: form.name });
            const detail = await recorded(admin, me.subject, "team.enable", form.name);
            setDone({ name: form.name, detail });
            notify(`${form.name} is a team.`);
            setPreviewing(false);
            setForm(null);
            onApplied();
          }}
        />
      )}
    </div>
  );
}
