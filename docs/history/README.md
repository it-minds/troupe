# Imported histories

Three repositories were merged into this one with their history (Decision 666), each
rewritten by `git filter-repo` so its paths sit under their new prefix. Rewriting a commit
changes its SHA, so a SHA quoted in an imported document — "Audited against troupe-gui
commit 783e660" — no longer names a commit here. The archived repository still has it,
and these maps translate it:

| map | from | imported at |
| --- | --- | --- |
| [`troupe-gui.commit-map`](troupe-gui.commit-map) | `it-minds/troupe-gui` main at `2c86ccd` | `clients/gui/` |
| [`troupe-tui.commit-map`](troupe-tui.commit-map) | `it-minds/troupe-tui` main at `5cf5be2` | `clients/tui/` |
| [`troupe.commit-map`](troupe.commit-map) | `it-minds/troupe` main at `de07e9c` | `daemon/` (now `apps/troupe_daemon/`), `install.*`, `docs/program/` |

Each line is `old new`, full SHAs, as `git filter-repo` wrote it. To find a quoted commit:

```sh
grep ^783e660 docs/history/troupe-gui.commit-map
```

The maps list every commit on every branch the clone had, so they are longer than `main`.
