// Triggers: a team's list, a trigger read whole, and making, changing, pausing and
// deleting one.
//
// A trigger fires a session unattended, on a schedule, from a webhook or by hand, as one of
// its team's service principals. The list is per team: a platform admin picks any team, a
// team admin their own, as the plane answers each. A trigger's page reads every field the
// plane keeps of it, and every revision of its document with what each one said.
//
// A new trigger, a change, a pause and a resume are each previewed, field by field, and
// confirmed plainly, since each can be changed back; deleting one takes its runs with it
// and is confirmed by typing its name. A change sends only the fields that moved, as the
// plane takes a put on an existing trigger, so a field this form does not show (its terms,
// who is told) is left as it is. Each is shown as the audit recorded it. On a plane in
// `gitops` mode the triggers are resources a repository holds: shown locked, with where
// they come from, and nothing offers a write. A new webhook trigger is made with its key,
// which is shown once, with a button that copies it; a trigger on a GitHub repository is
// fired by the App's signed deliveries and has none. Running one by hand and rotating a key
// are in the current console for now.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminTeam, Trigger, TriggerPut } from "@troupe/client";
import { currentConsole } from "../plane";
import { go, href } from "../route";
import { recorded, show, useConsole, useLoad } from "../console";
import { AuditNote, Empty, Field, Fields, GitopsProblem, Loaded, Locked, Preview, Region, Status, modeOf, useChange, when } from "./bits";
import type { DiffLine, Done } from "./bits";

/** The teams this person may see triggers for: every one for a platform admin, their own for a team admin. */
function useTeams(): ReturnType<typeof useLoad<AdminTeam[]>> {
  const { admin } = useConsole();
  return useLoad(() => admin.teams(), [admin]);
}

/** What fires it, in words. */
function firedBy(source: Record<string, unknown> | null): string {
  const kind = source?.["kind"];
  if (kind === "schedule") return `on a schedule: ${show(source?.["cron"])} (UTC)`;
  if (kind === "webhook" && source?.["repository"]) {
    const on = [
      source["label"] ? `an issue labelled ${String(source["label"])}` : null,
      source["command"] ? `a comment saying ${String(source["command"])}` : null,
    ].filter(Boolean);
    return `by GitHub on ${String(source["repository"])}: ${on.join(", or ") || "nothing yet"}`;
  }
  if (kind === "webhook") return `by a webhook${source?.["provider"] ? ` from ${String(source["provider"])}` : ""}`;
  if (kind === "manual") return "only by hand";
  return show(kind);
}

function TriggerState({ trigger }: { trigger: Trigger }): JSX.Element {
  if (trigger.gitops?.problem === "refused") {
    return (
      <Status kind="denied" glyph="✕">
        refused
      </Status>
    );
  }
  return trigger.enabled ? (
    <Status kind="running" glyph="●">
      on
    </Status>
  ) : (
    <Status kind="muted" glyph="○">
      paused
    </Status>
  );
}

// -- a team's list -----------------------------------------------------------------------

