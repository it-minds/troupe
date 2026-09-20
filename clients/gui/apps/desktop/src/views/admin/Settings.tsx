// Platform settings, and whether the identity provider is actually reachable.
//
// Every setting says where its value came from, and that is the column that matters: a
// value the deployment owns cannot be changed here, and a screen that let somebody try
// and then silently did nothing would be worse than one that does not offer it. A
// secret reports as set and never returns its value, so there is nothing here that
// could render one.
//
// The identity check is four named probes with what each proved. It is here rather than
// on the sign-in screen because by the time sign-in is failing, the person who can fix
// it is not the person looking at it.

import { useCallback, useState } from "react";
import type { JSX } from "react";
import type { AdminApi, IdentityCheckResult, PlatformSetting, SettingsList } from "@troupe/client";
import { useAdminQuery } from "../../hooks";
import { Loading, Pill } from "../bits";
import { AfterTheChange, Failed, Table } from "./bits";

export function AdminSettings({ api }: { api: AdminApi }): JSX.Element {
  const [round, setRound] = useState(0);
  const [wrote, setWrote] = useState(0);
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => api.settings(), [api]);
  const { data: listed, loading, error: readError } = useAdminQuery<SettingsList>(load, [load, round]);
  // The provider's own settings have a tab of their own, where the save is gated on the
  // check; rendering them here too would be a second save nobody gated.
  const data = listed ? listed.settings.filter((s) => s.group !== "sign_in") : null;

  const after = (): void => {
    setRound((n) => n + 1);
    setWrote((n) => n + 1);
    setEditing(null);
  };

  const save = async (setting: PlatformSetting): Promise<void> => {
    setBusy(setting.key);
    setError(null);
    try {
      await api.putSetting(setting.key, coerce(draft, setting.type));
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const reset = async (setting: PlatformSetting): Promise<void> => {
    setBusy(setting.key);
    setError(null);
    try {
      await api.resetSetting(setting.key);
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <>
      <Identity api={api} />

      <section className="group">
        <h3>Platform settings</h3>
        <Failed error={readError ?? error} />
        {loading && !data && <Loading what="Reading the settings…" />}

        {data && (
          <Table head={["Setting", "Value", "From", "What it does", "  "]}>
            {data.map((s) => {
              const owned = s.source === "deployed";
              return (
                <tr key={s.key}>
                  <th scope="row" className="mono micro">
                    {s.key}
                  </th>
                  <td>
                    {editing === s.key ? (
                      <input value={draft} onChange={(e) => setDraft(e.target.value)} aria-label={`Value for ${s.key}`} autoFocus />
                    ) : (
                      <Value setting={s} />
                    )}
                  </td>
                  <td>
                    <Source source={s.source} />
                  </td>
                  <td className="micro">
                    {s.summary ?? s.description ?? "—"}
                    {s.effect_description ? <span className="muted"> {s.effect_description}</span> : null}
                  </td>
                  <td>
                    {owned ? (
                      <span className="micro muted">the deployment owns this</span>
                    ) : editing === s.key ? (
                      <>
                        <button className="link" disabled={busy === s.key} onClick={() => void save(s)}>
                          Save
                        </button>
                        <button className="link" onClick={() => setEditing(null)}>
                          Cancel
                        </button>
                      </>
                    ) : (
                      <>
                        <button
                          className="link"
                          onClick={() => {
                            setEditing(s.key);
                            setDraft(s.secret ? "" : stringify(s.value));
                          }}
                        >
                          Change
                        </button>
                        {s.source === "stored" && (
                          <button className="link" disabled={busy === s.key} onClick={() => void reset(s)}>
                            Reset
                          </button>
                        )}
                      </>
                    )}
                  </td>
                </tr>
              );
            })}
          </Table>
        )}
      </section>

      <AfterTheChange api={api} nonce={wrote} />
    </>
  );
}

function Value({ setting }: { setting: PlatformSetting }): JSX.Element {
  if (setting.secret) return <span className="when">{setting.set ? "set" : "not set"}</span>;
  if (setting.value === null || setting.value === undefined) return <span className="when">unset</span>;
  return <span className="mono micro">{stringify(setting.value)}</span>;
}

function Source({ source }: { source: string }): JSX.Element {
  if (source === "deployed") return <Pill status="readonly">Deployed</Pill>;
  if (source === "stored") return <Pill status="allowed">Stored</Pill>;
  return <Pill status="dormant">Unset</Pill>;
}

function stringify(v: unknown): string {
  if (typeof v === "string") return v;
  return JSON.stringify(v) ?? "";
}

/** Parse against the setting's declared type; the plane refuses anything that does not fit. */
function coerce(text: string, type: string | undefined): unknown {
  if (type === "integer" || type === "number") {
    const n = Number(text);
    return Number.isFinite(n) ? n : text;
  }
  if (type === "boolean") return text === "true" || text === "1" || text === "yes";
  if (type === "object" || type === "array") {
    try {
      return JSON.parse(text) as unknown;
    } catch {
      return text;
    }
  }
  return text;
}

/** Four probes, and what each one proved. */
function Identity({ api }: { api: AdminApi }): JSX.Element {
  const [round, setRound] = useState(0);
  const load = useCallback(() => api.identityCheck(), [api]);
  const { data: result, loading, error } = useAdminQuery<IdentityCheckResult>(load, [load, round]);
  const data = result?.checks ?? null;

  return (
    <section className="group">
      <h3>
        Sign-in
        <span className="micro muted"> — what the platform can actually reach</span>
      </h3>
      <Failed error={error} />
      {loading && !data && <Loading what="Asking the identity provider…" />}
      {data && (
        <Table head={["Check", "Result", "What it proved", "Took"]}>
          {data.map((c) => (
            <tr key={c.name}>
              <th scope="row">{c.name}</th>
              <td>{c.ok ? <Pill status="allowed">Passed</Pill> : <Pill status="error">Failed</Pill>}</td>
              <td className="micro">{c.detail ?? "—"}</td>
              <td>{c.took_ms === undefined ? "—" : `${c.took_ms} ms`}</td>
            </tr>
          ))}
        </Table>
      )}
      <button onClick={() => setRound((n) => n + 1)}>Check again</button>
    </section>
  );
}
