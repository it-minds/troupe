---
number: 1013
title: troupe update from an install whose programs are not in the default place lists and updates only what is its own, and says the desktop app is the default install's
date: 2026-11-16
status: accepted
issue: 969
paths:
  - apps/troupe_core/lib/troupe/update.ex
  - apps/troupe_core/test/troupe/update_test.exs
gist: Elsewhere (troupe not in the default place), update leaves a desktop app outside its two dirs and a menu entry not naming its AppImage
---

#969. `troupe update` from an install whose `troupe` and `troupe-daemon` were moved with
`TROUPE_BIN_DIR` and `TROUPE_LIB_DIR` (a second install, a check of the installers, a gate
walk on scratch homes) listed the machine's desktop app as one of its own: on Windows it
found it through the setup's `HKCU` uninstall entry whichever install put it there. Once a
newer release was out, an update from there would have run the release's setup over the
desktop app the default install owns. Decision 873 had settled the same question for the
installers' uninstall and clean install; `update.ex` was not among its paths. This narrows
Decision 959 ("one update moves every component the installers put on a machine") for an
install elsewhere only: every component is every component that install owns. From the
default install 959 stands as written.

- **The same rule as 873, for the update.** Which install this is follows the directory of
  the running `troupe`, not the daemon's: the default install is the one whose `troupe` is
  in `%LOCALAPPDATA%\Programs\troupe` or `~/.local/bin`. From there nothing changes. An
  install elsewhere owns what is in its two directories: troupe, troupe-daemon, and the
  desktop app only where it is in them, the AppImage beside its programs on Linux, a
  Windows setup whose program (`DisplayIcon`) is under one of them, an app bundle under them
  on macOS. Any other desktop app the lookup finds is the default install's.
- **It is said, not hidden.** `--check` lists it as `the default install's, not this
  one's: troupe update run from <the default place> updates it`, with its version, so a
  person with two installs sees why it is not in the plan; `troupe update` says it is left
  as it is in the same words, and never runs its setup, copies its bundle or touches its
  files. With no desktop app found, nothing is said of one.
- **The menu entry on Linux is shared too.** An install elsewhere that updates its own
  AppImage stamps the menu entry's version only when the entry's `Exec=` starts that
  AppImage; one that starts another is the default install's and keeps the version it says.
- **The VS Code extension is unchanged.** 873 left it out of what an install elsewhere
  leaves alone (`install.ps1 -Uninstall` from there removes it), and the update follows the
  installers rather than going further than they do. It is one per VS Code profile, not one
  per install, so whichever install updates it last sets its version; that is the same
  for the default install.
- **Not chosen:** refusing `troupe update` elsewhere (a second install could then never be
  updated), and asking per component (a scripted update has nobody to ask).

Proof: `update_test.exs` gained an install elsewhere on Windows rules whose desktop app's
`DisplayIcon` is outside its directories (listed as the default install's, the setup never
run), one whose program is inside them (listed as its own), and a Linux one whose own
AppImage is updated while a menu entry naming another AppImage is not stamped and an
AppImage in the default place is left. The first and the third failed before the change.
Run by hand from a scratch install on Windows rules, with the machine's real uninstall
entry read by `reg query`: the desktop app line says it is the default install's.
