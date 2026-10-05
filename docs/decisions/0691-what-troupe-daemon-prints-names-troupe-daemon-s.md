---
number: 691
title: What `troupe-daemon` prints names `troupe-daemon`'s commands, in ASCII, with paths as Windows writes them
date: 2026-09-26
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/paths.ex
  - apps/troupe_core/test/troupe/config/explain_test.exs
  - apps/troupe_core/test/troupe/config/trust_test.exs
  - apps/troupe_core/test/troupe/paths_test.exs
  - apps/troupe_daemon/test/troupe/daemon/cli_test.exs
  - apps/troupe_gateway/test/troupe/gateway/autospawn_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/daemon.ex
  - apps/troupe_worker/test/troupe/worker/unrestorable_test.exs
gist: What `troupe-daemon` prints names `troupe-daemon`'s commands, in ASCII, with paths as Windows writes them
---

D20 in docs/developer/defects.md. What loading warns about
is written once, naming `troupe config migrate` and `troupe config trust`, and both
programs print it. `config --explain`, `validate`, `migrate`, `trust` and `untrust`
now take `command:`, as `Config.describe/2` has since #153, and
`Troupe.Config.as_run_by/2` names the program printing. The text is rewritten where
it is printed rather than where it is written, because the loader does not know who
will print it, and the same warnings reach a session's clients; a migration's diff
is a file's own text and is left alone. The masked key and the model report's
separators are ASCII (`sk-a...op`, commas), because the Windows console shows
anything else as stray characters. `Troupe.Paths.display/1` also gives a drive
letter the case Windows shows (`File.cwd!/0` says `c:/`), and is used for every path
a config report prints, an issue's file included; what is stored, and the JSON,
keep the path as loaded. `troupe-daemon status` says where the sessions are kept,
which is what the TUI's help sends a person to it for. `Troupe.Protocol.Daemon`
starts a daemon on Windows with `start "" /b` through `cmd /s /c`: `start` read a
program's quoted path, which one in a directory with a space has to be, as a window
title, and started nothing. A worker's activation error that is an exception is
its message. Proof: `Troupe.Daemon.CLITest`, `Troupe.Config.ExplainTest` and
`TrustTest`, `Troupe.PathsTest`, `Troupe.Gateway.AutospawnTest`,
`Troupe.Worker.UnrestorableTest`, and the installed build on this machine.
