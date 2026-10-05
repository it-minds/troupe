---
number: 113
title: A first run is told the one next step, and plain `troupe` asks it before a session
date: 2026-09-25
status: accepted
issue: 76
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/paths.ex
  - apps/troupe_core/test/troupe/config/key_problem_test.exs
  - clients/tui/lib/troupe/ui/model_error.ex
  - clients/tui/test/troupe/config_setup_test.exs
gist: A first run is told the one next step, and plain `troupe` asks it before a session
---

On a fresh account every surface said `key=(none)` or `no key` and
stopped, and `troupe config` without a terminal showed a gateway example, never the
simplest case (issue #76, the slice for the 0.5.0 beta). `Troupe.Config.key_problem/1`
now says whether the default model can be asked at all: its provider's own key, the
vendor's variable at the vendor's own endpoint, the fake, or an OpenAI-compatible
server elsewhere, which may want none. The report (`troupe config`, `troupe models`,
`troupe-daemon config` and `models`) names the key it will use
(`key=(ANTHROPIC_API_KEY)`) and, with none, ends with the next step and
`provider: anthropic` with `api_key: "{env:ANTHROPIC_API_KEY}"` before the gateways:
`troupe config` through `troupe`, and the file through `troupe-daemon`, because an
install may have the daemon without the TUI; a headless run and the TUI's transcript
put the same step under the model error (`Troupe.UI.ModelError`); the desktop app has
its own for a local session. `troupe config` offers a provider here first,
Anthropic first, and Enter at the key saves that reference; a `config.yaml` through
which no model can be asked gets the report and then the choices; and plain `troupe`
asks them before it opens a session on a machine with no file and no key. Three more
things a first run met: `--auto-approve`, `--watch` and `--full-send` are sent only
when given, where all three went as `false` and a config file's values never reached
a TUI session; the project brief is refreshed automatically only for a session a
person opens, in a git repository, with a model to ask, because the librarian
surveyed whatever directory `troupe` was opened in, spent tokens beside every
headless run and, with no key, failed beside the first turn; and a daemon session's
window says `shared` or `worktree`, not `remote`. The paths those surfaces print use
the platform's separator (`Troupe.Paths.display/1`). Proof:
`test/troupe/config_setup_test.exs`, the CLI, memory and model tests, and
`apps/troupe_core/test/troupe/config/key_problem_test.exs`.
