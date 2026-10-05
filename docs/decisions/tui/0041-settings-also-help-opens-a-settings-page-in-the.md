---
number: 41
title: "`/settings` (also `/help`) opens a settings page in the TUI: `Troupe.Settings` lists the tweakable config keys as data (type, struct path, YAML path, when it takes effect, help text) and the page renders that list next to a curated help text"
date: 2026-09-11
status: accepted
paths:
  - apps/troupe_core/lib/troupe.ex
  - clients/tui/lib/troupe/settings.ex
gist: "`/settings` (also `/help`) opens a settings page in the TUI: `Troupe.Settings` lists the tweakable config keys as data (type, struct path, YAML…"
---

A change goes through `Troupe.put_setting/3`, which updates the Dispatcher's config (branches dispatched from then on), applies the live ones to Approvals and the Watcher, and rewrites the config file that owns the key — the project's `.troupe/config.yaml` when it exists, else the global one. The file is re-emitted from its parsed contents, so comments and formatting in it are lost; env vars still override both files and the page says so.
