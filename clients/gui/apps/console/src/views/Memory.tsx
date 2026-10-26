// The organisation's memory (#55): what the organisation, each team and each worker profile
// wrote for every agent in their scope. Each document reaches the sessions in its scope as
// instructions from the organisation, before the person's own instructions and the
// repository's files, and no agent can change one: this is where a person does.
//
// Every save is a new version, kept with who saved it; a save shows what it changes line by
// line before it is made, and the audit's record after. The organisation's and a profile's
// are a platform admin's to change, a team's its team admins'. A profile's is edited on the
// profile's own page, through the same editor, below what it has from the profiles it extends.

import { useState } from "react";
import type { JSX } from "react";
import type { MemoryBlameLine, MemoryDocument, MemoryInherited, MemoryLine, MemoryPreview, MemoryReader, MemoryReaders, MemoryScope, MemorySaved } from "@troupe/client";
import { describeError, useConsole, useLoad } from "../console";
import { AuditNote, Empty, Field, Loaded, Preview, Region, TextDiff, count, useChange, when } from "./bits";

export function Memory(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.memoryList(), [admin]);

  return (
    <div className="page">
      <Loaded load={load} what="the organisation's memory" retry={reload}>
        {(list) => (
          <>
            <p className="lead">
              What every agent in a scope starts from: the organisation's for every session, a team's for that team's sessions and its members' machines. Each reaches a
              session as instructions from the organisation, before the person's own and the repository's, and no agent can change it. A worker profile's is on the
              profile's page. Each document holds at most {list.limit} bytes.
            </p>
            <Region>The organisation's</Region>
            <MemoryEditor scope="organisation" name={null} title="The organisation's memory" />
            <Region>Teams'</Region>
            {list.teams.length === 0 ? (
              <Empty title="No team of yours keeps memory here" />
            ) : (
              list.teams.map((t) => <MemoryEditor key={t.subject} scope="team" name={t.name} title={`The ${t.name} team's memory`} />)
            )}
          </>
        )}
      </Loaded>
    </div>
  );
}

/**
 * One memory document: the version in force, every version with who saved it and what it
 * changed, and, for whoever may, a change with its preview and its audit.
 */
export function MemoryEditor({ scope, name, title }: { scope: MemoryScope; name: string | null; title: string }): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.memoryGet(scope, name), [admin, scope, name]);
  const { done, clear, apply } = useChange(reload);

  return (
    <section className="memory card" aria-label={title}>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Loaded load={load} what={title} retry={reload}>
        {(doc) => (
          <Document
            key={doc.version ?? 0}
            doc={doc}
            title={title}
            onSave={(text) =>
              apply(
                "memory.put",
                doc.subject,
                () => admin.memoryPut(scope, name, text, doc.version ?? 0),
                `${title} is saved; running sessions read it from their next turn.`,
                (answer) => (answer as MemorySaved).changes,
              )
            }
            onRollback={(to) =>
              apply(
                "memory.put",
                doc.subject,
                () => admin.memoryRollback(scope, name, to, doc.version ?? 0),
                `${title} is rolled back to version ${to}; running sessions read it from their next turn.`,
              )
            }
            onEdit={clear}
          />
        )}
      </Loaded>
    </section>
  );
}

