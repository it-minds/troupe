// What a session's next prompt is read from, layer by layer (troupe #55): the
// organisation's memory, a team's, a worker profile's chain, the person's own memory, the
// person's own instruction file, the repository's files and its brief, in the order the
// prompt reads them, nearer later, each with where it came from and its version.
//
// One layer is edited here, the person's own memory on the plane, in place and through this
// computer's daemon, which saves it with its own sign-in and hands the new version to the
// sessions running here for their next turn. The rest are shown, never edited: the
// organisation's, a team's and a profile's are changed in the console, the files in the
// repository and the person's config directory. The session answers `context.get`, on a
// pod over its own connection with the documents its activation carried. A save on the
// plane reaches the running session at its next turn, which says so in the transcript
// (`memory_changed`); the pane reads the layers again then, and when this computer's
// settings change. The terminal UI's `/context` says the same in a line.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { instructionLayers } from "@troupe/client";
import type { DaemonClient, InstructionRow, OwnMemory, SessionView } from "@troupe/client";
import { storedLocalOnly } from "../mode";
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

  return (
    <>
      {rows.length === 0 ? (
        <p className="note">Nothing: no memory from an organisation, and no instruction files where the session works.</p>
      ) : (
        <>
          <p className="muted micro">Read in this order at the session's next turn; where two disagree, the later one wins. Only your own memory is changed from here.</p>
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
      )}
      {daemon ? (
        <YourMemory daemon={daemon} />
      ) : (
        <p className="muted micro">Your own memory is changed under Mine in the Troupe console, or with troupe memory --edit, and this session reads it from its next turn.</p>
      )}
    </>
  );
}

function message(e: unknown): string {
  const data = (e as { data?: { reason?: unknown } }).data;
  if (data && typeof data.reason === "string") return data.reason;
  return e instanceof Error ? e.message : String(e);
}

/**
 * The person's own memory on the plane, edited in place: what every session of theirs reads,
 * on every machine, after their organisation's. Saved over the version it was edited from,
 * so a save made elsewhere meanwhile is said, not overwritten. Local only keeps the app off
 * the plane, and so this too.
 */
function YourMemory({ daemon }: { daemon: DaemonClient }): JSX.Element {
  const local = storedLocalOnly();
  const [own, setOwn] = useState<OwnMemory | null>(null);
  const [why, setWhy] = useState<string | null>(null);
  const [draft, setDraft] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [said, setSaid] = useState<string | null>(null);

  useEffect(() => {
    if (local) return;
    let live = true;
    daemon.ownMemory().then(
      (o) => live && setOwn(o),
      (e: unknown) => live && setWhy(message(e)),
    );
    return () => {
      live = false;
    };
  }, [daemon, local]);

  if (local) {
    return <p className="note">Your own memory is kept on your organisation's plane, and Local only keeps this app off it: turn Local only off to change it here.</p>;
  }
  if (why) return <p className="note">Your own memory: {why}</p>;
  if (!own) return <Loading what="Reading your own memory…" />;

  const size = draft === null ? 0 : new TextEncoder().encode(draft).length;

  const save = (): void => {
    if (draft === null) return;
    setBusy(true);
    setError(null);
    daemon
      .putOwnMemory(draft, own.version)
      .then((saved) => {
        setOwn(saved.user);
        setDraft(null);
        setSaid(saved.changed ? `Saved as version ${saved.user.version}: the sessions here read it from their next turn.` : "Nothing changed; nothing was saved.");
      })
      .catch((e: unknown) => setError(message(e)))
      .finally(() => setBusy(false));
  };

  return (
    <section className="your-memory" aria-label="Your own memory">
      <h4>Your own memory</h4>
      <p className="muted micro">
        What every session of yours reads, on every machine, after your organisation's memory. Only you change it; an agent of yours only adds an entry when you ask it to remember
        something. {own.version > 0 ? `Version ${own.version}, ${own.bytes} of ${own.limit} bytes.` : "Nothing written yet."}
      </p>
      {said && <p className="note">{said}</p>}
      {draft === null ? (
        <>
          {own.text !== "" && <pre className="mono">{own.text}</pre>}
          <div className="actions">
            <button
              onClick={() => {
                setSaid(null);
                setDraft(own.text);
              }}
            >
              Edit your memory
            </button>
          </div>
        </>
      ) : (
        <>
          <textarea value={draft} onChange={(e) => setDraft(e.target.value)} rows={12} spellCheck={false} aria-label="What your own memory says" className="mono" />
          <p className={size > own.limit ? "note error" : "muted micro"}>
            {size} of {own.limit} bytes
          </p>
          {error && <p className="note error">{error}</p>}
          <div className="actions">
            <button className="primary" disabled={busy || size > own.limit} onClick={save}>
              {busy ? "Saving…" : "Save"}
            </button>
            <button disabled={busy} onClick={() => setDraft(null)}>
              Cancel
            </button>
          </div>
        </>
      )}
    </section>
  );
}
