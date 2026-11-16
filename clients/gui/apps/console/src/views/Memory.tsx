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
import { besideRows, writtenBy } from "@troupe/client";
import type { MemoryDocument, MemoryInherited, MemoryPreview, MemoryProposal, MemoryReader, MemoryReaders, MemoryScope, MemorySaved } from "@troupe/client";
import { describeError, useConsole, useLoad } from "../console";
import { href } from "../route";
import { AuditNote, Empty, Field, Loaded, Preview, Region, TextDiff, count, useChange, when } from "./bits";

export function Memory(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.memoryList(), [admin]);
  // Bumped when a proposal is accepted, so the document it went into is read again.
  const [accepted, setAccepted] = useState(0);

  return (
    <div className="page">
      <Loaded load={load} what="the organisation's memory" retry={reload}>
        {(list) => (
          <>
            <p className="lead">
              What every agent in a scope starts from: the organisation's for every session, a team's for that team's sessions and its members' machines. Each reaches a
              session as instructions from the organisation, before the person's own and the repository's. No agent changes one: an agent may propose an entry, which
              waits below until you accept or decline it. A profile's is on the profile's page. Each document holds at most {list.limit} bytes.
            </p>
            <Proposals onAccepted={() => setAccepted((n) => n + 1)} />
            <Region>The organisation's</Region>
            <MemoryEditor key={`organisation:${accepted}`} scope="organisation" name={null} title="The organisation's memory" />
            <Region>Teams'</Region>
            {list.teams.length === 0 ? (
              <Empty title="No team of yours keeps memory here" />
            ) : (
              list.teams.map((t) => <MemoryEditor key={`${t.subject}:${accepted}`} scope="team" name={t.name} title={`The ${t.name} team's memory`} />)
            )}
          </>
        )}
      </Loaded>
    </div>
  );
}

/** Where a proposal would go, in a sentence: "the core team's memory", "the organisation's memory". */
export function proposalLevel(p: MemoryProposal): string {
  return p.scope === "team" ? `the ${p.team ?? "team"} team's memory` : "the organisation's memory";
}

/**
 * What agents proposed for a team's or the organisation's memory and waits for whoever may
 * change that level (troupe #55): each entry, where it would go, and where it came from.
 * Accepting writes it as the next version, with the agent and its session as who wrote the
 * line, previewed first as every save is; declining asks for a sentence, which the session
 * is told. Nothing here is read by any session until it is accepted.
 */
