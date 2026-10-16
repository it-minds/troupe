// Identity: who administers the platform, the people and groups the identity provider
// sends, and the credentials that are not people.
//
// Membership is the provider's answer and is read here, never written: Troupe having a way
// to edit it would be a second source of truth for who is in a team. What a platform admin
// sees is the check that matters before the admin group is changed (how many people would
// administer this afterwards, and are you one), the groups this plane has actually seen,
// and the people and groups that look held twice: the same email or name under two keys,
// with the mismatch at the provider that most likely made them so. Nothing merges them on
// that evidence; the plane says what to make agree, and the person fixes it there.
//
// Service principals are a team's: a team admin makes, rotates and disables their own
// team's, a platform admin anybody's. A secret is in the answer to making and rotating one
// and in no other, so it is shown once with a way to copy it. Rotating and disabling are
// typed by the principal's subject: either stops whatever is using it at once.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminGroup, AdminTeam, IdentityCheckResult, IdentityDuplicates, LookalikePerson, ServicePrincipal } from "@troupe/client";
import { show, useConsole, useLoad } from "../console";
import { href } from "../route";
import { AuditNote, Checks, Empty, Field, Loaded, Preview, Region, ShownOnce, Status, useChange, when } from "./bits";
import { Twice } from "./Teams";

export function Identity(): JSX.Element {
  const { role } = useConsole();
  const platform = role === "platform_admin";
  return (
    <div className="page">
      <p className="lead">
        Where people come from, and every credential that is not a person. Membership is the identity provider's answer and is read-only here: a person is in a
        team because they are in one of its groups there.
      </p>
      {platform && <WhoAdministers />}
      {platform && <LooksTwice />}
      {platform && <GroupsSeen />}
      <Principals />
    </div>
  );
}

// -- who administers ---------------------------------------------------------------------

function WhoAdministers(): JSX.Element {
  const { admin } = useConsole();
  const [group, setGroup] = useState("");
  const [asked, setAsked] = useState<string | null>(null);
  const [load, reload] = useLoad(() => admin.identityCheck(asked ?? undefined), [admin, asked]);
  return (
    <section aria-label="Who administers this platform">
      <Region>Who administers this platform</Region>
      <p className="note">
        Not whether a group is valid, but how many people would administer this platform afterwards, and whether you are one: the plane asks its own record of who
        has arrived carrying the group. The group itself is saved on <a href={href({ page: "policy" })}>Policy and settings</a>, behind this same check.
      </p>
      <form
        className="toolbar"
        onSubmit={(e) => {
          e.preventDefault();
          setAsked(group.trim() === "" ? null : group.trim());
        }}
      >
        <Field label="Group" hint="As the provider spells it in the groups claim. Empty asks about the one set now.">
          {(p) => <input {...p} value={group} onChange={(e) => setGroup(e.target.value)} autoComplete="off" spellCheck={false} />}
        </Field>
        <div className="actions">
          <button type="submit">Run the check</button>
        </div>
      </form>
      <Loaded load={load} what="the identity check" retry={reload}>
        {(check: IdentityCheckResult) => (
          <div role="status" aria-label="The identity check">
            <p>
              For <code>{check.group ?? "no group"}</code>:
            </p>
            <Checks checks={check.checks} />
            <p className="note">
              The redirect this plane's own sign-in sends is <code>{check.redirect_uri ?? "unknown"}</code>. No check can prove the provider has it registered: if a
              sign-in comes back with an error, compare it with the registration.
            </p>
          </div>
        )}
      </Loaded>
    </section>
  );
}

// -- held twice --------------------------------------------------------------------------

function LooksTwice(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.identityDuplicates(), [admin]);
  return (
    <section aria-label="People and groups that look held twice">
      <Region tone="waiting">Looks held twice</Region>
      <Loaded load={load} what="the people and groups that look held twice" retry={reload}>
        {(d: IdentityDuplicates) =>
          d.people.length === 0 && d.groups.length === 0 ? (
            <Empty title="Nothing looks held twice">No two people share an email or a name, and no two groups a name, under different keys.</Empty>
          ) : (
            <>
              <p className="note">
                The same email or name under two keys. Nothing is merged on that: only the provider knows whether they are one. Each says what most likely made it,
                which is changed at the provider; the next sign-in or push settles it.
              </p>
              {d.people.map((set, i) => (
                <div className="card" key={`p${i}`} aria-label={`People sharing ${set.by.replace("_", " ")}`}>
                  <header>
                    <h3>{peopleTitle(set.by, set.people)}</h3>
                  </header>
                  <PeopleTable people={set.people} />
                  <p>Most likely {set.likely}.</p>
                  <Extra set={set} known={["by", "people", "likely"]} />
                </div>
              ))}
              {d.groups.map((set, i) => (
                <div className="card" key={`g${i}`} aria-label={`Groups sharing ${set.by.replace("_", " ")}`}>
                  <header>
                    <h3>
                      {set.groups.length} groups share the name {set.groups[0]?.display_name ?? "—"}
                    </h3>
                  </header>
                  <ul className="plain">
                    {set.groups.map((g) => (
                      <li key={g.external_id} className="mono">
                        {g.external_id}
                      </li>
                    ))}
                  </ul>
                  <p>Most likely {set.likely}.</p>
                  <Extra set={set} known={["by", "groups", "likely"]} />
                </div>
              ))}
            </>
          )
        }
      </Loaded>
    </section>
  );
}

