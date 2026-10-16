// Workers and pods: the pods behind each profile, with their state, version, bundle,
// sessions and disk, and a drain for each; and the profiles, the cluster policy and the
// triggers as a repository would hold them, for bootstrapping one before a plane is
// switched to gitops.
//
// A drain stops a pod taking new sessions and moves what it holds, which the plane then
// checks against its own record before it agrees the pod is empty. Sessions are moved, not
// lost, but every one of them is interrupted, so it is typed by the pod's name. Silence is
// unknown, not broken: a pod that has never reported may be starting.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminPod, AdminProfile, PodDrained, ProfilesExport } from "@troupe/client";
import { describeError, show, useConsole, useLoad } from "../console";
import { href } from "../route";
import { AuditNote, Empty, Loaded, Preview, Region, Status, count, useChange, when } from "./bits";

function podStatus(pod: AdminPod): JSX.Element {
  if (pod.draining) {
    return (
      <Status kind="dormant" glyph="◑">
        draining
      </Status>
    );
  }
  if (!pod.healthy) {
    return pod.last_seen_at ? (
      <Status kind="denied" glyph="✕">
        broken
      </Status>
    ) : (
      <Status kind="muted" glyph="○">
        unknown
      </Status>
    );
  }
  return (
    <Status kind="running" glyph="●">
      healthy
    </Status>
  );
}

export function Pods(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.profiles(), [admin]);
  const { done, apply } = useChange(reload);
  const [draining, setDraining] = useState<{ profile: string; pod: AdminPod } | null>(null);
  const [drained, setDrained] = useState<PodDrained | null>(null);

  return (
    <div className="page">
      <p className="lead">The pods behind each profile: their state, the release and bundle they run, the sessions they hold and their disk.</p>
      {drained && (
        <p className="note" role="status">
          {drained.pod} held {count(drained.sessions, "session")}: {drained.unreachable ? "it could not be reached, so they are marked dormant and open elsewhere" : `${show(drained.drained)} moved`}
          {drained.cancelled.length ? `, ${count(drained.cancelled.length, "turn")} cancelled` : ""}.
        </p>
      )}
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Loaded load={load} what="the profiles' pods" retry={reload}>
        {(profiles) =>
          profiles.length === 0 ? (
            <Empty title="No profile yet">A profile is made under Worker profiles.</Empty>
          ) : (
            <>
              {profiles.map((p) => (
                <ProfilePods key={p.name} profile={p} busy={draining !== null} onDrain={(pod) => setDraining({ profile: p.name, pod })} />
              ))}
            </>
          )
        }
      </Loaded>
      {draining && (
        <Preview
          title={`pod/${draining.pod.pod}`}
          lines={[{ field: "draining", from: false, to: true }]}
          effects={[
            `${draining.pod.pod} takes no new session from now on.`,
            draining.pod.active_sessions
              ? `Its ${count(draining.pod.active_sessions, "session")} ${draining.pod.active_sessions === 1 ? "is" : "are"} moved: each is interrupted, sealed and opened again on another pod, and a turn in flight is cancelled.`
              : "It holds no session, so nothing is moved.",
            "The plane checks its own record before it agrees the pod is empty.",
          ]}
          verb="Drain"
          typeToConfirm={draining.pod.pod}
          onCancel={() => setDraining(null)}
          onConfirm={async () => {
            const { pod } = draining;
            await apply("pod.drain", pod.pod, async () => {
              const report = await admin.drainPod(pod.worker_id);
              setDrained(report);
              return report;
            }, `${pod.pod} is drained.`);
            setDraining(null);
          }}
        />
      )}
      <Manifests />
    </div>
  );
}

function ProfilePods({ profile, busy, onDrain }: { profile: AdminProfile; busy: boolean; onDrain: (pod: AdminPod) => void }): JSX.Element {
  return (
    <section aria-label={`${profile.name}'s pods`}>
      <Region>
        {profile.name} · {profile.pods.length} / {show(profile.replicas)} pods
      </Region>
      <p className="note">
        <a href={href({ page: "profiles", path: [profile.name] })}>{profile.name}</a> runs <span className="mono">{show(profile.image)}</span>, following the{" "}
        {show(profile.channel)} channel; {profile.active_sessions} of {profile.capacity} sessions in use.
      </p>
      {profile.pods.length === 0 ? (
        <Empty title="No pod">Nothing is running for it; one starts when a session asks.</Empty>
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Pod</th>
                <th>State</th>
                <th>Release</th>
                <th>Bundle</th>
                <th className="num">Sessions</th>
                <th className="num">Disk</th>
                <th>Last heard</th>
                <th aria-label="Actions" />
              </tr>
            </thead>
            <tbody>
              {profile.pods.map((pod) => (
                <tr key={pod.worker_id}>
                  <td className="mono">{pod.pod}</td>
                  <td>{podStatus(pod)}</td>
                  <td className="mono">{show(pod.version)}</td>
                  <td className="mono">{pod.bundle_hash ? pod.bundle_hash.slice(0, 15) : "—"}</td>
                  <td className="num">
                    {pod.active_sessions} / {pod.capacity}
                  </td>
                  <td className="num">{pod.disk_fraction === null ? "—" : `${Math.round(pod.disk_fraction * 100)}%`}</td>
                  <td>{pod.last_seen_at ? when(pod.last_seen_at) : "never"}</td>
                  <td className="row-actions">
                    {!busy && !pod.draining && (
                      <button type="button" onClick={() => onDrain(pod)}>
                        Drain
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

/** The repository a plane in gitops mode would read: every file, asked for, never written here. */
function Manifests(): JSX.Element {
  const { admin } = useConsole();
  const [state, setState] = useState<{ kind: "asking" } | { kind: "ready"; answer: ProfilesExport } | { kind: "failed"; error: unknown } | null>(null);
  return (
    <section aria-label="Manifests for a repository">
      <Region>Manifests for a repository</Region>
      <p className="note">
        Every profile, the cluster policy and every trigger as a repository would hold them: what bootstrapping one commits before the plane is switched to gitops. Nothing
        is written; copy what is here into the repository.
      </p>
      {state === null || state.kind === "failed" ? (
        <>
          <button
            type="button"
            onClick={() => {
              setState({ kind: "asking" });
              admin.exportProfiles().then(
                (answer) => setState({ kind: "ready", answer }),
                (error: unknown) => setState({ kind: "failed", error }),
              );
            }}
          >
            Show the manifests
          </button>
          {state?.kind === "failed" && (
            <p className="field-error" role="alert">
              {describeError(state.error)}
            </p>
          )}
        </>
      ) : state.kind === "asking" ? (
        <p role="status">Asking the plane…</p>
      ) : (
        <>
          <p className="note">
            Left out of every profile's manifest, because the plane or the cluster writes it: <span className="mono">{state.answer.left_out.join(", ")}</span>.
          </p>
          {[...state.answer.profiles, ...(state.answer.policy ? [state.answer.policy] : []), ...state.answer.triggers].map((m) => (
            <details key={m.path}>
              <summary className="mono">{m.path}</summary>
              {m.notes.length > 0 && (
                <ul className="plain">
                  {m.notes.map((n) => (
                    <li key={n}>{n}</li>
                  ))}
                </ul>
              )}
              <pre className="mono manifest">{m.yaml}</pre>
            </details>
          ))}
          <button type="button" onClick={() => setState(null)}>
            Hide them
          </button>
        </>
      )}
    </section>
  );
}
