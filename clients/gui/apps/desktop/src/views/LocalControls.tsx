// The controls a session only has because it is running on this computer.
//
// Watch mode is the whole of it for now. It is the one thing on this screen that changes
// what the agent *does* without anybody typing: a comment saved in a file becomes input.
// So it says what it will do, it says that it is exclusive, and a refusal — another
// session in the same workspace already watching — is shown as the sentence it is rather
// than as a failed toggle that springs back.
//
// What the box shows is the daemon's, never its own record (troupe D114, Decision 852):
// `watch.get` when the controls open, then each `watch_changed` the session writes, so a
// watch the terminal's `/watch` turned on or off is shown here as it happens, and one
// another session holds says which.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import type { DaemonClient, FleetRow, SessionView, WatchState } from "@troupe/client";

export function LocalControls({ daemon, row, session }: { daemon: DaemonClient; row: FleetRow; session?: SessionView | null }): JSX.Element | null {
  const raw = row.raw as { workspace?: string; branch?: string | null } | undefined;
  const workspace = raw?.workspace;
  const [watch, setWatch] = useState<WatchState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // What the daemon says when the controls open.
  useEffect(() => {
    if (!workspace) return;
    let live = true;
    daemon
      .getWatch(workspace)
      .then((w) => live && setWatch(w))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [daemon, workspace]);

  // And each change the session says, from here or from any other client.
  useEffect(() => {
    if (!session) return;
    return session.listen((e) => {
      if (e.type !== "watch_changed") return;
      const enabled = e.data["enabled"] === true;
      const backend = typeof e.data["backend"] === "string" ? e.data["backend"] : enabled ? "poll" : "off";
      setWatch({ enabled, backend, session_id: enabled ? row.id : null });
    });
  }, [session, row.id]);

  if (!workspace) return null;

  const watching = watch?.enabled === true;
  const elsewhere = watching && watch?.session_id && watch.session_id !== row.id ? watch.session_id : null;

  const toggle = async (next: boolean): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const r = await daemon.setWatch(workspace, next);
      setWatch({ enabled: r.enabled, backend: r.backend ?? (r.enabled ? "poll" : "off"), session_id: r.enabled ? row.id : null });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section>
      <h3>On this computer</h3>
      <dl className="facts">
        <dt>Directory</dt>
        <dd className="mono micro">{workspace}</dd>
        {raw?.branch && (
          <>
            <dt>Branch</dt>
            <dd className="mono micro">{raw.branch}</dd>
          </>
        )}
      </dl>

      <label className="inline">
        <input
          type="checkbox"
          checked={watching}
          disabled={busy || watch === null}
          onChange={(e) => void toggle(e.target.checked)}
          aria-label="Act on notes I leave in the files"
        />
        Act on notes I leave in the files
      </label>
      <p className="note">
        {elsewhere
          ? `On, for session ${elsewhere} in this workspace: a comment you save here is read and answered there.`
          : watching
            ? "A comment you save in this workspace is read and answered as if you had typed it."
            : "Off. Nothing here reads what you save unless you say so."}
      </p>

      {error && (
        <div className="banner error">
          <p>{error}</p>
        </div>
      )}
    </section>
  );
}