function Document({
  doc,
  title,
  onSave,
  onRollback,
  onEdit,
}: {
  doc: MemoryDocument;
  title: string;
  onSave: (text: string) => Promise<void>;
  onRollback: (to: number) => Promise<void>;
  onEdit: () => void;
}): JSX.Element {
  const { admin } = useConsole();
  const [draft, setDraft] = useState<string | null>(null);
  const [preview, setPreview] = useState<MemoryPreview | null>(null);
  const [error, setError] = useState<unknown>(null);
  const size = draft === null ? 0 : new TextEncoder().encode(draft).length;

  return (
    <>
      <h3>{title}</h3>
      {(doc.inherited ?? []).length > 0 && <Inherited docs={doc.inherited ?? []} />}
      {doc.shown ? (
        <p className="note">
          Version {doc.shown.version}, saved {when(doc.shown.changed_at)} by {doc.shown.changed_by} · {count(doc.shown.bytes, "byte")}
        </p>
      ) : (
        <p className="note">Nothing written yet: no session reads anything from here.</p>
      )}
      {draft === null && doc.text !== "" && <pre className="prompt">{doc.text}</pre>}
      {draft === null && (doc.lines ?? []).length > 0 && <Blame doc={doc} />}

      {doc.editable && draft === null && (
        <div className="actions">
          <button
            type="button"
            onClick={() => {
              onEdit();
              setDraft(doc.text);
            }}
          >
            Change {title.charAt(0).toLowerCase() + title.slice(1)}
          </button>
        </div>
      )}
      {!doc.editable && <p className="note">{scope(doc.scope)}</p>}

      {draft !== null && preview === null && (
        <form
          className="edit wide"
          onSubmit={(e) => {
            e.preventDefault();
            setError(null);
            admin.memoryPreview(doc.scope, doc.name, draft).then(setPreview, setError);
          }}
        >
          <Field label={title} hint={`${size} of ${doc.limit} bytes`} error={size > doc.limit ? `At most ${doc.limit} bytes.` : null}>
            {(p) => <textarea {...p} className="mono source" value={draft} onChange={(e) => setDraft(e.target.value)} rows={14} spellCheck={false} />}
          </Field>
          {error !== null && (
            <p className="field-error" role="alert">
              {describeError(error)}
            </p>
          )}
          <div className="actions">
            <button type="submit" className="primary" disabled={size > doc.limit}>
              Preview
            </button>
            <button type="button" onClick={() => setDraft(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}

      {draft !== null && preview !== null && (
        <Preview
          title={preview.subject}
          lines={preview.unchanged ? [] : [{ field: "text", from: doc.version, to: (doc.version ?? 0) + 1 }]}
          body={<TextDiff title={`${preview.subject} v${preview.version ?? 0} → v${(preview.version ?? 0) + 1}`} lines={preview.unchanged ? [] : preview.diff} />}
          effects={[preview.effect, ...readersEffect(preview.readers), `${preview.bytes} of ${preview.limit} bytes.`]}
          verb="Save"
          onConfirm={async () => {
            await onSave(draft);
            setPreview(null);
            setDraft(null);
          }}
          onCancel={() => setPreview(null)}
        />
      )}

      {doc.readers && <Readers doc={doc} readers={doc.readers} />}
      {doc.versions.length > 0 && <Versions doc={doc} onRollback={onRollback} />}
    </>
  );
}

/** The preview's word on who reads the document now: how many running sessions, and how many are behind. */
function readersEffect(readers: MemoryReaders | undefined): string[] {
  if (!readers || readers.sessions.length === 0) return [];
  const n = readers.sessions.length;
  return [`${count(n, "running session")} ${n === 1 ? "reads" : "read"} it now; ${readers.behind} of them ${readers.behind === 1 ? "is" : "are"} behind version ${readers.version}.`];
}

/**
 * Who is behind: every running session the document reaches that has had a turn, with the
 * version its last turn ran under. A session on a pod can be nudged, which sends it the
 * documents again for its next turn; one on a person's machine hears at its daemon's next
 * poll, and the nudge says so.
 */
function Readers({ doc, readers }: { doc: MemoryDocument; readers: MemoryReaders }): JSX.Element {
  const { admin } = useConsole();
  const [said, setSaid] = useState<string | null>(null);
  const [error, setError] = useState<unknown>(null);

  const nudge = (r: MemoryReader): void => {
    setError(null);
    admin.memoryNudge(doc.scope, doc.name, r.session_id).then(
      (n) => setSaid(n.told ? `Told ${n.session_id} again; it reads version ${readers.version} at its next turn.` : `${n.session_id} is not told: ${n.reason ?? "its machine asks at its next poll"}.`),
      setError,
    );
  };

  return (
    <section className="readers" aria-label="Who reads it">
      <Region>Who reads it</Region>
      {readers.sessions.length === 0 ? (
        <p className="note">No running session has had a turn under it yet; each reads the version in force at its first.</p>
      ) : (
        <>
          <p className="note">
            {readers.behind === 0
              ? `Every one of the ${count(readers.sessions.length, "running session")} that read it ran its last turn under version ${readers.version}.`
              : `${count(readers.behind, "running session")} behind version ${readers.version}: each reads it at its next turn.`}
          </p>
          <table className="readers">
            <thead>
              <tr>
                <th scope="col">Session</th>
                <th scope="col">Owner</th>
                <th scope="col">Profile</th>
                <th scope="col">Version read</th>
                <th scope="col">Last turn</th>
                <th scope="col">
                  <span className="visually-hidden">Nudge</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {readers.sessions.map((r) => (
                <tr key={r.session_id} className={r.behind ? "behind" : undefined}>
                  <td className="mono">
                    {r.session_id}
                    {r.where === "machine" ? " (a person's machine)" : ""}
                  </td>
                  <td>{r.owner ?? "—"}</td>
                  <td>{r.profile ?? "—"}</td>
                  <td>
                    {r.version === 0 ? "none" : `v${r.version}`}
                    {r.behind ? " · behind" : ""}
                  </td>
                  <td>{when(r.turn_at)}</td>
                  <td>
                    {doc.editable && r.behind && (
                      <button type="button" onClick={() => nudge(r)}>
                        Nudge {r.session_id}
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="note">A session on a pod is told at once by a nudge; one on a person's machine hears at its daemon's next poll, within five minutes.</p>
        </>
      )}
      {said !== null && (
        <p className="note" role="status">
          {said}
        </p>
      )}
      {error !== null && (
        <p className="field-error" role="alert">
          {describeError(error)}
        </p>
      )}
    </section>
  );
}

/**
 * What a profile's sessions read before its own: the documents of the profiles it extends,
 * the one that extends nothing first, each saying which profile it is from. Changed on that
 * profile's page, not here.
 */
function Inherited({ docs }: { docs: MemoryInherited[] }): JSX.Element {
  return (
    <section className="inherited" aria-label="Inherited memory">
      <p className="note">Its sessions read these first, from the profiles it extends, then its own below:</p>
      {docs.map((d) => (
        <div key={d.profile}>
          <p className="note">
            From the {d.profile} profile: version {d.version}, saved {when(d.changed_at)} by {d.changed_by} · {count(d.bytes, "byte")}. Changed on {d.profile}'s page.
          </p>
          <pre className="prompt">{d.text}</pre>
        </div>
      ))}
    </section>
  );
}

/**
 * Who wrote each line of the version shown (troupe #55's provenance), asked for: the version
 * a line came in and who saved it in a column beside it, and for an agent's entry the agent
 * and the session it came from. Blame, not history: the versions say the rest.
 */
function Blame({ doc }: { doc: MemoryDocument }): JSX.Element {
  const [open, setOpen] = useState(false);
  return (
    <div className="blame">
      <button type="button" className="link" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        {open ? "Hide who wrote each line" : "Who wrote each line"}
      </button>
      {open && (
        <table className="blame-lines mono" aria-label={`Who wrote each line of ${doc.subject} v${doc.version ?? 0}`}>
          <tbody>
            {(doc.lines ?? []).map((l, i) => (
              <tr key={i}>
                <th scope="row" title={`saved ${when(l.at)} by ${l.by ?? "nobody named"}`}>
                  {writtenBy(l)}
                </th>
                <td>{l.text}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

/** A line's side column: the version and who saved it, or the agent and session of an agent's entry. */
export function writtenBy(line: MemoryBlameLine): string {
  if (line.agent) return `v${line.version} ${line.agent} in ${line.session ?? "a session"}`;
  if (line.session) return `v${line.version} an agent in ${line.session}`;
  return `v${line.version} ${line.by ?? ""}`.trim();
}

/**
 * Two versions side by side: the older on the left and the one shown on the right, line for
 * line as the plane compared them, a line that went marked on the left and one that came on
 * the right, and a run of each paired across.
 */
function SideBySide({ doc }: { doc: MemoryDocument }): JSX.Element {
  const rows = besideRows(doc.diff);
  return (
    <table className="side-by-side mono" aria-label={`${doc.subject} v${doc.against ?? 0} beside v${doc.version ?? 0}`}>
      <thead>
        <tr>
          <th scope="col">Version {doc.against ?? 0}</th>
          <th scope="col">Version {doc.version ?? 0}</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r, i) => (
          <tr key={i}>
            <td className={r.left === null ? "empty" : r.changed ? "del" : "ctx"}>
              {r.left !== null && r.changed && <span className="visually-hidden">removed: </span>}
              {r.left ?? ""}
            </td>
            <td className={r.right === null ? "empty" : r.changed ? "add" : "ctx"}>
              {r.right !== null && r.changed && <span className="visually-hidden">added: </span>}
              {r.right ?? ""}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/** The plane's line diff as two columns: a line kept on both sides, a run of lines gone beside the run that came. */
export function besideRows(lines: MemoryLine[]): Array<{ left: string | null; right: string | null; changed: boolean }> {
  const rows: Array<{ left: string | null; right: string | null; changed: boolean }> = [];
  let gone: string[] = [];
  let came: string[] = [];
  const flush = (): void => {
    for (let i = 0; i < Math.max(gone.length, came.length); i++) rows.push({ left: gone[i] ?? null, right: came[i] ?? null, changed: true });
    gone = [];
    came = [];
  };
  for (const l of lines) {
    if (l.op === "same") {
      flush();
      rows.push({ left: l.text, right: l.text, changed: false });
    } else if (l.op === "del") {
      if (came.length > 0) flush();
      gone.push(l.text);
    } else came.push(l.text);
  }
  flush();
  return rows;
}

function scope(of: MemoryScope): string {
  return of === "team" ? "Only this team's admins change it." : "Only a platform admin changes it.";
}

/**
 * Every version, newest first, each opening onto what it changed against the one before;
 * an open one can be set beside the version in force, two columns with the changed lines
 * marked, and, for whoever may change the document, rolled back to: its text saved as the
 * next version, previewed first as every save is.
 */
function Versions({ doc, onRollback }: { doc: MemoryDocument; onRollback: (to: number) => Promise<void> }): JSX.Element {
  const { admin } = useConsole();
  const [open, setOpen] = useState<MemoryDocument | null>(null);
  const [beside, setBeside] = useState<MemoryDocument | null>(null);
  const [rollback, setRollback] = useState<MemoryPreview | null>(null);
  const [error, setError] = useState<unknown>(null);
  const inForce = doc.versions[0]?.version ?? null;

  return (
    <>
      <Region>Versions</Region>
      <ol className="revisions">
        {doc.versions.map((v) => (
          <li key={v.version}>
            <button
              type="button"
              className="link"
              aria-expanded={open?.version === v.version}
              onClick={() => {
                setError(null);
                setBeside(null);
                setRollback(null);
                if (open?.version === v.version) setOpen(null);
                else admin.memoryGet(doc.scope, doc.name, v.version).then(setOpen, setError);
              }}
            >
              Version {v.version}
            </button>{" "}
            · {when(v.changed_at)} by {v.changed_by} · {count(v.bytes, "byte")}
            {v.version === inForce ? " · in force" : ""}
            {open?.version === v.version && (
              <div className="memory-version">
                <TextDiff title={`${doc.subject} v${v.version - 1} → v${v.version}`} lines={open.diff} />
                {inForce !== null && v.version !== inForce && (
                  <div className="actions">
                    <button
                      type="button"
                      onClick={() => {
                        setError(null);
                        admin.memoryGet(doc.scope, doc.name, inForce, v.version).then(setBeside, setError);
                      }}
                    >
                      Beside version {inForce}
                    </button>
                    {doc.editable && (
                      <button
                        type="button"
                        onClick={() => {
                          setError(null);
                          admin.memoryPreview(doc.scope, doc.name, open.text).then(setRollback, setError);
                        }}
                      >
                        Restore version {v.version}
                      </button>
                    )}
                  </div>
                )}
                {beside !== null && <SideBySide doc={beside} />}
                {rollback !== null && (
                  <Preview
                    title={rollback.subject}
                    lines={rollback.unchanged ? [] : [{ field: "text", from: inForce, to: (inForce ?? 0) + 1 }]}
                    body={<TextDiff title={`${rollback.subject} v${inForce} → v${(inForce ?? 0) + 1}, the text of v${v.version}`} lines={rollback.unchanged ? [] : rollback.diff} />}
                    effects={[`Saved as version ${(inForce ?? 0) + 1}, with the text of version ${v.version}; every version stays.`, rollback.effect, ...readersEffect(rollback.readers)]}
                    verb="Roll back"
                    onConfirm={async () => {
                      await onRollback(v.version);
                      setRollback(null);
                      setOpen(null);
                    }}
                    onCancel={() => setRollback(null)}
                  />
                )}
              </div>
            )}
          </li>
        ))}
      </ol>
      {error !== null && (
        <p className="field-error" role="alert">
          {describeError(error)}
        </p>
      )}
    </>
  );
}
