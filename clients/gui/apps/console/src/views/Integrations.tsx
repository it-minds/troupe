// Integrations: what this plane talks to that is not a person.
//
// First the plane's GitHub App, the one identity its pods clone and push with: what is set
// (never the key: its fingerprint and which transit version it is), a test against GitHub
// that writes nothing, and, for a platform admin, setting it and removing it. A change is
// previewed with the audit's own fields and confirmed; removing it is typed by its App ID.
// The private key and the webhook secret are pasted once and imported into OpenBao by the
// plane; nothing here keeps them, and no answer ever carries them back. A platform admin
// also sees what the App's webhook took lately and what the plane did with each delivery.
// On a `gitops` plane the App's ID, API URL and installations come from a `GitHubApp`
// resource: shown locked, with where they come from, and only its key and webhook secret,
// which no repository holds, are set here.
//
// Then three lists `admin.integrations.list` answers, read-only on purpose: the MCP servers
// more than one profile carries (the organisation's, and the blast radius of retiring one),
// every host anything dials against the same policy the pods' NetworkPolicy is made from,
// with where it was declared, which is where it is changed, and every trigger's
// notification target checked again rather than trusted.

import { useState } from "react";
import type { JSX } from "react";
import type { GitHubApp, GitHubAppChange, GitHubCheck, GitHubDelivery, IntegrationServer, Integrations as IntegrationsAnswer } from "@troupe/client";
import { describeError, show, useConsole, useLoad } from "../console";
import { AuditNote, Checks, DetailList, Empty, Field, Fields, GitopsProblem, Loaded, Locked, Preview, Region, Status, changed, useChange, when } from "./bits";
import type { DiffLine } from "./bits";

export function Integrations(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => Promise.all([admin.github(), admin.integrations()]), [admin]);
  return (
    <div className="page">
      <p className="lead">What this plane talks to that is not a person, and whether the cluster's policy lets it.</p>
      <Loaded load={load} what="the integrations" retry={reload}>
        {([app, answer]) => (
          <>
            <GitHubCard app={app} onApplied={reload} />
            <Deliveries />
            <Servers answer={answer} />
            <Egress answer={answer} />
            <Notify answer={answer} />
          </>
        )}
      </Loaded>
    </div>
  );
}

// -- the GitHub App --------------------------------------------------------------------

interface AppForm {
  appId: string;
  apiUrl: string;
  installations: string;
  privateKey: string;
  webhookSecret: string;
}

function formOf(app: GitHubApp): AppForm {
  return {
    appId: app.app_id === null ? "" : String(app.app_id),
    apiUrl: app.api_url === "https://api.github.com" ? "" : app.api_url,
    installations: app.installations.map((i) => `${i.owner} ${i.installation_id}`).join("\n"),
    privateKey: "",
    webhookSecret: "",
  };
}

/** The installations as the form holds them, one `owner id` a line; null where one does not read. */
function installationsOf(text: string): Array<{ owner: string; installation_id: number }> | null {
  const lines = text.split("\n").map((l) => l.trim()).filter(Boolean);
  const read = lines.map((l) => {
    const [owner, id, ...rest] = l.split(/[\s,]+/);
    return owner && id && /^\d+$/.test(id) && rest.length === 0 ? { owner, installation_id: Number(id) } : null;
  });
  return read.every((r) => r !== null) ? (read as Array<{ owner: string; installation_id: number }>) : null;
}

/**
 * What the form asks for, as `admin.github.put` takes it: only the keys that moved. On a
 * gitops plane only the key and the webhook secret, which no resource holds.
 */
