---
number: 170
title: "A prompt that draws nothing is said to be waited on from its first second in the curtain line's facts, preparing then the daemon's unsent request, thinking then no answer from the model's host, and after 45 s in a box above the composer saying what was sent and when, what has happened since, the last event heard and what to do; headless mode prints the box's line once at the same thresholds"
date: 2026-10-29
status: accepted
paths:
  - clients/tui/lib/troupe/ui/tui/model.ex
  - clients/tui/lib/troupe/ui/tui/server.ex
  - clients/tui/lib/troupe/ui/headless/printer.ex
  - clients/tui/lib/troupe/remote/translate.ex
  - clients/tui/lib/troupe/settings.ex
  - clients/tui/test/troupe/first_prompt_wait_test.exs
  - clients/gui/apps/desktop/src/frames.ts
  - clients/gui/apps/desktop/src/views/Session.tsx
  - clients/gui/apps/desktop/test/model-wait.test.tsx
  - clients/gui/packages/client/src/transcript.ts
  - docs/user/terminal-screen.md
symbols:
  - Troupe.UI.TUI.Model.waiting/3
  - Troupe.UI.TUI.Model.wait_lines/3
  - Troupe.UI.TUI.Model.activity_line/4
  - Troupe.Settings.model_host/1
  - Troupe.Settings.daemon_log/0
gist: "Facts from the first second: preparing (10 s: the daemon has not sent the model request yet), thinking (20 s: no answer from <host> yet); a box at 45 s with the times, the last event and Esc/doctor/daemon.log; headless one line"
---

A person on Windows started the terminal, typed a first line, and for two minutes saw
nothing: no output, no error, and at the gateway no token used. The curtain line of TUI
Decision 161 showed a flourish with no counter while nothing had happened (`the house
lights go down`), and would have shown `thinking (02:00)` ticking for the harness's five
minutes had the request gone out. They would rather see an error, or something that says
what is being waited on. This is the terminal's half; the harness's first-byte limit is
a root decision of the same date.

**What the terminal knows.** Three events stamp a turn's wait, and the window keeps the
three times: the prompt (`input`, the first copy of it by command id, since the same line
comes back queued and taken), the daemon's model request (`llm_request`, which reaches
the window as the `thinking` it starts, now with the model it named), and the first byte
back (a delta, a reply that never streamed, or the model error that ended it). A request
older than the prompt is the last turn's, and a byte older than the request answered the
last one, so the phase is read by comparing the three (`Model.waiting/3`): the request
while none has gone since the prompt and the agent does nothing else, the answer while
the request has drawn no byte and the agent still thinks, nothing otherwise. The window
also keeps the last event it heard, whatever it was, with its time.

**The curtain line keeps its shape.** TUI Decision 161's rule stands: the facts are never
optional, always in the same place, and the flourish is a prefix that goes first. So the
facts now say the wait from the first second — `the house lights go down — preparing
(00:04)`, the time from the prompt — and once the wait is news the flourish goes and the
facts say it plainly: `the daemon has not sent the model request yet (00:14)` from ten
seconds; after the request `thinking (00:12)` as ever, and from twenty seconds with
nothing back `no answer from api.anthropic.com yet (00:35)`, the host of the
configuration's `base_url` or the provider type's own endpoint (`Troupe.Settings.model_host/1`),
never the key, and `the model` where this machine does not know (a pod's configuration
is its plane's). A tile says the facts alone, as it always did. A second prompt starts
the wait again; before this, a second prompt showed nothing at all until the request,
since an agent that had said `idle` had no line.

**The box.** From forty-five seconds either way, under the curtain line and where an
approval would be — the last thing in the pane, above the composer — a framed box: `nothing
has happened for 00:46`, then when the prompt went (`your prompt went to the daemon at
14:02:11`, the clock on the wall, as a log's lines are), what has happened since (`the
daemon acknowledged it; it has not sent the model request`, or `the daemon has not
acknowledged it` where only this screen's copy of the line exists, or `the request went
to api.anthropic.com at 14:02:12; nothing has come back`), the last event this screen
heard and when, and what to do: `Esc cancels the turn · troupe doctor asks the model for
a token · the daemon's log is <path>` (`daemon.log` in the state directory, as the
daemon names it, in the platform's spelling). Forty-five seconds, so the box is there
before the harness's own first-byte limit ends the turn with its sentence. It goes with
the first byte or the turn's end, and is never drawn over something that waits on a
person. A model error is the agent stopped from the moment it arrives: the line says
`model error: <sentence>` at once rather than `thinking` until the turn's end, and keeps
saying it after, in the window and its tile.

**Headless** prints one line at the same thresholds, once for the prompt and once for the
request, from a timer rather than a clock since the printer draws nothing: `nothing has
happened for 45 s: the daemon took the prompt and has not sent the model request; ...`
and `no answer from <host> for 45 s after the request; ...`, both ending with `troupe
doctor` and the log's path. A byte or the log's word that the turn is over stops the
timer; a line is never repeated for the same wait.

**The desktop app, small**, from the same three stamps in its fold: the composer's hint
says `the daemon has not sent the model request yet (00:14)` from ten seconds after a
prompt with no request, and `waiting on the model (00:35), nothing back yet` from twenty
seconds after the request with nothing streaming; nothing more.

**Not chosen.** A spinner alone, which is what there was: it says the terminal is alive
and nothing else, and the report is of a person watching one for two minutes. A modal,
which would take the keys from the composer and the pane: the box is drawn where an
approval is, and Esc, a line typed and the scroll keys all still work; the box is
information, not a question. Saying the host in the curtain line from the first second:
`thinking` is right while a model takes its usual ten seconds, and the host is news only
once it is late. A new event from the harness: everything here is derived from what the
daemon already sends, so a daemon from before the harness's own change gets the box too.

**Proof.** `Troupe.FirstPromptWaitTest`: the curtain's words at each threshold, from a
fold with the clock driven by hand, in the pane and in a tile; the next prompt preparing
again and a queued copy no turn; the box's lines at 46 s before and after the request,
unacknowledged, and gone with a byte, the turn's end or a question; the model's sentence
from the error on, over this client's events and over the wire, and against the daemon
with the fake failing the request; the host from `base_url`, the type and neither; the
headless line once at the prompt and once at the request, none after a byte.
`transcript.test.ts` stamps the three times; `model-wait.test.tsx` holds the events back
and moves the clock.
