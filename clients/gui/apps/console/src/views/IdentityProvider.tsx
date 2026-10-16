// Sign-in: the identity provider people sign in through, and the SCIM connector that tells
// the plane when somebody has left.
//
// The provider is OpenID Connect: what its registration has to know about this plane (the
// URLs), every sign-in setting with where its value came from, a secret as set and never
// its value. A platform admin changes it behind the plane's own check (discovery answers
// and names itself the same, its keys can be read, the endpoints given agree with what it
// publishes); the check runs on the values in the form, and a save the provider does not
// stand behind is refused unless saved anyway for a provider that is down right now. A
// blank field is one nobody changed. Reset puts every sign-in setting back to the
// deployment's, which is the way back from a provider saved in error, and which the
// break-glass page at `/admin` can do too on the day nobody can sign in here.
//
// The SCIM connector: where the provider pushes, whether a token is set and where, when it
// was rotated and when the provider last pushed, and whether a pushed group becomes a team.
// Rotating mints a token shown once; forgetting it is typed by the base URL.

import { useState } from "react";
import type { JSX } from "react";
import type { PlatformSetting, ProviderCheck, ProviderState, ScimConnector } from "@troupe/client";
import { describeError, show, useConsole, useLoad } from "../console";
import { AuditNote, Checks, Field, Fields, Loaded, Preview, ShownOnce, Status, useChange, when } from "./bits";
import type { DiffLine } from "./bits";

export function IdentityProvider(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => Promise.all([admin.provider(), admin.scim()]), [admin]);
  return (
    <div className="page">
      <p className="lead">The identity provider people sign in through, and the connector that tells this plane when somebody has left it.</p>
      <Loaded load={load} what="sign-in" retry={reload}>
        {([provider, scim]) => (
          <>
            <Provider provider={provider} onApplied={reload} />
            <Scim scim={scim} onApplied={reload} />
          </>
        )}
      </Loaded>
    </div>
  );
}

// -- the provider --------------------------------------------------------------------------

function sourceWords(s: PlatformSetting): string {
  if (s.source === "stored") return "changed here";
  if (s.source === "deployed") return "from the deployment";
  return "not set";
}

function valueWords(s: PlatformSetting): string {
  if (s.secret) return s.set ? "set · never shown" : "not set";
  return show(s.value);
}

/** What a field shows: the value as the plane reads it, a list as words, a secret as nothing. */
function fieldOf(s: PlatformSetting): string {
  if (s.secret || s.value === null || s.value === undefined) return "";
  return Array.isArray(s.value) ? s.value.join(" ") : String(s.value);
}

