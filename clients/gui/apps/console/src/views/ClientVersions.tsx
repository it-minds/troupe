// Which versions of its clients this plane serves: per component, the version people are
// sent to, the oldest it serves, and the versions it serves to nobody.
//
// The components are the plane's answer's, not a list of this screen's. A client below the
// minimum, or on a blocked version, is refused when it next connects and told what to run;
// that is the plane's to do, and the preview says it before anything is saved. Either
// admin role reads it; only a platform admin changes it, since it holds every team's
// clients alike.
//
// Beside each policy, the clients it holds (#657): the plane records the version each
// person's client of each kind last gave when it connected, so a count says how many are
// current, behind the recommended version, or refused when they next connect, and a list
// says who is behind and since when. A team admin's are their teams' people.
//
// Above the policies, a platform admin's one button for the usual step after an upgrade:
// recommend the version this plane runs (its discovery's `plane.build.version`) for every
// kind of client, previewed and applied as the policies' own changes are (#925).

import { useState } from "react";
import type { JSX } from "react";
import { andList, clientStanding, releaseVersion, versionOlder } from "@troupe/client";
import type { ClientCounts, ClientFleet, ClientPolicy, ClientPolicyChange, ClientPolicyPut, ClientSeen } from "@troupe/client";
import { describeError, show, useConsole, useLoad } from "../console";
import { AuditNote, Diff, Empty, Field, Loaded, Loading, Preview, Region, Status, changed, count, when } from "./bits";
import type { DiffLine } from "./bits";

/** What each component is to a person, for the ones this console knows the name of. */
const KNOWN: Record<string, { name: string; program: string; updates: boolean }> = {
  tui: { name: "The terminal", program: "troupe", updates: true },
  daemon: { name: "The daemon", program: "troupe-daemon", updates: true },
  desktop: { name: "The desktop app", program: "the desktop app", updates: false },
};

function known(component: string): { name: string; program: string; updates: boolean } {
  return KNOWN[component] ?? { name: component, program: component, updates: false };
}

