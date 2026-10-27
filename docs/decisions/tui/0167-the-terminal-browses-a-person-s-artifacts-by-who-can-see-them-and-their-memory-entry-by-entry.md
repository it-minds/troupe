---
number: 167
title: "The terminal browses a person's artifacts by who can see them, in the desktop app's words and glyphs, through the daemon's sign-in: it opens one in the browser through the plane's one-time address and reads a Markdown one in its own frames, past 500 lines offering the browser; /memory is what a new session starts knowing, entry by entry per level with what is in effect for each team, Only you's changed on the screen over the version edited; troupe artifacts is the same on the command line, and HQ has a line per invitation and one for what is shared"
date: 2026-10-27
status: accepted
issue: 62
paths:
  - clients/tui/lib/troupe/ui/tui/artifacts_page.ex
  - clients/tui/lib/troupe/ui/tui/memory_page.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/hq.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/artifacts.ex
  - clients/tui/lib/troupe/client/own_memory.ex
  - clients/tui/lib/troupe/client/memory_entries.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/cli/artifacts.ex
  - clients/tui/lib/troupe/cli/memory.ex
  - clients/tui/lib/troupe/cli.ex
  - clients/tui/lib/troupe/clipboard.ex
  - clients/tui/lib/troupe/browser.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/artifacts.ex
  - apps/troupe_gateway/lib/troupe/gateway/memory.ex
  - clients/tui/test/troupe/artifacts_screen_test.exs
  - clients/tui/test/troupe/memory_screen_test.exs
  - clients/tui/test/troupe/artifacts_cli_test.exs
  - clients/tui/test/troupe/hq_inbox_test.exs
  - docs/user/terminal-screen.md
  - docs/user/cli-reference.md
  - clients/tui/README.md
symbols:
  - Troupe.UI.TUI.ArtifactsPage
  - Troupe.UI.TUI.MemoryPage
  - Troupe.Client.Artifacts
  - Troupe.Client.OwnMemory
  - Troupe.Client.MemoryEntries
  - Troupe.CLI.Artifacts
gist: "/artifacts by audience (◉◎◐○), opened in the browser via artifact.open, Markdown in frames ≤500 lines; /memory entries per level + in effect; daemon only; HQ inbox"
---

Issues #62 and #55, chunk 45's "a person's things, in a person's apps", the maintainer's word
on #765 of 2026-10-26: the console is the administrators' panel, and what is a person's own —
their artifacts, what is shared with them, their memory — is seen and edited in the desktop
app and the terminal. The desktop app's half is root Decision 954; this is the terminal's. On
the chunk's tip there was no `/artifacts`, no `troupe artifacts`, `/memory` was the
repository brief's facts alone, and HQ listed no invitations (D137).

## Artifacts

**Through the daemon, never the terminal's own sign-in.** `/artifacts`, `troupe artifacts`
and HQ's shared line ask this computer's daemon: `artifact.list`, and the methods root
Decision 954 forwards to the plane as the person (`artifact.get`, `artifact.open`,
`artifact.share`), to which this adds `artifact.read` (`observe`), one text file of a version.
So the terminal and the desktop app see the same list, and Local only is the daemon's to keep
as for every `artifact.*`; the terminal under `local_only` asks nothing at all and says
"Local only: the plane is not asked".

**Grouped by who can see it, in the desktop app's words.** The maintainer's design for the
gallery names four audiences with a glyph each: ◉ *Everyone at* the organisation, ◎ *Your
teams* (a team's and, under it, a profile's), ◐ *Shared with you* (through a link) and ○
*Only you*; the tabs are those and *All*. The plane says a row's `scope` (root Decision 953), which
the tab follows. The slot named the tabs Mine, Organisation, Teams, Profiles and Shared;
the design's four replace them, a person's own shown under who it is for, *by you* on its
row. *New to you* marks a version not opened on this machine, kept in the state directory
(`artifacts-seen.json`), never on the plane: it is this machine's reading, not the person's.

