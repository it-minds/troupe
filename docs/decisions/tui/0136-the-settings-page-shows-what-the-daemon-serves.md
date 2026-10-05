---
number: 136
title: "The settings page shows what the daemon serves and writes the scope it names: the file the value on screen came from, else the user's own, and `s` picks another"
date: 2026-10-04
status: accepted
issue: 57
paths:
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/settings.ex
  - clients/tui/test/troupe/daemon_client_test.exs
  - clients/tui/test/troupe/phase3_client_test.exs
  - clients/tui/test/troupe/shared_settings_test.exs
gist: "The settings page shows what the daemon serves and writes the scope it names: the file the value on screen came from, else the user's own, and `s`…"
---

Issue #57, root Decision 761; amends 41, whose page wrote the project's file when the
project had one and the user's otherwise, a guess the page made from paths it worked
out itself, and read the values from a config it resolved in this process.
- **What a setting is, is the daemon's.** The page reads `config.get` for the
  session's workspace (`Client.settings/1`): each value, and the layer and file that
  set it, which the row shows beside a value that is not a default and the help names
  (`set by: project (…/.troupe/config.yaml)`). The config struct is still read, for the
  models the menu offers, and for the values when the daemon answering is from before
  #57 and says no keys; such a daemon is not asked to set one, since it would read the
  call as the desktop app's model panel and write a provider.
- **Where a change goes is named.** `Client.put_setting/4` is `config.set` of one key
  with a scope. The scope is the one picked with `s`, which steps through the scopes
  the daemon says the key may be written to here; else the layer the value on screen
  came from, when it is a file the key may be written to, so a change takes effect
  where it was made; else the user's own file, for a default or a value from the
  environment. The title says which, with its file, before Enter is pressed, and the
  status after it says where it went and what still wins over it there. The daemon
  refuses what a file may not hold (`auto_approve` in an untrusted workspace's file),
  and the page shows its reason; it no longer moves such a key to the user's file by
  itself.
- **The page follows other clients.** The link to the daemon hands every
  `config.changed` to whoever listens (`Client.subscribe_settings/0`), and an open page
  reads the settings again with nothing pressed, its cursor, a value being typed and
  the scope picked kept.
- **One key table.** `Troupe.Settings` is the schema's settings (root 761), less the
  `ui` keys, which only the desktop app acts on: the labels and help are the schema's,
  the order is the reference's, so the page now opens on the model. `watch` is still
  the one that applies at once.
- **Proof:** `test/troupe/shared_settings_test.exs` (a model the desktop app saves
  shows on the open page; one picked on the page reaches a second protocol client's
  `config.get` and its `config.changed`), both failing on the chunk's tip;
  `settings_test.exs` (the page's keys are the schema's, where a change goes, the page
  showing each value's layer, `s` writing the local file), `daemon_client_test.exs`
  and `phase3_client_test.exs`; and the installed build on scratch homes, on the pull
  request.
