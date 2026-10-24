---
number: 941
title: "The terminal unlinks this computer's daemon with /unlink, asked once: anyone who reaches the daemon as its owner may, it drops the link, the plane's token, the daemon's own sign-in and the memory copy, keeps the sessions and the pinned key, and whoever the terminal is signed in as, if somebody else, is linked next"
date: 2026-10-24
status: accepted
issue: 765
paths:
  - apps/troupe_core/lib/troupe/commands.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/daemon/link.ex
  - clients/tui/test/troupe/unlink_command_test.exs
  - clients/tui/test/troupe/private_link_test.exs
  - clients/gui/apps/desktop/src/views/CommandPalette.tsx
  - docs/user/cli-reference.md
gist: "/unlink asks, /unlink yes does: owner scope; drops link, plane token, steering sign-in, memory copy; keeps sessions, pinned key; terminal's other sign-in links next"
---

D71's first item, in the sweep of chunk 42 (#765). The desktop app had "Stop using my
account here" on This computer; the terminal had no way to unlink a daemon, so a second
person on the same login could not take it over from there: the TUI hands its plane token
over only to a daemon linked to nobody or to the person it is signed in as (#365), and one
linked to somebody else is left as it is.

- **Who may.** Anyone who reaches the daemon as its owner: `identity.unlink` is an `admin`
  call, which a connection with the daemon's own token has and a steering connection from
  another device does not. That is everyone on this login, as the desktop app says under
  the button: anything that can reach the daemon can already do everything on it. Linking
  is a label, not a sign-in, and unlinking is too.
- **Asked once.** `/unlink` says who the daemon records sessions as and what unlinking
  drops and keeps; `/unlink yes` does it. A word on the line rather than a key armed for
  the next keystroke: it is typed, read back in the palette, and done by nothing else.
  Unlinked already, `/unlink` says so and nothing is asked.
- **What goes**, as `identity.unlink` already did, now said: the link (`identity.json`);
  the plane's token and where the plane is; the daemon's own sign-in for steering,
  released at the plane and taken out of the credential store, its connection closed;
  the copy of the organisation's memory; and the sealing, which stops as at a sign-out, so
  a private session is not sealed until its owner links again (Decision 784).
- **What stays.** The sessions, every one, and the key this machine pinned for the plane.
  The key is the machine's trust in the plane's word, not the person's: it is per plane,
  a sign-out keeps it too (Decisions 919, 922), and dropping it would let the next link
  take whatever key it is served, which is weaker, not cleaner. A key that changed is still
  accepted only by a person's yes.
- **Who is linked next.** Whoever this terminal is signed in as, if that is somebody else:
  the TUI hands their token over at once, as at a new connection, which is how the second
  person takes the daemon over. Not the person just unlinked: their token's renewals stop
  handing it over too, so the unlink holds for this run of the terminal. Their next start
  of the terminal, still signed in, links them again (#365); `troupe logout` is how they
  leave this machine for good, and `/unlink` says nothing of that, since it is the other
  person's command.
- **The desktop app.** The palette's `/unlink` opens This computer, where the button is.

Proof: `test/troupe/unlink_command_test.exs` (asked, not done; done, and said) and
`test/troupe/private_link_test.exs` (a daemon linked to Bob taken over by Alice, signed in
here; Alice unlinked stays unlinked), in `clients/tui`; the installed TUI against an
installed daemon with scratch homes.