**Shown where it can touch nothing.** Enter asks `artifact.open` and opens the one-time
address in the browser, which the artifacts host redeems for its own cookie, as the console's
Open does (root Decision 948); the terminal never fetches a page. A Markdown one is also read
here (`m`): its source through `artifact.read`, drawn with the transcript's Markdown parser in
a frame (TUI Decision 161); a source past 500 lines is cut there, its last line offering
Enter for the whole in the browser, the viewer's limit Decision 161 left. `v` lists the
versions to open one; `l` asks a view link for one of the person's own and copies it through
the terminal with OSC 52 where its environment says it takes it (Windows Terminal, iTerm2,
WezTerm, kitty, Alacritty, foot, Ghostty), else with the clipboard command, and shows it
either way, since no terminal says whether it took it; `p` publishes a file of the workspace
with `/publish`'s line, for Only you where nothing is named, the design's default.

**On the command line**, `troupe artifacts list [--scope …] [--json]`, `open`, `show`
(the text on standard output), `publish FILE [--to …] [--title …]` and `link`, from the same
client module, in the command table so the reference regenerates. `--version` there names a
version; anywhere else it is the program's, so the subcommand parses its own options, as
`troupe update` does.

## Memory

**Entries, per level, and what is in effect.** The maintainer decided on 2026-10-26 that
memory is entries: a document's `## Topic` sections, the closest level's entry on a topic
replacing the lower ones'. `/memory` is the terminal form of the design's page: *In effect*
(for one of the person's teams, `t` another: the winning entry per topic and what it
replaces), then ◉ the organisation's, ◎ each team's and ○ Only you, a level the person
cannot change here marked `· read`. Until the plane answers entries, the client reads them
from each level's text (`Troupe.Client.MemoryEntries`) and saves Only you's whole text over
its version — a shim to go when it does. It reads the levels from the daemon's `me.memory`
(`documents`) and the history from `me.memory.history` and `me.memory.rollback`, root
Decision 954's; the daemon's `me.memory.status` now carries the copy's texts (`held`), which
is all the page reads under Local only, where it is read-only.

**Only you's, changed on the page.** `a` takes the topic on the page — refused where Only you
has it, said to replace a lower level's where one has — and the words in the person's editor
(`VISUAL`, then `EDITOR`), or, with neither set, in a box here, rather than Notepad or `vi`
uninvited; `e` edits and `f` forgets after a confirm line. A save names the version it was
made on: a `conflict` shows the person's text beside the version saved since, and `l`
reloads it. `h` lists the versions, two side by side, `r` rolls back to one (a version of its
own); `b` is who wrote each line, `troupe memory --blame`'s column; `s` is `--status`'s
lines. A `memory_changed` in the session, or the daemon's `config.changed` for memory, reads
the page again. The organisation's and a team's are read-only here in this slice: a team
admin's and a platform admin's saves go through the console until the daemon forwards
theirs. `/memory facts` is the brief's page as `/memory` was (this amends root Decision
839, which put the facts at `/memory` alone), `refresh` and `forget` as before; `/memory`
no longer needs a session on this machine, so the command table drops its `local`.

## HQ

One line per invitation (`invites.list` at the plane HQ looks at), Enter opening the session
to follow it — a private session's is the desktop app's to read, with its key, and says so —
and one for how many artifacts are shared with the person when any are, Enter opening
`/artifacts` on Shared with you. They are a column of their own while there are any.

## Proof

`artifacts_screen_test.exs` (each tab and its count, `new` gone once opened, Enter and `v`
through the one-time address, `m` in a frame and cut past 500 lines, `l` the owner's alone,
`p` for Only you; Local only asking nothing), `memory_screen_test.exs` (in effect with what
it replaces, a team read, edit in the editor and in a box, a clash refused and one said to
replace, forget after its confirm, a conflict beside the version saved since and reloaded,
the versions side by side and a roll back, who wrote each line, Local only read-only from
the copy), `artifacts_cli_test.exs`, `hq_inbox_test.exs`, against `FakeRemote` with the
embedded daemon linked to it; the gateway's `artifacts_test.exs` (the forwarded
methods with `artifact.read` among them) and `plane_memory_test.exs` (`held`). All failed on the
chunk's tip (`e544a82f`): no screen, command or method.
