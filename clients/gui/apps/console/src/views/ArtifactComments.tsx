// An artifact's thread.
//
// The thread is one per artifact, kept on the plane, oldest first, each comment with who
// wrote it and when. Whoever may open the artifact reads it; its owners, and anybody given
// comment or edit, write in it. The session the artifact came from hears each comment, so
// whoever steers it can ask its agent to act on it; nothing a reader writes reaches an agent
// unless that person passes it on. Its author edits a comment, marked edited, and deletes
// it; an owner, or whoever may take the artifact down, deletes any.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import type { ArtifactApi, ArtifactDetail, ArtifactThread } from "@troupe/client";
import { describeError } from "../console";
import { Region, when } from "./bits";

export function ArtifactComments({ artifact: a, api }: { artifact: ArtifactDetail; api: ArtifactApi }): JSX.Element | null {
  const [thread, setThread] = useState<ArtifactThread | null>(null);
  const [absent, setAbsent] = useState(false);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [asked, setAsked] = useState(0);
  const [editing, setEditing] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState("");
  const [confirming, setConfirming] = useState<string | null>(null);
  // Which change failed, for the error's words: posting, deleting or saving an edit.
  const [failed, setFailed] = useState<"delete" | "edit" | null>(null);

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
    setFailed(null);
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

  // A comment's own controls, there only for whoever the plane says may: its author edits
  // and deletes it, an owner or whoever may take the artifact down deletes any. Deleting
  // asks once, saying what it does.
  const change = (what: "delete" | "edit", work: Promise<unknown>): void => {
    setBusy(true);
    setError(null);
    setFailed(what);
    work.then(
      () => {
        setBusy(false);
        setFailed(null);
        setEditing(null);
        setConfirming(null);
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
                {c.edited_at && <span className="muted"> · edited {when(c.edited_at)}</span>}
              </header>
              {editing === c.id ? (
                <form
                  className="edit"
                  onSubmit={(e) => {
                    e.preventDefault();
                    if (editDraft.trim() !== "") change("edit", api.editComment(a.id, c.id, editDraft));
                  }}
                >
                  <label>
                    Edit your comment
                    <textarea value={editDraft} maxLength={thread?.max_length} rows={3} disabled={busy} onChange={(e) => setEditDraft(e.target.value)} />
                  </label>
                  <div className="actions">
                    <button type="submit" className="primary" disabled={busy || editDraft.trim() === ""}>
                      Save
                    </button>
                    <button type="button" disabled={busy} onClick={() => setEditing(null)}>
                      Cancel
                    </button>
                  </div>
                </form>
              ) : (
                <p className="comment-body">{c.body}</p>
              )}
              {confirming === c.id ? (
                <div className="actions" role="group" aria-label="Delete this comment?">
                  <span className="hint">It goes from the thread for everybody, and cannot be brought back.</span>
                  <button type="button" className="danger" disabled={busy} onClick={() => change("delete", api.deleteComment(a.id, c.id))}>
                    Delete
                  </button>
                  <button type="button" disabled={busy} onClick={() => setConfirming(null)}>
                    Keep it
                  </button>
                </div>
              ) : (
                editing !== c.id &&
                (c.may_edit || c.may_delete) && (
                  <div className="actions">
                    {c.may_edit && (
                      <button
                        type="button"
                       
                        disabled={busy}
                        onClick={() => {
                          setEditing(c.id);
                          setEditDraft(c.body);
                        }}
                      >
                        Edit
                      </button>
                    )}
                    {c.may_delete && (
                      <button type="button" disabled={busy} onClick={() => setConfirming(c.id)}>
                        Delete
                      </button>
                    )}
                  </div>
                )
              )}
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
          Could not {!thread ? "read the comments" : failed === "delete" ? "delete the comment" : failed === "edit" ? "save the comment" : "post the comment"}: {describeError(error)}
        </p>
      )}
    </section>
  );
}
