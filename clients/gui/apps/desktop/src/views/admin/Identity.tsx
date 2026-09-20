// The identity provider: where people sign in, and the connector that tells this plane
// when they have left.
//
// Two cards, in the shape every tool an operator has already configured this in uses.
// Single sign-on: the provider's values with where each came from, the URLs the
// registration has to know about this plane, a check and a save behind it. The SCIM
// connector: a base URL, a token rotated here and seen once, when the provider last
// pushed, and one switch.
//
// Two rules carried over from the console. A blank field is a field nobody changed, which
// is what lets the client secret be edited without being retyped. And nothing here ever
// renders a credential after the notice it was minted in: the plane's answers say *set*
// and nothing more, and this component renders exactly those answers.

import { useCallback, useState } from "react";
import type { JSX } from "react";
import type { AdminApi, IdentityCheck, PlatformSetting, ProviderState, ScimConnector } from "@troupe/client";
import { useAdminQuery } from "../../hooks";
import { Loading, Pill } from "../bits";
import { AfterTheChange, Confirm, Failed, Table } from "./bits";

export function AdminIdentity({ api, platform }: { api: AdminApi; platform: boolean }): JSX.Element {
  const [wrote, setWrote] = useState(0);
  const after = (): void => setWrote((n) => n + 1);

  return (
    <>
      <SignIn api={api} platform={platform} nonce={wrote} onWrote={after} />
      <Scim api={api} platform={platform} nonce={wrote} onWrote={after} />
      <AfterTheChange api={api} nonce={wrote} />
    </>
  );
}

// -- single sign-on ---------------------------------------------------------------------

