---
number: 799
title: A model its provider does not serve has no window in `troupe models`, as text or JSON, whether a role names it or not, and the VS Code extension's Settings view shows a config that does not load as the errors `troupe config --explain --json` prints
date: 2026-10-06
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/models.ex
  - clients/vscode/src/run.ts
  - clients/vscode/src/settings.ts
  - clients/vscode/src/settingsView.ts
symbols:
  - Troupe.Config.describe/2
  - Troupe.Config.Models.json/2
  - settingsFailed
gist: "served: false means context null and no ctx in the text, role or not; models/1 and context_window/2 keep the fallback; config errors read from stdout"
---

Defects D70 (its fourth item) and D76, which chunk 20 left. Two reports said less than
the truth.

- **The model list.** `Config.models/1` gives every model the window `context_window/2`
  plans compaction against: what a file declares, else what the provider's list said,
  else `context_window` (200,000 by default, TUI Decision 17). For a model its provider
  has answered without, that last is a number nobody said, and `troupe models --json`
  printed it as `context: 200000` beside `served: false`; the text printed `200k ctx` for
  any such model no role named, since only a role's model read NOT SERVED (778).
- **The editor.** A config that does not load makes `troupe config --explain --json` exit
  1 with `{"errors": [...]}` on standard output and nothing on standard error (783 kept it
  so for a program). The Settings view read standard error only, and with nothing there
  showed Node's own message, `Command failed: <path> config --explain --json ...`.

What changed:

- **No window for a model nobody serves.** `Troupe.Config.Models.json/2` gives `context:
  null` to every model whose `served` is `false`, a role's or not, and whatever a file
  declares for it: a window describes a model a session can call, and this one fails a
  turn. A price the config gives it is still there (as 794 shows it: someone wrote it
  down). `served: null` (the provider has not answered) keeps the fallback, since that is
  what a session on it would plan against and nothing says it is not served.
- **The text says so for every model.** `describe/2` asks `Store.served/3` of each model,
  not only a role's. A role's model stays as 778 has it, loud, `NOT SERVED by openai; it
  serves ...` in place of window and price. Any other reads `not served by openai`, then
  its config price, where its facts came from and `no key`, as the extension's row does
  (794): the text is loud about what would fail a turn (783), and a model nobody chose
  does not, so it is said where its window was, without the five nearest ids on every
  such line.
- **Only what is reported.** `Config.models/1` and `context_window/2` are unchanged:
  compaction, `compact_threshold/2` and the TUI's model menu (`Troupe.Settings.choices/3`)
  read them, and a model with no window is what the fallback is for. The JSON and the
  text decide "not served" from the cache's record, which `models/1` does not read.
- **The extension reads what a failing `troupe` printed.** `run` moved from
  `settingsView.ts` to `run.ts`, which has no `vscode` import, so a unit test runs it
  against a fake `troupe`; a failure rejects with `Failed`, carrying standard output.
  `settingsFailed` turns `errors` there into a group, "The configuration did not load", one
  row an error, each as the Problems group shows a refusal (the message, `file:line`, a
  click opening the file at the line), with anything a key could be taken out of the
  message (794's helper). Any other failure, `{"errors": []}` and output that is not JSON
  among them, is the one line it was, from standard error. The Models group is still
  asked and says why it could not list them.
- **Older `troupe`s.** The extension's Models group already gave a not-served model no
  window (794), so it reads a `troupe` before this one and after it the same.

Not in this: the TUI's model menu still shows a not-served model's fallback window, since
it does not read the cache's record; the view does not ask again when a file only an error
names is saved (it does for the files a loaded config listed); `troupe-daemon models
--json` (D70's fourth bullet).

Proof: `Troupe.Config.ModelsTest`, against the stand-in gateway: a model not served, a
role's and a priced `house-model`, has `context: null` and keeps its price, a served one
its window, and before any answer the fallback stands; the JSON and the text agree, each
not-served model said so and with no `ctx`. Both failed on the chunk's tip with `"context"
=> 200000` and `house-model  200k ctx`. TUI `ModelsCLITest`: `troupe models` prints
`house-model  not served by openai, $0.50/$1.50 (models.prices), from your config`, and
`--json` gives it and `qwen3.5` `context: null` (failed on the tip with `200k ctx`). The
extension's unit tests run a fake `troupe` that prints `errors` and exits 1, through `run`:
the view shows the errors, a key in one taken out, and no "Command failed" (failed on the
tip's reading, moved unchanged, with `Command failed: C:\WINDOWS\system32\cmd.exe /d /s /c
...`); a failure with no errors to show is still one line from standard error; and the
Models group gives a not-served model with `context: null` the rows it gave one with the
fallback. The suite inside VS Code, its fake now printing a config's errors, shows them,
each opening its file at its line.
