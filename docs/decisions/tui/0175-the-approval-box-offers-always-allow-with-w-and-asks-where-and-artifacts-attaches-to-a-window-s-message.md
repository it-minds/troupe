---
number: 175
title: "A call's approval box offers Always allow where the daemon names it, as `w`, and asks where with one more key, `w` this workspace or `g` everywhere, Esc back; a pod names none and the box offers none; `/artifacts` typed in a window is the picker for its message, `a` attaching the artifact the window's box then shows until it is sent; an answered question says who answered where two or more people steer"
date: 2026-11-16
status: accepted
issue: 956
paths:
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/tui/view.ex
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/artifacts_page.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/troupe/client/daemon.ex
  - clients/tui/lib/troupe/client/remote.ex
  - clients/tui/test/support/fake_remote.ex
  - clients/tui/test/troupe/client_leftovers_test.exs
  - docs/user/terminal-screen.md
symbols:
  - Troupe.UI.TUI.Model.always_allow?/1
  - Troupe.UI.TUI.Model.attach_artifact?/1
  - Troupe.Client.attach_artifact/3
gist: "w = Always allow where approval_allow_always is named; w again = workspace, g = everywhere, Esc back; pod: no w, refusal in its words; /artifacts in a window + a attaches to its message; 'answered by' with 2+ steerers"
---

Issue #956, the terminal client's half of what chunk 47 left (#938, #940). The desktop's
half is root Decision 1003. On the chunk's tip the approval box answered `y`, `n` and `a`
only, the composer had no way to attach an artifact, and an answered question left no
line, although the daemon and the plane answer all three (root Decisions 989, 990, 992).

**Always allow is `w`.** The box grows by one key, not a second box: a call's approval
reads `APPROVAL: shell (y allow / n deny / a allow for session / w always allow)` where the
session's server named `approval_allow_always` at `initialize`, which the worker passes up
in its status beside `relayed?`. `w` asks where, on a line under the approval in the
desktop app's words, "Always allow shell where? w this workspace (.troupe/config.local.yaml)
· g everywhere (your config.yaml) · Esc back": `w` again writes the rule for this workspace,
the default as on the desktop and a second press of the same key, `g` for every session on
this computer, and Esc leaves the approval waiting as it was. Not chosen: `A`, which a
terminal may send as `a` with a modifier or not at all; two keys with no question, which
would make the scope a thing to remember rather than a thing asked; and a scope toggle
held between approvals, which would write a rule somewhere the person did not look.

**The key line at 80 columns** (TUI Decision 173): the approval's piece is `y/n/a approve
· w always`, then `y/n/a/w approve`, then `y/n/a/w`, so the key is never what leaves the
line; while it asks, `w this workspace · g everywhere · Esc back`, then `w workspace · g
everywhere · Esc`, then `w/g`.

**Where it is not offered.** A pod does not name the capability (its rules are its worker
profile's, root Decision 989), so the box draws no `w` there and the line has none
(DESIGN.md §8). A `w` pressed there anyway is sent, and the pod's refusal is shown as it
words it ("rules on the platform are the worker profile's…"), since the terminal keeps no
copy of that sentence; a daemon's refusal under `managed_permission_rules_only` or in a
workspace not trusted is shown the same way, the request still waiting. A laptop's session
steered from here through the plane answers once, and `w` says so as `a` does.

**An artifact attached to a message.** `/artifacts` (TUI Decision 167) typed in a window
whose server names `fs_upload_artifact` opens on that window: its line leads with "attach to
<window> — a attaches it to the message", and `a` attaches the artifact on the cursor and
goes back to the window. The window's box title then says "→ root + “Release plan” v2 —
Enter sends it with the message, Backspace drops it": what goes, before it goes. Enter sends
`fs.upload` with the artifact first (the session's server fetches its files from the plane,
never through this client, root Decision 990) and then the message, with a line per file in
`/upload`'s words, "uploaded index.md to session:/index.md", as the desktop's message says
it; so the transcript shows the attachment after. Enter in the empty box sends the
attachment alone; a refusal keeps the text and the attachment and says why in the server's
words. From the command line, or a window whose server does not name the capability, the
page is the browser it was. Not chosen: a key of the window's own for the picker, one more
thing to learn beside a command the palette already lists.

**Who answered.** Where two or more people steer the session (another person attached now,
by presence, or the answer another's), an answered question leaves a line in its agent's
transcript, "“Which branch?” answered by Bob Example: main", the person's own "answered by
you". With one, nothing is drawn, as before. The name is the event's actor's
(`display_name`), the subject where it has none, and nothing while this client does not
know yet who it is, as another person's lines are drawn (TUI people by name, root 992).

## Proof

`client_leftovers_test.exs`, over a session of the embedded daemon (and its real
`allow_always`) and over a pod on `FakeRemote`: the box and the key line offer `w`; `w`
asks where, Esc goes back, `g` writes `write_file` into the person's `config.yaml` and the
call runs; `w w` writes the workspace's file or is refused in the daemon's words; at 80
columns the key line keeps `y/n/a/w` and the question's keys; from another device `w` says
the call is answered once; on a pod no `w`, and one pressed is the pod's refusal; `/artifacts`
from a window attaches with `a`, the box shows it, and the message lands with
"uploaded index.md to session:/index.md" and the file in the workspace; Backspace takes it
off; another's answer named, the person's own "you" beside another, one steerer no line.
All failed on the chunk's tip, where none of the keys, the picker or the line existed.