function changeOf(app: GitHubApp, form: AppForm): GitHubAppChange | null {
  const change: GitHubAppChange = {};
  if (app.gitops) {
    if (form.privateKey.trim() !== "") change.private_key = form.privateKey.trim();
    if (form.webhookSecret.trim() !== "") change.webhook_secret = form.webhookSecret.trim();
    return change;
  }
  const installations = installationsOf(form.installations);
  if (installations === null) return null;
  const id = form.appId.trim() === "" ? null : /^\d+$/.test(form.appId.trim()) ? Number(form.appId.trim()) : NaN;
  if (Number.isNaN(id)) return null;
  if (id !== app.app_id) change.app_id = id;
  const api = form.apiUrl.trim() === "" ? null : form.apiUrl.trim();
  if ((api ?? "https://api.github.com") !== app.api_url) change.api_url = api;
  if (JSON.stringify(installations) !== JSON.stringify(app.installations)) change.installations = installations;
  if (form.privateKey.trim() !== "") change.private_key = form.privateKey.trim();
  if (form.webhookSecret.trim() !== "") change.webhook_secret = form.webhookSecret.trim();
  return change;
}

function GitHubCard({ app, onApplied }: { app: GitHubApp; onApplied: () => void }): JSX.Element {
  const { admin, role } = useConsole();
  const platform = role === "platform_admin";
  const { done, apply } = useChange(onApplied);
  const [form, setForm] = useState<AppForm | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [check, setCheck] = useState<{ state: "asking" } | { state: "done"; answer: GitHubCheck } | { state: "failed"; error: unknown } | null>(null);
  const change = form ? changeOf(app, form) : null;
  const lines: DiffLine[] = change
    ? [
        ...changed({ app_id: app.app_id, api_url: app.api_url, installations: app.installations }, {
          app_id: "app_id" in change ? change.app_id : app.app_id,
          api_url: "api_url" in change ? (change.api_url ?? "https://api.github.com") : app.api_url,
          installations: change.installations ?? app.installations,
        }),
        ...(change.private_key ? [{ field: "private_key", from: app.private_key.fingerprint ?? null, to: "the key pasted, by its fingerprint once imported" }] : []),
        ...(change.webhook_secret ? [{ field: "webhook_secret", from: app.webhook?.secret.set ? `version ${String(app.webhook.secret.version)}` : null, to: "the secret typed, never shown" }] : []),
      ]
    : [];
  const busy = form !== null || removing;
  // On a gitops plane the App's ID, API URL and installations are a `GitHubApp` resource's.
  const locked = Boolean(app.gitops);

  const test = () => {
    setCheck({ state: "asking" });
    admin.checkGithub().then(
      (answer) => setCheck({ state: "done", answer }),
      (error: unknown) => setCheck({ state: "failed", error }),
    );
  };

  return (
    <section className="card" aria-label="The GitHub App">
      <header>
        <h2>The GitHub App</h2>
        <span className="meta">
          {app.configured ? (
            <Status kind="running" glyph="●">
              configured
            </Status>
          ) : (
            <Status kind="muted" glyph="○">
              not configured
            </Status>
          )}
        </span>
      </header>
      <p>The one identity this plane's pods clone and push with, on the repositories the organisation installed it on. Its key is in OpenBao's transit engine, where nothing can take a copy.</p>
      {app.gitops && (
        <Locked things="GitHub App's ID, API URL and installations, and every team's GitHub repositories," source={app.gitops.source}>
          <p className="note">
            They come from the resource <code>GitHubApp/{app.gitops.resource}</code>
            {app.gitops.generation !== null ? `, read at generation ${app.gitops.generation}` : ""}. The App's private key and webhook secret are no resource's: they are still set here, into OpenBao.
          </p>
          <GitopsProblem gitops={app.gitops} />
        </Locked>
      )}
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Fields
        rows={[
          ["App ID", show(app.app_id)],
          ["API", <span className="mono">{app.api_url}</span>],
          ["Clones from", <span className="mono">{app.git_url ?? "—"}</span>],
          ["Installations", app.installations.length ? app.installations.map((i) => `${i.owner} (${i.installation_id})`).join(", ") : "none"],
          [
            "Private key",
            app.private_key.set ? (
              <>
                <span className="mono">{app.private_key.fingerprint}</span>
                <span className="hint">
                  {" "}
                  {app.private_key.type}, transit key {app.private_key.transit_key} version {app.private_key.version}; never shown
                </span>
              </>
            ) : (
              "not set"
            ),
          ],
          [
            "Webhook",
            app.webhook ? (
              <>
                <span className="mono">{app.webhook.path}</span>
                <span className="hint">
                  {" "}
                  {app.webhook.secret.set ? `signed with a secret at version ${String(app.webhook.secret.version)}; never shown` : "no secret set, so every delivery is refused"}
                </span>
              </>
            ) : (
              "—"
            ),
          ],
          ["A session's clone token", Object.entries(app.permissions).map(([k, v]) => `${k}: ${v}`).join(", ") || "—"],
          ["Changed", app.updated_by ? `${when(app.updated_at)} by ${app.updated_by}` : "—"],
        ]}
      />
      {platform && !busy && (
        <div className="actions">
          <button type="button" onClick={test} disabled={check?.state === "asking"}>
            {check?.state === "asking" ? "Asking GitHub…" : "Test it"}
          </button>
          <button type="button" onClick={() => setForm(formOf(app))}>
            {locked ? "Set its key or webhook secret" : app.app_id === null ? "Set the App" : "Change the App"}
          </button>
          {app.app_id !== null && (!locked || app.gitops?.problem === "missing") && (
            <button type="button" className="danger" onClick={() => setRemoving(true)}>
              Remove the App
            </button>
          )}
        </div>
      )}
      {!platform && <p className="note">Only a platform admin changes or tests the App: one App serves every team on the plane.</p>}
      {check?.state === "done" && (
        <div className="check" role="status" aria-label="What GitHub said">
          <p>{check.answer.ok ? `GitHub knows the App${check.answer.app?.slug ? ` as ${check.answer.app.slug}` : ""}, and every installation set here.` : "The App does not work as set:"}</p>
          <Checks checks={check.answer.checks} />
        </div>
      )}
      {check?.state === "failed" && (
        <p className="field-error" role="alert">
          {describeError(check.error)}
        </p>
      )}
      {form && !previewing && (
        <form
          className="edit grid"
          aria-label="The GitHub App"
          onSubmit={(e) => {
            e.preventDefault();
            setPreviewing(true);
          }}
        >
          {!locked && (
            <>
              <Field label="App ID" hint="The number on the App's settings page at GitHub.">
                {(p) => <input {...p} value={form.appId} onChange={(e) => setForm({ ...form, appId: e.target.value })} inputMode="numeric" autoComplete="off" />}
              </Field>
              <Field label="API URL" hint="Empty for github.com. https://api.<name>.ghe.com for Enterprise Cloud; https://<host>/api/v3 for Enterprise Server.">
                {(p) => <input {...p} value={form.apiUrl} onChange={(e) => setForm({ ...form, apiUrl: e.target.value })} placeholder="https://api.github.com" spellCheck={false} />}
              </Field>
              <Field
                label="Installations"
                hint="One a line: the organisation or account, then the installation's number from its URL at GitHub. The whole list: one left out is no longer used."
                error={installationsOf(form.installations) === null ? "Each line is an owner and a number, like example-org 77001." : null}
              >
                {(p) => <textarea {...p} value={form.installations} onChange={(e) => setForm({ ...form, installations: e.target.value })} rows={3} spellCheck={false} />}
              </Field>
            </>
          )}
          <Field
            label="Private key"
            hint={
              app.private_key.set
                ? "Empty keeps the key there is. A new PEM becomes its next version, and the plane signs with it from then on."
                : "The PEM GitHub downloads. The plane imports it into OpenBao and keeps no copy; it is in no answer afterwards."
            }
          >
            {(p) => (
              <textarea
                {...p}
                value={form.privateKey}
                onChange={(e) => setForm({ ...form, privateKey: e.target.value })}
                rows={4}
                spellCheck={false}
                autoComplete="off"
                placeholder="-----BEGIN RSA PRIVATE KEY-----"
              />
            )}
          </Field>
          <Field
            label="Webhook secret"
            hint={
              app.webhook?.secret.set
                ? "Empty keeps the secret there is. A new one must be typed into the App's webhook settings at GitHub too."
                : "As typed into the App's webhook settings at GitHub, at least 32 characters (openssl rand -hex 32 makes one). Kept in OpenBao, never shown back."
            }
          >
            {(p) => <input {...p} type="password" value={form.webhookSecret} onChange={(e) => setForm({ ...form, webhookSecret: e.target.value })} autoComplete="off" spellCheck={false} />}
          </Field>
          <div className="actions">
            <button type="submit" className="primary" disabled={!change || lines.length === 0}>
              Preview
            </button>
            <button type="button" onClick={() => setForm(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}
      {form && previewing && change && (
        <Preview
          title="github/app"
          lines={lines}
          effects={appWords(app, change)}
          verb="Apply"
          onCancel={() => setPreviewing(false)}
          onConfirm={async () => {
            await apply("github.put", "app", () => admin.putGithub(change), "The GitHub App is changed.", (a) => (a as GitHubApp).changes);
            setPreviewing(false);
            setForm(null);
          }}
        />
      )}
      {removing && app.app_id !== null && (
        <Preview
          title="github/app"
          lines={[
            { field: "app_id", from: app.app_id, to: null },
            { field: "installations", from: app.installations.map((i) => i.owner), to: [] },
            { field: "fingerprint", from: app.private_key.fingerprint, to: null },
          ]}
          effects={[
            "A session that names a repository is refused from now on, and a pod asking for a session's token is given none.",
            "Sessions already cloned keep what they cloned; their next push or pull request has no token.",
            "The key stays in OpenBao, where nothing signs with it. Setting an App again with a key imports that as its next version.",
          ]}
          verb="Remove the App"
          typeToConfirm={String(app.app_id)}
          onCancel={() => setRemoving(false)}
          onConfirm={async () => {
            await apply("github.delete", "app", () => admin.deleteGithub(app.app_id!), "The GitHub App is removed.", (a) => (a as GitHubApp).changes);
            setRemoving(false);
          }}
        />
      )}
    </section>
  );
}

function appWords(app: GitHubApp, change: GitHubAppChange): string[] {
  const out: string[] = [];
  if ("app_id" in change) out.push(change.app_id === null ? "The plane has no App ID: no session can name a repository." : `The plane signs as App ${change.app_id}.`);
  if (change.private_key) out.push(app.private_key.set ? "The key becomes the next version in OpenBao and the plane signs with it; GitHub must hold its public half." : "The key is imported into OpenBao and is in no answer afterwards.");
  if (change.installations) {
    const owners = change.installations.map((i) => i.owner);
    const gone = app.installations.filter((i) => !owners.includes(i.owner)).map((i) => i.owner);
    if (gone.length) out.push(`A session can no longer name a repository of ${gone.join(", ")}.`);
    out.push(owners.length ? `Sessions may name repositories of ${owners.join(", ")}.` : "No installation is left: no session can name a repository.");
  }
  if (change.webhook_secret) out.push("Every delivery is checked against the new secret from now on: GitHub's webhook settings must have the same one, or its deliveries are refused.");
  if ("api_url" in change) out.push(`Clones come from where ${change.api_url ?? "https://api.github.com"} says, and each profile must declare that host in egress.gitHosts.`);
  out.push("Test it afterwards: the test asks GitHub with the App's own key.");
  return out;
}

// -- what the plane dials ---------------------------------------------------------------

function credential(s: IntegrationServer): string {
  if (s.credential_mode === "person") return `each person's own${s.credential_ref ? `, in slot ${s.credential_ref}` : ""}`;
  if (s.credential_mode === "client_credentials") return "each profile's own identity, by client credentials";
  if (s.credential_ref) return `a Secret named ${s.credential_ref}`;
  return "none";
}

function Servers({ answer }: { answer: IntegrationsAnswer }): JSX.Element {
  return (
    <>
      <Region>MCP servers · more than one profile</Region>
      <p className="note">An organisation's integration rather than one profile's: the profiles are the blast radius of retiring it.</p>
      {answer.servers.length === 0 ? <Empty title="No shared server">No server is carried by two profiles: everything below belongs to one.</Empty> : <ServerTable servers={answer.servers} />}
      {answer.profile_servers.length > 0 && (
        <>
          <Region>MCP servers · one profile each</Region>
          <ServerTable servers={answer.profile_servers} />
        </>
      )}
    </>
  );
}

function ServerTable({ servers }: { servers: IntegrationServer[] }): JSX.Element {
  return (
    <div className="scroll">
      <table>
        <thead>
          <tr>
            <th>Server</th>
            <th>URL</th>
            <th>Credential</th>
            <th>Carried by</th>
          </tr>
        </thead>
        <tbody>
          {servers.map((s) => (
            <tr key={s.name}>
              <td>{s.name}</td>
              <td className="mono">{s.url}</td>
              <td>{credential(s)}</td>
              <td>{s.profiles.join(", ")}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Egress({ answer }: { answer: IntegrationsAnswer }): JSX.Element {
  return (
    <>
      <Region>Every host anything here dials</Region>
      <p className="note">
        Checked against the same function the pods' network policy is made from. A host the policy refuses is a tool that fails the first time somebody uses it,
        and it is changed where it was declared, which is the column beside it. Read-only here: an allowlist edited in two places is one nobody trusts.
      </p>
      {answer.egress.length === 0 ? (
        <Empty title="Nothing dials out">Nothing here dials anything outside the cluster.</Empty>
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Host</th>
                <th>Declared by</th>
                <th>The policy</th>
              </tr>
            </thead>
            <tbody>
              {answer.egress.map((e) => (
                <tr key={e.host}>
                  <td className="mono">{e.host}</td>
                  <td>{e.from}</td>
                  <td>
                    {e.allowed ? (
                      <Status kind="running" glyph="●">
                        allowed
                      </Status>
                    ) : (
                      <Status kind="denied" glyph="✕">
                        refused
                      </Status>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function Notify({ answer }: { answer: IntegrationsAnswer }): JSX.Element {
  return (
    <>
      <Region>Where outcomes are sent</Region>
      <p className="note">
        A trigger may post its outcome somewhere. The target must name a host and must not be this machine; it is checked again here rather than trusted, since one that
        passed when it was saved and does not now is what somebody needs told.
      </p>
      {answer.notify.length === 0 ? (
        <Empty title="No notification target">No trigger sends its outcome anywhere.</Empty>
      ) : (
        <ul className="plain">
          {answer.notify.map((n) => (
            <li key={`${n.team}/${n.trigger}`}>
              {n.refusal ? (
                <Status kind="denied" glyph="✕">
                  would be refused
                </Status>
              ) : (
                <Status kind="running" glyph="●">
                  passes
                </Status>
              )}{" "}
              <span className="mono">
                {n.team}/{n.trigger}
              </span>{" "}
              <span className="mono">{n.url}</span>
              {n.refusal && <span> · {n.refusal}</span>}
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

/** What the App's webhook took lately, and what the plane made of each: a platform admin's. */
function Deliveries(): JSX.Element | null {
  const { admin, role } = useConsole();
  const [load, reload] = useLoad(() => (role === "platform_admin" ? admin.githubDeliveries(20) : Promise.resolve(null)), [admin, role]);
  if (role !== "platform_admin") return null;
  return (
    <section aria-label="What GitHub has sent">
      <Region>What GitHub has sent</Region>
      <p className="note">
        The newest deliveries the App's webhook took, by GitHub's own id, and what the plane did with each: the runs it fired, the session it sent back to work, or
        why neither. Never what an issue or a review said.
      </p>
      <Loaded load={load} what="the deliveries" retry={reload}>
        {(deliveries: GitHubDelivery[] | null) =>
          !deliveries || deliveries.length === 0 ? (
            <Empty title="Nothing received yet">GitHub has sent this plane no delivery it took.</Empty>
          ) : (
            <div className="scroll">
              <table>
                <thead>
                  <tr>
                    <th>Received</th>
                    <th>Event</th>
                    <th>What the plane did</th>
                    <th>Delivery</th>
                  </tr>
                </thead>
                <tbody>
                  {deliveries.map((d) => (
                    <tr key={d.id}>
                      <td>{when(d.received_at)}</td>
                      <td className="mono">
                        {d.event}
                        {d.action ? `.${d.action}` : ""}
                      </td>
                      <td>{d.outcome ? <DetailList detail={d.outcome} /> : "—"}</td>
                      <td className="mono">{d.id}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        }
      </Loaded>
    </section>
  );
}