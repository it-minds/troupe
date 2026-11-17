---
number: 1016
title: "A comment in an artifact's thread is deleted by its author, the artifact's owners, or whoever may take the artifact down (artifact.comment.delete, its row removed with no tombstone), and edited by its author while they may write in the thread (artifact.comment.edit, marked with edited_at); both audited without the text, the thread says per comment who may do which, and neither is announced to the session"
date: 2026-11-16
status: accepted
issue: 979
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts/comments.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts/comment.ex
  - apps/troupe_plane/lib/troupe/plane/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - clients/gui/apps/desktop/src/views/Artifacts.tsx
  - clients/gui/apps/console/src/views/ArtifactComments.tsx
symbols:
  - Troupe.Plane.Artifacts.delete_comment/4
  - Troupe.Plane.Artifacts.edit_comment/5
  - Troupe.Plane.Artifacts.Comments.delete/5
  - Troupe.Plane.Artifacts.Comments.edit/5
gist: "comment delete: author, owners, takedown (platform admin, team admin), row removed, audited without text; edit: author while a writer, edited_at; may_edit/may_delete per comment"
---

Decision 1007 gave every artifact one thread and left taking a comment back to #979: the
only way to remove one was deleting the artifact.

## Who

- **Delete** (`artifact.comment.delete {id, comment}`): the comment's **author**, always, as
  long as they still see the artifact (their own words are theirs to take back, even after
  an owner took their role away); the artifact's **owners**, any comment in their thread;
  and whoever may **take the artifact down** as `artifact.delete` lets them (a platform
  administrator, the administrator of the team a `team:<name>` artifact is for), any comment.
  Whoever may remove the whole artifact may remove one comment of it: the takedown is the same
  method, decided by the plane from who calls it, not a separate administrator's method in
  `admin.ex`. A platform administrator calls it as themselves from either app, and the audit
  says `by: takedown`. A private artifact's thread is not reachable to a platform
  administrator who cannot see it (`visible/3`), so its comments go with the artifact's
  takedown, as before.
- **Edit** (`artifact.comment.edit {id, comment, body}`): the **author** alone, while they
  may still write in the thread (owner, edit or comment); nobody edits another's words. The
  text is checked as a new comment's is (trimmed, not empty, at most 4000 characters). The
  argument is `body`, as `artifact.comment` names it, not `text`.

## What happens

- A deleted comment's **row is removed**: no tombstone "a comment was removed" is kept in the
  thread. The thread is a conversation on the artifact, not a record; the audit is the record
  (who deleted which comment of whose, and how), and a mark in the thread would say to every
  reader that somebody took something back, which is what the author or owner chose not to
  leave. The artifact's comment count drops with it.
- An edit replaces the text and sets `edited_at` (a column added by the migration
  `20261116001016_artifact_comment_edits`, additive); the thread shows "edited" with when.
  Earlier texts are not kept.
- **Audited** as the write is, never with the text: `artifact.comment.delete` with the
  comment's id, its author's subject and `by` (`author`, `owner` or `takedown`);
  `artifact.comment.edit` with its id and new length.
- **Not announced.** `artifact_commented` is unchanged. A session told of a comment is not
  told it was edited or deleted, and a deleted comment is never in a later daemon poll
  (Decision 1015). Who steers the session reads the thread for the current words.

## Clients

`artifact.comments` gives each comment `may_edit` and `may_delete` for the caller, and
`edited_at`, so a client offers each control only to whoever the plane will let use it
(DESIGN §8: remove, don't disable) and never reasons about roles itself. The desktop app's
thread and the console's show **Edit** (the text in a box, **Save** and **Cancel**) and
**Delete**, which asks once in place, saying what it does ("It goes from the thread for
everybody, and cannot be brought back."), with **Delete** and **Keep it** (DESIGN §11: say
the consequence, not "Are you sure?"). The daemon forwards both methods with only their
arguments and refuses them under Local only, as every `artifact.*` (Decision 1007).

## Proof

- `apps/troupe_plane/test/troupe/plane/artifact_comment_edits_test.exs`: the author deletes
  their own and another writer may not; an owner deletes anybody's and the rows count what is
  left; a platform administrator's takedown, audited with who and `by: takedown` and without
  the text; a comment not in the thread, or no id, refused; the author edits, marked edited,
  audited without the text, an owner may not edit it, and the thread's `may_edit` and
  `may_delete` per reader; an author whose role was taken may not edit but may delete.
- `apps/troupe_gateway/test/troupe/gateway/artifacts_test.exs` (both forwarded with only their
  arguments) and `local_only_test.exs` (both refused under Local only).
- The desktop app's `artifacts-gallery.test.tsx` and the console's
  `artifact-comments.test.tsx`: Edit and Delete only where the plane says, an edit marked
  edited, a delete asked once and Keep it keeping it, an owner's Delete on another's comment
  and no Edit, a reader's none on another's.

All failed on the chunk's tip: there was no `artifact.comment.delete` or `.edit`, no
`edited_at` and no `may_edit` or `may_delete`.
