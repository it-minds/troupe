---
number: 171
title: "/profiles lists the profiles a person may use, one summary line each, and /profile <name> (or Enter) opens what one gives a session in a frame drawn as /settings is, in six groups in reading order — Agents (and those not here, with why), Tools (rules, then MCP servers with whose access), Model, Reach, Limits, Who — every line from the plane's profile.get and a null said to be not said; troupe profiles prints the same lines, --json the answer"
date: 2026-10-29
status: accepted
paths:
  - clients/tui/lib/troupe/ui/profile_view.ex
  - clients/tui/lib/troupe/ui/tui/profiles_page.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/lib/troupe/client/profiles.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/cli/profiles.ex
  - clients/tui/lib/troupe/cli.ex
  - apps/troupe_core/lib/troupe/commands.ex
  - clients/tui/test/support/fake_remote.ex
  - clients/tui/test/troupe/profiles_screen_test.exs
  - clients/tui/test/troupe/profiles_cli_test.exs
  - clients/tui/test/troupe/profile_lines_headless_test.exs
  - docs/user/terminal-screen.md
  - docs/user/cli-reference.md
symbols:
  - Troupe.UI.ProfileView
  - Troupe.UI.TUI.ProfilesPage
  - Troupe.Client.Profiles
  - Troupe.CLI.Profiles
gist: "/profiles one summary line each; /profile <name> six groups Agents, Tools, Model, Reach, Limits, Who from profile.get; null is not said; access in words; troupe profiles same lines"
---

A person choosing where to start a session had a profile's name and, in HQ, its health
and room; what a session there would be given — which agents, which tools and with whose
access, which hosts it reaches, what it may spend — was in a bundle and a profile spec
only an administrator reads. The plane now answers `profile.get` for the caller, composed
from what it enforces (the root decision of the same date); this is the terminal's side.

**The list.** `/profiles` is one line per profile the person may use, from `profiles.list`
for the names and `profile.get` for each, so a row's summary and its page are one answer:
`code  3 agents · severa, sursen · reaches github.com · 2 of 8 sessions` — the agents a
session may start as, the MCP servers it is offered, the hosts (two and *n more* past
three), the sessions running of those there is room for. A plane from before `profile.get`
still lists its profiles from what the listing says, the rest *not said*.

**The page.** Enter on a row, or `/profile <name>`, opens a frame drawn as the settings page
is (double-ruled, titled, one block), six groups in the order a person asks: what can I
start as, what can it touch, what thinks, where can it go, how much, whose. **Agents**:
offered, with mode and description and *(built in)* for Troupe's own; then **Not here**,
dimmed, each with why in words — *the profile leaves it out*, *your team's grant leaves it
out*. **Tools**: the rules, one a line, `deny  shell(git push)   the profile`; then each MCP
server, `name · host · whose access · asked first | automatic`, its tools wrapped under it;
one not offered dimmed, with why; then the skills. **Model**, **Reach**, **Limits** (money
in the screen's dollar words) and **Who** (the team a session would run under, the
person's teams that may use it, the channel and bundle, the terms). Whose access is said
as the person would: *as you, once you connect it* (`yours`), *as the profile*
(`profile`), *as the profile's own identity* (`system`). A field the plane left null is
*not said*: a page that filled in a default would be believed. ↑↓, PgUp/PgDn, Home/End and
the wheel scroll it; `q` or Esc goes back to the list it came from, or closes. A profile
the person may not use is said to be one, never an empty frame.

**One set of words.** `Troupe.UI.ProfileView` makes each line as `{kind, text}`; the frame
draws a kind as a style, the headless printer (`profile_lines/2`, `profiles_lines/1`) as
plain text, and `troupe profiles [NAME]` prints those, `--json` the answer as it came. So
the command line and the screen cannot drift apart.

**Through the terminal's own sign-in.** It is asked of the plane this machine is signed in
to, as `profiles.list` and `troupe whoami` are. The daemon forwards `profile.get` but not
`profiles.list`, and the list's summaries and the page are to be one answer through one
sign-in, so both go the way the listing must; under Local only nothing is asked.

**Not chosen.** A tab in `/settings`: the settings page is this machine's configuration,
written with `s` and Enter; a profile's page is the plane's word, read-only, and about a
session not yet started — mixing the two would make it look editable. Composing the page
from the bundle and the profile spec in the client: what the bundle declares is not what
a person's session gets once their team's grant, the organisation's rules and the
profile's identity are applied, and only the plane applies them; two clients composing
would be two answers. A screen per group: the point is reading it through once before
starting.

**Proof.** `profiles_screen_test.exs` (the list's lines; the six groups in order with the
not-here rows, the rules and each access word; a profile not granted; a profile with
little said; Esc and `q`; scrolling), `profiles_cli_test.exs` (the list, the page, `--json`,
not found exits 1), `profile_lines_headless_test.exs` (not said throughout, the access
words, a long tool list wrapped), against `FakeRemote`'s `profile.get`.
