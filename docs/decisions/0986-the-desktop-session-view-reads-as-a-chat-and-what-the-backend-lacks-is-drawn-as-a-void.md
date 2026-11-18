---
number: 986
title: "The desktop session view reads as a chat: a one-line head, one centred column, cards at its foot, a one-box composer; the backstage under ⋯, the goal from /goal; what the backend lacks is drawn, with its reason, and waits on #920"
date: 2026-11-15
status: accepted
issue: 919
supersedes: [708, 877]
paths:
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/src/views/Approval.tsx
  - clients/gui/packages/client/src/transcript.ts
symbols:
  - Composer
  - ContextRing
  - ReplyFoot
  - SessionMenu
  - contextStatus
  - ALLOW_ALWAYS
gist: "Session = chat comp: one-line head, a column 760px to 1200px, cards at its foot, one-box composer; backstage/scratchpad under ⋯; goal via /goal; voids say why and wait on #920"
---

Issue #919. The maintainer redrew the desktop app's session screen as a chat
(`clients/gui/docs/design/session-chat.dc.html`, its notes at its top). The screen is now
that comp, and nothing the old screen did was dropped to make it so.

**The shape.** One line of head: back, the mask, the title, the session's setup as mono
tags (where it runs, the plane profile, the agent this window runs), who is here, the
status, Invite and ⋯. The transcript is one column centred in its track, 760 px on a
laptop and widening with the window to 1200 px (#926): a person's words a block on the
right, the troupe's reply beside the mask with its working folded into the strip (Decision
877's strip, unchanged), and under the reply, on hover or focus, Copy, Retry, Publish and
the turn's cost line. The cards that wait on the person (approval, question, delegation,
publication, the offer of your servers, the start's questions) stay at the column's foot,
in the column's width, with #906's floors: header and answers outside a body that scrolls,
the transcript keeping its minimum.

**Where the rest went.** The backstage (tasks, files, instructions, memory, settings, the
company, this computer's controls, what the session costs) and the scratchpad are under
⋯, and start hidden at every width; with neither open the conversation is the screen on a
phone too. ⋯ also holds steering from another device, About the agent, and the session's
id, your part in it and who invited you, which were the breadcrumb's. The goal is set
with `/goal` and cleared with `/goal clear` (or Clear on its line); while there is one it
is a line under the head with Change, Loop and Clear and the loop's status, which replaces
Decision 708's goal line and loop pill in the head. The agent switch (the dialog of
Decision 981, its refusals) is the composer's chip; the head names the agent. `/` opens
the commands over the composer; Ctrl-K over the screen.

**The palette keeps its list.** The command list keeps at least eight rows and scrolls in
itself; the chosen command's detail is a box of its own: beside the list from 1024 px,
under it, held to 30% of the height, below that. A file's prompt shows twelve lines and
counts the rest.

**Voids, each saying why, each waiting on #920.**
- *The context ring* is the root's last call's tokens in (input, cache read, cache write).
  Until the harness says the window, it is a turning quarter arc labelled "Context: 24.1k
  tokens in; the window size is not reported yet." A `context_status` event
  `{window_tokens, used_tokens}`, durable or not, makes it the share used.
- *Always allow <tool>* is drawn beside Allow once and the session-wide allowance,
  disabled, "Always allow (not yet: allow it for this session instead)". Where the server
  names `approval_allow_always` among its `initialize` capabilities it is live and sends
  `approval.respond` with `decision: "allow_always"`. A disabled control is against
  DESIGN.md §8's remove-don't-disable; it is kept here on purpose, as the comp's promise
  with its reason.
- *Add from artifacts* works for a session on this computer: the person's artifacts
  through the daemon's `artifact.list`, each file of the newest version read with
  `artifact.read` and uploaded with the message. On the platform it is disabled, "Not yet
  on the platform": the plane would have to put the files into the pod's workspace.
- *Upload files* (and files dropped on the window) go to `session:/<name>` with
  `fs.upload` before the message, as the terminal's `/upload` puts them (text only, the
  server's message size heeded), and the message ends with `/upload`'s own line for each.
  *Add a folder* names a folder of this computer, picked with the shell's chooser, in the
  message; elsewhere it says "Only for sessions on this computer".
- *Retry* sends the person's own message that began the turn again, as a new turn; where
  the transcript cannot say which (a loop's turn, somebody else's), it is disabled with
  "Not yet". *Publish* opens the publish dialog with the answer as `reply.md`.

**Not taken.** The backstage open by default on wide windows: the comp is one column, and
⋯ is one press. Approval cards inline at their place in the history: they would scroll away
from the composer, and DESIGN.md §6 keeps them where the eye is.