function sharedValue(by: string, people: LookalikePerson[]): string {
  const v = people[0]?.[by];
  return typeof v === "string" ? v : "—";
}

/**
 * What a set of people has in common, as its heading: an email or a name two rows share,
 * or an externalId a sign-in or a push was refused adoption on, which may be one row.
 */
function peopleTitle(by: string, people: LookalikePerson[]): string {
  const value = sharedValue(by, people);
  if (by === "external_id") return `Not merged on externalId ${value}`;
  const what = by === "email" ? "an email" : by === "display_name" ? "a name" : by.replace(/_/g, " ");
  return `${people.length} people share ${what}: ${value}`;
}

function PeopleTable({ people }: { people: LookalikePerson[] }): JSX.Element {
  return (
    <div className="scroll">
      <table>
        <thead>
          <tr>
            <th>Arrived by</th>
            <th>Subject</th>
            <th>externalId</th>
            <th>userName</th>
            <th>Email</th>
            <th>Name</th>
          </tr>
        </thead>
        <tbody>
          {people.map((p) => (
            <tr key={p.subject}>
              <td>{p.origin}</td>
              <td className="mono">{p.subject}</td>
              <td className="mono">{show(p.external_id)}</td>
              <td className="mono">{show(p.user_name)}</td>
              <td>{show(p.email)}</td>
              <td>{show(p.display_name)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Whatever else the plane says about a set (why it refused to adopt one, say), as it says it. */
function Extra({ set, known }: { set: Record<string, unknown>; known: string[] }): JSX.Element | null {
  const rest = Object.entries(set).filter(([k, v]) => !known.includes(k) && v !== null && v !== undefined && v !== "");
  if (rest.length === 0) return null;
  return (
    <ul className="detail">
      {rest.map(([k, v]) => (
        <li key={k}>
          <code>{k}</code> <span className="to">{show(v)}</span>
        </li>
      ))}
    </ul>
  );
}

// -- groups ------------------------------------------------------------------------------

function GroupsSeen(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => Promise.all([admin.groups(), admin.teams()]), [admin]);
  return (
    <section aria-label="Groups this plane has seen">
      <Region>Groups this plane has seen</Region>
      <p className="note">
        Mirrored, never authored: what SCIM pushed, or what somebody's groups claim brought in at sign-in. A group absent here is one nobody has arrived from, and a
        team cannot draw on it yet.
      </p>
      <Loaded load={load} what="the groups" retry={reload}>
        {([groups, teams]: [AdminGroup[], AdminTeam[]]) =>
          groups.length === 0 ? (
            <Empty title="No group has been seen">Nobody has signed in, or the groups claim is not the one this plane reads.</Empty>
          ) : (
            <div className="scroll">
              <table>
                <thead>
                  <tr>
                    <th>Group</th>
                    <th>Id at the provider</th>
                    <th>Drawn on by</th>
                  </tr>
                </thead>
                <tbody>
                  {groups.map((g) => {
                    const drawing = teams.filter((t) => t.groups.some((x) => x.external_id === g.external_id)).map((t) => t.name);
                    return (
                      <tr key={g.external_id}>
                        <td>
                          {g.display_name ?? "—"}
                          {g.looks_duplicated && (
                            <>
                              {" "}
                              <Status kind="waiting" glyph="◆">
                                looks held twice
                              </Status>
                              <Twice group={g} />
                            </>
                          )}
                        </td>
                        <td className="mono">{g.external_id}</td>
                        <td>{drawing.length ? drawing.join(", ") : <span className="muted">no team</span>}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )
        }
      </Loaded>
    </section>
  );
}

// -- service principals ------------------------------------------------------------------

function Principals(): JSX.Element {
  const { admin, role } = useConsole();
  const [teams, reloadTeams] = useLoad(() => admin.teams(), [admin]);
  const [chosen, setChosen] = useState<string | null>(null);
  return (
    <section aria-label="Service principals">
      <Region>Service principals</Region>
      <p className="note">
        Credentials a team owns, for triggers and other work nobody starts by hand. Each names a person in the team, its sponsor, answerable for what it does: if they
        leave, it stops and says it needs a sponsor, which is a field to fill in rather than a fault.
      </p>
      <Loaded load={teams} what="the teams" retry={reloadTeams}>
        {(all) => {
          if (all.length === 0) return <Empty title="No team">{role === "platform_admin" ? "A principal belongs to a team; enable a group as a team first." : "You administer no team."}</Empty>;
          const shown = all.find((t) => t.name === chosen) ?? all[0]!;
          return (
            <>
              {all.length > 1 && (
                <div className="toolbar">
                  <Field label="Team">
                    {(p) => (
                      <select {...p} value={shown.name} onChange={(e) => setChosen(e.target.value)}>
                        {all.map((t) => (
                          <option key={t.name} value={t.name}>
                            {t.name}
                          </option>
                        ))}
                      </select>
                    )}
                  </Field>
                </div>
              )}
              <TeamPrincipals team={shown} key={shown.name} />
            </>
          );
        }}
      </Loaded>
    </section>
  );
}

function stateOf(p: ServicePrincipal): JSX.Element {
  if (p.state === "needs_sponsor") {
    return (
      <Status kind="waiting" glyph="◆">
        needs a sponsor
      </Status>
    );
  }
  if (p.state === "disabled" || (!p.enabled && !p.state)) {
    return (
      <Status kind="muted" glyph="○">
        disabled
      </Status>
    );
  }
  return (
    <Status kind="running" glyph="●">
      works
    </Status>
  );
}

function TeamPrincipals({ team }: { team: AdminTeam }): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.principals(team.name), [admin, team.name]);
  const { done, clear, apply } = useChange(reload);
  const [secret, setSecret] = useState<{ subject: string; value: string } | null>(null);
  const [making, setMaking] = useState(false);
  const [acting, setActing] = useState<{ kind: "rotate" | "disable"; principal: ServicePrincipal } | null>(null);
  const busy = making || acting !== null;

  return (
    <div className="team-principals">
      {secret && (
        <ShownOnce label={`${secret.subject}'s secret`} value={secret.value}>
          <p className="note">Give it to whatever runs as {secret.subject}; it signs in with the subject and this secret.</p>
        </ShownOnce>
      )}
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Loaded load={load} what={`${team.name}'s service principals`} retry={reload}>
        {(principals) =>
          principals.length === 0 ? (
            <Empty title="No service principal">{team.name} has none yet. A trigger that fires unattended runs as one.</Empty>
          ) : (
            <div className="scroll">
              <table>
                <thead>
                  <tr>
                    <th>Principal</th>
                    <th>State</th>
                    <th>May use</th>
                    <th>Sponsor</th>
                    <th>Last used</th>
                    <th aria-label="Actions" />
                  </tr>
                </thead>
                <tbody>
                  {principals.map((p) => (
                    <tr key={p.subject}>
                      <td>
                        <span className="mono">{p.subject}</span>
                        {p.description && <span className="hint"> {p.description}</span>}
                      </td>
                      <td>{stateOf(p)}</td>
                      <td>{p.profiles.join(", ") || "—"}</td>
                      <td>{show(p.sponsor)}</td>
                      <td>{p.last_used_at ? when(p.last_used_at) : "never"}</td>
                      <td className="row-actions">
                        {!busy && p.state !== "disabled" && p.enabled !== false && (
                          <>
                            <button type="button" onClick={() => setActing({ kind: "rotate", principal: p })}>
                              Rotate
                            </button>
                            <button type="button" className="danger" onClick={() => setActing({ kind: "disable", principal: p })}>
                              Disable
                            </button>
                          </>
                        )}
                        {!busy && p.state === "needs_sponsor" && (
                          <button type="button" className="danger" onClick={() => setActing({ kind: "disable", principal: p })}>
                            Disable
                          </button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        }
      </Loaded>
      {acting && (
        <Preview
          title={`principal/${acting.principal.subject}`}
          lines={
            acting.kind === "rotate"
              ? [{ field: "secret", from: "the one in use", to: "a new one, shown once" }]
              : [{ field: "enabled", from: true, to: false }]
          }
          effects={
            acting.kind === "rotate"
              ? [
                  "The secret in use stops working the moment the new one is made: anything still using it is refused until it is given the new one.",
                  "The new secret is shown once, here.",
                ]
              : [`${acting.principal.subject}'s next call is refused, and a trigger that runs as it stops firing.`, "Its sessions are kept."]
          }
          verb={acting.kind === "rotate" ? "Rotate" : "Disable"}
          typeToConfirm={acting.principal.subject}
          onCancel={() => setActing(null)}
          onConfirm={async () => {
            const subject = acting.principal.subject;
            if (acting.kind === "rotate") {
              await apply("principal.rotate", subject, async () => {
                const answer = await admin.rotatePrincipal(subject);
                if (answer.secret) setSecret({ subject, value: answer.secret });
                return answer;
              }, `${subject} has a new secret.`);
            } else {
              setSecret(null);
              await apply("principal.disable", subject, () => admin.disablePrincipal(subject), `${subject} is disabled.`);
            }
            setActing(null);
          }}
        />
      )}
      {!busy && (
        <button
          type="button"
          onClick={() => {
            clear();
            setSecret(null);
            setMaking(true);
          }}
        >
          Make a principal for {team.name}
        </button>
      )}
      {making && (
        <MakePrincipal
          team={team}
          onCancel={() => setMaking(false)}
          onConfirm={async (principal) => {
            await apply("principal.create", `svc:${team.name}/${principal.name}`, async () => {
              const answer = await admin.createPrincipal(team.name, principal);
              if (answer.secret) setSecret({ subject: answer.subject, value: answer.secret });
              return answer;
            }, `svc:${team.name}/${principal.name} is a principal of ${team.name}.`);
            setMaking(false);
          }}
        />
      )}
    </div>
  );
}

/** A principal's name, as the plane holds it: a label that becomes part of its subject. */
const PRINCIPAL = /^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$/;

function MakePrincipal({
  team,
  onCancel,
  onConfirm,
}: {
  team: AdminTeam;
  onCancel: () => void;
  onConfirm: (principal: { name: string; description?: string; profiles: string[]; sponsor: string }) => Promise<void>;
}): JSX.Element {
  const { me } = useConsole();
  const granted = team.grants.map((g) => g.profile);
  const members = team.members.map((m) => m.subject);
  const [form, setForm] = useState({ name: "", description: "", profiles: [] as string[], sponsor: members.includes(me.subject) ? me.subject : "" });
  const [previewing, setPreviewing] = useState(false);
  const name = form.name.trim();
  const nameProblem = name !== "" && !PRINCIPAL.test(name) ? "Lowercase letters, digits and dashes, starting and ending with a letter or digit." : null;
  const ready = name !== "" && !nameProblem && form.profiles.length > 0 && form.sponsor !== "";
  const principal = { name, profiles: form.profiles, sponsor: form.sponsor, ...(form.description.trim() ? { description: form.description.trim() } : {}) };

  if (previewing) {
    return (
      <Preview
        title={`principal/svc:${team.name}/${name}`}
        lines={[
          { field: "subject", from: null, to: `svc:${team.name}/${name}` },
          { field: "profiles", from: null, to: form.profiles },
          { field: "sponsor", from: null, to: form.sponsor },
        ]}
        effects={[
          `It may start sessions on ${form.profiles.join(", ")}, which spend ${team.name}'s budget with nobody watching.`,
          `${form.sponsor} is answerable for what it does; if they leave ${team.name}, it stops until it has a sponsor again.`,
          "Its secret is shown once, when it is made.",
        ]}
        verb="Make it"
        onCancel={() => setPreviewing(false)}
        onConfirm={() => onConfirm(principal)}
      />
    );
  }

  return (
    <form
      className="edit grid"
      aria-label={`A principal for ${team.name}`}
      onSubmit={(e) => {
        e.preventDefault();
        if (ready) setPreviewing(true);
      }}
    >
      <Field label="Name" hint={`Its subject is svc:${team.name}/<name>.`} error={nameProblem}>
        {(p) => <input {...p} value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="What it is for" hint="A sentence, for whoever reads the list later.">
        {(p) => <input {...p} value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} />}
      </Field>
      <fieldset className="field">
        <legend>May use</legend>
        {granted.length === 0 ? (
          <p className="hint">{team.name} is granted no profile, so a principal of it could start nothing. Grant one on the team's Access tab first.</p>
        ) : (
          granted.map((g) => (
            <label key={g}>
              <input
                type="checkbox"
                checked={form.profiles.includes(g)}
                onChange={(e) => setForm({ ...form, profiles: e.target.checked ? [...form.profiles, g] : form.profiles.filter((x) => x !== g) })}
              />{" "}
              {g}
            </label>
          ))
        )}
      </fieldset>
      <Field label="Sponsor" hint={`A person in ${team.name}, answerable for what it does.`}>
        {(p) => (
          <select {...p} value={form.sponsor} onChange={(e) => setForm({ ...form, sponsor: e.target.value })}>
            <option value="">choose a person</option>
            {team.members.map((m) => (
              <option key={m.subject} value={m.subject}>
                {m.display_name ? `${m.display_name} (${m.subject})` : m.subject}
              </option>
            ))}
          </select>
        )}
      </Field>
      <div className="actions">
        <button type="submit" className="primary" disabled={!ready}>
          Preview
        </button>
        <button type="button" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  );
}

