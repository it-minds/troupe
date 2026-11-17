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
