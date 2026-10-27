---
number: 960
title: "An organisation says, in its own words, where a person gets a key for local sessions, and may choose to hand one key to everybody who signs in; the clients show the word wherever a key is asked for, and troupe config key pastes one"
date: 2026-10-27
status: accepted
supersedes: [675]
paths:
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/test/troupe/plane/client_defaults_test.exs
  - apps/troupe_core/lib/troupe/config/org.ex
  - apps/troupe_core/lib/troupe/config/model_settings.ex
  - apps/troupe_core/test/troupe/config/org_test.exs
  - clients/tui/lib/troupe/cli/config_setup.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/test/troupe/config_setup_test.exs
  - clients/gui/packages/client/src/config.ts
  - clients/gui/packages/client/test/config.test.ts
  - clients/gui/apps/desktop/src/views/Models.tsx
  - clients/gui/apps/console/src/views/Organisation.tsx
  - docs/admin/client-config.md
  - PROTOCOL.md
symbols:
  - Troupe.Config.Org.key_help/0
  - Troupe.CLI.ConfigSetup.key/2
gist: "client_key_help (words, shown beside every key field) and client_key (secret, optional: one key for everybody, in the document's defaults below the user file); api_key_source organisation"
---

An organisation enforces a configuration for local sessions and gives people defaults
(Decision 869), but the one thing the defaults could not bring was the key, and nothing
told a person where to get one: Decision 675 ruled that the plane never hands out a key,
since anybody signed in could read it, and left each person to find their own. IT Minds
mints keys at its own gateway and wanted to point people there; another organisation
would rather say "open a ticket at the helpdesk"; a third does not care about personal
keys and would hand everybody the same one. Troupe is built for all three.

- **Two settings** in the *Organisation* group. `client_key_help` is the organisation's
  word on where a key comes from, a URL or a sentence, carried in `me.client_defaults` as
  `key_help`, beside the document rather than in it: a document holds only what a config
  file takes. `client_key` is a secret, empty unless an administrator chooses it, and
  then goes in the document's `defaults` as `api_key`. That is the half of 675 this
  undoes, knowingly: the setting's own consequence says that whoever can sign in can
  read it, that it is one key with one bill, and that a key a person pasted themselves
  still wins, since the defaults sit below the user file. The settings list never shows
  the value (`set` says whether there is one), the console previews it as "set (new)",
  and the plane signs the answer as it signs the rest.
- **The daemon** keeps `key_help` in its copy of the document (`organisation.json`) and
  writes that copy readable by the owner alone, since it may now hold a key.
  `config.get` carries `key_help`, and `api_key_source` says `organisation` where the key
  in force is the document's: the environment and the person's file still come first.
- **Where a key is asked for.** `troupe config` says the organisation's word before it
  asks anything; `troupe config key` says it, then whether the organisation's key is in
  use, then takes a key or `{env:VAR}` without echo and writes it alone into the person's
  file (`config.set` with `key: api_key`), naming an unset variable; after `troupe config`
  pulls a plane's settings it asks for the key there and then, where there is a terminal
  and no key is in force. The desktop app's Models panel shows the word beside the key
  field, an address as a link, says when the key in force is the organisation's and that
  one pasted wins, and says so when *Use my organisation* fills in from a plane that hands
  one out.
- **Not done.** The first run's key step asks before any plane is signed in, so it has no
  word to show; the daemon's own copy of the document is what `troupe config` reads, so a
  machine that has never pulled says nothing. The browser build and the TUI's settings
  page are unchanged.
- **Proof.** `client_defaults_test` (no key and no word by default; the word in the
  answer; the stored key in `defaults`, cleared with the setting, never in the settings
  list). `org_test` (the key a default below the person's file, the copy `0600`, the word
  kept and reported by `ModelSettings.describe/1` as `key_help` with `api_key_source`
  `organisation`, gone with the next pull). `config_setup_test` (`troupe config key` says
  the word, saves what is pasted alone, names an unset variable; the organisation's key in
  use is said and Enter changes nothing; no terminal says where to put one; a plane's
  settings pulled are followed by the key prompt, and by none where the plane hands one
  out). `config.test.ts` (the word trimmed, an address told from a sentence, whether a key
  is handed out, the form never taking it). `organisation.test.tsx` (a secret setting
  shown as set or unset, edited behind a password field, previewed without the value).
