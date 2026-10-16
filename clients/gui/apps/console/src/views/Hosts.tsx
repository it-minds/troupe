// Provisioners and hosts: what makes a profile's workers, what that does not guarantee, and
// the machines registered to run them.
//
// Each substrate's guarantees are named one at a time (admission policy, network policy,
// egress by hostname, a disruption budget), with what stands in for a missing one, because
// "unenforced" is not something a person deciding where a team's work may run can act on.
// Each profile says what its own workers lack, and which teams may be granted one that
// lacks something with nothing in its place.
//
// A machine is registered against a profile, which decides what it may run. Registering
// mints the secret it enrols with and answers the CA it pins for the control port: both
// are shown once, here, and the plane keeps only a hash of the secret. Rotating mints a new
// one and the old stops at once, so it is typed by the machine's name; switching a machine
// off refuses its next enrolment and reaches nothing already connected.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminProfile, AdminTeam, Host, Provisioner } from "@troupe/client";
import { show, useConsole, useLoad } from "../console";
import { href } from "../route";
import { AuditNote, Empty, Field, Loaded, Preview, Region, ShownOnce, Status, useChange, when } from "./bits";

/** A guarantee, as a person would say it. */
const GUARANTEES: Record<string, string> = {
  admission_policy: "admission policy",
  network_policy: "network policy",
  fqdn_egress: "egress by hostname",
  egress_checked_at_admission: "the egress allowlist checked at admission, not on the wire",
  disruption_budget: "disruption budget",
};

function words(names: string[]): string {
  return names.length ? names.map((n) => GUARANTEES[n] ?? n.replace(/_/g, " ")).join(", ") : "none";
}

export function Hosts(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => Promise.all([admin.provisioners(), admin.profiles(), admin.teams()]), [admin]);
  return (
    <div className="page">
      <p className="lead">What makes each profile's workers, what that substrate does not guarantee, and the machines registered to run them.</p>
      <Loaded load={load} what="the provisioners" retry={reload}>
        {([provisioners, profiles, teams]) => (
          <>
            <Substrates provisioners={provisioners} />
            <ProfileGuarantees profiles={profiles} />
            <Unenforced teams={teams} />
            {profiles
              .filter((p) => p.provisioner && p.provisioner !== "kubernetes")
              .map((p) => (
                <Machines key={p.name} profile={p} />
              ))}
          </>
        )}
      </Loaded>
    </div>
  );
}

