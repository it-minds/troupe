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

import { useState } from "react";
import type { JSX } from "react";
import type { ClientFleet, ClientPolicy, ClientPolicyChange, ClientPolicyPut, ClientSeen } from "@troupe/client";
import { show, useConsole, useLoad } from "../console";
import { AuditNote, Empty, Field, Loaded, Preview, Region, Status, changed, count, when } from "./bits";
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
  const { admin, role } = useConsole();
  const [load, reload] = useLoad(() => admin.clients(), [admin]);
  const [done, setDone] = useState<ClientPolicyPut | null>(null);
  const [query, setQuery] = useState("");

  return (
    <div className="page">
      <p className="lead">
        Each kind of client is held to a policy here. One below the minimum, or on a blocked version, is refused when it next connects and told what to
        run; the recommended version is the one people are nudged to, and the one <code>troupe update</code> installs.
      </p>
      {done && <AuditNote action="clients.put" subject={done.component} detail={done.changes} />}
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
              {policies.map((p) => (
                <Component
                  key={p.component}
                  policy={p}
                  fleet={data.fleet?.[p.component]}
                  editable={role === "platform_admin"}
                  onApplied={(answer) => {
                    setDone(answer);
                    reload();
                  }}
                />
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
            <Empty title={`Nobody behind matches "${query.trim()}"`}>Filter by a person's name or address, a version, or a kind of client.</Empty>
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
          ? `${updates ? `troupe update installs ${String(to)} for people signed in here, and an` : "An"} older ${program} is told ${String(to)} is out.`
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
