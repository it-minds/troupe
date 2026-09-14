// The controls a session only has because it is running on this computer.
//
// Watch mode is the whole of it for now. It is the one thing on this screen that changes
// what the agent *does* without anybody typing: a comment saved in a file becomes input.
// So it says what it will do, it says that it is exclusive, and a refusal — another
// session in the same workspace already watching — is shown as the sentence it is rather
// than as a failed toggle that springs back.

import { useState } from "react";
import type { JSX } from "react";
import type { DaemonClient, FleetRow } from "@troupe/client";

export function LocalControls({ daemon, row }: { daemon: DaemonClient; row: FleetRow }): JSX.Element | null {
  const raw = row.raw as { workspace?: string; branch?: string | null; config?: { watch?: boolean } } | undefined;
  const workspace = raw?.workspace;
  const [watching, setWatching] = useState(Boolean(raw?.config?.watch));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!workspace) return null;

  const toggle = async (next: boolean): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const r = await daemon.setWatch(workspace, next);
      setWatching(r.enabled);
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
        <input type="checkbox" checked={watching} disabled={busy} onChange={(e) => void toggle(e.target.checked)} />
        Act on notes I leave in the files
      </label>
      <p className="note">
        {watching
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