function Substrates({ provisioners }: { provisioners: Provisioner[] }): JSX.Element {
  return (
    <section aria-label="What each one guarantees">
      <Region>What each one guarantees</Region>
      <p className="note">In general, before any profile is configured: what a substrate gives is a property of the substrate, and a profile may get less.</p>
      <div className="scroll">
        <table>
          <thead>
            <tr>
              <th>Provisioner</th>
              <th>Gives</th>
              <th>Does not give</th>
              <th>In its place</th>
            </tr>
          </thead>
          <tbody>
            {provisioners.map((p) => (
              <tr key={p.name}>
                <td className="mono">{p.name}</td>
                <td>{words(p.guarantees)}</td>
                <td>{words(p.missing)}</td>
                <td>
                  {Object.keys(p.instead).length
                    ? Object.entries(p.instead)
                        .map(([missing, weaker]) => `${GUARANTEES[missing] ?? missing}: ${GUARANTEES[weaker] ?? weaker}`)
                        .join("; ")
                    : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function ProfileGuarantees({ profiles }: { profiles: AdminProfile[] }): JSX.Element {
  return (
    <section aria-label="What each profile's workers do not get">
      <Region>Every profile, and what its workers do not get</Region>
      {profiles.length === 0 ? (
        <Empty title="No profile yet" />
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Profile</th>
                <th>Provisioner</th>
                <th>Its workers do not get</th>
              </tr>
            </thead>
            <tbody>
              {profiles.map((p) => {
                const missing = p.missing_guarantees ?? [];
                return (
                  <tr key={p.name}>
                    <td>
                      <a href={href({ page: "profiles", path: [p.name] })}>{p.name}</a>
                    </td>
                    <td className="mono">{show(p.provisioner)}</td>
                    <td>
                      {missing.length === 0 ? (
                        <Status kind="running" glyph="●">
                          everything is enforced
                        </Status>
                      ) : (
                        <>
                          <Status kind={p.unenforced ? "denied" : "waiting"} glyph={p.unenforced ? "✕" : "◆"}>
                            {p.unenforced ? "not enforced" : "weaker"}
                          </Status>{" "}
                          {words(missing)}
                          {p.guarantees_instead &&
                            Object.entries(p.guarantees_instead).map(([m, w]) => (
                              <span key={m} className="hint">
                                {" "}
                                ({GUARANTEES[m] ?? m}: {GUARANTEES[w] ?? w} instead)
                              </span>
                            ))}
                        </>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function Unenforced({ teams }: { teams: AdminTeam[] }): JSX.Element {
  const allowed = teams.filter((t) => t.allow_unenforced_workers);
  return (
    <section aria-label="Who may run where nothing is enforced">
      <Region>Who may run where nothing is enforced</Region>
      <p className="note">
        A team is granted a profile nothing is enforced on only once a platform admin has said it may, on the team's Access tab. Deliberate friction, and not a way
        around the policy: the profile's workers still run what it says.
      </p>
      {allowed.length === 0 ? (
        <Empty title="No team allowed">No team may be granted a profile nothing is enforced on.</Empty>
      ) : (
        <ul className="plain">
          {allowed.map((t) => (
            <li key={t.name}>
              <a href={href({ page: "teams", team: t.name, tab: "access" })}>{t.name}</a>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

const HOST_STATE: Record<string, { kind: "running" | "muted" | "waiting"; glyph: string; word: string }> = {
  enrolled: { kind: "running", glyph: "●", word: "enrolled" },
  never_seen: { kind: "waiting", glyph: "◆", word: "never seen" },
  disabled: { kind: "muted", glyph: "○", word: "switched off" },
};

/** A machine's name, as the plane holds it: a hostname's label. */
const HOST_NAME = /^[a-z0-9]([a-z0-9.-]{0,61}[a-z0-9])?$/;

function Machines({ profile }: { profile: AdminProfile }): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.hosts(profile.name), [admin, profile.name]);
  const { done, clear, apply } = useChange(reload);
  const [minted, setMinted] = useState<Host | null>(null);
  const [form, setForm] = useState<{ name: string; address: string } | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [acting, setActing] = useState<{ kind: "rotate" | "switch"; host: Host } | null>(null);
  const busy = form !== null || acting !== null;
  const nameProblem = form && form.name.trim() !== "" && !HOST_NAME.test(form.name.trim()) ? "Lowercase letters, digits, dots and dashes." : null;

  const keep = (host: Host) => {
    if (host.secret) setMinted(host);
    return host;
  };

  return (
    <section aria-label={`Machines registered to ${profile.name}`}>
      <Region>Machines registered to {profile.name}</Region>
      {minted?.secret && (
        <ShownOnce label={`${minted.name}'s enrolment secret`} value={minted.secret}>
          {minted.ca && (
            <>
              <p className="note">And the CA it pins for the control port: it trusts this and nothing else for the channel its secret crosses.</p>
              <pre className="mono secret">{minted.ca}</pre>
            </>
          )}
        </ShownOnce>
      )}
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Loaded load={load} what={`${profile.name}'s machines`} retry={reload}>
        {(hosts) =>
          hosts.length === 0 ? (
            <Empty title="No machine registered">None is registered to {profile.name}. Register one, then install the worker on it with the secret it is given.</Empty>
          ) : (
            <div className="scroll">
              <table>
                <thead>
                  <tr>
                    <th>Machine</th>
                    <th>Address</th>
                    <th>State</th>
                    <th>Registered</th>
                    <th>Last enrolled</th>
                    <th aria-label="Actions" />
                  </tr>
                </thead>
                <tbody>
                  {hosts.map((h) => {
                    const s = HOST_STATE[h.state] ?? { kind: "muted" as const, glyph: "○", word: h.state };
                    return (
                      <tr key={h.name}>
                        <td className="mono">{h.name}</td>
                        <td className="mono">{show(h.address)}</td>
                        <td>
                          <Status kind={s.kind} glyph={s.glyph}>
                            {s.word}
                          </Status>
                        </td>
                        <td>{when(h.registered_at)}</td>
                        <td>{h.last_enrolled_at ? when(h.last_enrolled_at) : "never"}</td>
                        <td className="row-actions">
                          {!busy && (
                            <>
                              <button type="button" onClick={() => setActing({ kind: "rotate", host: h })}>
                                Rotate
                              </button>
                              <button type="button" onClick={() => setActing({ kind: "switch", host: h })}>
                                {h.enabled ? "Switch off" : "Switch on"}
                              </button>
                            </>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )
        }
      </Loaded>
      {acting?.kind === "rotate" && (
        <Preview
          title={`host/${profile.name}/${acting.host.name}`}
          lines={[{ field: "secret", from: "the one it enrols with", to: "a new one, shown once" }]}
          effects={[
            `${acting.host.name}'s secret stops working at once: its next enrolment is refused until it is given the new one.`,
            "The new secret and the CA are shown once, here.",
          ]}
          verb="Rotate"
          typeToConfirm={acting.host.name}
          onCancel={() => setActing(null)}
          onConfirm={async () => {
            const name = acting.host.name;
            await apply("host.rotate", `${profile.name}/${name}`, async () => keep(await admin.rotateHost(profile.name, name)), `${name} has a new secret.`);
            setActing(null);
          }}
        />
      )}
      {acting?.kind === "switch" && (
        <Preview
          title={`host/${profile.name}/${acting.host.name}`}
          lines={[{ field: "enabled", from: acting.host.enabled, to: !acting.host.enabled }]}
          effects={
            acting.host.enabled
              ? [`${acting.host.name}'s next enrolment is refused, and every one after it.`, "Nothing reaches the machine: a worker already connected keeps its sessions until it is drained."]
              : [`${acting.host.name} may enrol again with the secret it has.`]
          }
          verb={acting.host.enabled ? "Switch off" : "Switch on"}
          onCancel={() => setActing(null)}
          onConfirm={async () => {
            const { name, enabled } = acting.host;
            await apply(enabled ? "host.disable" : "host.enable", `${profile.name}/${name}`, () => admin.setHostEnabled(profile.name, name, !enabled), `${name} is switched ${enabled ? "off" : "on"}.`);
            setActing(null);
          }}
        />
      )}
      {!busy && (
        <button
          type="button"
          onClick={() => {
            clear();
            setMinted(null);
            setForm({ name: "", address: "" });
          }}
        >
          Register a machine to {profile.name}
        </button>
      )}
      {form && !previewing && (
        <form
          className="edit grid"
          aria-label={`A machine for ${profile.name}`}
          onSubmit={(e) => {
            e.preventDefault();
            if (form.name.trim() && !nameProblem) setPreviewing(true);
          }}
        >
          <Field label="Name" hint="The machine's name here: lowercase letters, digits, dots and dashes." error={nameProblem}>
            {(p) => <input {...p} value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} autoComplete="off" spellCheck={false} />}
          </Field>
          <Field label="Address" hint="Where it is, for whoever reads this list; nothing dials it.">
            {(p) => <input {...p} value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} autoComplete="off" spellCheck={false} />}
          </Field>
          <div className="actions">
            <button type="submit" className="primary" disabled={!form.name.trim() || Boolean(nameProblem)}>
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
          title={`host/${profile.name}/${form.name.trim()}`}
          lines={[
            { field: "name", from: null, to: form.name.trim() },
            ...(form.address.trim() ? [{ field: "address", from: null, to: form.address.trim() }] : []),
          ]}
          effects={[
            `${form.name.trim()} may enrol as a worker of ${profile.name}, and run what ${profile.name} is granted to run.`,
            ...(profile.missing_guarantees?.length ? [`Its workers do not get ${words(profile.missing_guarantees)}.`] : []),
            "Its enrolment secret and the CA are shown once, here.",
          ]}
          verb="Register"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            const host = { name: form.name.trim(), ...(form.address.trim() ? { address: form.address.trim() } : {}) };
            await apply("host.register", `${profile.name}/${host.name}`, async () => keep(await admin.registerHost(profile.name, host)), `${host.name} is registered to ${profile.name}.`);
            setPreviewing(false);
            setForm(null);
          }}
        />
      )}
    </section>
  );
}
