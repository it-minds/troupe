---
number: 705
title: A first run's questions are one state machine in the harness, asked over the protocol, so both clients ask the same things and a run done in one is done in the other
date: 2026-09-27
status: accepted
issue: 76
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe/config/model_settings.ex
  - apps/troupe_core/lib/troupe/doctor.ex
  - apps/troupe_core/lib/troupe/setup.ex
  - apps/troupe_core/test/troupe/doctor_test.exs
  - apps/troupe_core/test/troupe/setup_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/lib/troupe/gateway/setup.ex
  - apps/troupe_gateway/test/troupe/gateway/setup_test.exs
  - apps/troupe_protocol/lib/troupe/protocol/schema.ex
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/views/Onboarding/FirstRun.tsx
  - clients/gui/apps/desktop/src/views/Onboarding/Setup.tsx
  - clients/gui/apps/desktop/src/views/Onboarding/hooks.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/test/launcher.test.tsx
  - clients/gui/apps/desktop/test/onboarding.test.tsx
  - clients/gui/packages/client/src/daemon.ts
  - clients/gui/packages/client/src/setup.ts
  - clients/gui/packages/client/test/support/daemon.ts
gist: A first run's questions are one state machine in the harness, asked over the protocol, so both clients ask the same things and a run done in one is…
---

Issue #76's second slice: a person with a fresh machine and one API
key reaches a first working session in the desktop app without opening the docs,
and the terminal client does not ask again. `Troupe.Setup` is the flow — `where`
(this machine or a plane), `provider` (Anthropic, OpenAI, a gateway or a LiteLLM
proxy by URL; or opencode's providers and a `config.yaml` that works, detected and
offered), `key` (pasted, or kept as `{env:VAR}`), `models`, `workspace` with the
approval model in two sentences, `finish` — and `Troupe.Gateway.Setup` holds one
in progress behind `setup.get` and `setup.answer`, the daemon's only, like
`config.*`. The choices that could have gone another way:
- **The key is checked with a real request before anything is written**: the
  provider's model listing, which every provider authenticates and which also
  fills the models step. A refused key keeps the step; a provider that answers
  but will not list (a gateway with no listing) is `unknown` and the person goes
  on and types a model id, since a working gateway is not a wrong key. Everything
  is written as late as the answer is complete — the settings at `models`,
  `auto_approve` at `workspace` — through `Troupe.Config.ModelSettings` and
  `Troupe.Config.write_key/3`, into the user's `config.yaml` and never a
  repository's `.troupe/`. The fake provider takes part (`ModelSettings` now
  accepts it), so a packaged build's first run is driven to a written file with
  no model behind it.
- **No keychain.** The daemon has no keychain module — the plane's refresh tokens
  are the plane's — so the key goes into `config.yaml`, readable by the user alone
  on Unix, and the flow says so (`key_storage`) rather than pretending. A keychain
  is a later slice.
- **Completion is a record in the state directory** (`<state>/setup.json`, beside
  `identity.json`), not a config key: the settings file is what was set up, and
  the record is that somebody finished, including a person who chose a plane and
  wrote no settings. `needed` is the absence of all three (the record, a
  `config.yaml`, a model that can be asked), which is what the desktop app asks
  before showing the questions and the terminal client asks before its own
  (`setup.get`; a daemon without the method still gets the old questions).
- **`finish` starts the first session on the daemon**, as `session.create` would
  under the caller, with a prompt suited to the directory — a repository is asked
  to explain itself — so the flow ends on a session and not on a settings screen.
- **`troupe doctor` is `Troupe.Doctor` in the harness**, printed by both programs:
  config, provider, key (the same live check), key storage, daemon, both binaries
  on the PATH, and every plane the caller knows of, one line each, `FAIL` making
  the exit status 1. It is not a session command, so it is not in
  `Troupe.Commands`.
- **Out of this slice:** the daemon at login (launchd, systemd, Task Scheduler),
  the full-screen terminal flow (`troupe setup`; `troupe config`'s questions
  stay), a plane pushing a recommended setup, and the keychain.
Proof: `apps/troupe_core/test/troupe/setup_test.exs` (every path, a refused and
an accepted key against a socket, the reference written for an environment key,
the suggestion), `doctor_test.exs`, `apps/troupe_gateway/test/troupe/gateway/setup_test.exs`
(over the socket to a session, the key never in an answer, a worker without the
methods), the desktop app's `test/onboarding.test.tsx`, and the terminal client's
`config_setup_test.exs` ("a first run done in the desktop app means no questions
here").
