---
number: 150
title: "`troupe --prompt TEXT` opens the TUI with TEXT on its command line and the cursor after it, nothing sent until Enter; only the TUI mode reads it"
date: 2026-10-07
status: accepted
issue: 378
paths:
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/test/troupe/cli_test.exs
symbols:
  - Troupe.CLI.Runner.window_opts/1
gist: "--prompt fills the command line at mount, cursor at its end, focus there; nothing is sent, and no other mode reads it"
---

Issue #378, root Decision 808. The VS Code extension's "Ask Troupe About This File" puts the
file's path in the TUI's prompt, and Decision 765 found no way into the prompt from outside.

- **A flag, not the protocol.** The text is the person's own, typed nowhere yet, so it
  never needs to reach the daemon: `troupe --prompt TEXT` hands it to the window this VM
  opens, and the session is created as for a bare `troupe`. The command line, the input
  whose line goes to the session's agent, opens holding TEXT exactly as given (a newline
  included: the box holds multi-line text), the cursor after its last grapheme, the focus
  on it. Enter sends it as it sends anything typed there; Esc empties it.
- **The TUI mode only.** `--prompt` is parsed for every mode, as every switch is, and only
  `troupe` itself (with `--workspace` or not) reads it: `run` has its task, and a report
  has no input. With `--remote`, HQ is in front and the text waits on the command line
  behind it.
- **`Runner.window_opts/1`.** What the runner hands the window (HQ's page, the prompt, the
  mouse) is one public function, so the suite opens a TUI with what the runner would.
- **A crash's restart** mounts the window again with the same options, so it opens with
  the text again; nothing is sent either way.
- **Proof:** `cli_test.exs`: `--prompt` with `--workspace` opens a TUI on the session with
  the text (a quoted path with a space) on its command line and the cursor after it, what
  is typed next goes after it, and the session has no input. On the chunk's tip it failed
  with `unknown option: --prompt`. `cli_reference_test.exs` holds the new row to the parser
  and the help. The installed `troupe.exe` opened by the extension with `--prompt` showed
  the path in its input.