export function Triggers({ team }: { team: string | null }): JSX.Element {
  const { role } = useConsole();
  const [teams, reloadTeams] = useTeams();
  return (
    <div className="page">
      <p className="lead">A trigger starts a session with nobody watching: on a schedule, from a webhook, or by hand. It runs as one of its team's service principals, on a profile the team is granted.</p>
      <Loaded load={teams} what="the teams" retry={reloadTeams}>
        {(all) => {
          if (all.length === 0) return <Empty title="No team">{role === "platform_admin" ? "A trigger belongs to a team; enable a group as a team first." : "You administer no team."}</Empty>;
          const shown = team && all.some((t) => t.name === team) ? team : all[0]!.name;
          const known = team === null || all.some((t) => t.name === team);
          return (
            <>
              {all.length > 1 && (
                <div className="toolbar">
                  <Field label="Team">
                    {(p) => (
                      <select {...p} value={shown} onChange={(e) => go({ page: "triggers", path: [e.target.value] })}>
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
              {known ? (
                <TeamTriggers team={all.find((t) => t.name === shown)!} key={shown} />
              ) : (
                <Empty title={`No team called ${team}`}>
                  Or not one you administer. <a href={href({ page: "triggers" })}>Triggers</a>
                </Empty>
              )}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

function TeamTriggers({ team }: { team: AdminTeam }): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => Promise.all([admin.triggers(team.name), admin.provisioningMode().catch(() => null)]), [admin, team.name]);
  const [creating, setCreating] = useState(false);
  const [minted, setMinted] = useState<{ name: string; key: string; url: string } | null>(null);
  const { done, apply } = useChange(reload);

  return (
    <Loaded load={load} what={`${team.name}'s triggers`} retry={reload}>
      {([listed, mode]) => {
        const locked = modeOf(mode) === "gitops";
        // A gitops listing also carries resources the plane refused and has no trigger for: a name and reasons.
        const triggers = listed.filter((t) => Boolean(t.id));
        const refused = listed.filter((t) => !t.id);
        const source = listed.map((t) => t.gitops?.source).find(Boolean);
        return (
          <>
            {locked && (
              <Locked things="triggers" source={source}>
                <p className="note">Running one by hand and minting its key still work, in the current console: they are things done with a trigger, not what it is.</p>
              </Locked>
            )}
            {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
            {minted && <KeyOnce name={minted.name} secret={minted.key} url={minted.url} onDone={() => setMinted(null)} />}
            {triggers.length === 0 ? (
              <Empty title={`${team.name} has no trigger`}>{locked ? "A trigger is a manifest in the repository." : "Make one below."}</Empty>
            ) : (
              <div className="scroll">
                <table className="triggers">
                  <thead>
                    <tr>
                      <th>Trigger</th>
                      <th>State</th>
                      <th>Fired</th>
                      <th>Profile</th>
                      <th>Runs as</th>
                      <th>Last fired</th>
                    </tr>
                  </thead>
                  <tbody>
                    {triggers.map((t) => (
                      <tr key={t.name}>
                        <td>
                          <a href={href({ page: "triggers", path: [team.name, t.name] })}>{t.name}</a>
                        </td>
                        <td>
                          <TriggerState trigger={t} />
                        </td>
                        <td>{firedBy(t.source)}</td>
                        <td>{show(t.profile)}</td>
                        <td className="mono">{show(t.principal)}</td>
                        <td>{when(t.last_fired_at)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {refused.map((r) => (
              <div key={r.name} className="card">
                <header>
                  <span className="mono">{r.name}</span>
                  <Status kind="denied" glyph="✕">
                    not in use
                  </Status>
                </header>
                <GitopsProblem gitops={r.gitops} />
              </div>
            ))}
            {!locked && !creating && (
              <button type="button" onClick={() => setCreating(true)}>
                New trigger
              </button>
            )}
            {creating && (
              <TriggerForm
                team={team}
                existing={null}
                names={triggers.map((t) => t.name)}
                onCancel={() => setCreating(false)}
                onConfirm={async (changes, name) => {
                  // A webhook trigger comes back with its key, this once: kept for the panel
                  // below until the person says they have it, and nowhere else.
                  const write = async (): Promise<TriggerPut> => {
                    const answer = await admin.putTrigger({ team: team.name, name, ...changes });
                    if (answer.key) setMinted({ name, key: answer.key, url: answer.url ?? "" });
                    return answer;
                  };
                  await apply("trigger.put", `${team.name}/${name}`, write, `${name} is a trigger of ${team.name}.`, (a) => (a as { changes?: Record<string, unknown> }).changes);
                  setCreating(false);
                }}
              />
            )}
          </>
        );
      }}
    </Loaded>
  );
}

/**
 * A new webhook trigger's key, the one time the plane answers it: where to send, the key,
 * a button that copies it, and that it is not shown again. Kept on screen until the person
 * says they have it; reading the trigger again shows only that it has a key.
 */
function KeyOnce({ name, secret, url, onDone }: { name: string; secret: string; url: string; onDone: () => void }): JSX.Element {
  const { plane } = useConsole();
  const [copied, setCopied] = useState<"yes" | "no" | null>(null);
  const address = `${plane.url.replace(/\/$/, "")}${url}`;
  const copy = async () => {
    try {
      await globalThis.navigator.clipboard.writeText(secret);
      setCopied("yes");
    } catch {
      setCopied("no");
    }
  };
  return (
    <section className="card key-once" aria-label={`${name}'s webhook key`}>
      <header>
        <span>{name}'s webhook key</span>
      </header>
      <p>
        POST to <code>{address}</code> with <code>Authorization: Bearer</code> and this key. Copy it now: it is not shown again, and losing it costs a rotation.
      </p>
      <p>
        <code className="mono secret">{secret}</code>
      </p>
      <div className="actions">
        <button type="button" className="primary" onClick={() => void copy()}>
          Copy the key
        </button>
        <button type="button" onClick={onDone}>
          I have copied it
        </button>
      </div>
      {copied === "yes" && <p className="note" role="status">Copied.</p>}
      {copied === "no" && <p className="note" role="status">This browser would not copy it; select it above and copy it by hand.</p>}
    </section>
  );
}

// -- a trigger ---------------------------------------------------------------------------

export function TriggerPage({ team, name }: { team: string; name: string }): JSX.Element {
  const { admin, me, plane, notify } = useConsole();
  const [load, reload] = useLoad(
    () => Promise.all([admin.triggers(team), admin.triggerRevisions(team, name).catch(() => null), admin.provisioningMode().catch(() => null), admin.teams()]),
    [admin, team, name],
  );
  const [editing, setEditing] = useState(false);
  const [switching, setSwitching] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [gone, setGone] = useState<Done | null>(null);
  const { done, apply } = useChange(reload);

  if (gone) {
    return (
      <div className="page">
        <AuditNote action={gone.action} subject={gone.subject} detail={gone.detail} />
        <p>
          {name} is no longer a trigger of {team}. <a href={href({ page: "triggers", path: [team] })}>{team}'s triggers</a>
        </p>
      </div>
    );
  }

  return (
    <div className="page">
      <p className="team-meta">
        <a href={href({ page: "triggers", path: [team] })}>{team}'s triggers</a>
      </p>
      <Loaded load={load} what={`trigger ${name}`} retry={reload}>
        {([listed, revisions, mode, teams]) => {
          const t = listed.find((x) => x.name === name && x.id);
          const owner = teams.find((x) => x.name === team);
          if (!t || !owner) {
            return (
              <Empty title={`No trigger called ${name} in ${team}`}>
                Or not one you administer. <a href={href({ page: "triggers", path: [team] })}>{team}'s triggers</a>
              </Empty>
            );
          }
          const locked = modeOf(mode) === "gitops";
          const deletable = !locked || t.gitops?.problem === "missing";
          const busy = editing || switching || deleting;
          const terms = t.terms ?? {};
          const notifyList = Array.isArray(t.notify) ? t.notify : [];
          return (
            <>
              {locked && (
                <Locked things="triggers" source={t.gitops?.source}>
                  {t.gitops?.resource && (
                    <p className="note">
                      It comes from the resource <code>{t.gitops.resource}</code>
                      {t.gitops.generation !== null ? `, read at generation ${t.gitops.generation}` : ""}.
                    </p>
                  )}
                  <GitopsProblem gitops={t.gitops} />
                </Locked>
              )}
              {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
              <Fields
                rows={[
                  ["State", <TriggerState trigger={t} />],
                  ["Fired", firedBy(t.source)],
                  ["Runs as", <span className="mono">{show(t.principal)}</span>],
                  ["Profile", show(t.profile)],
                  ["Agent", t.agent ?? "the profile's default"],
                  ["Its sessions are seen by", t.visibility === "private" ? "the principal alone" : `${team}`],
                  ["A person reads each run", t.review === "none" || t.review === false ? "not expected" : "expected"],
                  ["Runs at once, at most", show(t.concurrency ?? 1)],
                  ["Spends, per run", Object.keys(terms).length ? Object.entries(terms).map(([k, v]) => `${k}: ${show(v)}`).join(", ") : "the defaults"],
                  ["Collaborators on each run", notifyList.length ? notifyList.join(", ") : "none"],
                  ["Its outcome is posted to", <span className="mono">{show(t.notify_url)}</span>],
                  ["Webhook key", t.has_key ? `set${t.key_rotated_at ? `, minted ${when(t.key_rotated_at)}` : ""}` : "none"],
                  ["Last fired", when(t.last_fired_at)],
                  ["Made by", show(t.created_by)],
                  ["Changed", when(t.updated_at)],
                  ["Revision", t.revision ? `${t.revision.revision} · ${t.revision.hash}` : "—"],
                ]}
              />
              <Region>What each session is asked to do</Region>
              <pre className="prompt">{t.prompt_template ?? "—"}</pre>

              {!busy && (
                <div className="actions">
                  {!locked && (
                    <>
                      <button type="button" onClick={() => setEditing(true)}>
                        Change {name}
                      </button>
                      <button type="button" onClick={() => setSwitching(true)}>
                        {t.enabled ? `Pause ${name}` : `Resume ${name}`}
                      </button>
                    </>
                  )}
                  {deletable && (
                    <button type="button" className="danger" onClick={() => setDeleting(true)}>
                      Delete {name}
                    </button>
                  )}
                </div>
              )}
              <p className="note">
                Running it now by hand, and rotating its webhook key, come to this console next; for now they are on the{" "}
                <a href={currentConsole(plane.url, `/triggers/${encodeURIComponent(team)}`)}>current console's Triggers page</a>.
              </p>
              {editing && (
                <TriggerForm
                  team={owner}
                  existing={t}
                  names={[]}
                  onCancel={() => setEditing(false)}
                  onConfirm={async (changes) => {
                    await apply("trigger.put", `${team}/${name}`, () => admin.putTrigger({ team, name, ...changes }), `${name} is changed.`, (a) => (a as { changes?: Record<string, unknown> }).changes);
                    setEditing(false);
                  }}
                />
              )}
              {switching && (
                <Preview
                  title={`trigger/${team}/${name}`}
                  lines={[{ field: "enabled", from: t.enabled, to: !t.enabled }]}
                  effects={
                    t.enabled
                      ? [`${name} stops firing, by its ${t.source?.["kind"] === "schedule" ? "schedule" : "webhook"} and by hand, until it is resumed.`, "Runs already going carry on."]
                      : [`${name} fires again ${firedBy(t.source)}.`]
                  }
                  verb={t.enabled ? `Pause ${name}` : `Resume ${name}`}
                  onCancel={() => setSwitching(false)}
                  onConfirm={async () => {
                    await apply("trigger.put", `${team}/${name}`, () => admin.putTrigger({ team, name, enabled: !t.enabled }), `${name} is ${t.enabled ? "paused" : "on again"}.`, (a) => (a as { changes?: Record<string, unknown> }).changes);
                    setSwitching(false);
                  }}
                />
              )}
              {deleting && (
                <Preview
                  title={`trigger/${team}/${name}`}
                  lines={[{ field: "trigger", from: name, to: null }]}
                  effects={[`${name} never fires again, and its runs go with it.`, "The sessions its runs started stay, with their history.", locked ? "The cluster has no resource for it, so this deletes the plane's row and nothing else." : ""].filter(Boolean)}
                  verb={`Delete ${name}`}
                  typeToConfirm={name}
                  onCancel={() => setDeleting(false)}
                  onConfirm={async () => {
                    await admin.deleteTrigger(team, name);
                    setGone({ action: "trigger.delete", subject: `${team}/${name}`, detail: await recorded(admin, me.subject, "trigger.delete", `${team}/${name}`) });
                    notify(`${name} is deleted.`);
                  }}
                />
              )}

              <Region>Revisions</Region>
              {revisions === null ? (
                <p className="note">Its revisions could not be read.</p>
              ) : revisions.length === 0 ? (
                <Empty title="No revision yet" />
              ) : (
                <ol className="revisions">
                  {revisions.map((r) => (
                    <li key={r.revision}>
                      <details>
                        <summary>
                          Revision {r.revision} · <span className="mono">{r.hash}</span> · {when(r.created_at)} by {show(r.created_by)}
                        </summary>
                        <pre className="mono">{JSON.stringify(r.document ?? {}, null, 2)}</pre>
                      </details>
                    </li>
                  ))}
                </ol>
              )}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

// -- making and changing one -------------------------------------------------------------

interface TriggerFields {
  name: string;
  principal: string;
  profile: string;
  agent: string;
  /** schedule, webhook or manual, or github: a webhook from GitHub on one repository. */
  kind: string;
  cron: string;
  provider: string;
  repository: string;
  label: string;
  command: string;
  /** The branch a GitHub trigger's sessions clone: kept as it is, since no field here shows it. */
  ref: string;
  prompt: string;
  visibility: string;
  review: string;
  concurrency: string;
  notifyUrl: string;
}

function fieldsOf(t: Trigger | null): TriggerFields {
  const s = t?.source ?? {};
  return {
    name: t?.name ?? "",
    principal: t?.principal ?? "",
    profile: t?.profile ?? "",
    agent: t?.agent ?? "",
    kind: s["kind"] === "webhook" && s["repository"] ? "github" : String(s["kind"] ?? "schedule"),
    cron: String(s["cron"] ?? ""),
    provider: String(s["provider"] ?? ""),
    repository: String(s["repository"] ?? ""),
    label: String(s["label"] ?? ""),
    command: String(s["command"] ?? ""),
    ref: String(s["ref"] ?? ""),
    prompt: t?.prompt_template ?? "",
    visibility: t?.visibility ?? "team",
    review: t?.review === "none" || t?.review === false ? "none" : "required",
    concurrency: String(t?.concurrency ?? 1),
    notifyUrl: t?.notify_url ?? "",
  };
}

/** What the form says, as the fields `admin.trigger.put` takes; blank optional ones as null. */
function valuesOf(f: TriggerFields): Record<string, unknown> {
  const source: Record<string, unknown> = { kind: f.kind === "github" ? "webhook" : f.kind };
  if (f.kind === "schedule") Object.assign(source, { cron: f.cron.trim(), tz: "UTC" });
  if (f.kind === "webhook" && f.provider.trim()) source["provider"] = f.provider.trim();
  if (f.kind === "github") {
    Object.assign(source, { provider: "github", repository: f.repository.trim() });
    if (f.label.trim()) source["label"] = f.label.trim();
    if (f.command.trim()) source["command"] = f.command.trim();
    if (f.ref) source["ref"] = f.ref;
  }
  return {
    principal: f.principal,
    profile: f.profile,
    agent: f.agent.trim() || null,
    source,
    prompt_template: f.prompt.trim() || null,
    visibility: f.visibility,
    review: f.review,
    concurrency: /^\d+$/.test(f.concurrency.trim()) ? Number(f.concurrency.trim()) : f.concurrency,
    notify_url: f.notifyUrl.trim() || null,
  };
}

const NAME = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;

function TriggerForm({
  team,
  existing,
  names,
  onCancel,
  onConfirm,
}: {
  team: AdminTeam;
  existing: Trigger | null;
  names: string[];
  onCancel: () => void;
  onConfirm: (changes: Record<string, unknown>, name: string) => Promise<void>;
}): JSX.Element {
  const { admin } = useConsole();
  const [f, setF] = useState<TriggerFields>(() => fieldsOf(existing));
  const [previewing, setPreviewing] = useState(false);
  const [listed] = useLoad(() => admin.principals(team.name), [admin, team.name]);
  const creating = existing === null;
  // The team's principals that still work, and the one it runs as now whatever its state.
  const principals = [...new Set([...(listed.state === "ready" ? listed.data.filter((p) => p.enabled).map((p) => p.subject) : []), ...(existing?.principal ? [existing.principal] : [])])];
  const profiles = [...new Set([...team.grants.map((g) => g.profile), ...(existing?.profile ? [existing.profile] : [])])];
  const asked = valuesOf(f);
  const before = existing ? valuesOf(fieldsOf(existing)) : {};
  // A change sends only what moved: the plane keeps every field it is not sent.
  const changes = Object.fromEntries(Object.entries(asked).filter(([k, v]) => creating ? v !== null && v !== "" : JSON.stringify(v) !== JSON.stringify(before[k])));
  const lines: DiffLine[] = Object.entries(changes).map(([field, to]) => ({ field, from: creating ? null : (before[field] ?? null), to }));
  const name = f.name.trim();
  const nameProblem = creating && name !== "" ? (names.includes(name) ? `${team.name} has a trigger called ${name} already.` : NAME.test(name) ? null : "Lowercase letters, digits and dashes.") : null;
  const cronProblem = f.kind === "schedule" && f.cron.trim() !== "" && f.cron.trim().split(/\s+/).length !== 5 ? "Five fields: minute, hour, day of the month, month, day of the week." : null;
  const repositoryProblem = f.kind === "github" && f.repository.trim() !== "" && !/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+$/.test(f.repository.trim()) ? "owner/name, as GitHub writes it." : null;
  const githubMissing = f.kind === "github" && (!f.repository.trim() || (!f.label.trim() && !f.command.trim()));
  const missing = githubMissing || (creating && (!name || !f.principal || !f.profile || (f.kind === "schedule" && !f.cron.trim())));
  const set = (patch: Partial<TriggerFields>) => setF({ ...f, ...patch });

  if (previewing) {
    return (
      <Preview
        title={`trigger/${team.name}/${name}`}
        lines={lines.map((l) => (l.field === "source" ? { ...l, from: l.from ? firedBy(l.from as Record<string, unknown>) : null, to: firedBy(l.to as Record<string, unknown>) } : l))}
        effects={triggerWords(team.name, name, creating, changes)}
        verb={creating ? `Create ${name}` : "Apply"}
        onCancel={() => setPreviewing(false)}
        onConfirm={() => onConfirm(changes, name)}
      />
    );
  }

  return (
    <form
      className="edit grid"
      aria-label={creating ? `A new trigger for ${team.name}` : `Changing ${name}`}
      onSubmit={(e) => {
        e.preventDefault();
        setPreviewing(true);
      }}
    >
      <Field label="Name" hint={creating ? "Unique within the team." : "A different name is a different trigger."} error={nameProblem}>
        {(p) => <input {...p} value={f.name} onChange={(e) => set({ name: e.target.value })} readOnly={!creating} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field
        label="Runs as"
        hint={
          listed.state === "loading"
            ? "Reading the team's service principals…"
            : principals.length
              ? "A service principal of the team: a credential somebody is answerable for, since it fires with nobody watching."
              : `${team.name} has no service principal that works: one is made on Identity, in the current console for now.`
        }
      >
        {(p) => (
          <select {...p} value={f.principal} onChange={(e) => set({ principal: e.target.value })}>
            <option value="">choose a principal</option>
            {principals.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        )}
      </Field>
      <Field label="Profile" hint={`What its sessions start on: one ${team.name} is granted.`}>
        {(p) => (
          <select {...p} value={f.profile} onChange={(e) => set({ profile: e.target.value })}>
            <option value="">choose a profile</option>
            {profiles.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
        )}
      </Field>
      <Field label="Agent" hint="The primary agent. Empty is the profile's default.">
        {(p) => <input {...p} value={f.agent} onChange={(e) => set({ agent: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="Fired by" hint="A webhook is made with its key, shown once. A GitHub repository is fired by the plane's GitHub App, with no key.">
        {(p) => (
          <select {...p} value={f.kind} onChange={(e) => set({ kind: e.target.value })}>
            <option value="schedule">a schedule</option>
            <option value="webhook">a webhook</option>
            <option value="github">an issue on a GitHub repository</option>
            <option value="manual">only by hand</option>
          </select>
        )}
      </Field>
      {f.kind === "github" && (
        <>
          <Field label="Repository" hint="owner/name: one the plane's GitHub App is installed on. Its sessions clone it and propose a fix as a draft pull request." error={repositoryProblem}>
            {(p) => <input {...p} value={f.repository} onChange={(e) => set({ repository: e.target.value })} autoComplete="off" spellCheck={false} />}
          </Field>
          <Field label="Label" hint="An issue given this label starts a run. A label, a command, or both.">
            {(p) => <input {...p} value={f.label} onChange={(e) => set({ label: e.target.value })} autoComplete="off" spellCheck={false} />}
          </Field>
          <Field label="Command" hint="A comment whose first line is this, such as /troupe fix, by the repository's owner, a member or a collaborator, starts a run.">
            {(p) => <input {...p} value={f.command} onChange={(e) => set({ command: e.target.value })} autoComplete="off" spellCheck={false} />}
          </Field>
        </>
      )}
      {f.kind === "schedule" && (
        <Field label="Schedule" hint="Five fields, in UTC, the only zone this plane keeps: 0 3 * * 1-5 is three in the morning on weekdays." error={cronProblem}>
          {(p) => <input {...p} value={f.cron} onChange={(e) => set({ cron: e.target.value })} autoComplete="off" spellCheck={false} />}
        </Field>
      )}
      {f.kind === "webhook" && (
        <Field label="Sent by" hint="Who sends it, for the executor that receives it. Optional.">
          {(p) => <input {...p} value={f.provider} onChange={(e) => set({ provider: e.target.value })} autoComplete="off" spellCheck={false} />}
        </Field>
      )}
      <Field label="Its sessions are seen by" hint="Who may see the sessions it starts.">
        {(p) => (
          <select {...p} value={f.visibility} onChange={(e) => set({ visibility: e.target.value })}>
            <option value="team">the team</option>
            <option value="private">the principal alone</option>
          </select>
        )}
      </Field>
      <Field label="A person reads each run" hint="Expected, each run waits on Runs and review until somebody has read it.">
        {(p) => (
          <select {...p} value={f.review} onChange={(e) => set({ review: e.target.value })}>
            <option value="required">expected</option>
            <option value="none">not expected</option>
          </select>
        )}
      </Field>
      <Field label="Runs at once, at most" hint="1 to 100. A firing over it is recorded as skipped.">
        {(p) => <input {...p} value={f.concurrency} onChange={(e) => set({ concurrency: e.target.value })} inputMode="numeric" />}
      </Field>
      <Field label="Its outcome is posted to" hint="An absolute http or https address told when a run ends, on a host the egress policy allows. Optional.">
        {(p) => <input {...p} value={f.notifyUrl} onChange={(e) => set({ notifyUrl: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="What each session is asked to do" hint="With {{event.*}}, {{trigger.*}} and {{run.*}} placeholders. A missing path renders empty.">
        {(p) => <textarea {...p} value={f.prompt} onChange={(e) => set({ prompt: e.target.value })} rows={4} />}
      </Field>
      {!creating && <p className="note">Its terms and who is made a collaborator on each run are kept as they are; this form does not change them.</p>}
      <div className="actions">
        <button type="submit" className="primary" disabled={Boolean(missing || nameProblem || cronProblem || repositoryProblem) || lines.length === 0}>
          Preview
        </button>
        <button type="button" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  );
}

function triggerWords(team: string, name: string, creating: boolean, changes: Record<string, unknown>): string[] {
  const out: string[] = [];
  if (creating) {
    out.push(`${name} fires ${firedBy(changes["source"] as Record<string, unknown>)}, and each firing starts a ${team} session that spends ${team}'s budget.`);
    const source = changes["source"] as Record<string, unknown>;
    if (source["kind"] === "webhook" && source["repository"]) {
      out.push(`Each run starts a session on ${String(source["repository"])} with the issue as its task, given as data, and proposes a fix as a draft pull request. GitHub's deliveries to the plane's App fire it; it has no key.`);
    } else if (source["kind"] === "webhook") {
      out.push("It is made with its webhook key, which is shown once, here, when it is created: copy it then.");
    }
  } else {
    if ("source" in changes) out.push(`From now it fires ${firedBy(changes["source"] as Record<string, unknown>)}.`);
    if ("profile" in changes || "principal" in changes) out.push("Runs already going carry on as they started; the next one uses the new setting.");
    out.push("The plane makes a new revision of its document; runs say which revision they ran.");
  }
  return out;
}

