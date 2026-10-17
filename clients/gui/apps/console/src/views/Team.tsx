// One team, in six tabs: who is in it and from which groups, which profiles it may use,
// who administers it, its limits, the GitHub repositories its sessions may name with its
// fix loop's caps, and what removing it would take with it.
//
// Every tab reads, and every tab changes what it shows: a group linked or unlinked, a
// profile granted or revoked, an administrator named or removed, a limit narrowed, the
// team removed. Each change is previewed (what moves, and what that does in words), then
// confirmed: plainly where it can be changed back, and by typing the name of what goes
// where it takes something away that nobody can simply give back (a group's people, a
// profile's running sessions, the team). Once made, it is shown as the audit recorded it.
// The edits other than the limits and the GitHub repositories are a platform admin's, as
// the plane holds them, and a team admin is not offered them.
//
// The plane has no read of one team: `admin.teams.list` is the read, and a team a team
// admin does not administer is not in their answer, so it is "not found" here as it is
// at the plane.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminProfile, AdminTeam, LadderValue, TeamDisableEffect, TeamUnlinkEffect } from "@troupe/client";
import { TEAM_TABS, href } from "../route";
import type { TeamTab } from "../route";
import { recorded, show, useConsole, useLoad } from "../console";
import type { Load } from "../console";
import { AuditNote, Empty, Field, Loaded, Preview, Region, Status, changed, count, money, useChange } from "./bits";
import type { DiffLine, Done, FieldProps } from "./bits";
import { Spend, Twice } from "./Teams";

const TAB_LABELS: Record<TeamTab, string> = {
  members: "Members and groups",
  access: "Access",
  admins: "Admins",
  limits: "Limits",
  github: "GitHub",
  danger: "Danger zone",
};

