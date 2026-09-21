// Which model a session on this computer talks to.
//
// The daemon keeps these settings in a file of its own, and this window has no way to
// touch a file — deliberately — so the panel is a form over three daemon methods:
// `config.get` to fill it, `config.models` to find out what a provider offers before
// anything is kept, and `config.set` to keep it. The rules about what an empty field
// means live in `@troupe/client`, where a test can see them; this is the screen.
//
// The key is the one thing that only ever travels one way. It is typed, sent, and never
// shown again: the daemon answers whether one is saved, not what it is, and the field
// is empty every time the panel is opened. An empty field on save keeps the saved key,
// so saving a model change never asks for the key again, and removing one is a separate
// button that says it removes it.

import { useEffect, useMemo, useState } from "react";
import type { JSX } from "react";
import {
  MODEL_ROLES,
  PROVIDER_DEFAULT_URLS,
  applyClientDefaults,
  clientDefaults,
  configSetParams,
  describeOffer,
  describeOverride,
  discoveryParams,
  formFromConfig,
  modelConfigError,
} from "@troupe/client";
import type { AuthSession, ClientDefaults, DaemonClient, ModelConfig, ModelDiscovery, ModelForm, ModelRole } from "@troupe/client";
import { Failed, Loading, Pill } from "./bits";

const PROVIDERS: Array<{ id: string; label: string }> = [
  { id: "anthropic", label: "Anthropic" },
  { id: "openai", label: "OpenAI-compatible (LiteLLM, vLLM, gateways…)" },
];

const ROLES: Record<ModelRole, { label: string; hint: string }> = {
  default: { label: "Main model", hint: "does the editing — usually the capable, expensive one" },
  cheap: { label: "Cheap model", hint: "exploring, summarising, and /ask" },
  expensive: { label: "Heaviest work", hint: "optional — for the hardest problems" },
};

const KEY_SOURCES: Record<string, string> = {
  file: "Key saved",
  env: "Key from an environment variable",
  opencode: "Key from OpenCode's settings",
};