function Provider({ provider, onApplied }: { provider: ProviderState; onApplied: () => void }): JSX.Element {
  const { admin, role } = useConsole();
  const platform = role === "platform_admin";
  const { done, apply } = useChange(onApplied);
  const editable = provider.settings.filter((s) => s.editable !== false);
  const [form, setForm] = useState<Record<string, string> | null>(null);
  const [check, setCheck] = useState<{ asked: string; answer: ProviderCheck } | { asked: string; error: unknown } | null>(null);
  const [force, setForce] = useState(false);
  const [previewing, setPreviewing] = useState<"put" | "reset" | null>(null);
  const stored = provider.settings.some((s) => s.source === "stored");

  // What the form changes: a field differing from what the plane reads, a secret only if typed.
  const typed = form
    ? Object.fromEntries(
        editable
          .map((s) => [s.key, (form[s.key] ?? "").trim()] as const)
          .filter(([key, v]) => {
            const s = editable.find((x) => x.key === key)!;
            return s.secret ? v !== "" : v !== "" && v !== fieldOf(s);
          }),
      )
    : {};
  const key = JSON.stringify(typed);
  const lines: DiffLine[] =
    previewing === "reset"
      ? provider.settings
          .filter((s) => s.source === "stored")
          .map((s) => ({ field: s.key, from: s.secret ? "set" : (s.value ?? null), to: s.secret ? (s.deployed ? "the deployment's" : null) : (s.deployed ?? null) }))
      : Object.entries(typed).map(([k, v]) => {
          const s = editable.find((x) => x.key === k)!;
          return s.secret ? { field: k, from: s.set ? "set" : null, to: "a new one, never shown" } : { field: k, from: fieldOf(s) || null, to: v };
        });
  const checked = check !== null && check.asked === key && "answer" in check;

  return (
    <section className="card" aria-label="Single sign-on">
      <header>
        <h2>Single sign-on</h2>
        <span className="meta">OpenID Connect · {provider.known_people} people have arrived through it</span>
      </header>
      <p>
        The authorization code flow for this console and the plane's own pages, the device grant for the terminal, one provider for both. Not SAML: there is no ACS
        URL and no metadata to upload. These are what the provider's registration has to know about this plane.
      </p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Fields
        paths
        rows={[
          ["Redirect", <code>{provider.urls.redirect ?? "unknown: base_url is not set"}</code>],
          ["Client discovery", <code>{provider.urls.discovery ?? "unknown"}</code>],
          ["Signing keys", <code>{provider.urls.jwks ?? "unknown"}</code>],
          ["MCP resource", <code>{provider.urls.resource_metadata ?? "unknown"}</code>],
        ]}
      />
      <Fields paths rows={provider.settings.map((s) => [s.key, <><span className="mono">{valueWords(s)}</span> <span className="hint">{sourceWords(s)}</span></>])} />
      {platform && form === null && previewing === null && (
        <div className="actions">
          <button
            type="button"
            onClick={() => {
              setForm(Object.fromEntries(editable.map((s) => [s.key, fieldOf(s)])));
              setCheck(null);
              setForce(false);
            }}
          >
            Change sign-in
          </button>
          {stored && (
            <button type="button" onClick={() => setPreviewing("reset")}>
              Back to the deployment
            </button>
          )}
        </div>
      )}
      {!platform && <p className="note">Only a platform admin changes sign-in.</p>}
      {form && previewing === null && (
        <form
          className="edit grid"
          aria-label="Sign-in"
          onSubmit={(e) => {
            e.preventDefault();
            setPreviewing("put");
          }}
        >
          {editable.map((s) => (
            <Field key={s.key} label={<code>{s.key}</code>} hint={`${s.summary ?? ""} ${s.secret ? (s.set ? "Blank keeps the one set." : "") : ""}`.trim()}>
              {(p) => (
                <input
                  {...p}
                  type={s.secret ? "password" : "text"}
                  value={form[s.key] ?? ""}
                  onChange={(e) => setForm({ ...form, [s.key]: e.target.value })}
                  placeholder={s.secret ? (s.set ? "set" : "not set") : "not set"}
                  autoComplete="off"
                  spellCheck={false}
                />
              )}
            </Field>
          ))}
          <div className="actions">
            <button
              type="button"
              onClick={() => {
                const asked = key;
                admin.providerCheck(typed).then(
                  (answer) => setCheck({ asked, answer }),
                  (error: unknown) => setCheck({ asked, error }),
                );
              }}
            >
              Check these values
            </button>
            <span className="hint">Asks the provider, writing nothing.</span>
          </div>
          {check && check.asked === key && ("answer" in check ? <Checks checks={check.answer.checks} /> : <p className="field-error">{describeError(check.error)}</p>)}
          {checked && "answer" in check && !check.answer.ok && (
            <label>
              <input type="checkbox" checked={force} onChange={(e) => setForce(e.target.checked)} /> Save anyway: the provider is down right now, and I know these values
              are right
            </label>
          )}
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
      {previewing && (
        <Preview
          title="sign-in"
          lines={lines}
          effects={
            previewing === "reset"
              ? ["Every sign-in value changed here goes, and the deployment's are read again.", "Somebody signing in from now on goes to the deployment's provider."]
              : [
                  force
                    ? "Saved without the provider standing behind it: anybody signing in fails until the provider answers as these values say."
                    : "The plane checks these values against the provider first and refuses them if it does not stand behind them.",
                  "Takes effect at the next sign-in. Anybody already signed in keeps their session.",
                  "If it is wrong and nobody can sign in, the break-glass page at /admin puts the deployment's values back.",
                ]
          }
          verb={previewing === "reset" ? "Put them back" : "Save"}
          onCancel={() => setPreviewing(null)}
          onConfirm={async () => {
            if (previewing === "reset") {
              await apply("provider.reset", "sign-in", () => admin.providerReset(), "Sign-in is back to the deployment's.", (a) => (a as ProviderState).changes);
            } else {
              await apply("provider.put", "sign-in", () => admin.providerPut(typed, force), "Sign-in is saved.", (a) => (a as ProviderState).changes);
              setForm(null);
            }
            setPreviewing(null);
          }}
        />
      )}
    </section>
  );
}

// -- SCIM --------------------------------------------------------------------------------

const SCIM_STATUS: Record<string, { kind: "running" | "waiting" | "muted" | "denied"; glyph: string; word: string }> = {
  connected: { kind: "running", glyph: "●", word: "connected" },
  quiet: { kind: "waiting", glyph: "◆", word: "quiet" },
  never_pushed: { kind: "muted", glyph: "○", word: "waiting for a push" },
  no_token: { kind: "denied", glyph: "✕", word: "off: no token" },
};

function Scim({ scim, onApplied }: { scim: ScimConnector; onApplied: () => void }): JSX.Element {
  const { admin, role } = useConsole();
  const platform = role === "platform_admin";
  const { done, apply } = useChange(onApplied);
  const [token, setToken] = useState<string | null>(null);
  const [acting, setActing] = useState<"rotate" | "delete" | "switch" | null>(null);
  const status = SCIM_STATUS[scim.status] ?? { kind: "muted" as const, glyph: "○", word: scim.status };
  const where = scim.token_set && scim.deployed_token_set ? "set here, and one in the deployment too" : scim.token_set ? "set here" : scim.deployed_token_set ? "from the deployment" : "not set";

  return (
    <section className="card" aria-label="SCIM connector">
      <header>
        <h2>SCIM connector</h2>
        <span className="meta">
          <Status kind={status.kind} glyph={status.glyph}>
            {status.word}
          </Status>
        </span>
      </header>
      <p>
        How this plane learns that somebody has stopped being in the directory, before their next sign-in. Point the provider's provisioning at the URL below with the
        token, and it pushes people and groups here.
      </p>
      {token && <ShownOnce label="The SCIM token" value={token}>{<p className="note">Paste it into the provider's provisioning settings; the token it had stopped working just now.</p>}</ShownOnce>}
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Fields
        rows={[
          ["Base URL", <code>{scim.base_url ?? "unknown: base_url is not set"}</code>],
          ["Token", `${where} · never shown`],
          ["Rotated", scim.rotated_at ? `${when(scim.rotated_at)}${scim.rotated_by ? ` by ${scim.rotated_by}` : ""}` : "never"],
          ["Last push", scim.last_seen_at ? `${when(scim.last_seen_at)} · ${scim.last_seen_op ?? ""}` : "never"],
          ["A pushed group", scim.teams_from_groups ? "becomes a team on arrival" : "stays a group until somebody enables it"],
        ]}
      />
      {platform && acting === null && (
        <div className="actions">
          <button type="button" onClick={() => setActing("rotate")}>
            {scim.token_set ? "Rotate the token" : "Make a token"}
          </button>
          <button type="button" onClick={() => setActing("switch")}>
            {scim.teams_from_groups ? "Stop making teams from groups" : "Make teams from pushed groups"}
          </button>
          {scim.token_set && scim.base_url && (
            <button type="button" className="danger" onClick={() => setActing("delete")}>
              Forget the token
            </button>
          )}
        </div>
      )}
      {!platform && <p className="note">Only a platform admin changes the connector.</p>}
      {acting === "rotate" && (
        <Preview
          title="scim/connector"
          lines={[{ field: "token", from: scim.token_set ? "the one set" : null, to: "a new one, shown once" }]}
          effects={[
            ...(scim.token_set ? ["The token set now stops working at once: every push presenting it answers 401 until the provider has the new one."] : []),
            "The new token is shown once, here.",
          ]}
          verb={scim.token_set ? "Rotate" : "Make it"}
          onCancel={() => setActing(null)}
          onConfirm={async () => {
            await apply("scim.rotate", "connector", async () => {
              const answer = await admin.scimRotate();
              if (answer.token) setToken(answer.token);
              return answer;
            }, "The SCIM token is new.");
            setActing(null);
          }}
        />
      )}
      {acting === "switch" && (
        <Preview
          title="scim/connector"
          lines={[{ field: "teams_from_groups", from: scim.teams_from_groups, to: !scim.teams_from_groups }]}
          effects={
            scim.teams_from_groups
              ? ["A pushed group stays a group until somebody enables it. No team made so far is removed."]
              : ["A group the provider pushes that is no team yet becomes one, named from its display name, with the platform's defaults for a new team."]
          }
          verb="Apply"
          onCancel={() => setActing(null)}
          onConfirm={async () => {
            await apply("scim.update", "connector", () => admin.scimUpdate({ teams_from_groups: !scim.teams_from_groups }), "The connector is changed.", (a) => (a as ScimConnector).changes);
            setActing(null);
          }}
        />
      )}
      {acting === "delete" && scim.base_url && (
        <Preview
          title="scim/connector"
          lines={[{ field: "token", from: "set", to: null }]}
          effects={[
            "Every push presenting it answers 401 from now on, so a person who leaves the directory is noticed only at their next sign-in.",
            ...(scim.deployed_token_set ? ["The deployment's own token is not touched, and still opens the door."] : []),
          ]}
          verb="Forget it"
          typeToConfirm={scim.base_url}
          onCancel={() => setActing(null)}
          onConfirm={async () => {
            setToken(null);
            await apply("scim.delete", "connector", () => admin.scimDelete(scim.base_url!), "The SCIM token is forgotten.");
            setActing(null);
          }}
        />
      )}
    </section>
  );
}

