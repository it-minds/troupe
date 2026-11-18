// What an administrator reads of somebody else's artifact beyond what anybody who may open
// it reads (`admin.artifact.get`): who its owner shared it with by name, its links with who
// was signed in through each, and, for one they may not open as anybody may, its comments.
// To read, never to change: taking a link or a person back is its owner's, and the
// administrator's own control is the takedown on the artifact's page.

import type { JSX } from "react";
import type { AdminArtifactPage, ArtifactComment } from "@troupe/client";
import { Region, when } from "./bits";

const ROLE: Record<string, string> = { view: "may open it", comment: "may comment on it", edit: "may comment on it and publish new versions" };
const LINK: Record<string, string> = { view: "View", comment: "Comment", edit: "Edit" };

/** Its thread, oldest first, as its administrator reads it: nothing to write in. */
export function AuditedThread({ comments }: { comments: ArtifactComment[] }): JSX.Element {
  return (
    <section aria-label="Comments">
      <Region>Comments</Region>
      {comments.length === 0 ? (
        <p className="lead">No comments yet.</p>
      ) : (
        <ol className="artifact-comments">
          {comments.map((c) => (
            <li key={c.id}>
              <header>
                <b>{c.author.display_name || c.author.subject}</b>
                <span className="muted"> · {when(c.created_at)}</span>
                {c.edited_at && <span className="muted"> · edited {when(c.edited_at)}</span>}
              </header>
              <p className="comment-body">{c.body}</p>
            </li>
          ))}
        </ol>
      )}
      <p className="hint">Only those who may open it write here.</p>
    </section>
  );
}

/** Who it is shared with by name, and its links, as its administrator reads them. */
export function AuditedPeople({ artifact: a }: { artifact: AdminArtifactPage }): JSX.Element {
  const people = a.people ?? [];
  const shares = a.shares ?? [];
  return (
    <>
      <section aria-label="Shared with">
        <Region>Shared with</Region>
        {people.length === 0 ? (
          <p className="lead">Nobody by name.</p>
        ) : (
          <ul className="artifact-people">
            {people.map((p) => (
              <li key={p.subject}>
                <b>{p.display_name || p.subject}</b>{" "}
                <span className="muted">
                  {ROLE[p.role] ?? p.role} · since {when(p.granted_at)}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
      <section aria-label="Links">
        <Region>Links</Region>
        {shares.length === 0 ? (
          <p className="note">No link has been made to it.</p>
        ) : (
          <ul className="artifact-links" aria-label="Its links">
            {shares.map((s) => (
              <li key={s.id} aria-label={`${s.public ? "Public link" : "Link"} ${s.id}`}>
                <header>
                  <b>{s.public ? "Public, view" : (LINK[s.role] ?? s.role)}</b>
                  <span className="muted">
                    {" "}
                    · {s.state} · made {when(s.created_at)} · {s.expires_at ? `expires ${when(s.expires_at)}` : "no expiry"}
                  </span>
                </header>
                {s.used_by.length === 0 ? (
                  <p className="note">{s.public ? "A public link signs nobody in, so it records nobody." : "Nobody has been signed in through it yet."}</p>
                ) : (
                  <p className="note">
                    Signed in through it:{" "}
                    {s.used_by.map((u) => `${u.person.display_name ?? u.person.subject}${u.revoked_at ? " (revoked)" : ""}, last ${when(u.last_used_at)}`).join("; ")}
                  </p>
                )}
              </li>
            ))}
          </ul>
        )}
        <p className="hint">Its owner makes and revokes its links, and shares it with people by name.</p>
      </section>
    </>
  );
}
