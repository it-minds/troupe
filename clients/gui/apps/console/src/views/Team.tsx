// One team, in five tabs: who is in it and from which groups, which profiles it may use,
// who administers it, its limits, and what removing it would take with it.
//
// Every tab reads. Limits also changes: each value says what is in force and which rung
// of the ladder decided it, and an edit is previewed, field by field and in words, before
// it is sent. The other changes a tab will offer (linking a group, granting and revoking
// a profile, naming an administrator, removing the team) are in the plane's current
// console until this one has them, and each tab says so.
//
// The plane has no read of one team: `admin.teams.list` is the read, and a team a team
// admin does not administer is not in their answer, so it is "not found" here as it is
// at the plane.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminTeam, LadderValue, TeamUpdated } from "@troupe/client";
import { currentConsole } from "../plane";
import { TEAM_TABS, href } from "../route";
import type { TeamTab } from "../route";
import { show, useConsole, useLoad } from "../console";
import { AuditNote, Empty, Loaded, Preview, Region, Status, changed, money } from "./bits";
import type { DiffLine } from "./bits";
import { Spend } from "./Teams";

const TAB_LABELS: Record<TeamTab, string> = {
  members: "Members and groups",
  access: "Access",
  admins: "Admins",
  limits: "Limits",
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
              {tab === "members" && <Members team={team} />}
              {tab === "access" && <Access team={team} />}
              {tab === "admins" && <Admins team={team} />}
              {tab === "limits" && <Limits team={team} onApplied={reload} />}
              {tab === "danger" && role === "platform_admin" && <Danger team={team} />}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

/** Where a change a tab does not offer yet is made for now. */
function Elsewhere({ what }: { what: string }): JSX.Element {
  const { plane } = useConsole();
  return (
    <p className="note">
      {what} comes to this console next; for now it is on the <a href={currentConsole(plane.url, "/teams")}>current console's Teams page</a>.
    </p>
  );
}

function Members({ team }: { team: AdminTeam }): JSX.Element {
  const { role } = useConsole();
  return (
    <section className="tab">
      <p className="lead">
        Membership is the identity provider's: a person is in {team.name} because they are in one of its groups. Nothing here adds or removes a person.
      </p>
      <Region>Groups</Region>
      {team.groups.length === 0 ? (
        <Empty title="No group linked">Nobody can be in this team until a group is linked to it.</Empty>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Group</th>
              <th>Id at the provider</th>
              <th>Linked by</th>
            </tr>
          </thead>
          <tbody>
            {team.groups.map((g) => (
              <tr key={g.external_id}>
                <td>{g.display_name ?? g.external_id}</td>
                <td className="mono">{g.external_id}</td>
                <td>{g.linked_by ?? "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <Region>People</Region>
      {team.members.length === 0 ? (
        <Empty title="Nobody yet">A person appears here once they are in a linked group, at their next sign-in or the provider's next push.</Empty>
      ) : (
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
      )}
      {role === "platform_admin" && <Elsewhere what="Linking and unlinking a group, with a preview of who joins and who leaves," />}
    </section>
  );
}

function Access({ team }: { team: AdminTeam }): JSX.Element {
  return (
    <section className="tab">
      <p className="lead">
        A profile grant is the only way {team.name} gains reach. Revoking one turns every {team.name} session on that profile read-only the moment it
        lands.
      </p>
      {team.grants.length === 0 ? (
        <Empty title="No profile granted">This team can start no session until a platform admin grants it a profile.</Empty>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Profile</th>
              <th>Team volume</th>
            </tr>
          </thead>
          <tbody>
            {team.grants.map((g) => (
              <tr key={g.profile}>
                <td>{g.profile}</td>
                <td>{g.volume_mode ?? <span className="muted">none</span>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <Elsewhere what="Granting a profile, and revoking one behind a warning of the sessions it turns read-only," />
    </section>
  );
}

function Admins({ team }: { team: AdminTeam }): JSX.Element {
  return (
    <section className="tab">
      <p className="lead">Who may administer {team.name}: change its limits and see its sessions, its members and its spend. Platform admins may as well.</p>
      {team.admins.length === 0 ? (
        <Empty title="No team admin">Only platform admins administer this team.</Empty>
      ) : (
        <ul className="plain">
          {team.admins.map((a) => (
            <li key={a} className="mono">
              {a}
            </li>
          ))}
        </ul>
      )}
      <Elsewhere what="Naming an administrator, and removing one behind a confirmation of what they lose," />
    </section>
  );
}

// -- limits ------------------------------------------------------------------------------

type Field = "budget_micros" | "budget_period" | "idle_timeout_seconds" | "cache_eviction_days" | "erase_after_days" | "members_may_control" | "pins_allowed" | "volume_size" | "volume_storage_class" | "allow_unenforced_workers";

interface Limit {
  field: Field;
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
  const [done, setDone] = useState<TeamUpdated | null>(null);
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
      {done && <AuditNote action="team.update" subject={team.name} changes={done.changes} />}
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
            <label key={l.field}>
              {l.label}
              <LimitField limit={l} value={form[l.field] ?? ""} onChange={(v) => setForm({ ...form, [l.field]: v })} />
              {ladder.get(l.field) && <span className="hint">The platform allows at most {valueWords(l, ladder.get(l.field)!.ceiling)}.</span>}
            </label>
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
            setDone(answer);
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

function LimitField({ limit, value, onChange }: { limit: Limit; value: string; onChange: (v: string) => void }): JSX.Element {
  if (limit.kind === "switch") {
    return (
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {value === "" && <option value="">unset</option>}
        <option value="true">yes</option>
        <option value="false">no</option>
      </select>
    );
  }
  if (limit.kind === "period") {
    const periods = ["monthly", "never"];
    return (
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        {!periods.includes(value) && <option value={value}>{value || "unset"}</option>}
        <option value="monthly">monthly, from the 1st (UTC)</option>
        <option value="never">never turns over</option>
      </select>
    );
  }
  const unit = limit.kind === "money" ? "in currency units; 0 is no ceiling" : limit.kind === "seconds" ? "seconds" : limit.kind === "days" ? "days" : "";
  return <input value={value} onChange={(e) => onChange(e.target.value)} placeholder={unit} spellCheck={false} />;
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

// -- danger zone -------------------------------------------------------------------------

function Danger({ team }: { team: AdminTeam }): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.disableTeamPreview(team.name), [admin, team.name]);
  return (
    <section className="tab danger">
      <p className="lead">Removing {team.name} stops it being a team. Its people stay people, its groups stay groups, and its sessions stay, with no team.</p>
      <Loaded load={load} what="what removing it would take" retry={reload}>
        {(effect) => (
          <div className="card">
            <Region tone="waiting">What removing it would take</Region>
            <ul className="effects">
              <li>{effect.grants.length ? `Grants revoked: ${effect.grants.join(", ")}, and their sessions turned read-only.` : "No grant to revoke."}</li>
              <li>{effect.groups.length ? `Group links removed: ${effect.groups.join(", ")}.` : "No group link."}</li>
              <li>
                {effect.members} {effect.members === 1 ? "person loses" : "people lose"} this team.
              </li>
              <li>{effect.admins.length ? `Administrators removed: ${effect.admins.join(", ")}.` : "No team admin."}</li>
              <li>{effect.principals.length ? `Service principals removed: ${effect.principals.join(", ")}.` : "No service principal."}</li>
              <li>{effect.triggers.length ? `Triggers removed: ${effect.triggers.join(", ")}.` : "No trigger."}</li>
              <li>
                {effect.sessions_kept} {effect.sessions_kept === 1 ? "session is" : "sessions are"} kept, with no team.
              </li>
            </ul>
          </div>
        )}
      </Loaded>
      <Elsewhere what={`Removing ${team.name}, confirmed by typing its name,`} />
    </section>
  );
}
