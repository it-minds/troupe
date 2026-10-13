# Recipe: an unattended session

A session nobody is watching, on a build machine or started by a script with `troupe run
... --headless`, has nobody to ask. Left as they are, a tool call that asks waits for
somebody to answer it, and a spent budget asks whether to go on. This file has such a
session told no instead, held to a budget, and stopped when the budget is spent. It is
loaded by a test, like every recipe here.

It is the user file of the machine the session runs on, `<config>/config.yaml`
([where that is](files.md)); a repository's `.troupe/config.yaml` may carry the budget
lines, and the approval lines once the workspace is trusted.

<!-- recipe: unattended -->
```yaml title="config.yaml"
version: 1
provider: anthropic
api_key: "{env:ANTHROPIC_API_KEY}"
models:
  default: claude-sonnet-5
  cheap: claude-haiku-4-5

# Nobody is attached: a call that would ask is denied, and the model is told so.
approvals: deny
# And nothing runs without asking either: writes, edits and commands are the ones that
# ask, so with the line above they are refused. Turn this on only in a directory whose
# changes you can afford to throw away.
auto_approve: false

# What one session may spend, each a limit that stops it.
max_turns: 30                  # model calls
wall_clock_ms: 900000          # fifteen minutes
max_input_tokens: 1000000
max_output_tokens: 100000
max_depth: 1                   # the root agent may delegate, its children may not
# A spent budget stops the session rather than asking whether to go on.
budget_asks: false
# No warnings as a limit nears: nobody is there to read them.
full_send: true
```

`approvals: deny` with `auto_approve: false` is a session that reads and answers and
changes nothing. One that should change files, in a throwaway checkout, sets
`auto_approve: true` and keeps the limits. An organisation can hold every machine to
`approvals: deny` and to ceilings on `max_turns`, `wall_clock_ms` and `max_depth`
([its defaults and limits](../configuration.md#your-organisations-defaults-and-limits)).