export function Models({ client, auth }: { client: DaemonClient; auth: AuthSession | null }): JSX.Element {
  const [saved, setSaved] = useState<ModelConfig | null>(null);
  const [form, setForm] = useState<ModelForm | null>(null);
  const [readError, setReadError] = useState<string | null>(null);
  const [discovery, setDiscovery] = useState<ModelDiscovery | null>(null);
  const [org, setOrg] = useState<ClientDefaults | null>(null);
  const [busy, setBusy] = useState<"discovering" | "saving" | "removing" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<{ text: string; done: boolean } | null>(null);

  useEffect(() => {
    let live = true;
    client
      .modelConfig()
      .then((c) => {
        if (!live) return;
        setSaved(c);
        setForm(formFromConfig(c));
      })
      .catch((e: unknown) => live && setReadError(modelConfigError(e)));
    return () => {
      live = false;
    };
  }, [client]);

  // Asked up front rather than on click, so the button only exists when there is
  // something behind it. A plane too old to know the method, or one that is not
  // answering, is the same as an organisation with no defaults: no button.
  useEffect(() => {
    if (!auth) return;
    let live = true;
    clientDefaults((m, p) => auth.rpc(m, p))
      .then((d) => live && setOrg(d))
      .catch(() => live && setOrg(null));
    return () => {
      live = false;
    };
  }, [auth]);

  const offered = useMemo(() => new Map((discovery?.models ?? []).map((m) => [m.id, m])), [discovery]);

  if (readError) {
    return (
      <section className="group">
        <h3>Models</h3>
        <Failed error={readError} />
      </section>
    );
  }
  if (!saved || !form) {
    return (
      <section className="group">
        <h3>Models</h3>
        <Loading what="Reading the model settings…" />
      </section>
    );
  }

  const edit = (changes: Partial<ModelForm>): void => {
    setForm({ ...form, ...changes });
    setOutcome(null);
  };
  const editRole = (role: ModelRole, value: string): void => edit({ models: { ...form.models, [role]: value } });

  const act = async (what: NonNullable<typeof busy>, run: () => Promise<void>): Promise<void> => {
    setBusy(what);
    setError(null);
    setOutcome(null);
    try {
      await run();
    } catch (e) {
      setError(modelConfigError(e));
    } finally {
      setBusy(null);
    }
  };

  const discover = () =>
    act("discovering", async () => {
      setDiscovery(await client.discoverModels(discoveryParams(form)));
    });

  // Both keep whatever the daemon answers as the new starting point, so the form is
  // what is saved and the key field is empty again.
  const save = () =>
    act("saving", async () => {
      const next = await client.setModelConfig(configSetParams(form));
      setSaved(next);
      setForm(formFromConfig(next));
      setOutcome({ done: true, text: "The next session you start uses these settings; nothing needs restarting." });
    });

  // From what is saved, not from the form: removing the key should not also keep
  // whatever half-finished edit happens to be on screen.
  const removeKey = () =>
    act("removing", async () => {
      const next = await client.setModelConfig(configSetParams(formFromConfig(saved), { removeKey: true }));
      setSaved(next);
      setForm({ ...form, apiKey: "" });
      setOutcome({ done: true, text: "The saved key is gone. Sessions need a new one before they can reach a model." });
    });

  const useOrg = (): void => {
    if (!org) return;
    edit(applyClientDefaults(form, org));
    setDiscovery(null);
    setOutcome({ done: false, text: "Filled in from your organisation. It does not hand out keys — paste your own, then save." });
  };

  const knownProvider = PROVIDERS.some((p) => p.id === form.provider);
  const defaultUrl = PROVIDER_DEFAULT_URLS[form.provider as keyof typeof PROVIDER_DEFAULT_URLS];
  const keyState = saved.api_key_set ? (KEY_SOURCES[saved.api_key_source ?? "file"] ?? "Key saved") : null;

  return (
    <section className="group">
      <h3>Models</h3>

      <dl className="facts wide">
        <dt>Settings file</dt>
        <dd className="mono micro">
          {saved.path}
          {!saved.exists && <span className="muted"> — not written yet; saving creates it</span>}
        </dd>
      </dl>

      {/* The same colour as a read-only session, because it is the same situation:
          what is on screen is real, and editing it will not change what happens. */}
      {saved.overrides.map((o) => (
        <div key={`${o.source}:${o.detail}`} className="banner readonly">
          <p>{describeOverride(o)}</p>
        </div>
      ))}

      <form
        className="stack measure"
        style={{ gap: "var(--space-3)", marginTop: "var(--space-3)" }}
        onSubmit={(e) => {
          e.preventDefault();
          void save();
        }}
      >
        <label>
          Provider
          <select value={form.provider} onChange={(e) => edit({ provider: e.target.value })}>
            {PROVIDERS.map((p) => (
              <option key={p.id} value={p.id}>
                {p.label}
              </option>
            ))}
            {/* A provider this window has no name for — set by hand, or by a newer
                daemon — is shown as itself rather than silently replaced. */}
            {!knownProvider && <option value={form.provider}>{form.provider}</option>}
          </select>
        </label>

        <label>
          Address <small>optional — leave empty for the provider&apos;s own</small>
          <input
            value={form.baseUrl}
            onChange={(e) => edit({ baseUrl: e.target.value })}
            placeholder={defaultUrl ?? "https://…"}
            spellCheck={false}
            inputMode="url"
          />
        </label>

        <label>
          API key{" "}
          <small>{keyState ? "leave empty to keep the one that is saved" : "none is saved — sessions cannot reach a model without one"}</small>
          <input
            type="password"
            value={form.apiKey}
            onChange={(e) => edit({ apiKey: e.target.value })}
            // Never dots: a row of them reads as the key being shown back, which it is not.
            placeholder={keyState ? "Paste a new key to replace the saved one" : "Paste your key"}
            autoComplete="off"
            spellCheck={false}
          />
        </label>
        <div className="inline-form" style={{ marginBottom: 0, alignItems: "center" }}>
          {keyState ? <Pill status="allowed">{keyState}</Pill> : <Pill status="offline">No key</Pill>}
          {/* Only a key in the file can be removed from here. One from the environment
              or from OpenCode is somebody else's to take away. */}
          {saved.api_key_set && saved.api_key_source === "file" && (
            <button type="button" className="link" onClick={() => void removeKey()} disabled={busy !== null}>
              {busy === "removing" ? "Removing…" : "Remove saved key"}
            </button>
          )}
        </div>

        <details className="advanced">
          <summary className="note">Advanced</summary>
          <label style={{ marginTop: "var(--space-2)" }}>
            How the key is sent <small>most providers take the first; a gateway often wants the second</small>
            <select value={form.auth} onChange={(e) => edit({ auth: e.target.value as ModelForm["auth"] })}>
              <option value="api_key">As an x-api-key header</option>
              <option value="bearer">As Authorization: Bearer</option>
            </select>
          </label>
        </details>

        <div className="inline-form" style={{ marginBottom: 0 }}>
          <button type="button" onClick={() => void discover()} disabled={busy !== null}>
            {busy === "discovering" ? "Asking…" : "Discover models"}
          </button>
          {discovery && discovery.failures.length === 0 && (
            <span className="note">
              {discovery.models.length === 0 ? "The provider answered, and offers nothing." : `${discovery.models.length} offered.`}
            </span>
          )}
        </div>
        {discovery?.failures.map((f) => (
          <p key={f.provider} className="note error">
            {f.provider} refused: {f.reason}
          </p>
        ))}

        {/* One list for all three roles. It suggests; it does not restrict, because a
            gateway can serve a model it does not list. */}
        <datalist id="troupe-models">
          {[...offered.values()].map((m) => (
            <option key={m.id} value={m.id} />
          ))}
        </datalist>
        {MODEL_ROLES.map((role) => {
          const picked = offered.get(form.models[role].trim());
          const detail = picked ? describeOffer(picked) : "";
          return (
            <label key={role}>
              {ROLES[role].label} <small>{ROLES[role].hint}</small>
              <input
                value={form.models[role]}
                onChange={(e) => editRole(role, e.target.value)}
                list="troupe-models"
                placeholder={discovery ? "Pick one, or type an id" : "Type an id, or discover what is offered"}
                spellCheck={false}
                className="mono"
              />
              {detail && <span className="note">{detail}</span>}
            </label>
          );
        })}

        <Failed error={error} />
        {outcome && (
          <p className="note">
            {outcome.done && <Pill status="allowed">Saved</Pill>} {outcome.text}
          </p>
        )}

        <div className="inline-form" style={{ marginBottom: 0 }}>
          <button type="submit" className="primary" disabled={busy !== null || !form.provider}>
            {busy === "saving" ? "Saving…" : "Save"}
          </button>
          {org?.configured && (
            <button type="button" onClick={useOrg} disabled={busy !== null}>
              Use organisation defaults
            </button>
          )}
        </div>
      </form>
    </section>
  );
}