export function ClientVersions(): JSX.Element {
  const { admin, role, plane } = useConsole();
  const [load, reload] = useLoad(() => admin.clients(), [admin]);
  const [done, setDone] = useState<ClientPolicyPut[] | null>(null);
  const [query, setQuery] = useState("");
  const applied = (answers: ClientPolicyPut[]) => {
    setDone(answers);
    reload();
  };

  return (
    <div className="page">
      <p className="lead">
        Each kind of client is held to a policy here. One below the minimum, or on a blocked version, is refused when it next connects and told what to
        run; the recommended version is the one people are nudged to, and the one <code>troupe update</code> installs.
      </p>
      {done && done.length > 0 && <AuditNote action="clients.put" subject={done.map((d) => d.component).join(", ")} detail={auditOf(done)} />}
      <Loaded load={load} what="the version policy" retry={reload}>
        {(data) => {
          const policies = Object.values(data.clients);
          const none = policies.every((p) => !p.recommended && !p.minimum && p.blocked.length === 0);
          return (
            <>
              {none && (
                <Empty title="No policy yet">
                  This plane serves every version of every client.{" "}
                  {role === "platform_admin" ? "Set a minimum to turn away clients older than a release." : "A platform admin sets one."}
                </Empty>
              )}
              {role === "platform_admin" &&
                (plane.version ? (
                  <RecommendPlane version={plane.version} dryRun={plane.dryRun.includes("admin.clients.put")} policies={policies} fleet={data.fleet} onApplied={applied} />
                ) : (
                  <p className="note recommend">
                    This plane does not say which version it runs, so it is too old to recommend its own version from here. Set each kind of client's recommended
                    version below.
                  </p>
                ))}
              {policies.map((p) => (
                <Component key={p.component} policy={p} fleet={data.fleet?.[p.component]} editable={role === "platform_admin"} onApplied={(answer) => applied([answer])} />
              ))}
              {role !== "platform_admin" && <p className="note">Only a platform admin changes these, since they hold every team's clients alike.</p>}
              {data.fleet && <Behind fleet={data.fleet} query={query} onQuery={setQuery} team={role !== "platform_admin"} />}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

/** What the audit recorded of one put or several: a component's own fields, or each prefixed with its component where there are several. */
function auditOf(answers: ClientPolicyPut[]): Record<string, unknown> {
  if (answers.length === 1) return answers[0]!.changes;
  return Object.fromEntries(answers.flatMap((a) => Object.entries(a.changes).map(([field, moved]) => [`${a.component}.${field}`, moved])));
}

/** Where one component stands against recommending the plane's version: already, can, or the plane would refuse it and why. */
type Plan = { policy: ClientPolicy; refused: string | null };

function planOf(policy: ClientPolicy, version: string): Plan | null {
  if (policy.recommended === version) return null;
  const name = known(policy.component).name.toLowerCase();
  if (policy.blocked.includes(version)) return { policy, refused: `${name}'s policy blocks ${version}` };
  if (policy.minimum && versionOlder(version, policy.minimum)) return { policy, refused: `${name}'s minimum, ${policy.minimum}, is newer than ${version}` };
  return { policy, refused: null };
}

/** A component's clients last seen, counted against its policy with `recommended` moved to `version`, from what the plane last saw of them. */
function countsWith(policy: ClientPolicy, version: string, fleet: ClientFleet): ClientCounts {
  const next = { recommended: version, minimum: policy.minimum, blocked: policy.blocked };
  const standings = fleet.people.map((p) => clientStanding(next, p.version));
  const n = (s: string) => standings.filter((x) => x === s).length;
  return { current: n("current"), behind: n("behind"), refused: n("refused") };
}

function countsLine(counts: ClientCounts, version: string): string {
  const seen = counts.current + counts.behind + counts.refused;
  if (seen === 0) return "None has connected since the plane began recording versions.";
  const parts = [`${counts.current} current`, `${counts.behind} behind ${version}`];
  if (counts.refused > 0) parts.push(`${counts.refused} refused when ${counts.refused === 1 ? "it next connects" : "they next connect"}, as now`);
  return `Of ${count(seen, "client")} last seen: ${parts.join(", ")}.`;
}

/**
 * After an upgrade, the usual intent: recommend what this plane runs, for every kind of
 * client at once, through the same preview and the same puts as one component's change.
 * The puts go one at a time, in the page's order; one the plane refuses stops the rest and
 * says which, and the ones before it stand. A component whose policy the plane would refuse
 * it for (the version blocked, or a minimum newer than it) is left as it is, and the
 * preview says so before anything is sent. The counts are the plane's own, from a dry run
 * of each put, where the plane's discovery says `admin.clients.put` takes one; a plane from
 * before would make the write, so there the counts are worked out here from the clients
 * last seen, as the plane judges them.
 */
function RecommendPlane({
  version: reported,
  dryRun,
  policies,
  fleet,
  onApplied,
}: {
  version: string;
  dryRun: boolean;
  policies: ClientPolicy[];
  fleet: Record<string, ClientFleet> | undefined;
  onApplied: (answers: ClientPolicyPut[]) => void;
}): JSX.Element {
  const { admin, notify } = useConsole();
  const [previewing, setPreviewing] = useState(false);
  // The plane's answer to each dry run, by component: what the put would leave, or why it would be refused.
  const [dry, setDry] = useState<Record<string, ClientPolicyPut | { refused: string }> | null>(null);
  const version = releaseVersion(reported);
  if (!version) {
    return (
      <p className="note">
        This plane says it runs <code>{reported}</code>, which is not a version as releases are numbered, so it cannot be recommended from here. Set each kind of client's
        recommended version below.
      </p>
    );
  }
  const plans = policies.map((p) => planOf(p, version)).filter((p): p is Plan => p !== null);
  const todo = plans.filter((p) => !p.refused).map((p) => p.policy);
  const refused = plans.filter((p) => p.refused).map((p) => p.refused!);
  if (todo.length === 0) {
    return (
      <p className="note recommend">
        {refused.length === 0
          ? `Every client is recommended this plane's version, ${version}.`
          : `This plane's version, ${version}, cannot be recommended for every client: the plane refuses it while ${andList(refused)}.`}
      </p>
    );
  }
  // A component the plane's dry run refused is left as it is, as one the console knows it refuses is.
  const planeRefused = (c: string): string | null => {
    const answer = dry?.[c];
    return answer && "refused" in answer ? answer.refused : null;
  };
  const sent = todo.filter((p) => !planeRefused(p.component));
  const lines: DiffLine[] = sent.map((p) => ({ field: `${p.component}.recommended`, from: p.recommended, to: version }));
  const effects = [
    ...sent.map((p) => {
      const { name, program, updates } = known(p.component);
      return `${name}: ${updates ? `troupe update installs ${version} for people signed in here, and ${anOlder(program)}` : anOlder(program)} is told ${version} is out.`;
    }),
    ...(refused.length > 0 ? [`Left as it is, since the plane refuses it while ${andList(refused)}.`] : []),
    ...todo.filter((p) => planeRefused(p.component)).map((p) => `${known(p.component).name} is left as it is: the plane would refuse it. ${planeRefused(p.component)}`),
    "A client already connected is held to it when it next connects. The plane installs and removes nothing.",
  ];
  const open = async () => {
    setDry(null);
    setPreviewing(true);
    if (!dryRun) return;
    const answers: Record<string, ClientPolicyPut | { refused: string }> = {};
    for (const p of todo) {
      try {
        answers[p.component] = await admin.previewClients(p.component, { recommended: version });
      } catch (e) {
        answers[p.component] = { refused: describeError(e) };
      }
    }
    setDry(answers);
  };

  return (
    <section className="recommend" aria-label="Recommend this plane's version">
      {!previewing && (
        <button type="button" onClick={() => void open()}>
          Recommend this plane's version
        </button>
      )}
      {previewing && dryRun && dry === null && <Loading what="what the plane would do" />}
      {previewing && (!dryRun || dry !== null) && (
        <Preview
          title="clients"
          lines={lines}
          body={
            <>
              {sent.map((p) => {
                const f = fleet?.[p.component];
                const answer = dry?.[p.component];
                const counts = answer && "affected" in answer && answer.affected ? answer.affected : f ? countsWith(p, version, f) : null;
                return (
                  <div key={p.component} className="recommend-row">
                    <Diff title={`clients/${p.component}`} lines={[{ field: "recommended", from: p.recommended, to: version }]} />
                    {counts && <p className="fleet">{countsLine(counts, version)}</p>}
                  </div>
                );
              })}
            </>
          }
          effects={effects}
          verb="Apply"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            const answers: ClientPolicyPut[] = [];
            for (const p of sent) {
              try {
                answers.push(await admin.putClients(p.component, { recommended: version }));
              } catch (e) {
                if (answers.length > 0) onApplied(answers);
                const kept = answers.map((a) => a.component);
                const failed = `${known(p.component).name}'s recommended version was not changed: ${describeError(e)}`;
                throw new Error(kept.length > 0 ? `${named(kept)} now ${kept.length === 1 ? "recommends" : "recommend"} ${version}; ${lower(failed)}` : failed);
              }
            }
            setPreviewing(false);
            onApplied(answers);
            notify(`${named(answers.map((a) => a.component))} now ${answers.length === 1 ? "recommends" : "recommend"} ${version}.`);
          }}
        />
      )}
    </section>
  );
}

const lower = (s: string): string => s.charAt(0).toLowerCase() + s.slice(1);

/** "an older troupe", and "an older desktop app" rather than "an older the desktop app". */
const anOlder = (program: string): string => `an older ${program.replace(/^the /, "")}`;

/** Components by the names people know them by, as a sentence begins: "The terminal, the daemon and the desktop app". */
function named(components: string[]): string {
  return andList(components.map((c, i) => (i === 0 ? known(c).name : lower(known(c).name))));
}

/** A component's clients last seen, as one line: how many, and how they stand. */
function FleetLine({ fleet }: { fleet: ClientFleet | undefined }): JSX.Element | null {
  if (!fleet) return null;
  const seen = fleet.current + fleet.behind + fleet.refused;
  if (seen === 0) return <p className="fleet muted">None has connected since the plane began recording versions.</p>;
  const parts = [`${fleet.current} current`, `${fleet.behind} behind the recommended version`];
  if (fleet.refused > 0) parts.push(`${fleet.refused} refused when ${fleet.refused === 1 ? "it next connects" : "they next connect"}`);
  return (
    <p className="fleet">
      {count(seen, "client")} last seen: {parts.join(", ")}.
    </p>
  );
}

type BehindRow = ClientSeen & { component: string };

/** Everyone whose client is behind its component's recommended version, or refused, oldest first, with a filter. */
function Behind({ fleet, query, onQuery, team }: { fleet: Record<string, ClientFleet>; query: string; onQuery: (q: string) => void; team: boolean }): JSX.Element {
  const rows: BehindRow[] = Object.entries(fleet)
    .flatMap(([component, f]) => f.people.map((p) => ({ ...p, component })))
    .filter((p) => p.standing !== "current")
    .sort((a, b) => a.since.localeCompare(b.since));
  const q = query.trim().toLowerCase();
  const shown = rows.filter((r) => !q || [r.subject, r.display_name, r.version, r.platform, known(r.component).name, r.standing].some((v) => v?.toLowerCase().includes(q)));
  return (
    <>
      <Region>Who is behind</Region>
      {rows.length === 0 ? (
        <Empty title="Nobody is behind">{team ? "Every client your teams' people last connected with" : "Every client last seen"} is on the recommended version or later.</Empty>
      ) : (
        <>
          <div className="toolbar">
            <input aria-label="Filter who is behind" placeholder="filter by a person, a version, a client…" value={query} onChange={(e) => onQuery(e.target.value)} />
          </div>
          {shown.length === 0 ? (
            <Empty title={<>Nobody behind matches <code>"{query.trim()}"</code></>}>Filter by a person's name or address, a version, or a kind of client.</Empty>
          ) : (
            <div className="scroll">
              <table className="behind">
                <thead>
                  <tr>
                    <th>Person</th>
                    <th>Client</th>
                    <th>Version</th>
                    <th>Standing</th>
                    <th>On it since</th>
                    <th>Last seen</th>
                  </tr>
                </thead>
                <tbody>
                  {shown.map((r) => (
                    <tr key={`${r.component}:${r.subject}`}>
                      <td>
                        <span className="who">{r.display_name && r.display_name !== r.subject ? `${r.display_name} (${r.subject})` : r.subject}</span>
                      </td>
                      <td>{known(r.component).name}</td>
                      <td className="mono">
                        {r.version}
                        {r.platform && <span className="muted"> · {r.platform}</span>}
                      </td>
                      <td>
                        {r.standing === "refused" ? (
                          <Status kind="denied" glyph="✕">
                            refused when it next connects
                          </Status>
                        ) : (
                          <Status kind="local" glyph="◐">
                            behind
                          </Status>
                        )}
                      </td>
                      <td>{when(r.since)}</td>
                      <td>{when(r.seen_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </>
  );
}

type Form = { recommended: string; minimum: string; blocked: string };

const formOf = (p: ClientPolicy): Form => ({ recommended: p.recommended ?? "", minimum: p.minimum ?? "", blocked: p.blocked.join(", ") });

/** What the form asks for, as the plane takes it: blank is none, the blocked list whole. */
function asked(form: Form): { recommended: string | null; minimum: string | null; blocked: string[] } {
  return {
    recommended: form.recommended.trim() || null,
    minimum: form.minimum.trim() || null,
    blocked: form.blocked.split(/[\s,]+/).filter(Boolean),
  };
}

function Component({
  policy,
  fleet,
  editable,
  onApplied,
}: {
  policy: ClientPolicy;
  fleet: ClientFleet | undefined;
  editable: boolean;
  onApplied: (answer: ClientPolicyPut) => void;
}): JSX.Element {
  const { admin, notify } = useConsole();
  const { name, program, updates } = known(policy.component);
  const [form, setForm] = useState<Form | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const current = { recommended: policy.recommended, minimum: policy.minimum, blocked: policy.blocked };
  const lines: DiffLine[] = form ? changed(current, asked(form)) : [];

  return (
    <section className="card" aria-label={name}>
      <header>
        <h3>{name}</h3>
        <code className="muted">{policy.component}</code>
        <span className="meta">
          {policy.updated_by ? (
            <>
              last set by <span className="who">{policy.updated_by}</span>, {when(policy.updated_at)}
            </>
          ) : (
            "never set"
          )}
        </span>
      </header>
      {!form && (
        <dl className="fields">
          <div>
            <dt>Recommended</dt>
            <dd className="mono">{show(policy.recommended)}</dd>
          </div>
          <div>
            <dt>Minimum</dt>
            <dd className="mono">{show(policy.minimum)}</dd>
          </div>
          <div>
            <dt>Blocked</dt>
            <dd className="mono">{policy.blocked.length ? policy.blocked.join(", ") : "none"}</dd>
          </div>
        </dl>
      )}
      {!form && <FleetLine fleet={fleet} />}
      {!form && editable && (
        <button type="button" onClick={() => setForm(formOf(policy))}>
          Change {name.toLowerCase()}'s policy
        </button>
      )}
      {form && !previewing && (
        <form
          className="edit"
          onSubmit={(e) => {
            e.preventDefault();
            setPreviewing(true);
          }}
        >
          <Field label="Recommended" hint="The version people are nudged to. Blank is none.">
            {(p) => <input {...p} value={form.recommended} onChange={(e) => setForm({ ...form, recommended: e.target.value })} placeholder="0.16.0-beta" spellCheck={false} />}
          </Field>
          <Field label="Minimum" hint="The oldest version served. Blank is none.">
            {(p) => <input {...p} value={form.minimum} onChange={(e) => setForm({ ...form, minimum: e.target.value })} spellCheck={false} />}
          </Field>
          <Field label="Blocked" hint="Versions served to nobody, separated by commas. Blank is none.">
            {(p) => <input {...p} value={form.blocked} onChange={(e) => setForm({ ...form, blocked: e.target.value })} spellCheck={false} />}
          </Field>
          <p className="hint">Versions as releases are numbered, pre-release and all: 0.16.0-beta comes before 0.16.0.</p>
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
          title={`clients/${policy.component}`}
          lines={lines}
          effects={effects(lines, program, updates)}
          verb="Apply"
          onCancel={() => setPreviewing(false)}
          cancel="Back to editing"
          onConfirm={async () => {
            const change: ClientPolicyChange = {};
            for (const l of lines) Object.assign(change, { [l.field]: l.to });
            const answer = await admin.putClients(policy.component, change);
            setForm(null);
            setPreviewing(false);
            const held = answer.affected ? answer.affected.behind + answer.affected.refused : 0;
            notify(
              `${name}'s version policy is applied.${answer.affected && held > 0 ? ` Of the clients last seen, ${answer.affected.behind} ${answer.affected.behind === 1 ? "is" : "are"} behind it and ${answer.affected.refused} refused when they next connect.` : ""}`,
            );
            onApplied(answer);
          }}
        />
      )}
    </section>
  );
}

/** What a change to the policy does, in the words a person deciding it needs. */
function effects(lines: DiffLine[], program: string, updates: boolean): string[] {
  const out: string[] = [];
  for (const { field, from, to } of lines) {
    if (field === "minimum") {
      out.push(
        to
          ? `Every ${program} older than ${String(to)} is refused when it next connects, and told to ${updates ? "run troupe update" : "update"}.`
          : `No ${program} is refused for its age any more.`,
      );
    }
    if (field === "recommended") {
      out.push(
        to
          ? `${updates ? `troupe update installs ${String(to)} for people signed in here, and ${anOlder(program)}` : `A${anOlder(program).slice(1)}`} is told ${String(to)} is out.`
          : `Nobody is nudged to a version${updates ? ", and troupe update installs the latest release" : ""}.`,
      );
    }
    if (field === "blocked") {
      const was = (from as string[] | null) ?? [];
      const is = (to as string[] | null) ?? [];
      for (const v of is.filter((v) => !was.includes(v))) out.push(`${program} ${v} is refused, whatever else the policy says.`);
      for (const v of was.filter((v) => !is.includes(v))) out.push(`${program} ${v} is served again.`);
    }
  }
  out.push("A client already connected is held to it when it next connects. The plane installs and removes nothing.");
  return out;
}
