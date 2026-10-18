// The organisation's memory (#55): what the organisation, each team and each worker profile
// wrote for every agent in their scope. Each document reaches the sessions in its scope as
// instructions from the organisation, before the person's own instructions and the
// repository's files, and no agent can change one: this is where a person does.
//
// Every save is a new version, kept with who saved it; a save shows what it changes line by
// line before it is made, and the audit's record after. The organisation's and a profile's
// are a platform admin's to change, a team's its team admins'. A profile's is edited on the
// profile's own page, through the same editor.

import { useState } from "react";
import type { JSX } from "react";
import type { MemoryDocument, MemoryPreview, MemoryScope, MemorySaved } from "@troupe/client";
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
                `${title} is saved; sessions read it from their next activation.`,
                (answer) => (answer as MemorySaved).changes,
              )
            }
            onEdit={clear}
          />
        )}
      </Loaded>
    </section>
  );
}

function Document({ doc, title, onSave, onEdit }: { doc: MemoryDocument; title: string; onSave: (text: string) => Promise<void>; onEdit: () => void }): JSX.Element {
  const { admin } = useConsole();
  const [draft, setDraft] = useState<string | null>(null);
  const [preview, setPreview] = useState<MemoryPreview | null>(null);
  const [error, setError] = useState<unknown>(null);
  const size = draft === null ? 0 : new TextEncoder().encode(draft).length;

  return (
    <>
      <h3>{title}</h3>
      {doc.shown ? (
        <p className="note">
          Version {doc.shown.version}, saved {when(doc.shown.changed_at)} by {doc.shown.changed_by} · {count(doc.shown.bytes, "byte")}
        </p>
      ) : (
        <p className="note">Nothing written yet: no session reads anything from here.</p>
      )}
      {draft === null && doc.text !== "" && <pre className="prompt">{doc.text}</pre>}

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
          effects={[preview.effect, `${preview.bytes} of ${preview.limit} bytes.`]}
          verb="Save"
          onConfirm={async () => {
            await onSave(draft);
            setPreview(null);
            setDraft(null);
          }}
          onCancel={() => setPreview(null)}
        />
      )}

      {doc.versions.length > 0 && <Versions doc={doc} />}
    </>
  );
}

function scope(of: MemoryScope): string {
  return of === "team" ? "Only this team's admins change it." : "Only a platform admin changes it.";
}

/** Every version, newest first, each opening onto what it changed against the one before. */
function Versions({ doc }: { doc: MemoryDocument }): JSX.Element {
  const { admin } = useConsole();
  const [open, setOpen] = useState<MemoryDocument | null>(null);
  const [error, setError] = useState<unknown>(null);

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
                if (open?.version === v.version) setOpen(null);
                else admin.memoryGet(doc.scope, doc.name, v.version).then(setOpen, setError);
              }}
            >
              Version {v.version}
            </button>{" "}
            · {when(v.changed_at)} by {v.changed_by} · {count(v.bytes, "byte")}
            {open?.version === v.version && (
              <div className="memory-version">
                <TextDiff title={`${doc.subject} v${v.version - 1} → v${v.version}`} lines={open.diff} />
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
