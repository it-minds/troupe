---
number: 761
title: "The desktop app and the terminal UI share one set of settings: `config.yaml` at the ladder's scopes, served by the daemon with where each value came from, one key set into the scope a client names, and every client told when a file changed"
date: 2026-10-04
status: accepted
issue: 57
paths:
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/config/explain.ex
  - apps/troupe_core/lib/troupe/config/layers.ex
  - apps/troupe_core/lib/troupe/config/migrate.ex
  - apps/troupe_core/lib/troupe/config/settings.ex
  - clients/gui/apps/desktop/src/shared.ts
  - clients/tui/lib/troupe/settings.ex
gist: "The desktop app and the terminal UI share one set of settings: `config.yaml` at the ladder's scopes, served by the daemon with where each value…"
---

Issue
#57, as decided on it and on #122: no second settings file and no second schema.
Amends 675, which had the methods read and edit the user's file alone, for the model
panel.
- **`config.get` is additive.** It keeps every field it answered (the model panel's, what
  the user's file says) and adds `keys`, `files`, `workspace`, `trusted`, `warnings` and
  `errors`, so the protocol stays version 1 and an older client reads what it read. A
  secret is `****`, not `Config.mask/1`'s first and last letters: those are for the person
  at the console, and nothing of a key goes over a socket (675).
- **`config.set` takes one key by name, or the panel's fields.** With `key` (or
  `path`, for a name under a map with a dot in it) it writes `value` into the file of
  `scope` (`user`, the default, `project` or `local`), through `Migrate.write/2`, the
  writer 711 made every screen use; `null` takes the key out. With `provider` it is the
  model panel's save, unchanged. Nothing is written for a key the schema does not know,
  `version` and `$schema`, a value the loader would refuse or warn about (the value is
  checked by the loader's own walk, `Layers.check_map/2`), or a scope that may not set
  the key: `trusted_workspaces` outside the user's file, and a key marked trusted in the
  project or local file of a workspace that is not trusted, the trust rules of 686. A
  daemon from before this reads a `config.set` without `provider` as the panel's and
  would write `provider: anthropic`, so both clients set one key only on a daemon whose
  `config.get` answers `keys`.
- **`config.changed` goes to every client after a write that changed a file.** The daemon
  reads the file before and after a `config.set`, a `config.import` and a `setup.answer`,
  and names the keys whose values differ (`Settings.changed/2`; the writer's own `version`
  is no change), to every connection that speaks the protocol, the writer's included: it
  is how one client shows what another set. A save that changed nothing says nothing. **A
  file edited by hand is not announced:** the daemon would need a watcher for every
  workspace a client names, and nothing in the daemon goes stale without one, since it
  reads the files at every session start and every `config.get`.
- **A `ui` section holds what follows the person**: `ui.theme`, `ui.mode` and
  `ui.notifications`, the desktop app's three. The daemon keeps them and acts on none, as
  it does `mouse`, which keeps its name (686 made it a key, and moving it is a migration).
  The theme is a string, one the app does not know reading as its default, so a newer
  app's theme is not a file an older daemon refuses; the mode is an enum. What belongs to
  one device — a window's size, the plane the app last used, whether it opens on Home —
  stays in that window.
- **The desktop app follows.** The model panel reads `config.get` again on
  `config.changed`, and its form follows unless somebody is part way through an edit,
  who is told instead; the Appearance screen's theme, light or dark and notifications
  are the `ui` keys.
