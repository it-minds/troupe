# Recipe: per-tool permission rules

Without rules, a write, an edit, a shell command, a web fetch and an MCP server's tool ask
before they run, and you answer each one: allow it, allow that tool for the rest of the
session, or deny it. Rules answer in advance. Each names a tool, optionally with a pattern,
and says `deny`, `ask` or `allow`. It is loaded by a test, like every recipe here.

This one is the user file, `<config>/config.yaml` ([where that is](files.md)). A
repository's `.troupe/config.yaml` and `.troupe/config.local.yaml` take the same block, and
so does an organisation's file.

<!-- recipe: permissions -->
```yaml title="config.yaml"
version: 1
provider: anthropic
api_key: "{env:ANTHROPIC_API_KEY}"

permissions:
  # Refused outright, with a sentence naming the rule and this file.
  deny:
    - "shell(git push)"            # git push, git push origin main; not git pushx
    - "shell(rm -rf)"
    - "read_file(secrets/**)"      # a path under the workspace
    - "read_file(~/.ssh/**)"       # or anywhere, written in full or from ~
    - "mcp(github.delete_*)"       # an MCP server's tools: server.tool, * a wildcard
  # Asked about every time, even with auto_approve on or an earlier "allow for the session".
  ask:
    - "mcp(tracker)"               # every tool of the server called tracker
    - "edit_file(**/*.lock)"
  # Run without asking.
  allow:
    - "shell(mix test)"
    - "shell(git status)"
    - "shell(git diff)"
    - "write_file(lib/**)"
    - "edit_file(lib/**)"
```

**What a pattern is.** For `shell`, the start of a command: `shell(mix test)` matches
`mix test` and `mix test --failed`, not `mix testing`; `shell(git push*)` matches the
characters, so `git pushx` too. For the file tools (`read_file`, `write_file`, `edit_file`,
`list_files`, `grep`, `glob`, `git_read`), a path: relative to the workspace unless it starts
with `/`, a drive or `~`; `*` is any name, `**` any number of directories, and a path with
neither is that path and everything under it. For `mcp`, `server.tool`, or a server's name
alone for all its tools. Any other tool is named alone. A malformed rule refuses the file,
saying what to write instead: `Bash(npm test)` is `shell(npm test)` here.

**A shell line is the commands it runs.** `mix test && git push` is two commands: the `deny`
above refuses it, and an `allow` covers a line only when it covers every command in it.
A line that runs another command's output in it, `$(...)` or backticks, is never covered by
an `allow`, since what it will run cannot be read in advance; it asks as before. A rule is
not a sandbox: a script, `sh -c '...'` or an alias runs what the rule never sees.

**Which rule holds.** Every file's rules are added together; none replaces another's. Of the
rules that match a call, `deny` beats `ask` beats `allow`, whatever file each is in, so a
repository cannot loosen your rules and you cannot loosen your organisation's. Inside one
file the more specific rule decides, which is how a file says "deny shell, but allow git
status": a rule with a pattern is more specific than the tool alone, and the longer of two
patterns more specific than the shorter.

**What each does.** A `deny` refuses the call before it runs and tells the model the rule
and its file. An `ask` asks you, and the question says which rule asked. An `allow` runs a
call that would have asked, except one that must always ask (a write into your config
directory) and every call in a branch an `AI!` comment started, unless
`watch_auto_approve` is on. With `approvals: deny` an allowed call runs, as one an agent
marks `auto` does, and every other call that asks is refused.

**Where a repository's rules apply.** Its `deny` and `ask` apply everywhere; its `allow`
only once you trust the workspace (`troupe config trust`), as with every setting that lets
something run unasked, and never on a pod. With `managed_permission_rules_only` on, only
your organisation's `allow` rules apply.

**On a team's pods.** A session on a plane's pods also obeys the rules of the worker
profile it runs on, which a platform administrator sets
([profiles](../../admin/profiles-and-policy.md#per-tool-rules-on-a-profile)). They are a
scope of their own and the same rule holds: the strictest wins, so nothing in a repository
loosens them. A call one refuses or asks about names "the worker profile" and its name, in
the transcript and on the approval. A `deny` for `shell` there refuses a command you type
with `!` too.

`troupe config --explain` lists every rule in force on this machine, with its file, and
those held back with why; `troupe config --explain permissions` lists only them. The
terminal UI's `/settings` and the desktop app's settings show them too. A pod's profile
rules are not among them: they are the session's on the pod, and the console's profile
page lists them.
