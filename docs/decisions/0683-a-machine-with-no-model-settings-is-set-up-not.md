---
number: 683
title: A machine with no model settings is set up, not reported on, and opencode's can be copied
date: 2026-09-25
status: accepted
paths:
  - apps/troupe_core/lib/troupe/config/model_settings.ex
  - apps/troupe_core/lib/troupe/config/open_code.ex
  - apps/troupe_core/test/troupe/config/model_settings_test.exs
  - apps/troupe_gateway/test/troupe/gateway/model_settings_test.exs
  - clients/tui/test/troupe/config_setup_test.exs
  - install.ps1
  - install.sh
gist: A machine with no model settings is set up, not reported on, and opencode's can be copied
---

An install ended with a daemon and a client that could not reach a
model, and `troupe config` then reported the defaults: `anthropic`,
`claude-sonnet-5`, no key. Troupe already reads opencode's providers while it has
none of its own (`Troupe.Config.OpenCode`), but only for as long as opencode's file
says so, and nothing said that it was happening.
- **`config.import`** (`admin`, the daemon's only), with `from: "opencode"`, copies
  opencode's providers into the `providers:` block of `config.yaml`: type, base URL,
  auth style, models, and each key as opencode has it written. An `{env:VAR}` stays a
  reference, and a literal key is copied, which the person asking for the copy
  asked for. That is the one exception to `OpenCode`'s "never written anywhere".
  Providers the file already names are kept, and opencode's default model is taken
  only when the file has none. `troupe-daemon config import-opencode` is the same
  write for the installers, which have a daemon but may have no client.
  `ModelSettings.describe/1` now counts a keyed `providers:` entry as the file's key,
  and reports the opencode fallback only for providers the file does not shadow.
- **`troupe config`** with no file and no `TROUPE_*` provider asks, in a terminal:
  copy opencode's config if it is there. Otherwise it offers a plane's settings
  (`login`, then `config pull`), a provider set up here (`config.models`, then
  `config.set`), or not now. Without a terminal it prints those choices
  (clients/tui Decision 111).
- **The installers** end with the same check. An existing `config.yaml` is named.
  opencode's config is offered for the copy. Otherwise, with the TUI installed, the
  installer hands over to `troupe config`, or names the ways on when it cannot;
  without it, the next step is the desktop app's Models panel where the app is
  installed, or the file, since only the TUI has `troupe config`. A
  daemon from before `import-opencode` answers "unknown arguments", and the
  installer says it could not copy and goes on.
- **Proof:**
  - `Troupe.Config.ModelSettingsTest` "import_opencode/1": the copy loads back to
    the same providers, and a reference stays one.
  - `Troupe.Gateway.ModelSettingsTest`: `config.import` over the socket, and a
    source other than opencode refused.
  - `Troupe.ConfigSetupTest`.
  - `scripts/dev config` and `install.sh`, the latter against a daemon built from
    this branch, driven through a pseudo-terminal in a scratch home.
  - `install.ps1`'s fallback against `v0.3.3-pre.1`.
- **Not tested:** the TUI's terminal detection and unechoed key prompt on Windows.
