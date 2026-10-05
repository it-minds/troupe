---
number: 711
title: A setting saved from a client changes its own line of `config.yaml` and nothing else; the file is edited, not rewritten
date: 2026-09-27
status: accepted
issue: 223
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/migrate.ex
  - apps/troupe_core/lib/troupe/config/yaml.ex
  - apps/troupe_core/test/troupe/agent/budget_question_test.exs
  - apps/troupe_core/test/troupe/config/explain_test.exs
  - apps/troupe_core/test/troupe/config/model_settings_test.exs
  - apps/troupe_core/test/troupe/config/write_key_test.exs
  - apps/troupe_core/test/troupe/config/yaml_test.exs
  - clients/tui/test/troupe/settings_test.exs
gist: A setting saved from a client changes its own line of `config.yaml` and nothing else; the file is edited, not rewritten
---

Issue #223 (defects D28), amending 675,
686 and 699, which each wrote a file by rendering its map again, so the first model
picked in the desktop app, the first value changed on the terminal UI's settings
page or the first budget raised for a workspace turned a hand-written, commented
file into a machine-written one.
- **One edit, in `Troupe.Config.Yaml`.** `edit/2` makes a file's text read as a new
  map key by key: a changed scalar takes the old value's place on its key's line,
  which keeps the key as it is spelled and the comment after it; a key that is not
  there is added after the last key of its map, a missing parent with it; a key
  that is gone goes with the lines beneath it; a map written one key a line is
  edited key by key, and any other map or list that changes is written out again
  under its key. `put/3` sets one key, nested or not, through it. A string goes bare
  when YAML reads it back as the same string, and would under YAML 1.1 too, and in
  double quotes when it needs them or was quoted before. The answer is read back
  and must be exactly the map asked for, as with `edit_list/4` (686), which stays
  what `troupe config trust` uses.
- **Every writer gets it through `Migrate.write/2`.** The terminal UI's settings
  page, `config.set` (the desktop app's model settings, and a first run's), a
  budget answer for the workspace (`Config.write_key/3`), `config.import` and a first
  run's approvals all write through it, so none of them changed. A file that is
  there is edited; a new file, or one the edit cannot follow — a value an alias
  shares, a key written twice, a document in braces — is written whole as before,
  with `version: 1` and the header, whose words no longer say comments are lost. The
  file before the save is kept as `.previous` either way.
- **The keys a writer sets are written in the new spellings; the others are the
  file's.** 686 had every writer write the new spellings only, which a whole-file
  write did for every key in it. An edit writes what the writer brings by its new
  name and removes that setting's old spellings, and leaves an old spelling of a
  setting it did not touch as it is, with its load warning, for `troupe config
  migrate --write`, the one rewrite, which is asked for and shows its diff first.
  An edited file gets no `version` line it did not have: a missing one reads as 1.
- **Not done:** `troupe config migrate --write` still renders the file, since a
  migration moves keys between blocks; and a string with a space or a letter
  outside ASCII is quoted, though YAML would take some of them bare.
- **Proof:** `Troupe.Config.YamlTest` (one key written is one line changed, nested,
  added under its parent and with a missing parent, quoting, a key with only a
  comment, a map in braces, line endings and a byte order mark, a key of the same
  name elsewhere, removal with the lines beneath, `{}` and new maps and lists);
  `Troupe.Config.WriteKeyTest`, `Troupe.Config.ModelSettingsTest` and the terminal
  UI's `Troupe.SettingsTest`, each keeping a comment and changing one line;
  `Troupe.Agent.BudgetQuestionTest`'s workspace answer; `Troupe.Config.ExplainTest`
  for a new file and an edited one; and `config.set` over the installed daemon's
  socket on a commented file, the diff that one line.
