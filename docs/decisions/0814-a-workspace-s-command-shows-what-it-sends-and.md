---
number: 814
title: "A command a file defines shows the prompt it sends in both palettes, and a workspace's asks once before it is first sent while `auto_approve` is on, its prompt in view"
date: 2026-10-08
status: accepted
issue: 371
paths:
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_core/lib/troupe/commands/trust.ex
  - apps/troupe_core/lib/troupe/session/approvals.ex
  - apps/troupe_core/lib/troupe/session/questions.ex
  - apps/troupe_core/test/troupe/commands_test.exs
  - apps/troupe_core/test/troupe/commands/run_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/commands_list_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/test/troupe/command_palette_test.exs
  - clients/tui/test/troupe/project_command_test.exs
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
  - clients/gui/apps/desktop/src/views/Question.tsx
  - clients/gui/apps/desktop/test/command-palette.test.tsx
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/packages/client/test/support/daemon.ts
symbols:
  - Troupe.Commands.run/4
  - Troupe.Commands.Trust
  - Troupe.Session.Approvals.auto_approve?/1
gist: "A defined command's row carries its prompt as `body`; a workspace's asks once per command and prompt hash while auto_approve is on; answers in <state>, never the repo."
---

Issue #371, found while building 763. A repository's `.troupe/commands/review.md`
appeared in both palettes with its frontmatter's `description` and its path, and running
it sent its body. So an innocently described `/review` could ask for anything, and with
`auto_approve` on nothing stood between running it and the agent doing it. The
maintainer chose both of the issue's options.

- **The prompt is in the row.** A command a file defines, the user's or the workspace's,
  carries `body` in `commands.list`: the prompt as its file has it, `$ARGUMENTS` and all.
  Only these rows carry it, so the built-ins' shape is unchanged and an older client
  ignores it. The whole prompt rather than its head, because what a palette shows should
  be the thing that is sent, and how much of it fits is the client's to judge: the
  terminal client's detail pane ends with `sends:` and as many lines as its room allows,
  then `… N more lines in the file`; the desktop app's shows eight and counts the rest.
  A person's own commands show it too: it costs nothing, and a client need not tell the
  two layers apart to draw the pane.
- **A workspace's command asks once while `auto_approve` is on** (`Troupe.Commands.run/4`,
  which `commands.run` calls). With `auto_approve` off every tool call the prompt leads to
  asks anyway, so nothing more is asked; with it on, the first run of a `project` command
  asks before anything is sent, the way a workspace's MCP servers ask before they start
  (700): a `question_asked` on the session's question path, so any client answers it,
  with the options `deny`, `once` and `allow`, `deny` first so a client that answers with
  the first option (the terminal client's headless mode) sends nothing. The question is
  one sentence, because the terminal client draws a question on one line, and the prompt
  as it would be sent, arguments in, rides beside it as `preview`, a new optional field of
  `question_asked` that both clients draw as it is under the question. `commands.run`
  answers at once with `question` naming the call; the prompt is sent when the answer
  comes, from a task of its own.
- **Keyed on the checkout, the command and its prompt.** `allow` is remembered in
  `<state>/command-trust.json` (`Troupe.Commands.Trust`), under the checkout's key as
  `Troupe.MCP.Trust` files it (a worktree shares its checkout's answers), as command name
  to a sha256 of the file's body. So an edited command is another prompt and asks again,
  and what is typed after the name, or a re-ordered directory, does not. Per command
  rather than once per workspace: a yes to `/review`'s prompt says nothing about
  `/deploy`'s, and the point is that what was seen is what was agreed to. The answers
  live in the state directory, never in the repository: a file the repository carried
  would be the repository approving itself. A file of its own beside `mcp-trust.json`
  rather than inside it, since that file maps server names to fingerprints and a command
  of the same name would collide with one.
- **`once` sends it this time and remembers nothing.** Any other answer, free text
  included, sends nothing and writes `command_declined` (`name`, `reason`, `command_id`),
  a new durable event whose `reason` says it was not sent and how to run it later: run it
  again to be asked again, and `allow` stops the asking until the file changes. A session
  nobody can answer in (`approvals: deny`) declines on the spot and says so, with how it
  would run: where somebody can answer, or with `auto_approve` off. A session that stops
  while the question is out sends nothing, and running the command again asks again.
- **Who is not asked.** A person's own commands, since the person wrote them, and a
  workspace on `trusted_workspaces`, as 700 does for MCP servers: trusting it already lets
  its `config.yaml` turn `auto_approve` on and name commands to run, so a question about a
  prompt would guard nothing the trust has not already given. The question is about
  `auto_approve` as the session holds it now (`Approvals.auto_approve?/1`), so a client's
  `--auto-approve` counts as a config file's does.
- **What this does not undo.** 763 stands: a workspace's commands are read and listed
  whether or not it is trusted, no built-in is shadowed, and no frontmatter changes tools,
  models or approvals. This is not a trust gate on reading a command; it is the one
  question asked when nothing else would ask before its prompt is acted on.
- **Proof:** `Troupe.CommandsTest` (a defined command's row carries its body; a
  built-in's has none: failed on the tip), `Troupe.Gateway.CommandsListTest` over a socket
  in a workspace nobody trusted (the first `/review` answers with `question`, asks with
  the prompt as `preview` and sends nothing until `allow`, and the second run does not
  ask: failed on the tip; an edited file asks again and `deny` writes `command_declined`),
  `Troupe.Commands.RunTest` (`once`, `allow` remembered and kept outside the repository,
  `deny`, an unattended session, a person's command, `auto_approve` off and a trusted
  workspace sending unasked, the store per checkout and command), the TUI's
  `Troupe.CommandPaletteTest` (the body in the detail, and a long one's first lines and
  count) and `Troupe.ProjectCommandTest` (against the daemon: the question in the window
  with the prompt under it, `allow` sends and is not asked again, an edit asks again and
  `deny` says it was not sent), and the desktop app's `command-palette.test.tsx` (the
  detail's body and count; the question panel with the prompt, `allow` and `deny`) and
  `transcript.test.ts` (`preview` kept, `command_declined` said).
