---
number: 837
title: How a shell call's command ended is a field of its tool_call_completed, beside an ok that keeps its meaning, and the model reads the text it always did
date: 2026-10-10
status: accepted
issue: 248
paths:
  - apps/troupe_core/lib/troupe/tools/shell.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_core/lib/troupe/tools.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/log/fold.ex
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - apps/troupe_core/test/troupe/tools/shell_outcome_test.exs
  - apps/troupe_worker/test/troupe/worker/sandbox_test.exs
symbols:
  - Troupe.Tools.Shell.run/2
  - Troupe.Tools.execute/3
gist: "shell's tool_call_completed carries exit_status or timed_out: true beside ok; ok stays true for a command that ran; fields never reach the model"
---

#248's first slice. `shell` answered `{:ok, text}` whatever its command exited with, so its
`tool_call_completed` said `ok: true` for a failing `mix test` and the status survived
only as `[exit status N]` at the end of `content`: a blob once the output is large, and
text a reader has to parse. Memory derived from what a session ran (#248's Options 1 and
3) needs to fold a pass and a fail without reading `content`.

**The fields.** A `shell` call whose command exited records `exit_status` (an integer); one
its timeout killed records `timed_out: true` and no `exit_status`. Both are optional
fields of `tool_call_completed` in protocol v1, additive like every field added since.
Neither is written for any other tool, for an ACP delegate or an MCP server's tool, or
for a `shell` call that ran no command: missing arguments, a reaper that will not start
(Decision 733), a worker's sandbox that refuses (Decision 832), a denial. A call the
harness's own tool timeout ended, or a cancel, is `ok: false` as before and carries
neither, because the tool never answered.

**`ok` keeps its meaning.** `ok` says the tool ran, not that the command succeeded. Making
a non-zero exit `ok: false` would have changed what the model reads (the tool result's
error flag follows `ok`), counted every failing test run towards the failure guard
(Decision 687), which stops a turn after ten, and changed `ok` for one tool and not the
others. A reader that wants the command's verdict reads `exit_status`.

**The model reads what it always did.** `content` is unchanged, `[exit status N]` and the
timeout's line included, and the fields go only on the event: not into the
`tool_results` a replay rebuilds the conversation from, not into the request.

**How a tool says it.** A tool may answer `{:ok, content, %{fields: fields}}`;
`Troupe.Tools.execute/3` keeps `fields` in the result's `meta` apart from an inline
tool's `updates`, and the agent merges them into the event under the four fields every
call has, which they can never replace. Every other tool's answer is untouched.

**The fold.** `Troupe.Log.Fold`'s witness gives each call `exit_status` or `timed_out` only
when its event has one, as it adds `goal` only when there is one, so every recorded
fixture folds to the hash it had.

**Not here.** The commit a command ran against (#248 names it beside the status) is the
facts' `head`, which the fact writer reads when it writes (#248's later slices). A
person's own command (`user_shell`, Decision 813) already records `ended` and
`exit_status`.

Proof: `Troupe.Tools.ShellOutcomeTest` (a failing, a passing and a timed-out command, the
fold, the model's request byte for byte, and no fields on `read_file` or a `shell` call
with no command), `Troupe.Log.FoldTest`, `Troupe.MCPLocalTest`, and on a worker
`Troupe.Worker.SandboxTest`, in the sandbox as on a laptop.
