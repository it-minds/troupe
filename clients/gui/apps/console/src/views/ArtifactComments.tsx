// An artifact's thread and, for its owner, who it is shared with by name.
//
// The thread is one per artifact, kept on the plane, oldest first, each comment with who
// wrote it and when. Whoever may open the artifact reads it; its owners, and anybody given
// comment or edit, write in it. The session the artifact came from hears each comment, so
// whoever steers it can ask its agent to act on it; nothing a reader writes reaches an agent
// unless that person passes it on.
//
// Who it is shared with by name is the owner's to read here and to take back; the desktop
// app's gallery is where a person picks somebody to share their own with.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import type { ArtifactApi, ArtifactDetail, ArtifactThread } from "@troupe/client";
import { describeError, useConsole } from "../console";
import { Region, when } from "./bits";

const ROLE: Record<string, string> = { view: "may open it", comment: "may comment on it", edit: "may comment on it and publish new versions" };

export function ArtifactComments({ artifact: a, api }: { artifact: ArtifactDetail; api: ArtifactApi }): JSX.Element | null {
  const [thread, setThread] = useState<ArtifactThread | null>(null);
  const [absent, setAbsent] = useState(false);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [asked, setAsked] = useState(0);

  useEffect(() => {
    let live = true;
    api.comments(a.id).then(
      (t) => live && setThread(t),
      (e: unknown) => {
        if (!live) return;
        // A plane from before comments has no thread, which is no fault.
        if ((e as { code?: unknown } | null)?.code === -32601) setAbsent(true);
        else setError(e);
      },
    );
    return () => {
      live = false;
    };
  }, [api, a.id, asked]);

  if (absent) return null;

  const send = (): void => {
    setBusy(true);
    setError(null);
    api.comment(a.id, draft).then(
      () => {
        setBusy(false);
        setDraft("");
        setAsked((n) => n + 1);
      },
      (e: unknown) => {
        setBusy(false);
        setError(e);
      },
    );
  };

  const comments = thread?.comments ?? [];
  return (
    <section aria-label="Comments">
      <Region>Comments</Region>
      {thread && comments.length === 0 && <p className="lead">No comments yet.</p>}
      {comments.length > 0 && (
        <ol className="artifact-comments">
          {comments.map((c) => (
            <li key={c.id}>
              <header>
                <b>{c.author.display_name || c.author.subject}</b>
                <span className="muted"> · {when(c.created_at)}</span>
              </header>
              <p className="comment-body">{c.body}</p>
            </li>
          ))}
        </ol>
      )}
      {thread?.may_comment ? (
        <form
          className="edit"
          onSubmit={(e) => {
            e.preventDefault();
            if (draft.trim() !== "") send();
          }}
        >
          <label>
            Write a comment
            <textarea value={draft} maxLength={thread.max_length} rows={3} disabled={busy} onChange={(e) => setDraft(e.target.value)} />
          </label>
          <div className="actions">
            <button type="submit" className="primary" disabled={busy || draft.trim() === ""}>
              Comment
            </button>
            <span className="hint">Its owners and editors read it here, and the session it came from is told.</span>
          </div>
        </form>
      ) : (
        thread && <p className="hint">You can read the comments. Its owner decides who may write them.</p>
      )}
      {error !== null && (
        <p className="field-error" role="alert">
          Could not {thread ? "post the comment" : "read the comments"}: {describeError(error)}
        </p>
      )}
    </section>
  );
}

/** Who its owner shared it with by name, each at a role, and taking somebody back. */
export function ArtifactPeople({ artifact: a, api, reload }: { artifact: ArtifactDetail; api: ArtifactApi; reload: () => void }): JSX.Element | null {
  const { notify } = useConsole();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const people = a.people;
  if (!people) return null;

  const remove = (subject: string, name: string): void => {
    setBusy(true);
    setError(null);
    api.unshare(a.id, { person: subject }).then(
      () => {
        setBusy(false);
        notify(`${name} cannot open ${a.title} now, unless it is for somebody they are.`);
        reload();
      },
      (e: unknown) => {
        setBusy(false);
        setError(e);
      },
    );
  };

  return (
    <section aria-label="Shared with">
      <Region>Shared with</Region>
      {people.length === 0 ? (
        <p className="lead">Nobody by name. You share your own with a picked person from the desktop app's gallery, or with a link below.</p>
      ) : (
        <ul className="artifact-people">
          {people.map((p) => {
            const name = p.display_name || p.subject;
            return (
              <li key={p.subject}>
                <b>{name}</b> <span className="muted">{ROLE[p.role] ?? p.role} · since {when(p.granted_at)}</span>{" "}
                <button type="button" disabled={busy} onClick={() => remove(p.subject, name)} aria-label={`Remove ${name}`}>
                  Remove
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {error !== null && (
        <p className="field-error" role="alert">
          Could not remove them: {describeError(error)}
        </p>
      )}
    </section>
  );
}
