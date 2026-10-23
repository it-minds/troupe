// What a session's next prompt is read from, layer by layer (troupe #55): the
// organisation's memory, a team's, a worker profile's chain, the person's own instruction
// file, the repository's files and its brief, in the order the prompt reads them, nearer
// later, each with where it came from and its version.
//
// Shown, never edited: the organisation's, a team's and a profile's are changed in the
// console, the files in the repository and the person's config directory. The session
// answers `context.get`, on a pod over its own connection with the documents its
// activation carried. A save on the plane reaches the running session at its next turn,
// which says so in the transcript (`memory_changed`); the pane reads the layers again then,
// and when this computer's settings change. The terminal UI's `/context` says the same in
// a line.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { instructionLayers } from "@troupe/client";
import type { DaemonClient, InstructionRow, SessionView } from "@troupe/client";
import { Loading, Table } from "./bits";

export function Instructions({ view, daemon }: { view: SessionView | null; daemon: DaemonClient | null }): JSX.Element {
  const [rows, setRows] = useState<InstructionRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!view) return;
    let live = true;
    const read = (): void => {
      view
        .context()
        .then((c) => {
          if (!live) return;
          setError(null);
          setRows(instructionLayers(c));
        })
        .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)));
    };
    read();
    const stopEvents = view.listen((e) => {
      if (e.type === "memory_changed") read();
    });
    const stopConfig = daemon ? daemon.onConfigChanged(read) : () => {};
    return () => {
      live = false;
      stopEvents();
      stopConfig();
    };
  }, [view, daemon]);

  if (error) return <p className="note">The session did not say what its instructions are read from: {error}</p>;
  if (!rows) return <Loading what="Reading what the session's instructions are read from…" />;
  if (rows.length === 0) return <p className="note">Nothing: no memory from an organisation, and no instruction files where the session works.</p>;

  return (
    <>
      <p className="muted micro">Read in this order at the session's next turn; where two disagree, the later one wins. Nothing here changes them.</p>
      <Table head={["Layer", "What", "From", "Version"]}>
        {rows.map((r, i) => (
          <tr key={`${r.layer}-${r.what}-${i}`} className={r.inForce ? undefined : "muted"}>
            <td>{r.heading}</td>
            <td>
              <code>{r.what}</code>
              {r.note && <div className="micro muted">{r.note}</div>}
            </td>
            <td>{r.source}</td>
            <td className="mono">{r.version}</td>
          </tr>
        ))}
      </Table>
    </>
  );
}