function SignIn({
  api,
  platform,
  nonce,
  onWrote,
}: {
  api: AdminApi;
  platform: boolean;
  nonce: number;
  onWrote: () => void;
}): JSX.Element {
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [checks, setChecks] = useState<IdentityCheck[] | null>(null);
  const [force, setForce] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const load = useCallback(() => api.provider(), [api]);
  const { data, loading, error: readError, reload } = useAdminQuery<ProviderState>(load, [load, nonce]);

  const check = async (): Promise<void> => {
    setBusy("check");
    setError(null);
    try {
      const result = await api.providerCheck(drafts);
      setChecks(result.checks);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const save = async (): Promise<void> => {
    setBusy("save");
    setError(null);
    try {
      const result = await api.providerPut(drafts, force);
      const changed = Object.keys(result.changes ?? {}).sort();
      setNotice(changed.length === 0 ? "Nothing changed." : `Saved: ${changed.join(", ")}. In force on the next sign-in.`);
      setDrafts({});
      setChecks(null);
      setForce(false);
      reload();
      onWrote();
    } catch (e) {
      // A refused save carries the checks, so the card shows why rather than no.
      const carried = (e as { data?: { checks?: IdentityCheck[] } }).data?.checks;
      if (carried) setChecks(carried);
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const reset = async (): Promise<void> => {
    setBusy("reset");
    setError(null);
    try {
      await api.providerReset();
      setNotice("Every sign-in setting is back to what this plane was deployed with.");
      setResetting(false);
      setDrafts({});
      setChecks(null);
      reload();
      onWrote();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const anyStored = (data?.settings ?? []).some((s) => s.source === "stored");

  return (
    <section className="group">
      <h3>
        Single sign-on
        <span className="micro muted"> — OpenID Connect, not SAML: no ACS URL, no metadata upload</span>
      </h3>
      <Failed error={readError ?? error} />
      {notice && <p className="note">{notice}</p>}
      {loading && !data && <Loading what="Reading the provider…" />}

      {data && (
        <>
          <dl className="facts wide">
            <dt>Redirect URL</dt>
            <dd className="mono micro">{data.urls.redirect ?? "unknown — base_url is not set"}</dd>
            <dt>Client discovery</dt>
            <dd className="mono micro">{data.urls.discovery ?? "unknown"}</dd>
            <dt>Signing keys</dt>
            <dd className="mono micro">{data.urls.jwks ?? "unknown"}</dd>
            <dt>MCP resource</dt>
            <dd className="mono micro">{data.urls.resource_metadata ?? "unknown"}</dd>
            <dt>People arrived</dt>
            <dd>{data.known_people}</dd>
          </dl>

          <Table head={["Setting", "Value", "From", "What it does"]}>
            {data.settings.map((s) => (
              <tr key={s.key}>
                <th scope="row" className="mono micro">
                  {s.key}
                </th>
                <td>
                  <input
                    type={s.secret ? "password" : "text"}
                    value={drafts[s.key] ?? (s.secret ? "" : shown(s))}
                    placeholder={s.secret ? (s.set ? "set — leave blank to keep it" : "not set") : "not set"}
                    disabled={!platform}
                    aria-label={`Value for ${s.key}`}
                    autoComplete="off"
                    onChange={(e) => setDrafts({ ...drafts, [s.key]: e.target.value })}
                  />
                </td>
                <td>
                  <Source source={s.source} />
                </td>
                <td className="micro">
                  {s.summary ?? s.description ?? "—"}
                  {s.consequence ? <span className="muted"> {s.consequence}</span> : null}
                </td>
              </tr>
            ))}
          </Table>

          {platform && (
            <div className="inline-form">
              <button disabled={busy !== null} onClick={() => void check()}>
                {busy === "check" ? "Asking the provider…" : "Check"}
              </button>
              <button className="primary" disabled={busy !== null} onClick={() => void save()}>
                {busy === "save" ? "Saving…" : "Save"}
              </button>
              <label className="inline">
                <input type="checkbox" checked={force} onChange={(e) => setForce(e.target.checked)} /> save anyway, the provider is
                down
              </label>
              {anyStored && !resetting && (
                <button className="link" disabled={busy !== null} onClick={() => setResetting(true)}>
                  Back to the deployment
                </button>
              )}
              {resetting && (
                <span className="micro">
                  Every sign-in value changed here goes, and the deployment's are read again.{" "}
                  <button className="link danger" disabled={busy !== null} onClick={() => void reset()}>
                    Put them back
                  </button>{" "}
                  <button className="link" onClick={() => setResetting(false)}>
                    No
                  </button>
                </span>
              )}
            </div>
          )}

          {checks && (
            <Table head={["Check", "Result", "What it proved", "Took"]}>
              {checks.map((c) => (
                <tr key={c.name}>
                  <th scope="row">{c.name}</th>
                  <td>{c.ok ? <Pill status="allowed">Passed</Pill> : <Pill status="error">Failed</Pill>}</td>
                  <td className="micro">{c.detail ?? "—"}</td>
                  <td>{c.took_ms === undefined ? "—" : `${c.took_ms} ms`}</td>
                </tr>
              ))}
            </Table>
          )}

          <p className="note micro">
            A blank field is a field nobody changed. Saving runs the check first and is refused when the provider does not
            stand behind the values; a wrong save is undone with <em>back to the deployment</em>, and the break-glass door
            opens the console without any provider at all.
          </p>
        </>
      )}
    </section>
  );
}

// -- the SCIM connector -----------------------------------------------------------------

function Scim({
  api,
  platform,
  nonce,
  onWrote,
}: {
  api: AdminApi;
  platform: boolean;
  nonce: number;
  onWrote: () => void;
}): JSX.Element {
  const [deleting, setDeleting] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [token, setToken] = useState<string | null>(null);

  const load = useCallback(() => api.scim(), [api]);
  const { data, loading, error: readError, reload } = useAdminQuery<ScimConnector>(load, [load, nonce]);

  const run = async (what: string, action: () => Promise<void>): Promise<void> => {
    setBusy(what);
    setError(null);
    try {
      await action();
      reload();
      onWrote();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const rotate = (): Promise<void> =>
    run("rotate", async () => {
      const result = await api.scimRotate();
      // The one time the token is ever seen: in this notice, and in no state after the
      // next change to the card.
      setToken(result.token ?? null);
    });

  const remove = (): Promise<void> =>
    run("delete", async () => {
      if (!data?.base_url) return;
      await api.scimDelete(data.base_url);
      setDeleting(false);
      setToken(null);
    });

  const toggle = (on: boolean): Promise<void> =>
    run("switch", async () => {
      await api.scimUpdate({ teams_from_groups: on });
      setToken(null);
    });

  return (
    <section className="group">
      <h3>
        SCIM connector
        <span className="micro muted"> — how this plane learns that somebody has left</span>
      </h3>
      <Failed error={readError ?? error} />
      {loading && !data && <Loading what="Reading the connector…" />}

      {token && (
        <p className="note">
          The connector's token, shown once — paste it into the provider now: <code className="mono">{token}</code>
        </p>
      )}

      {data && (
        <>
          <dl className="facts wide">
            <dt>Base URL</dt>
            <dd className="mono micro">{data.base_url ?? "unknown — base_url is not set"}</dd>
            <dt>Status</dt>
            <dd>{statusOf(data)}</dd>
            <dt>Token</dt>
            <dd>{tokenOf(data)}</dd>
            <dt>Last rotated</dt>
            <dd>{data.rotated_at ? `${data.rotated_at}${data.rotated_by ? ` by ${data.rotated_by}` : ""}` : "never"}</dd>
            <dt>Last sync</dt>
            <dd>{data.last_seen_at ? `${data.last_seen_at} · ${data.last_seen_op ?? ""}` : "never"}</dd>
          </dl>

          {platform && (
            <div className="inline-form">
              <button disabled={busy !== null} onClick={() => void rotate()}>
                {busy === "rotate" ? "Minting…" : data.token_set ? "Rotate the token" : "Create a token"}
              </button>
              {data.token_set && (
                <button className="link" disabled={busy !== null} onClick={() => setDeleting(true)}>
                  Delete the token
                </button>
              )}
              <label className="inline">
                <input
                  type="checkbox"
                  checked={data.teams_from_groups}
                  disabled={busy !== null}
                  onChange={(e) => void toggle(e.target.checked)}
                />{" "}
                Create teams from SCIM groups
              </label>
            </div>
          )}

          <p className="note micro">
            The provider's connection test is a <code>GET</code> on <code>Users</code> with a filter, and that is what{" "}
            <em>last sync</em> shows after it. With the switch on, a group the provider pushes becomes a team named from
            its display name, with the platform's defaults; off, it is a group until somebody enables it. Turning it off
            creates no more and deletes none.
          </p>
        </>
      )}

      {deleting && data?.base_url && (
        <Confirm
          what="Delete the token"
          identifier={data.base_url}
          consequence={`Every push from the provider answers 401 until a new token is made${
            data.deployed_token_set ? ", except with the deployment's own token, which stays" : ""
          }.`}
          busy={busy !== null}
          onCancel={() => setDeleting(false)}
          onConfirm={() => void remove()}
        />
      )}
    </section>
  );
}

// -- words --------------------------------------------------------------------------------

function shown(s: PlatformSetting): string {
  if (s.value === null || s.value === undefined) return "";
  if (Array.isArray(s.value)) return s.value.join(" ");
  return typeof s.value === "string" ? s.value : JSON.stringify(s.value);
}

function Source({ source }: { source: string }): JSX.Element {
  if (source === "deployed") return <Pill status="readonly">Deployed</Pill>;
  if (source === "stored") return <Pill status="allowed">Changed here</Pill>;
  return <Pill status="dormant">Unset</Pill>;
}

export function statusOf(c: ScimConnector): string {
  switch (c.status) {
    case "connected":
      return `connected — the provider pushed at ${c.last_seen_at ?? "?"}`;
    case "quiet":
      return `quiet — nothing from the provider since ${c.last_seen_at ?? "?"}`;
    case "never_pushed":
      return "waiting — a token exists and the provider has not pushed yet";
    case "no_token":
      return "off — no token anywhere, so every push answers 401";
    default:
      return c.status;
  }
}

export function tokenOf(c: ScimConnector): string {
  if (c.token_set && c.deployed_token_set) return "set here, and one in the deployment too; either opens the door";
  if (c.token_set) return "set here · reference only, never shown";
  if (c.deployed_token_set) return "from the deployment (TROUPE_SCIM_TOKEN) · rotating here adds one beside it";
  return "not set";
}