function Proposals({ onAccepted }: { onAccepted: () => void }): JSX.Element | null {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.memoryProposals(), [admin]);
  const { done, apply } = useChange(reload);
  const [accepting, setAccepting] = useState<MemoryProposal | null>(null);
  const [declining, setDeclining] = useState<MemoryProposal | null>(null);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<unknown>(null);

  // A plane from before proposals has none to list; any other failure is said.
  if (load.state === "loading" || (load.state === "error" && (load.error as { code?: unknown } | null)?.code === -32601)) return null;
  if (load.state === "error") return <Loaded load={load} what="the proposals waiting for review" retry={reload}>{() => null}</Loaded>;
  const { enabled, proposals } = load.data;
  if (proposals.length === 0 && enabled && !done) return null;

  const decline = async (p: MemoryProposal): Promise<void> => {
    setError(null);
    try {
      await apply("memory.proposal.decline", subjectOf(p), () => admin.memoryDecline(p.id, reason), `The proposal for ${proposalLevel(p)} is declined; its session is told why.`);
      setDeclining(null);
      setReason("");
    } catch (e) {
      setError(e);
    }
  };

  return (
    <section className="proposals" aria-label="Waiting for review">
      {proposals.length > 0 ? <Region tone="waiting">Waiting for review</Region> : <Region>Waiting for review</Region>}
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      {!enabled && (
        <p className="note">
          Agents' proposals are switched off (Agents may propose memory, on <a href={href({ page: "policy" })}>Policy and settings</a>): an agent's is refused, and what is here was proposed before.
        </p>
      )}
      {proposals.length === 0 ? (
        <p className="note">Nothing waits for review.</p>
      ) : (
        <ul className="proposal-list">
          {proposals.map((p) => (
            <li key={p.id} className="proposal card">
              <p className="note">
                For {proposalLevel(p)}, under <strong>{p.topic}</strong>
              </p>
              <blockquote className="entry">{p.entry}</blockquote>
              <p className="note">
                Proposed {when(p.at)} by {p.agent ? `the agent ${p.agent}` : "an agent"}
                {p.session_id ? (
                  <>
                    {" "}
                    in <span className="mono">{p.session_id}</span>
                  </>
                ) : null}
                , {p.where === "machine" ? "on" : "for"} {p.by}
                {p.where === "machine" ? "'s machine" : ", on a pod"}.
              </p>
              {accepting?.id === p.id ? (
                <Preview
                  title={subjectOf(p)}
                  lines={[{ field: p.topic, from: null, to: `- ${p.entry}` }]}
                  body={<TextDiff title={`${subjectOf(p)} · ## ${p.topic}`} lines={[{ op: "add", text: `- ${p.entry}` }]} />}
                  effects={[
                    `Saved as the next version of ${proposalLevel(p)}, by you, with ${p.agent ?? "the agent"}${p.session_id ? ` in ${p.session_id}` : ""} as who wrote the line.`,
                    p.scope === "team" ? `The sessions of ${p.team} read it from their next turn, and its members' machines within five minutes.` : "Every session reads it from its next turn, and every signed-in machine within five minutes.",
                    "The session it came from is told it was accepted.",
                  ]}
                  verb="Accept"
                  onConfirm={async () => {
                    await apply("memory.proposal.accept", subjectOf(p), () => admin.memoryAccept(p.id), `The proposal is in ${proposalLevel(p)} now; running sessions read it from their next turn.`);
                    setAccepting(null);
                    onAccepted();
                  }}
                  onCancel={() => setAccepting(null)}
                />
              ) : declining?.id === p.id ? (
                <form
                  className="edit"
                  onSubmit={(e) => {
                    e.preventDefault();
                    void decline(p);
                  }}
                >
                  <Field label="Why it is declined" hint="Its session is told this sentence as it is, and so is the person it came from.">
                    {(f) => <textarea {...f} value={reason} onChange={(e) => setReason(e.target.value)} rows={2} />}
                  </Field>
                  {error !== null && (
                    <p className="field-error" role="alert">
                      {describeError(error)}
                    </p>
                  )}
                  <div className="actions">
                    <button type="submit" className="primary" disabled={reason.trim() === ""}>
                      Decline
                    </button>
                    <button type="button" onClick={() => setDeclining(null)}>
                      Cancel
                    </button>
                  </div>
                </form>
              ) : (
                <div className="actions">
                  <button
                    type="button"
                    onClick={() => {
                      setDeclining(null);
                      setAccepting(p);
                    }}
                  >
                    Accept
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      setAccepting(null);
                      setError(null);
                      setReason("");
                      setDeclining(p);
                    }}
                  >
                    Decline
                  </button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function subjectOf(p: MemoryProposal): string {
  return p.scope === "team" ? `team/${p.team}` : "organisation";
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
      {draft === null && (doc.entries ?? []).length > 0 && <Entries doc={doc} />}

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
          cancel="Back to editing"
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
          <div className="scroll">
            <table className="readers">
              <thead>
                <tr>
                  <th scope="col">Session</th>
                  <th scope="col">Owner</th>
                  <th scope="col">Profile</th>
                  <th scope="col">Version read</th>
                  <th scope="col">Last turn</th>
                  <th scope="col" className="row-actions">
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
                    <td>{r.activated && !r.turn_at ? "activated, no turn yet" : when(r.turn_at)}</td>
                    <td className="row-actions">
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
          </div>
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
        <div className="scroll">
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
        </div>
      )}
    </div>
  );
}

/**
 * The version shown as its entries (troupe #55), asked for: one per `## Topic`, as the plane
 * reads them, each with who last changed it and in how many sessions it was used. Read only:
 * the document above is what is edited.
 */
function Entries({ doc }: { doc: MemoryDocument }): JSX.Element {
  const [open, setOpen] = useState(false);
  const entries = doc.entries ?? [];
  return (
    <div className="blame">
      <button type="button" className="link" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        {open ? "Hide its entries" : `Its entries, one per topic (${entries.length})`}
      </button>
      {open && (
        <div className="scroll">
          <table className="blame-lines" aria-label={`Entries of ${doc.subject} v${doc.version ?? 0}`}>
            <tbody>
              {entries.map((e, i) => (
                <tr key={i}>
                  <th scope="row">{e.topic}</th>
                  <td className="mono">
                    v{e.version ?? "?"} {e.agent ?? e.by ?? ""} · used in {count(e.used ?? 0, "session")}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

/**
 * Two versions side by side: the older on the left and the one shown on the right, line for
 * line as the plane compared them, a line that went marked on the left and one that came on
 * the right, and a run of each paired across.
 */
function SideBySide({ doc }: { doc: MemoryDocument }): JSX.Element {
  const rows = besideRows(doc.diff);
  return (
    <div className="scroll">
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
    </div>
  );
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
