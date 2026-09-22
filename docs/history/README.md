# History

Records of a moment that has passed. Each was true on the day it was written and none is
kept up to date; the documents that are maintained cite them, and they are kept here so
those citations, and `git log --follow`, still lead somewhere.

## Reports, the audit and the briefs

| file | what it was | when |
| --- | --- | --- |
| [`REPORT.md`](REPORT.md) | The remote's (`troupe-remote`) evidence, stage by stage: stages 1 to 6, then R0 to R5, R8 and R9 of the remote brief, each done item with the command that proves it and its output. Was `REPORT.md` at the root. | 2026-09-11 to 2026-09-18, R9 the last section |
| [`AUDIT.md`](AUDIT.md) | The documentation audit the `docs/` tracks were written from: what the repository contained, where the prose disagreed with the code, caveats, open questions. The tracks still cite it by section. Was `docs/AUDIT.md`. | against commit `4083b1f`, 2026-09-13; superseded in part 2026-09-14 |
| [`gui-REPORT.md`](gui-REPORT.md) | The GUI's stage report from its own repository (`troupe-gui`): stages 1, 2 and 4, what stage 3 needs, the live deployment, and phase 4 of the daemon plan. `clients/gui/docs` cites it as `REPORT.md`. Was `clients/gui/REPORT.md`. | 2026-09-13 to 2026-09-21, before the move into this repository |
| [`tui-FINAL_REPORT.md`](tui-FINAL_REPORT.md) | The terminal client's final report against `clients/tui/elixir-prmpt.md`, each done item with the test that proves it, then phases 2 and 3 of the daemon plan as they landed in `troupe-tui`. Was `clients/tui/FINAL_REPORT.md`. | 2026-09-11 to 2026-09-20 |
| [`brief-remote.md`](brief-remote.md) | Nine work packages, R0 to R9, for `troupe-remote`, handed out with [`HANDOFF.md`](../program/HANDOFF.md). Was `docs/program/brief-remote.md`. | in the umbrella repository from 2026-09-19 |
| [`brief-gui.md`](brief-gui.md) | Six work packages, G0 to G6, for `troupe-gui`, handed out with the same handoff. Was `docs/program/brief-gui.md`. | in the umbrella repository from 2026-09-19 |
| [`brief-daemon.md`](brief-daemon.md) | The daemon plan: one harness under the TUI, the GUI and the worker, in five phases, with the prompt a session was started from. Decision 666 supersedes its section 7 answers 1 and 2. Was `docs/program/brief-daemon.md`. | drafted 2026-09-19, last updated 2026-09-20 |

## Imported histories

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
