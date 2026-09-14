// Automation: the credentials that run work unattended, and the things that fire it.
//
// One rule shapes this whole screen. **A secret is shown once.** `create` and `rotate`
// are the only answers that ever carry one, the plane keeps no copy that can be read
// back, and the listing does not have the field. So the secret lives in this component's
// state for exactly as long as the panel showing it is open, and the only way to see it
// again is to rotate — which is a different secret and says so.
//
// Rotating and disabling are destructive in the sense that matters: something that is
// working stops. Both go through the same confirmation as an erase, because "the old
// one fails within a token lifetime" is not a thing to discover afterwards.

import { useCallback, useState } from "react";
import type { JSX } from "react";
import type { AdminApi, AuthSession, ServicePrincipal, Trigger, TriggerRun } from "@troupe/client";
import { useAdminQuery } from "../../hooks";
import { Cost, Loading, Pill, When } from "../bits";
import { AfterTheChange, Confirm, Failed, Table } from "./bits";

export function AdminAutomation({
  auth,
  api,
  onOpen,
}: {
  auth: AuthSession;
  api: AdminApi;
  onOpen: (id: string) => void;
}): JSX.Element {
  const teams = auth.me?.teams ?? [];
  const [team, setTeam] = useState(teams[0] ?? "");
  const [wrote, setWrote] = useState(0);

  if (teams.length === 0) {
    return (
      <div className="empty">
        <h2>No team</h2>
        <p>Service principals and triggers belong to a team. You are not on one, so there is nothing here to administer.</p>
      </div>
    );
  }

  return (
    <>
      {teams.length > 1 && (
        <section className="group">
          <h3>Team</h3>
          <select value={team} onChange={(e) => setTeam(e.target.value)} aria-label="Team">
            {teams.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
        </section>
      )}

      <Principals api={api} team={team} onWrote={() => setWrote((n) => n + 1)} />
      <Triggers api={api} team={team} onOpen={onOpen} onWrote={() => setWrote((n) => n + 1)} />
      <AfterTheChange api={api} nonce={wrote} />
    </>
  );
}

function Principals({ api, team, onWrote }: { api: AdminApi; team: string; onWrote: () => void }): JSX.Element {
  const [round, setRound] = useState(0);
  const [creating, setCreating] = useState(false);
  // The one place a secret exists in this application. Never persisted, never re-read.
  const [revealed, setRevealed] = useState<ServicePrincipal | null>(null);
  const [acting, setActing] = useState<{ kind: "rotate" | "disable"; principal: ServicePrincipal } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => api.principals(team), [api, team]);
  const { data, loading, error: readError } = useAdminQuery<ServicePrincipal[]>(team ? load : null, [load, round]);

  const after = (): void => {
    setRound((n) => n + 1);
    onWrote();
  };

  const act = async (): Promise<void> => {
    if (!acting) return;
    setBusy(true);
    setError(null);
    try {
      const answer =
        acting.kind === "rotate" ? await api.rotatePrincipal(acting.principal.subject) : await api.disablePrincipal(acting.principal.subject);
      setActing(null);
      if (acting.kind === "rotate") setRevealed(answer);
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="group">
      <h3>
        Service principals
        <span className="micro muted"> — credentials that are not a person</span>
      </h3>

      <Failed error={readError ?? error} />
      {loading && !data && <Loading what="Reading the principals…" />}

      {data && data.length === 0 && !loading ? (
        <p className="note">This team has no service principals. A trigger needs one to run as.</p>
      ) : (
        data && (
          <Table head={["Name", "Subject", "May use", "Last used", "State", "  "]}>
            {data.map((p) => (
              <tr key={p.subject}>
                <th scope="row">{p.name ?? "—"}</th>
                <td className="mono micro">{p.subject}</td>
                <td>{p.profiles.join(", ") || "nothing"}</td>
                <td>
                  <When iso={p.last_used_at} />
                </td>
                <td>{p.enabled ? <Pill status="allowed">Working</Pill> : <Pill status="denied">Disabled</Pill>}</td>
                <td>
                  {p.enabled && (
                    <>
                      <button className="link" onClick={() => setActing({ kind: "rotate", principal: p })}>
                        Rotate
                      </button>
                      <button className="link" onClick={() => setActing({ kind: "disable", principal: p })}>
                        Disable
                      </button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )
      )}

      <button onClick={() => setCreating(true)}>Create a principal</button>

      {creating && (
        <CreatePrincipal
          api={api}
          team={team}
          onClose={() => setCreating(false)}
          onCreated={(p) => {
            setCreating(false);
            setRevealed(p);
            after();
          }}
        />
      )}

      {revealed?.secret && <TheSecret principal={revealed} onDone={() => setRevealed(null)} />}

      {acting && (
        <Confirm
          what={acting.kind === "rotate" ? "Rotate this secret" : "Disable this principal"}
          identifier={acting.principal.subject}
          consequence={
            acting.kind === "rotate"
              ? "The current secret stops working at once. Anything still using it fails until it is given the new one, and the new one is shown exactly once."
              : "Its next call is refused. The sessions it already created are kept, and nothing it made is deleted."
          }
          busy={busy}
          onCancel={() => setActing(null)}
          onConfirm={() => void act()}
        />
      )}
    </section>
  );
}

function CreatePrincipal({
  api,
  team,
  onClose,
  onCreated,
}: {
  api: AdminApi;
  team: string;
  onClose: () => void;
  onCreated: (p: ServicePrincipal) => void;
}): JSX.Element {
  const load = useCallback(() => api.teams(), [api]);
  const { data: teams } = useAdminQuery(load, [load]);
  const grants = teams?.find((t) => t.name === team)?.grants.map((g) => g.profile) ?? [];

  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [profiles, setProfiles] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const create = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      onCreated(await api.createPrincipal(team, { name, ...(description ? { description } : {}), profiles }));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="scrim" onClick={onClose}>
      <div className="dialog" role="dialog" aria-modal="true" aria-label="Create a principal" onClick={(e) => e.stopPropagation()}>
        <h1>Create a service principal</h1>
        <p className="copy">
          Its secret is in the answer and nowhere else. Put it where whatever is going to use it can read it, before you close the panel
          that shows it.
        </p>

        <label>
          What it is for
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder="nightly-review" />
        </label>
        <label>
          A note <small>optional</small>
          <input value={description} onChange={(e) => setDescription(e.target.value)} />
        </label>

        <fieldset>
          <legend>What it may use</legend>
          {grants.length === 0 ? (
            <p className="note">{team} is granted no profile, so a principal on it could start nothing.</p>
          ) : (
            grants.map((p) => (
              <label key={p} className="inline">
                <input
                  type="checkbox"
                  checked={profiles.includes(p)}
                  onChange={(e) => setProfiles((cur) => (e.target.checked ? [...cur, p] : cur.filter((x) => x !== p)))}
                />
                {p}
              </label>
            ))
          )}
        </fieldset>

        <Failed error={error} />

        <div className="actions">
          <button onClick={onClose}>Cancel</button>
          <button className="primary" onClick={() => void create()} disabled={busy || !name.trim() || profiles.length === 0}>
            {busy ? "Creating…" : "Create"}
          </button>
        </div>
      </div>
    </div>
  );
}

/** The secret, once. There is no second time and the panel says so. */
function TheSecret({ principal, onDone }: { principal: ServicePrincipal; onDone: () => void }): JSX.Element {
  const [copied, setCopied] = useState(false);
  return (
    <div className="scrim">
      <div className="dialog" role="dialog" aria-modal="true" aria-label="The secret">
        <h1>Copy this now</h1>
        <p className="copy">
          This is the only time {principal.subject} will show its secret. The platform keeps no copy that can be read back; if it is lost,
          the only way forward is to rotate, which makes a different one.
        </p>
        <pre className="payload secret mono">{principal.secret}</pre>
        <div className="actions">
          <button
            onClick={() => {
              void navigator.clipboard?.writeText(principal.secret ?? "").then(() => setCopied(true));
            }}
          >
            {copied ? "Copied" : "Copy"}
          </button>
          <button className="primary" onClick={onDone}>
            I have it
          </button>
        </div>
      </div>
    </div>
  );
}

function Triggers({
  api,
  team,
  onOpen,
  onWrote,
}: {
  api: AdminApi;
  team: string;
  onOpen: (id: string) => void;
  onWrote: () => void;
}): JSX.Element {
  const [round, setRound] = useState(0);
  const [deleting, setDeleting] = useState<Trigger | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showRuns, setShowRuns] = useState<string | null>(null);

  const load = useCallback(() => api.triggers(team), [api, team]);
  const { data, loading, error: readError } = useAdminQuery<Trigger[]>(team ? load : null, [load, round]);

  const after = (): void => {
    setRound((n) => n + 1);
    onWrote();
  };

  const toggle = async (t: Trigger): Promise<void> => {
    setBusy(t.name);
    setError(null);
    try {
      await api.putTrigger({ team, name: t.name, enabled: !t.enabled });
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const runNow = async (t: Trigger): Promise<void> => {
    setBusy(t.name);
    setError(null);
    try {
      await api.runTrigger(team, t.name);
      setShowRuns(t.name);
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const remove = async (t: Trigger): Promise<void> => {
    setBusy(t.name);
    setError(null);
    try {
      await api.deleteTrigger(team, t.name);
      setDeleting(null);
      after();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  return (
    <section className="group">
      <h3>
        Triggers
        <span className="micro muted"> — work that starts without anybody asking</span>
      </h3>

      <Failed error={readError ?? error} />
      {loading && !data && <Loading what="Reading the triggers…" />}

      {data && data.length === 0 && !loading ? (
        <p className="note">Nothing fires unattended for {team}.</p>
      ) : (
        data && (
          <Table head={["Name", "Fires", "Runs as", "Profile", "Last fired", "State", "  "]}>
            {data.map((t) => (
              <tr key={t.id}>
                <th scope="row">{t.name}</th>
                <td>{describeSource(t)}</td>
                <td className="mono micro">{t.principal ?? "—"}</td>
                <td>{t.profile ?? "—"}</td>
                <td>
                  <When iso={t.last_fired_at} />
                </td>
                <td>{t.enabled ? <Pill status="allowed">On</Pill> : <Pill status="dormant">Off</Pill>}</td>
                <td>
                  <button className="link" disabled={busy === t.name} onClick={() => void toggle(t)}>
                    {t.enabled ? "Switch off" : "Switch on"}
                  </button>
                  <button className="link" disabled={busy === t.name || !t.enabled} onClick={() => void runNow(t)}>
                    Run now
                  </button>
                  <button className="link" onClick={() => setShowRuns(showRuns === t.name ? null : t.name)}>
                    History
                  </button>
                  <button className="link" onClick={() => setDeleting(t)}>
                    Delete
                  </button>
                </td>
              </tr>
            ))}
          </Table>
        )
      )}

      {showRuns && <Runs api={api} team={team} trigger={showRuns} onOpen={onOpen} nonce={round} />}

      {deleting && (
        <Confirm
          what="Delete this trigger"
          identifier={deleting.name}
          consequence={`${deleting.name} stops firing and its run history goes with it. The sessions it created are kept.`}
          busy={busy !== null}
          onCancel={() => setDeleting(null)}
          onConfirm={() => void remove(deleting)}
        />
      )}
    </section>
  );
}

function describeSource(t: Trigger): string {
  const source = t.source ?? {};
  const kind = String(source["kind"] ?? "—");
  if (kind === "schedule") return `on a schedule (${String(source["schedule"] ?? "?")})`;
  if (kind === "webhook") return "when something calls its webhook";
  if (kind === "event") return "on an event";
  return kind;
}

/** A trigger's runs, newest first, with the session each one made. */
function Runs({
  api,
  team,
  trigger,
  onOpen,
  nonce,
}: {
  api: AdminApi;
  team: string;
  trigger: string;
  onOpen: (id: string) => void;
  nonce: number;
}): JSX.Element {
  const load = useCallback(() => api.runs({ team, trigger, limit: 25 }), [api, team, trigger]);
  const { data, loading, error } = useAdminQuery<TriggerRun[]>(load, [load, nonce]);

  return (
    <>
      <h4>{trigger}</h4>
      <Failed error={error} />
      {loading && !data && <Loading what="Reading the runs…" />}
      {data && data.length === 0 && !loading && <p className="note">It has never fired.</p>}
      {data && data.length > 0 && (
        <Table head={["Fired", "By", "State", "Ended", "Cost", "Session"]}>
          {data.map((r) => (
            <tr key={r.id}>
              <td>
                <When iso={r.fired_at} />
              </td>
              <td className="micro">{r.fired_by ?? "—"}</td>
              <td>
                <RunState run={r} />
              </td>
              <td>{r.done_reason ? r.done_reason.replace(/_/g, " ") : (r.status ?? "—")}</td>
              <td>
                <Cost micros={r.cost_micros} />
              </td>
              <td>
                {r.session_id ? (
                  <button className="link" onClick={() => onOpen(r.session_id as string)}>
                    Open
                  </button>
                ) : (
                  <span className="when">none</span>
                )}
              </td>
            </tr>
          ))}
        </Table>
      )}
    </>
  );
}

function RunState({ run }: { run: TriggerRun }): JSX.Element {
  if (run.state === "failed") return <Pill status="error">Failed</Pill>;
  if (run.state === "waiting" || (run.pending_approvals ?? 0) > 0) return <Pill status="waiting">Waiting for you</Pill>;
  if (run.state === "running") return <Pill status="running">Working</Pill>;
  if (run.state === "skipped") return <Pill status="dormant">Skipped</Pill>;
  if (run.state === "done") return <Pill status="allowed">Done</Pill>;
  return <Pill status="queued">Created</Pill>;
}