export function Team({ name, tab }: { name: string; tab: TeamTab }): JSX.Element {
  const { admin, role } = useConsole();
  const [load, reload] = useLoad(() => admin.teams(), [admin, name]);
  // Removing a team is a platform admin's, and so is asking what it would take.
  const tabs = TEAM_TABS.filter((t) => t !== "danger" || role === "platform_admin");

  return (
    <div className="page">
      <Loaded load={load} what={`team ${name}`} retry={reload}>
        {(teams) => {
          const team = teams.find((t) => t.name === name);
          if (!team) {
            return (
              <Empty title={`No team called ${name}`}>
                Or not one you administer. <a href={href({ page: "teams" })}>All teams</a>
              </Empty>
            );
          }
          return (
            <>
              <p className="team-meta">
                {team.members.length} {team.members.length === 1 ? "person" : "people"} · {team.groups.length}{" "}
                {team.groups.length === 1 ? "group" : "groups"} · <Spend team={team} />
              </p>
              <nav className="tabs" aria-label={`${name}'s tabs`}>
                {tabs.map((t) => (
                  <a key={t} href={href({ page: "teams", team: name, tab: t })} aria-current={t === tab ? "page" : undefined}>
                    {TAB_LABELS[t]}
                  </a>
                ))}
              </nav>
              {tab === "members" && <Members team={team} onApplied={reload} />}
              {tab === "access" && <Access team={team} onApplied={reload} />}
              {tab === "admins" && <Admins team={team} onApplied={reload} />}
              {tab === "limits" && <Limits team={team} onApplied={reload} />}
              {tab === "github" && <GitHub team={team} onApplied={reload} />}
              {tab === "danger" && role === "platform_admin" && <Danger team={team} />}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

/** Where a person's own cap is set: on Budgets, since it follows them across every team. */
function OwnCaps(): JSX.Element | null {
  const { role } = useConsole();
  if (role !== "platform_admin") return null;
  return (
    <p className="note">
      A person's own spending cap follows them across every team, so it is set on <a href={href({ page: "budgets" })}>Budgets</a>.
    </p>
  );
}

// -- members and groups ------------------------------------------------------------------

function Members({ team, onApplied }: { team: AdminTeam; onApplied: () => void }): JSX.Element {
  const { admin, role } = useConsole();
  const platform = role === "platform_admin";
  const { done, apply } = useChange(onApplied);
  const [linking, setLinking] = useState<string | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [unlinking, setUnlinking] = useState<string | null>(null);
  const [groups, reloadGroups] = useLoad(() => (linking !== null ? admin.groups() : Promise.resolve([])), [admin, linking !== null]);
  const ids = team.groups.map((g) => g.external_id);
  const busy = linking !== null || unlinking !== null;

  return (
    <section className="tab">
      <p className="lead">
        Membership is the identity provider's: a person is in {team.name} because they are in one of its groups. Nothing here adds or removes a person;
        linking a group brings in everyone in it, and unlinking one takes away whoever is in {team.name} only through it.
      </p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Region>Groups</Region>
      {team.groups.length === 0 ? (
        <Empty title="No group linked">Nobody can be in this team until a group is linked to it.</Empty>
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Group</th>
                <th>Id at the provider</th>
                <th>Linked by</th>
                {platform && <th aria-label="Actions" />}
              </tr>
            </thead>
            <tbody>
              {team.groups.map((g) => (
                <tr key={g.external_id}>
                  <td>{g.display_name ?? g.external_id}</td>
                  <td className="mono">{g.external_id}</td>
                  <td>{g.linked_by ?? "—"}</td>
                  {platform && (
                    <td className="row-actions">
                      {!busy && (
                        <button type="button" onClick={() => setUnlinking(g.external_id)}>
                          Unlink
                        </button>
                      )}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {unlinking !== null && (
        <Unlink
          team={team}
          group={unlinking}
          onCancel={() => setUnlinking(null)}
          onConfirm={async () => {
            await apply("team.unlink", team.name, () => admin.unlinkTeam(team.name, unlinking), `${unlinking} is unlinked from ${team.name}.`);
            setUnlinking(null);
          }}
        />
      )}
      {platform && !busy && (
        <button type="button" onClick={() => setLinking("")}>
          Link a group
        </button>
      )}
      {linking !== null && !previewing && (
        <Loaded load={groups} what="the identity provider's groups" retry={reloadGroups}>
          {(all) => {
            const offered = all.filter((g) => !ids.includes(g.external_id));
            return (
              <form
                className="edit"
                onSubmit={(e) => {
                  e.preventDefault();
                  setPreviewing(true);
                }}
              >
                <Field label="Group" hint="Every group the identity provider has told the plane about that this team does not draw on yet.">
                  {(p) => (
                    <select {...p} value={linking} onChange={(e) => setLinking(e.target.value)}>
                      <option value="">choose a group</option>
                      {offered.map((g) => (
                        <option key={g.external_id} value={g.external_id}>
                          {g.display_name ? `${g.display_name} (${g.external_id})` : g.external_id}
                          {g.looks_duplicated ? " · looks held twice" : ""}
                        </option>
                      ))}
                    </select>
                  )}
                </Field>
                <Twice group={offered.find((g) => g.external_id === linking)} />
                {offered.length === 0 && <p className="hint">This team draws on every group the plane knows of.</p>}
                <div className="actions">
                  <button type="submit" className="primary" disabled={!linking}>
                    Preview
                  </button>
                  <button type="button" onClick={() => setLinking(null)}>
                    Cancel
                  </button>
                </div>
              </form>
            );
          }}
        </Loaded>
      )}
      {linking && previewing && (
        <Preview
          title={`team/${team.name}`}
          lines={[{ field: "groups", from: ids, to: [...ids, linking] }]}
          effects={[
            `Everyone in ${groupName(groups, linking)} is in ${team.name} from their next sign-in or the provider's next push, and may use what ${team.name} is granted.`,
            `Nobody already in ${team.name} loses anything.`,
          ]}
          verb="Link"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            await apply("team.link", team.name, () => admin.linkTeam(team.name, linking), `${linking} is linked to ${team.name}.`);
            setPreviewing(false);
            setLinking(null);
          }}
        />
      )}
      <Region>People</Region>
      {team.members.length === 0 ? (
        <Empty title="Nobody yet">A person appears here once they are in a linked group, at their next sign-in or the provider's next push.</Empty>
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Person</th>
                <th>Subject</th>
                <th className="num">Spent</th>
                <th className="num">Own cap</th>
              </tr>
            </thead>
            <tbody>
              {team.members.map((m) => (
                <tr key={m.subject}>
                  <td>{m.display_name ?? m.subject}</td>
                  <td className="mono">{m.subject}</td>
                  <td className="num">{money(m.spent_micros ?? 0)}</td>
                  <td className="num">{m.budget_micros ? money(m.budget_micros) : <span className="muted">none</span>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <OwnCaps />
    </section>
  );
}

function groupName(load: Load<Array<{ external_id: string; display_name: string | null }>>, id: string): string {
  const found = load.state === "ready" ? load.data.find((g) => g.external_id === id) : undefined;
  return found?.display_name ?? id;
}

/** Unlinking a group: who loses the team, read from the plane first, then typed by the group's id. */
function Unlink({ team, group, onCancel, onConfirm }: { team: AdminTeam; group: string; onCancel: () => void; onConfirm: () => Promise<void> }): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.unlinkTeamPreview(team.name, group), [admin, team.name, group]);
  const ids = team.groups.map((g) => g.external_id);
  return (
    <Loaded load={load} what={`what unlinking ${group} would do`} retry={reload}>
      {(effect) => (
        <Preview
          title={`team/${team.name}`}
          lines={[{ field: "groups", from: ids, to: ids.filter((id) => id !== group) }]}
          effects={unlinkWords(team.name, effect)}
          verb={`Unlink ${group}`}
          typeToConfirm={group}
          onCancel={onCancel}
          onConfirm={onConfirm}
        />
      )}
    </Loaded>
  );
}

function unlinkWords(team: string, e: TeamUnlinkEffect): string[] {
  const out = [`${count(e.in_group, "person", "people")} ${e.in_group === 1 ? "is" : "are"} in ${e.group}.`];
  if (e.lose_access === 0) {
    out.push(`Nobody loses ${team}: everyone in ${e.group} is in ${team} through another group too.`);
  } else {
    out.push(`${count(e.lose_access, "person", "people")} ${e.lose_access === 1 ? "loses" : "lose"} ${team}: ${e.losing.join(", ")}.`);
    out.push(`${e.lose_access === 1 ? "They" : "Together they"} can open ${count(e.sessions_they_can_open, "session")} now through ${team}.`);
  }
  if (e.keep_access > 0) out.push(`${e.keep_access} ${e.keep_access === 1 ? "keeps" : "keep"} it through another group.`);
  out.push("Sessions do not move: a session's team is fixed when it starts, and only who may open it changes.");
  return out;
}

// -- access ------------------------------------------------------------------------------

const VOLUME: Record<string, string> = { ro: "read only", rw: "read and write" };

function Access({ team, onApplied }: { team: AdminTeam; onApplied: () => void }): JSX.Element {
  const { admin, role } = useConsole();
  const platform = role === "platform_admin";
  const { done, apply } = useChange(onApplied);
  const [granting, setGranting] = useState<{ profile: string; volume: string } | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [revoking, setRevoking] = useState<string | null>(null);
  const [profiles, reloadProfiles] = useLoad(() => (granting !== null ? admin.profiles() : Promise.resolve([] as AdminProfile[])), [admin, granting !== null]);
  const granted = team.grants.map((g) => g.profile);
  const busy = granting !== null || revoking !== null;

  return (
    <section className="tab">
      <p className="lead">
        A profile grant is the only way {team.name} gains reach. Revoking one turns every {team.name} session on that profile read-only the moment it
        lands.
      </p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      {team.grants.length === 0 ? (
        <Empty title="No profile granted">This team can start no session until a platform admin grants it a profile.</Empty>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Profile</th>
              <th>Team volume</th>
              {platform && <th aria-label="Actions" />}
            </tr>
          </thead>
          <tbody>
            {team.grants.map((g) => (
              <tr key={g.profile}>
                <td>{g.profile}</td>
                <td>{g.volume_mode ? (VOLUME[g.volume_mode] ?? g.volume_mode) : <span className="muted">none</span>}</td>
                {platform && (
                  <td className="row-actions">
                    {!busy && (
                      <button type="button" onClick={() => setRevoking(g.profile)}>
                        Revoke
                      </button>
                    )}
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {revoking !== null && (
        <Preview
          title={`team/${team.name}`}
          lines={[{ field: "grants", from: granted, to: granted.filter((p) => p !== revoking) }]}
          effects={[
            `Every ${team.name} session on ${revoking} turns read-only the moment this lands: it keeps its history and can still be read, and nobody can steer it until ${team.name} is granted ${revoking} again.`,
            `No new ${team.name} session can start on ${revoking}.`,
          ]}
          verb={`Revoke ${revoking}`}
          typeToConfirm={revoking}
          onCancel={() => setRevoking(null)}
          onConfirm={async () => {
            await apply("team.revoke", team.name, () => admin.revokeTeam(team.name, revoking), `${team.name} no longer has ${revoking}; its sessions there are read-only.`);
            setRevoking(null);
          }}
        />
      )}
      {platform && !busy && (
        <button type="button" onClick={() => setGranting({ profile: "", volume: "ro" })}>
          Grant a profile
        </button>
      )}
      {granting !== null && !previewing && (
        <Loaded load={profiles} what="the profiles" retry={reloadProfiles}>
          {(all) => {
            const offered = all.filter((p) => !granted.includes(p.name));
            return (
              <form
                className="edit"
                onSubmit={(e) => {
                  e.preventDefault();
                  setPreviewing(true);
                }}
              >
                <Field label="Profile" hint="Every profile this plane has that the team is not granted yet.">
                  {(p) => (
                    <select {...p} value={granting.profile} onChange={(e) => setGranting({ ...granting, profile: e.target.value })}>
                      <option value="">choose a profile</option>
                      {offered.map((o) => (
                        <option key={o.name} value={o.name}>
                          {o["unenforced"] ? `${o.name} (nothing enforced)` : o.name}
                        </option>
                      ))}
                    </select>
                  )}
                </Field>
                <Field label="Team volume" hint="How the team's shared volume is mounted in its sessions on this profile.">
                  {(p) => (
                    <select {...p} value={granting.volume} onChange={(e) => setGranting({ ...granting, volume: e.target.value })}>
                      <option value="ro">read only</option>
                      <option value="rw">read and write</option>
                    </select>
                  )}
                </Field>
                <div className="actions">
                  <button type="submit" className="primary" disabled={!granting.profile}>
                    Preview
                  </button>
                  <button type="button" onClick={() => setGranting(null)}>
                    Cancel
                  </button>
                </div>
              </form>
            );
          }}
        </Loaded>
      )}
      {granting?.profile && previewing && (
        <Preview
          title={`team/${team.name}`}
          lines={[{ field: "grants", from: granted, to: [...granted, granting.profile] }]}
          effects={grantWords(team, granting.profile, granting.volume, profiles.state === "ready" ? profiles.data.find((p) => p.name === granting.profile) : undefined)}
          verb="Grant"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            await apply("team.grant", team.name, () => admin.grantTeam(team.name, granting.profile, granting.volume), `${team.name} may use ${granting.profile}.`);
            setPreviewing(false);
            setGranting(null);
          }}
        />
      )}
    </section>
  );
}

function grantWords(team: AdminTeam, profile: string, volume: string, spec: AdminProfile | undefined): string[] {
  const out: string[] = [];
  const missing = Array.isArray(spec?.["missing_guarantees"]) ? (spec["missing_guarantees"] as string[]) : [];
  if (spec?.["unenforced"] && !team.allow_unenforced_workers) {
    out.push(
      `The plane will refuse this: ${profile} runs where nothing is enforced${missing.length ? ` (${missing.join(", ")} missing)` : ""}, and ${team.name} may not use such workers. A platform admin allows that on ${team.name}'s Limits tab first.`,
    );
  }
  out.push(`${team.name}'s people may start sessions on ${profile} from now; sessions already running are unchanged.`);
  out.push(`The team volume is mounted ${VOLUME[volume] ?? volume} on ${profile}.`);
  return out;
}

// -- admins ------------------------------------------------------------------------------

function Admins({ team, onApplied }: { team: AdminTeam; onApplied: () => void }): JSX.Element {
  const { admin, role } = useConsole();
  const platform = role === "platform_admin";
  const { done, apply } = useChange(onApplied);
  const [naming, setNaming] = useState<string | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [removing, setRemoving] = useState<string | null>(null);
  const busy = naming !== null || removing !== null;
  const asked = naming?.trim() ?? "";
  const listId = `${team.name}-members`;

  return (
    <section className="tab">
      <p className="lead">Who may administer {team.name}: change its limits and see its sessions, its members and its spend. Platform admins may as well.</p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      {team.admins.length === 0 ? (
        <Empty title="No team admin">Only platform admins administer this team.</Empty>
      ) : (
        <ul className="plain">
          {team.admins.map((a) => (
            <li key={a} className="with-actions">
              <span className="mono">{a}</span>
              {platform && !busy && (
                <button type="button" onClick={() => setRemoving(a)}>
                  Remove
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
      {removing !== null && (
        <Preview
          title={`team/${team.name}`}
          lines={[{ field: "admins", from: team.admins, to: team.admins.filter((a) => a !== removing) }]}
          effects={[
            `${removing} stops administering ${team.name} at their next click. They stay in ${team.name} while a linked group has them.`,
            team.admins.length === 1 ? `Nobody but the platform admins administers ${team.name} after this.` : "",
          ].filter(Boolean)}
          verb={`Remove ${removing}`}
          onCancel={() => setRemoving(null)}
          onConfirm={async () => {
            await apply("team.admin.remove", team.name, () => admin.removeTeamAdmin(team.name, removing), `${removing} no longer administers ${team.name}.`);
            setRemoving(null);
          }}
        />
      )}
      {platform && !busy && (
        <button type="button" onClick={() => setNaming("")}>
          Name an administrator
        </button>
      )}
      {naming !== null && !previewing && (
        <form
          className="edit"
          onSubmit={(e) => {
            e.preventDefault();
            setPreviewing(true);
          }}
        >
          <Field
            label="Subject"
            hint="The person as the identity provider names them, usually their email. Their sign-in need not have happened yet."
            error={team.admins.includes(asked) ? `${asked} already administers ${team.name}.` : null}
          >
            {(p) => <input {...p} value={naming} onChange={(e) => setNaming(e.target.value)} list={listId} autoComplete="off" spellCheck={false} />}
          </Field>
          <datalist id={listId}>
            {team.members
              .filter((m) => !team.admins.includes(m.subject))
              .map((m) => (
                <option key={m.subject} value={m.subject}>
                  {m.display_name ?? m.subject}
                </option>
              ))}
          </datalist>
          <div className="actions">
            <button type="submit" className="primary" disabled={!asked || team.admins.includes(asked)}>
              Preview
            </button>
            <button type="button" onClick={() => setNaming(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}
      {naming !== null && previewing && (
        <Preview
          title={`team/${team.name}`}
          lines={[{ field: "admins", from: team.admins, to: [...team.admins, asked].sort() }]}
          effects={[
            `${asked} may change ${team.name}'s limits and see its sessions, members and spend, from their next click.`,
            team.members.some((m) => m.subject === asked) ? "" : `${asked} is not in ${team.name} today; they administer it all the same.`,
          ].filter(Boolean)}
          verb="Name"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            await apply("team.admin.add", team.name, () => admin.addTeamAdmin(team.name, asked), `${asked} administers ${team.name}.`);
            setPreviewing(false);
            setNaming(null);
          }}
        />
      )}
    </section>
  );
}

// -- limits ------------------------------------------------------------------------------

type LimitKey = "budget_micros" | "budget_period" | "idle_timeout_seconds" | "cache_eviction_days" | "erase_after_days" | "members_may_control" | "pins_allowed" | "volume_size" | "volume_storage_class" | "allow_unenforced_workers";

interface Limit {
  field: LimitKey;
  label: string;
  kind: "money" | "period" | "seconds" | "days" | "switch" | "text";
  platformOnly?: boolean;
}

const LIMITS: Limit[] = [
  { field: "budget_micros", label: "Budget", kind: "money" },
  { field: "budget_period", label: "Budget counted over", kind: "period" },
  { field: "idle_timeout_seconds", label: "Idle before it goes dormant", kind: "seconds" },
  { field: "cache_eviction_days", label: "A dormant session's cache kept", kind: "days" },
  { field: "erase_after_days", label: "Sessions erased after", kind: "days" },
  { field: "members_may_control", label: "Members may steer team sessions", kind: "switch" },
  { field: "pins_allowed", label: "Members may pin a session", kind: "switch" },
  { field: "volume_size", label: "Team volume size", kind: "text" },
  { field: "volume_storage_class", label: "Team volume storage class", kind: "text" },
  { field: "allow_unenforced_workers", label: "May use workers nothing is enforced on", kind: "switch", platformOnly: true },
];

function valueWords(limit: Limit, value: unknown): string {
  if (value === null || value === undefined || value === "") return "unset";
  switch (limit.kind) {
    case "money":
      return Number(value) === 0 ? "no ceiling" : money(Number(value));
    case "seconds":
      return `${String(value)} s`;
    case "days":
      return `${String(value)} days`;
    case "switch":
      return value ? "yes" : "no";
    default:
      return String(value);
  }
}

const RUNG: Record<string, { kind: "muted" | "running" | "dormant"; glyph: string }> = {
  deployment: { kind: "muted", glyph: "◇" },
  platform: { kind: "running", glyph: "●" },
  team: { kind: "dormant", glyph: "◆" },
};

function DecidedBy({ rung }: { rung: string }): JSX.Element {
  const r = RUNG[rung] ?? { kind: "muted" as const, glyph: "○" };
  return (
    <Status kind={r.kind} glyph={r.glyph}>
      {rung}
    </Status>
  );
}

function Limits({ team, onApplied }: { team: AdminTeam; onApplied: () => void }): JSX.Element {
  const { admin, role, notify } = useConsole();
  const [why, setWhy] = useState<string | null>(null);
  const [form, setForm] = useState<Record<string, string> | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [done, setDone] = useState<Done | null>(null);
  const own = team as unknown as Record<string, unknown>;
  const ladder = new Map<string, LadderValue>((team.effective ?? []).map((e) => [e.field, e]));
  const limits = LIMITS.filter((l) => !l.platformOnly || role === "platform_admin" || own[l.field] !== undefined);
  const editable = limits.filter((l) => !l.platformOnly || role === "platform_admin");

  const asked: Record<string, unknown> = {};
  if (form) for (const l of editable) asked[l.field] = fromForm(l, form[l.field] ?? "");
  const before = Object.fromEntries(editable.map((l) => [l.field, own[l.field] ?? null]));
  const lines = form ? changed(before, asked) : [];
  const erasesSooner = lines.some((l) => l.field === "erase_after_days" && l.to !== null && (l.from === null || Number(l.to) < Number(l.from)));

  return (
    <section className="tab">
      <p className="lead">Every limit says what is in force and which rung decided it. A team may narrow what the platform allows, never widen it.</p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      {!form && (
        <div className="limits">
          {limits.map((l) => {
            const laddered = ladder.get(l.field);
            const inForce = laddered ? laddered.value : own[l.field];
            return (
              <div key={l.field} className="limit">
                <span className="name">{l.label}</span>
                <span className="value mono">{valueWords(l, inForce)}</span>
                {laddered ? <DecidedBy rung={laddered.decided_by} /> : <DecidedBy rung={own[l.field] === null || own[l.field] === undefined ? "unset" : "team"} />}
                {laddered && (
                  <button type="button" className="link" aria-expanded={why === l.field} onClick={() => setWhy(why === l.field ? null : l.field)}>
                    Why?
                  </button>
                )}
                {laddered && why === l.field && <Ladder limit={l} value={laddered} />}
              </div>
            );
          })}
        </div>
      )}
      {!form && (
        <button type="button" onClick={() => setForm(Object.fromEntries(editable.map((l) => [l.field, toForm(l, own[l.field])])))}>
          Change {team.name}'s limits
        </button>
      )}
      {form && !previewing && (
        <form
          className="edit grid"
          onSubmit={(e) => {
            e.preventDefault();
            setPreviewing(true);
          }}
        >
          {editable.map((l) => (
            <Field key={l.field} label={l.label} hint={hintFor(l, ladder.get(l.field))}>
              {(p) => <LimitField limit={l} value={form[l.field] ?? ""} onChange={(v) => setForm({ ...form, [l.field]: v })} control={p} />}
            </Field>
          ))}
          <div className="actions">
            <button type="submit" className="primary" disabled={lines.length === 0}>
              Preview
            </button>
            <button type="button" onClick={() => setForm(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}
      {form && previewing && (
        <Preview
          title={`team/${team.name}`}
          lines={lines.map((l) => ({ ...l, from: valueWords(limitOf(l.field), l.from), to: valueWords(limitOf(l.field), l.to) }))}
          effects={lines.map((l) => consequence(team.name, l, ladder.get(l.field)))}
          verb="Apply"
          typeToConfirm={erasesSooner ? team.name : null}
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            const changes = Object.fromEntries(lines.map((l) => [l.field, l.to]));
            const answer = await admin.updateTeam(team.name, changes);
            setForm(null);
            setPreviewing(false);
            setDone({ action: "team.update", subject: team.name, detail: answer.changes });
            notify(`${team.name}'s limits are applied.`);
            onApplied();
          }}
        />
      )}
    </section>
  );
}

function limitOf(field: string): Limit {
  return LIMITS.find((l) => l.field === field)!;
}

/** What a limit's field says beside it: its unit, and the ceiling the rungs above allow. */
function hintFor(limit: Limit, laddered: LadderValue | undefined): string | undefined {
  const unit = limit.kind === "money" ? "In currency units; 0 is no ceiling." : limit.kind === "seconds" ? "In seconds." : limit.kind === "days" ? "In days." : "";
  const ceiling = laddered ? `The platform allows at most ${valueWords(limit, laddered.ceiling)}.` : "";
  return [unit, ceiling].filter(Boolean).join(" ") || undefined;
}

/** The ladder for one value: every rung that had an opinion, and the one in force. */
function Ladder({ limit, value }: { limit: Limit; value: LadderValue }): JSX.Element {
  return (
    <div className="ladder" role="region" aria-label={`Why ${limit.label.toLowerCase()} is ${valueWords(limit, value.value)}`}>
      <ol>
        {value.opinions.map((o) => (
          <li key={o.rung}>
            <span className="rung">{o.rung}</span>
            <span className="mono">{valueWords(limit, o.value)}</span>
          </li>
        ))}
        <li className="in-force">
          <span className="rung">in force</span>
          <span className="mono">{valueWords(limit, value.value)}</span>
        </li>
      </ol>
      <p>The narrowest opinion wins: a team can tighten what the platform allows, never loosen it.</p>
    </div>
  );
}

function toForm(limit: Limit, value: unknown): string {
  if (value === null || value === undefined) return "";
  if (limit.kind === "money") return String(Number(value) / 1_000_000);
  return String(value);
}

function fromForm(limit: Limit, text: string): unknown {
  const t = text.trim();
  if (limit.kind === "switch") return t === "" ? null : t === "true";
  if (t === "") return null;
  if (limit.kind === "money") return Number.isFinite(Number(t)) ? Math.round(Number(t) * 1_000_000) : t;
  if (limit.kind === "seconds" || limit.kind === "days") return /^\d+$/.test(t) ? Number(t) : t;
  return t;
}

function LimitField({ limit, value, onChange, control }: { limit: Limit; value: string; onChange: (v: string) => void; control: FieldProps }): JSX.Element {
  if (limit.kind === "switch") {
    return (
      <select {...control} value={value} onChange={(e) => onChange(e.target.value)}>
        {value === "" && <option value="">unset</option>}
        <option value="true">yes</option>
        <option value="false">no</option>
      </select>
    );
  }
  if (limit.kind === "period") {
    const periods = ["monthly", "never"];
    return (
      <select {...control} value={value} onChange={(e) => onChange(e.target.value)}>
        {!periods.includes(value) && <option value={value}>{value || "unset"}</option>}
        <option value="monthly">monthly, from the 1st (UTC)</option>
        <option value="never">never turns over</option>
      </select>
    );
  }
  return <input {...control} value={value} onChange={(e) => onChange(e.target.value)} inputMode={limit.kind === "text" ? undefined : "decimal"} spellCheck={false} />;
}

/** What one changed limit does, in words, and whether the plane will refuse it. */
function consequence(team: string, line: DiffLine, laddered: LadderValue | undefined): string {
  const to = line.to;
  if (laddered && typeof to === "number" && typeof laddered.ceiling === "number" && to > laddered.ceiling) {
    return `The plane will refuse ${line.field}: ${to} is wider than ${laddered.ceiling}, which the rungs above the team allow.`;
  }
  if (laddered && to === true && laddered.ceiling === false) {
    return `The plane will refuse ${line.field}: the platform has it off, and a team may not turn it on.`;
  }
  switch (line.field) {
    case "budget_micros":
      return to === 0 || to === null ? `${team} has no spending ceiling.` : `${team}'s new sessions are held to a ceiling of ${money(Number(to))} a period.`;
    case "budget_period":
      return to === "never" ? "The ceiling never turns over: what is spent stays spent." : "The ceiling turns over on the 1st of each month, UTC.";
    case "idle_timeout_seconds":
      return `A ${team} session idle for ${show(to)} seconds goes dormant: it stops costing anything and wakes with its history.`;
    case "cache_eviction_days":
      return `A dormant ${team} session keeps its cache ${show(to)} days.`;
    case "erase_after_days":
      return `${team}'s sessions older than ${show(to)} days are erased. Erasure cannot be undone.`;
    case "members_may_control":
      return to ? `${team}'s members may steer a team session.` : `${team}'s members may watch a team session and no longer steer it, from their next request.`;
    case "pins_allowed":
      return to ? `${team}'s members may pin a session against eviction.` : `${team}'s members may no longer pin a session.`;
    case "volume_size":
    case "volume_storage_class":
      return `${team}'s team volume asks for ${show(to)}; one that exists already changes only as its storage class allows.`;
    case "allow_unenforced_workers":
      return to
        ? `${team} may be granted a profile whose workers run where nothing is enforced.`
        : `${team} may not; the plane refuses this while the team holds such a grant.`;
    default:
      return `${line.field} becomes ${show(to)}.`;
  }
}

// -- GitHub ------------------------------------------------------------------------------

/** One repository per line, as a team lists it: `owner/name`, or `owner/*`. */
const repositoryLines = (text: string): string[] => [...new Set(text.split(/[\s,]+/).map((r) => r.trim()).filter(Boolean))];

const capWords = (cap: number | null | undefined, what: string): string => (cap === null || cap === undefined ? "no cap of the team's" : `${cap} ${what}`);

/**
 * The repositories the team's sessions and triggers may name, and its fix loop's caps:
 * the team's own administrators', as the plane holds them. The plane's App bounds them all.
 */
function GitHub({ team, onApplied }: { team: AdminTeam; onApplied: () => void }): JSX.Element {
  const { admin, notify } = useConsole();
  const github = team.github ?? { repositories: [], max_pushes: null, max_runs: null };
  const [form, setForm] = useState<{ repositories: string; maxPushes: string; maxRuns: string } | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [done, setDone] = useState<Done | null>(null);

  const cap = (text: string): number | string | null => (text.trim() === "" ? null : /^\d+$/.test(text.trim()) ? Number(text.trim()) : text.trim());
  const asked = form ? { repositories: repositoryLines(form.repositories), max_pushes: cap(form.maxPushes), max_runs: cap(form.maxRuns) } : null;
  const lines: DiffLine[] = asked
    ? [
        ...(asked.repositories.join("\n") !== github.repositories.join("\n") ? [{ field: "github.repositories", from: github.repositories.join(", ") || "none", to: asked.repositories.join(", ") || "none" }] : []),
        ...(asked.max_pushes !== github.max_pushes ? [{ field: "github.max_pushes", from: github.max_pushes, to: asked.max_pushes }] : []),
        ...(asked.max_runs !== github.max_runs ? [{ field: "github.max_runs", from: github.max_runs, to: asked.max_runs }] : []),
      ]
    : [];
  const dropped = asked ? github.repositories.filter((r) => !asked.repositories.includes(r)) : [];

  return (
    <section className="tab">
      <p className="lead">
        The GitHub repositories {team.name}'s sessions and triggers may name, through the plane's App, and how far its unattended runs may go. A repository not listed here is refused, a session at its creation and a push at
        its token. The App's installations bound every list: a team cannot list its way to an owner the App is not installed for.
      </p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      {!form && (
        <>
          <Region>Repositories</Region>
          {github.repositories.length === 0 ? (
            <Empty title="None listed">{team.name}'s sessions name no repository until one is listed here.</Empty>
          ) : (
            <ul className="repositories">
              {github.repositories.map((r) => (
                <li key={r} className="mono">
                  {r}
                  {r.endsWith("/*") && <span className="hint"> every repository of {r.slice(0, -2)} the App reaches</span>}
                </li>
              ))}
            </ul>
          )}
          <Region>Caps</Region>
          <div className="limits">
            <div className="limit">
              <span className="name">Pushes a run may make</span>
              <span className="value mono">{capWords(github.max_pushes, "pushes")}</span>
            </div>
            <div className="limit">
              <span className="name">Runs on a repository at once</span>
              <span className="value mono">{capWords(github.max_runs, "runs")}</span>
            </div>
          </div>
          <p className="note">A worker profile may set its own caps; the lower of the two holds. A run that asks for a push past its cap stops, with a comment on its draft pull request, as three red CI rounds stop it.</p>
          <button type="button" onClick={() => setForm({ repositories: github.repositories.join("\n"), maxPushes: github.max_pushes === null ? "" : String(github.max_pushes), maxRuns: github.max_runs === null ? "" : String(github.max_runs) })}>
            Change {team.name}'s repositories
          </button>
        </>
      )}
      {form && !previewing && (
        <form
          className="edit grid"
          aria-label={`${team.name}'s GitHub repositories`}
          onSubmit={(e) => {
            e.preventDefault();
            setPreviewing(true);
          }}
        >
          <Field label="Repositories" hint="One per line: owner/name, or owner/* for every repository of the owner.">
            {(p) => <textarea {...p} value={form.repositories} onChange={(e) => setForm({ ...form, repositories: e.target.value })} rows={5} spellCheck={false} />}
          </Field>
          <Field label="Pushes a run may make" hint="1 to 1000. Empty is no cap of the team's.">
            {(p) => <input {...p} value={form.maxPushes} onChange={(e) => setForm({ ...form, maxPushes: e.target.value })} inputMode="numeric" />}
          </Field>
          <Field label="Runs on a repository at once" hint="1 to 1000, across the team's triggers; a firing over it is skipped. Empty is no cap of the team's.">
            {(p) => <input {...p} value={form.maxRuns} onChange={(e) => setForm({ ...form, maxRuns: e.target.value })} inputMode="numeric" />}
          </Field>
          <div className="actions">
            <button type="submit" className="primary" disabled={lines.length === 0}>
              Preview
            </button>
            <button type="button" onClick={() => setForm(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}
      {form && previewing && asked && (
        <Preview
          title={`team/${team.name}`}
          lines={lines}
          effects={[
            ...(dropped.length ? [`${team.name}'s sessions on ${dropped.join(", ")} get no new token from now: their next clone, push or pull request is refused.`] : []),
            ...(asked.repositories.length === 0 ? [`${team.name}'s sessions name no repository.`] : []),
            ...lines.filter((l) => l.field !== "github.repositories").map((l) => `${l.field} becomes ${l.to === null ? "no cap of the team's" : show(l.to)}.`),
          ]}
          verb="Apply"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            const answer = await admin.updateTeam(team.name, { github: asked });
            setForm(null);
            setPreviewing(false);
            setDone({ action: "team.update", subject: team.name, detail: answer.changes });
            notify(`${team.name}'s GitHub repositories are applied.`);
            onApplied();
          }}
        />
      )}
    </section>
  );
}

// -- danger zone -------------------------------------------------------------------------

function Danger({ team }: { team: AdminTeam }): JSX.Element {
  const { admin, me, notify } = useConsole();
  const [load, reload] = useLoad(() => admin.disableTeamPreview(team.name), [admin, team.name]);
  const [previewing, setPreviewing] = useState(false);
  const [done, setDone] = useState<Done | null>(null);

  if (done) {
    // The team is gone, so its page is not read again: what was done stays on the screen.
    return (
      <section className="tab danger">
        <AuditNote action={done.action} subject={done.subject} detail={done.detail} />
        <p>
          {team.name} is no longer a team. <a href={href({ page: "teams" })}>All teams</a>
        </p>
      </section>
    );
  }

  return (
    <section className="tab danger">
      <p className="lead">Removing {team.name} stops it being a team. Its people stay people, its groups stay groups, and its sessions stay, with no team.</p>
      <Loaded load={load} what="what removing it would take" retry={reload}>
        {(effect) => (
          <>
            <div className="card">
              <Region tone="waiting">What removing it would take</Region>
              <ul className="effects">
                {disableWords(effect).map((w) => (
                  <li key={w}>{w}</li>
                ))}
              </ul>
            </div>
            {!previewing && (
              <button type="button" className="danger" onClick={() => setPreviewing(true)}>
                Remove {team.name}
              </button>
            )}
            {previewing && (
              <Preview
                title={`team/${team.name}`}
                lines={[{ field: "team", from: team.name, to: null }]}
                effects={[...disableWords(effect), "It cannot be undone: enabling the group again makes a new team, with none of this one's grants, administrators, principals or triggers."]}
                verb={`Remove ${team.name}`}
                typeToConfirm={effect.confirm || team.name}
                onCancel={() => setPreviewing(false)}
                onConfirm={async () => {
                  await admin.disableTeam(team.name);
                  setDone({ action: "team.disable", subject: team.name, detail: await recorded(admin, me.subject, "team.disable", team.name) });
                  notify(`${team.name} is removed.`);
                }}
              />
            )}
          </>
        )}
      </Loaded>
    </section>
  );
}

function disableWords(effect: TeamDisableEffect): string[] {
  return [
    effect.grants.length ? `Grants revoked: ${effect.grants.join(", ")}, and their sessions turned read-only.` : "No grant to revoke.",
    effect.groups.length ? `Group links removed: ${effect.groups.join(", ")}.` : "No group link.",
    `${effect.members} ${effect.members === 1 ? "person loses" : "people lose"} this team.`,
    effect.admins.length ? `Administrators removed: ${effect.admins.join(", ")}.` : "No team admin.",
    effect.principals.length ? `Service principals removed: ${effect.principals.join(", ")}.` : "No service principal.",
    effect.triggers.length ? `Triggers removed: ${effect.triggers.join(", ")}.` : "No trigger.",
    `${effect.sessions_kept} ${effect.sessions_kept === 1 ? "session is" : "sessions are"} kept, with no team.`,
  ];
}
