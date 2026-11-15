// Pods: the pods behind each profile, with their state, version, bundle,
// sessions and disk, and a drain for each; and the profiles, the cluster policy and the
// triggers as a repository would hold them, for bootstrapping one before a plane is
// switched to gitops.
//
// A drain stops a pod taking new sessions and moves what it holds, which the plane then
// checks against its own record before it agrees the pod is empty. Sessions are moved, not
// lost, but every one of them is interrupted, so it is typed by the pod's name. Silence is
// unknown, not broken: a pod that has never reported may be starting. A pod a scale-down
// removed reads "gone" with when it was last heard, offers nothing, and is never where a
// drained pod's sessions are said to go; the plane forgets its row on its own.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminPod, AdminProfile, PodDrained, ProfilesExport } from "@troupe/client";
import { describeError, show, useConsole, useLoad } from "../console";
import { href } from "../route";
import { AuditNote, Empty, Loaded, Preview, Region, Status, count, useChange, when } from "./bits";

function podStatus(pod: AdminPod): JSX.Element {
  // Removed by a scale-down and quiet since: the plane forgets the row on its own.
  if (pod.gone) {
    return (
      <Status kind="muted" glyph="○">
        gone {pod.last_seen_at ? when(pod.last_seen_at) : ""}
      </Status>
    );
  }
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

/** What a profile's workers are called: a registered ssh host is a machine, as Hosts names it; anything else is a pod. */
function unitOf(profile: AdminProfile): { one: string; many: string } {
  return profile.provisioner === "ssh" ? { one: "machine", many: "machines" } : { one: "pod", many: "pods" };
}

/**
 * Where a drained pod's sessions go, as the preview says it: only a pod of the same profile
 * that is healthy, not draining itself and not gone can take them, and where none can they
 * wait. A pod a scale-down removed is never one of them, however its row last read.
 */
function whereTheyGo(profile: AdminProfile, pod: AdminPod): string {
  const held = pod.active_sessions;
  if (!held) return "It holds no session, so nothing is moved.";
  const unit = unitOf(profile);
  const takers = profile.pods.filter((p) => p.worker_id !== pod.worker_id && p.healthy && !p.draining && !p.gone).map((p) => p.pod);
  const its = `Its ${count(held, "session")} ${held === 1 ? "is" : "are"}`;
  if (takers.length === 0) return `${its} interrupted and sealed, and a turn in flight is cancelled. No other ${unit.one} can take them; they will wait for one.`;
  const where = takers.length === 1 ? takers[0] : `one of ${takers.length} other ${unit.many} that can take them`;
  return `${its} moved: each is interrupted, sealed and opened again on ${where}, and a turn in flight is cancelled.`;
}

export function Pods(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.profiles(), [admin]);
  const { done, apply } = useChange(reload);
  const [draining, setDraining] = useState<{ profile: AdminProfile; pod: AdminPod } | null>(null);
  const [drained, setDrained] = useState<PodDrained | null>(null);

  return (
    <div className="page">
      <p className="lead">The pods behind each profile: their state, the release and bundle they run, the sessions they hold and their disk.</p>
      {drained && (
        <p className="note" role="status">
          {drained.pod} held {count(drained.sessions, "session")}: {drained.unreachable ? "it could not be reached, so they are asleep and open elsewhere" : `${show(drained.drained)} moved`}
          {drained.cancelled.length ? `, ${count(drained.cancelled.length, "turn")} cancelled` : ""}.
        </p>
      )}
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Loaded load={load} what="the profiles' pods" retry={reload}>
        {(profiles) =>
          profiles.length === 0 ? (
            <Empty title="No profile yet">A profile is made under Configure → Profiles.</Empty>
          ) : (
            <>
              {profiles.map((p) => (
                <ProfilePods key={p.name} profile={p} busy={draining !== null} onDrain={(pod) => setDraining({ profile: p, pod })} />
              ))}
            </>
          )
        }
      </Loaded>
      {draining && (
        <Preview
          title={`${unitOf(draining.profile).one}/${draining.pod.pod}`}
          lines={[{ field: "draining", from: false, to: true }]}
          effects={[
            `${draining.pod.pod} takes no new session from now on.`,
            whereTheyGo(draining.profile, draining.pod),
            `The plane checks its own record before it agrees the ${unitOf(draining.profile).one} is empty.`,
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
  const unit = unitOf(profile);
  const name = <a href={href({ page: "profiles", path: [profile.name] })}>{profile.name}</a>;
  return (
    <section aria-label={`${profile.name}'s ${unit.many}`}>
      <Region>
        {profile.name} · {profile.pods.filter((p) => !p.gone).length} of {show(profile.replicas)} {profile.replicas === 1 ? unit.one : unit.many}
      </Region>
      <p className="note">
        {profile.image ? (
          <>
            {name} runs <span className="mono">{profile.image}</span>, following the {show(profile.channel)} channel
          </>
        ) : (
          <>
            {name} has no image yet, following the {show(profile.channel)} channel
          </>
        )}
        ; {profile.active_sessions} of {count(profile.capacity, "session")} in use.
      </p>
      {profile.pods.length === 0 ? (
        unit.one === "machine" ? (
          <Empty title="No machine">
            None has enrolled for it yet; one is registered under <a href={href({ page: "hosts" })}>Hosts</a>.
          </Empty>
        ) : (
          <Empty title="No pod">Nothing is running for it; one starts when a session asks.</Empty>
        )
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>{unit.one === "machine" ? "Machine" : "Pod"}</th>
                <th>State</th>
                <th>Release</th>
                <th>Bundle</th>
                <th className="num">Sessions</th>
                <th className="num">Disk</th>
                <th>Last heard</th>
                <th className="row-actions" aria-label="Actions" />
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
                    {!busy && !pod.draining && !pod.gone && (
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
