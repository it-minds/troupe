---
number: 965
title: "A publication is aimed by the person at the gate: the agent proposes an audience only where the person named one, a call that names none must be asked whatever the rules say, and the approval's answer carries whom it is for and whose it is"
date: 2026-10-28
status: accepted
supersedes: [850]
paths:
  - apps/troupe_core/lib/troupe/tools/publish_artifact.ex
  - apps/troupe_core/lib/troupe/session/approvals.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_worker/lib/troupe/worker/artifacts.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - PROTOCOL.md
  - apps/troupe_core/test/troupe/tools/publish_artifact_test.exs
symbols:
  - Troupe.Tools.PublishArtifact.must_ask?/1
  - Troupe.Tools.PublishArtifact.publication/1
  - Troupe.Tools.PublishArtifact.as_answered/2
  - Troupe.Session.Approvals.decide/5
gist: "publish_artifact with no visibility must ask; approval_requested carries publication; the answer's visibility/owner run the call; allow_session with null visibility is allow"
---

An agent that published an artifact chose whom it was for. `publish_artifact` defaulted
`visibility` to `private`, the model filled it in from whatever it took the person to
mean, and the approval the clients showed was the bare tool call: a person who allowed
"publish the report" had no say in whether it went to them alone, the team or the whole
organisation, and no way to see which before it did. Who reads an artifact is the one
thing about a publication the person cares about, and it was the one thing the gate did
not ask.

- **The model proposes, the person chooses.** The tool's description tells the model to
  set `visibility` only to what the person asked for and to leave it out otherwise, so the
  gate asks. `must_ask?/1` is true for a call with no `visibility`: it is asked whatever a
  per-tool rule, the profile's permission or `auto_approve` says, as a write into the
  config directory is (Decision 823), because nobody but the person may choose the
  audience, and a rule that says "publishing is fine" said nothing about for whom. A call
  that names one is asked as any `ask` tool's and a rule may allow it, since the person
  named it in the prompt. The tool gains `owner` (`me` or `team`): whose a team
  publication is, the team's unless told `me`, which the plane decides and the hosts pass
  through to `artifact.publish` and `session.artifact.publish`.
- **The gate shows a publication, not a tool call.** `approval_requested` for
  `publish_artifact` carries `publication`: `title`, `kind`, `files` (how many),
  `visibility` and `owner` as proposed (`null` for none), `id` and `note`. It is the
  delegation's shape of request (Decision 850): a request with `publication` is one with
  `delegation` in everything but what it shows, and a client that knows neither sees an
  approval for `publish_artifact` with its arguments.
- **The answer carries whom it is for.** `approval.respond` takes `visibility` (one of
  the four shapes; whether the person is in the team is the plane's to refuse, at
  publish, so the gate does not pretend to know) and `owner`, with `reason` on a denial
  as a delegation's. An `allow` naming no visibility where the model named none is refused
  with "say whom it is for: ..." and the request waits on: an artifact is published for
  somebody. `approval_decided` names the `visibility` and `owner` the call ran with and
  which the person `edited`; an audience chosen where the model proposed none counts as
  edited, since it is the person's and not the model's. The tool runs with the person's
  choice laid over the model's arguments, in the one place a task tool's allowed call
  proceeds (`Troupe.Tools.run_task/4`), and its answer says "as the person chose", so the
  model does not take its proposal for what happened. `Troupe.Tool.Ctx` carries the answer
  (`answer`) for that sentence; the arguments carry the choice.
- **`allow_session` on an unaimed publication is this call's `allow`.** A standing
  permission to publish would let the next call run for an audience not yet chosen, which
  is exactly what the must-ask forbids; so it is recorded and acted on as `allow`, as a
  managed session's is. On a publication that named a visibility it is the usual standing
  allow for the tool.
- **Every answer is a call now.** Decision 850 kept a plain word as the cast it had been
  and checked only an answer that carried more. A bare `allow` to a publication nobody
  aimed is the wrong answer, and a cast could only drop it; so `Approvals.decide/5` is a
  `GenServer.call` for every answer, and a wrong plain word is refused to its sender like
  a wrong brief. That part of 850 is superseded; the rest stands.
- **Not chosen.** Asking the person with `ask_user` before the call: the model would
  still carry the answer into `visibility`, and the gate would show a tool call again; the
  gate is where the person already decides, and the choice belongs on the record of that
  decision. A default audience in the profile or the configuration (`artifacts.visibility:
  team:core`), which would answer the gate for a call that said nothing: a reasonable later
  addition, and one that should be the person's or the organisation's setting rather than
  the model's guess, so nothing here forecloses it; until then the person chooses each
  time, which is the safe default for something other people read.
- **Proof.** `Troupe.Tools.PublishArtifactTest`: a call with no visibility must ask and
  its request carries `publication`; one with a visibility is a plain ask; the allow with
  an answer publishes for the chosen audience and owner, says so, and the decision names
  them with `edited`; an allow naming nobody is refused and the request waits on;
  `allow_session` on it is an allow; a wrong shape and a delegation's keys are refused
  naming the publication; a publication's keys on another tool's request are refused
  naming the tool; a denial with a word back. The gateway's and the worker's artifacts
  tests pass `owner` through to the plane.
