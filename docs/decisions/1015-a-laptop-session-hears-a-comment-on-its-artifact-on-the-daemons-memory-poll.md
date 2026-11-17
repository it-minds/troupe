---
number: 1015
title: "A comment on an artifact a laptop's session published reaches that session on its daemon's existing poll of me.memory, which asks for the comments written since the last answer on its person's artifacts from a session on their machine, beside the signed memory; the daemon writes each into its session's log as artifact_commented once, never as input, within one poll (five minutes)"
date: 2026-11-16
status: accepted
issue: 980
paths:
  - apps/troupe_plane/lib/troupe/plane/artifacts/comments.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/memory.ex
symbols:
  - Troupe.Plane.Artifacts.Comments.since/2
  - Troupe.Gateway.Artifacts.heard/2
  - Troupe.Gateway.Artifacts.comments_ask/1
gist: "laptop session hears a comment on me.memory's poll: artifact_comments {since} beside signed, no session ids sent; once per comment id; never input; Local only hears nothing"
---

Decision 1007 told the session an artifact came from of each comment, but only on a pod:
the plane notifies the pod over its control link. A daemon is never dialled; it dials the
plane. An artifact published from a laptop's session (`origin.where: laptop`) had no path.

## The path

The daemon already asks the plane's `me.memory` at every link that brings a token and every
five minutes (Decision 922), and that ask already carries news for the sessions here: what
each read (Decision 947), and the person's memory proposals decided, which the daemon tells
the session they came from (Decision 1004). The comments ride the same ask rather than a
method of their own: one round trip the daemon makes anyway, no second timer.

- **The ask** carries `artifact_comments: {since}`, where the last answer left off for this
  plane (`null` at first, and after the daemon starts again).
- **The plane** answers `artifact_comments: {since, comments}`: the comments written after
  `since` on artifacts the caller owns (`owner_id`) whose origin is a laptop session, oldest
  first, at most 200, each with the session it came from, the artifact's id and title and the
  comment as the thread has it; and the `since` to ask with next, the newest one's time, or the
  one asked with where there is none. With `since` `null` it answers none and its own now: a
  daemon hears what is written while it runs, as a pod's session does (Decision 1007's best
  effort; the thread on the plane is the record). Asked without the field, the answer has none,
  so a plane from before it and a daemon from before it each go on as they were.
- **The daemon** writes each into its session's log as `artifact_commented` with the same data
  a pod writes (`artifact: {id, title}`, `comment: {id, author, body, created_at}`), as the
  session's own line (agent path `[]`, as the pod writes it), where that session runs here and
  is not under Local only; a comment for a session not running here is dropped. Before it writes
  it reads the log for an `artifact_commented` with that comment's id, so two asks made at
  once (a link's and the poll's) write it once. Then it keeps the answer's `since`.

**Latency** is the poll's: within five minutes of the comment, at once after a sign-in.

**Never input.** As on a pod: the event is a line in the log, no turn starts, no agent is
given it. A comment is somebody else's words.

## Choices

- **Beside the signed memory, not in it.** `Signing.signed("memory", ...)` signs the body, and
  the daemon keeps the signed envelope as its memory copy on disk. Comments inside it would be
  written into that file on every poll and covered by a signature whose meaning is "the
  organisation's memory as the plane holds it". The field is put on the answer after signing;
  the daemon reads it from the answer, over the same authenticated connection.
- **No session ids sent.** The brief offered asking for "the sessions it owns". The plane can
  answer by whose artifacts they are (the caller's, from a laptop session), and the daemon
  picks the ones it runs. Sending ids would put on the wire every session id here, a Local
  only one included unless filtered, for no gain; the answer for a person with two machines
  carries both machines' comments, and each daemon writes its own.
- **A cursor kept in memory**, per plane URL, not on disk: a daemon started again starts from
  the plane's now, as its sessions start again too. A comment written while the daemon was down
  is in the thread, as one written while a pod's session was down is.
- **Local only.** While every client attached is in Local only the poll asks nothing
  (Decision 947's rule), so nothing is heard; a session under Local only is skipped when
  writing. Nothing of a session is sent to hear its comments.
- **Edits and deletions are not announced** (Decision 1016): a deleted comment is not in a
  later answer, and an edit does not move its `created_at`.

## Proof

- `apps/troupe_plane/test/troupe/plane/artifact_comment_edits_test.exs` ("a laptop's daemon,
  on its poll"): the first poll hears nothing written before it and is given where to start;
  the next hears a comment on the caller's laptop artifact with its session, artifact and
  author, and not one on an artifact from no session nor on another person's; asked again from
  where it left off, nothing, and a deleted comment is not told; the field is not inside
  `signed`; a poll that does not ask has none.
- `apps/troupe_gateway/test/troupe/gateway/plane_memory_test.exs` ("a comment on an artifact a
  session here published"): the comment is written into the running session's log once across
  several polls, starts no turn, is not written into a session under Local only, and the asks
  carry `since` and nothing else.

Both failed on the chunk's tip: `me.memory` answered no `artifact_comments`, and the daemon
asked for none.
