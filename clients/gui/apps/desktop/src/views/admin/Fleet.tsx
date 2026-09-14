// Fleet health: what is running the work, how much of it is left, and what version.
//
// One profile per section rather than one pod per row, because capacity is a property
// of the profile and a person asking "can I start a session" is asking about the
// profile. The pods are underneath it for the question that comes next, which is always
// "which one is wrong".
//
// A pod that has never reported and a pod that reported and said it was unhealthy are
// different things and are shown as different things. Calling both "broken" cries wolf
// during a partition, which is exactly when somebody is reading this page.

import { useCallback, useState } from "react";
import type { JSX } from "react";
import type { AdminApi, AdminPod, AdminProfile, FleetOverview } from "@troupe/client";
import { useAdminQuery } from "../../hooks";
import { Loading, Pill, When } from "../bits";
import { AfterTheChange, Confirm, Failed, Money, Table } from "./bits";

export function AdminFleet({
  api,
  platform,
  overview,
}: {
  api: AdminApi;
  platform: boolean;
  overview: FleetOverview | null;
}): JSX.Element {
  const [wrote, setWrote] = useState(0);
  const [draining, setDraining] = useState<AdminPod | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => api.profiles(), [api]);
  const { data: profiles, loading, error: readError, reload } = useAdminQuery<AdminProfile[]>(load, [load, wrote]);

  const drain = async (pod: AdminPod): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await api.drainPod(pod.worker_id);
      setDraining(null);
      setWrote((n) => n + 1);
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      {overview && (
        <section className="group">
          <h3>Right now</h3>
          <dl className="facts wide">
            <dt>Sessions</dt>
            <dd>
              {overview.sessions.active} running, {overview.sessions.dormant} asleep, {overview.sessions.read_only} read only
            </dd>
            <dt>Spend</dt>
            <dd>
              {overview.teams.length === 0
                ? "no team reports any"
                : overview.teams.map((t) => (
                    <span key={t.name} className="chip">
                      {t.name} <Money micros={t.spent_micros} />
                      {t.budget_micros ? (
                        <>
                          {" of "}
                          <Money micros={t.budget_micros} />
                          {t.budget_period ? ` per ${t.budget_period}` : ""}
                        </>
                      ) : null}
                    </span>
                  ))}
            </dd>
          </dl>
        </section>
      )}

      <Failed error={readError ?? error} />
      {loading && !profiles && <Loading what="Reading the fleet…" />}

      {(profiles ?? []).map((profile) => {
        const spare = profile.capacity - profile.active_sessions;
        const versions = new Set(profile.pods.map((p) => p.bundle_hash ?? "unknown"));
        return (
          <section className="group" key={profile.name}>
            <h3>
              {profile.name}
              <span className="micro muted">
                {" "}
                — {profile.active_sessions} of {profile.capacity} in use, {spare > 0 ? `${spare} free` : "full"}
              </span>
            </h3>

            <dl className="facts wide">
              <dt>Image</dt>
              <dd className="mono micro">{profile.image ?? "—"}</dd>
              <dt>Channel</dt>
              <dd>
                {profile.channel ?? "none"}
                {versions.size > 1 && <span className="micro muted"> — pods are on {versions.size} different bundles</span>}
              </dd>
              {profile.conditions.length > 0 && (
                <>
                  <dt>Conditions</dt>
                  <dd>
                    {profile.conditions.map((c, i) => (
                      <span key={i} className="chip" title={c.message ?? ""}>
                        {String(c.type ?? "condition")}: {String(c.status ?? "?")}
                        {c.reason ? ` (${String(c.reason)})` : ""}
                      </span>
                    ))}
                  </dd>
                </>
              )}
            </dl>

            {profile.pods.length === 0 ? (
              <p className="note">No pod has reported for this profile. Nothing can start on it.</p>
            ) : (
              <Table head={["Pod", "State", "In use", "Disk", "Version", "Bundle", "Last heard", ...(platform ? ["  "] : [])]}>
                {profile.pods.map((pod) => (
                  <tr key={pod.worker_id}>
                    <th scope="row" className="mono micro">
                      {pod.pod}
                    </th>
                    <td>
                      <PodState pod={pod} />
                    </td>
                    <td>
                      {pod.active_sessions} / {pod.capacity}
                    </td>
                    <td>{pod.disk_fraction === null ? "—" : `${Math.round(pod.disk_fraction * 100)}%`}</td>
                    <td className="mono micro">{pod.version ?? "—"}</td>
                    <td className="mono micro" title={pod.bundle_hash ?? ""}>
                      {pod.bundle_hash ? pod.bundle_hash.slice(0, 12) : "—"}
                    </td>
                    <td>
                      <When iso={pod.last_seen_at} />
                    </td>
                    {platform && (
                      <td>
                        <button className="link" disabled={pod.draining} onClick={() => setDraining(pod)}>
                          {pod.draining ? "Draining" : "Drain"}
                        </button>
                      </td>
                    )}
                  </tr>
                ))}
              </Table>
            )}
          </section>
        );
      })}

      <AfterTheChange api={api} nonce={wrote} />

      {draining && (
        <Confirm
          what="Drain this pod"
          identifier={draining.pod}
          consequence={`Every session on ${draining.pod} is moved or made dormant, and nothing new is placed there. Sessions that are mid-turn finish first.`}
          busy={busy}
          onCancel={() => setDraining(null)}
          onConfirm={() => void drain(draining)}
        />
      )}
    </>
  );
}

/**
 * Healthy, draining, unhealthy, or never heard from — four states, not two.
 *
 * `healthy` is what the pod last said about itself. A pod that has never said anything
 * has no `last_seen_at`, and that is silence rather than a verdict.
 */
function PodState({ pod }: { pod: AdminPod }): JSX.Element {
  if (pod.draining) return <Pill status="dormant">Draining</Pill>;
  if (!pod.last_seen_at) return <Pill status="offline">Never reported</Pill>;
  if (!pod.healthy) return <Pill status="error">Unhealthy</Pill>;
  return <Pill status="running">Healthy</Pill>;
}
