---
number: 821
title: "`troupe doctor --bench` runs the offline bench's scenarios in `troupe` itself after the checks, a line each and one for the whole, holds them to the bench's own verdict, and `--json` is the same as one object"
date: 2026-10-09
status: accepted
issue: 390
paths:
  - apps/troupe_core/lib/troupe/doctor.ex
  - apps/troupe_core/test/troupe/doctor_test.exs
  - clients/tui/lib/troupe/cli/doctor.ex
  - clients/tui/test/troupe/doctor_test.exs
symbols:
  - Troupe.Doctor.bench/1
  - Troupe.Doctor.json/2
  - Troupe.CLI.Doctor.run/2
gist: "doctor --bench runs the offline bench's own scenarios here against the scripted model, judged as troupe bench judges them; never a provider"
---

Issue #390's last item, `troupe doctor --bench`, as the offline half: whether this install
gets a session through the harness end to end, said in a few lines, with no provider, key
or network. The live bench (Decisions 773 and 775) is unchanged, and running it in the
nightly is still open.

- **The offline bench's scenarios, not a second set.** `Troupe.Doctor.bench/1` runs
  `Troupe.Bench.run/1`, the five scenarios `troupe bench` and CI run (Decision 772): a turn
  of thirty tool calls, a tool result over the limit cut and read back with
  `read_output`, a compaction, a cancel during a model call, and the log replayed and the
  session resumed. Between them they go through the file tools, `grep` (ripgrep through
  the reaper when it is on the `PATH`), the blob store behind `read_output`, the
  summariser, a cancelled call's task, the log on disk and a resume: what a broken install
  breaks. A scenario of the doctor's own would be a second suite to keep in step with the
  first, and one CI does not hold to anything.
- **Lines, in doctor's shape.** After the checks, one line a scenario, `bench <name>`:
  `ok` with the scenario's title, or `FAIL` with the title and what did not hold, each
  in words: why it did not run, a measure with its value over its budget, a check's label,
  the outcome. Then `bench`: `5 of 5 passed in 4.2 s, offline: ...`, or how many failed
  and which. The checks print before the bench starts, so they are read while it runs.
  Any `FAIL` makes the exit 1, doctor's rule (Decision 705). A bench that does not start
  at all (its directories not made) is one `bench` line saying why, not a crash.
- **The bench's verdict, budgets included.** A scenario passes when `troupe bench` says it
  does. Its budgets are compiled into the binary and the bench keeps the person's
  configuration out of the prompt, so a build CI passed holds them on any machine; one
  that does not is a harness behaving differently here than it did in CI, which is what a
  doctor is for. Making a measure past its budget a warning instead was the other choice:
  but the cancel scenario's budgets (no call after a cancel, no task left running) are
  correctness, not cost, and a warning there would pass an install whose cancel leaks.
- **Offline, never the person's provider.** Issue #390 first drew `troupe doctor --bench`
  as one small task against the person's own provider, saying what a turn costs there.
  That answer is `troupe bench --live` now: it prints the most it can spend and asks
  first (Decision 773, TUI Decision 141). A doctor must cost nothing and never ask, and
  whether the provider answers and accepts the key is already the checks' `key` and
  `model` lines. So the bench here runs against the scripted model (`Troupe.Bench.Model`)
  and needs no provider, key or network: `troupe doctor --bench` on a machine with nothing
  set up still says whether the harness works, beside a `provider` line that fails.
- **Where it runs: in `troupe`, as `troupe bench` does (TUI Decision 140).** The harness
  compiled into the binary, in its VM, with its environment (`PATH`, temporary directory,
  the reaper): what runs a person's sessions when no daemon answers, since `troupe` then
  embeds one. A daemon that does answer is another process, maybe another version, and the
  bench cannot drive it: the scripted model is a process in this VM, and a client cannot
  choose a session's provider (the daemon takes three settings from a client, none of them
  that). Its own line says whether one answers. A bench run by the daemon would be a
  method of the protocol; not built.
- **It leaves nothing.** The bench's directories are under a new temporary one, removed
  afterwards; its sessions are stopped as each scenario ends; while they run,
  `TROUPE_CONFIG_HOME` and `TROUPE_STATE_HOME` name the bench's own directories. Of the
  person's, nothing is written beyond what `troupe bench` writes: the installed `troupe`
  logs, into `troupe.log` in their state directory, one warning a scenario that the
  scripted model has no price.
- **`--json`.** The same as one object: `passed`, `checks` (each line's `name`, `state`
  and `detail`), and with `--bench`, `bench`: `passed`, `seconds`, `scenarios`, and
  `failed`, each thing that failed as `troupe bench`'s verdict names it
  (`scenario/measure`). `--json` without `--bench` is the checks alone: the switch was
  already parsed there, and ignored.
- **How long.** The time is on the `bench` line. The suite takes a few seconds, about one
  in the installed build on Windows; a step that never finishes fails after the runner's
  wait of a minute (`Troupe.Bench.Runner`).
- **Not here.** `troupe-daemon doctor` has no `--bench`: `Troupe.Doctor.bench/1` is the
  harness's, and the daemon's command line is a change of its own. None of the five
  scenarios calls the `shell` tool, so a `PATH` without a shell passes the bench; a shell
  step belongs in the offline suite, where CI holds it too, not in the doctor alone.
- **Proof:** `Troupe.DoctorTest` ("the bench"): a line a scenario and one for the whole,
  the scratch directories untouched; a measure over a lowered budget and one nobody takes,
  each a `FAIL` naming it, and the bench's `failed`; `json/2` with and without the bench.
  The TUI's `doctor_test.exs`: `troupe doctor --bench` parses, which failed on the chunk's
  tip with `unknown option: --bench`; the checks and then the five lines and the whole,
  exit 0, the person's config and state directories as they were and no bench directory
  left; a lowered budget a `FAIL` line and exit 1; `--json` as one object. And the
  installed `troupe doctor --bench`, on the pull request: with nothing set up (the
  `provider` line fails, the bench passes), with the fake provider, and with a broken
  `rg` first on the `PATH`, where `cut_output` fails and says what did not hold.
