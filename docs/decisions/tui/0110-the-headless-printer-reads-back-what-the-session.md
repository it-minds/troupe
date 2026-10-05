---
number: 110
title: The headless printer reads back what the session did before it was listening
date: 2026-09-21
status: accepted
paths:
  - clients/tui/lib/troupe/client.ex
gist: The headless printer reads back what the session did before it was listening
---

`troupe run --headless` creates the session and then starts the printer, and the
session starts working the moment it is created. On a slow machine a short run
finished and rested before the printer subscribed, and the printer, which only
listened, waited for a rest that had already happened — CI's clean-container check
hit it on its first run on GitHub and sat until its timeout, with `hello.txt` written
and nothing printed for `root`. The printer now subscribes, then reads the session's
journal (`Client.events/1`, what the TUI rebuilds its model from) and handles those
events exactly as it handles live ones, including the rest; a durable event that
arrives both ways is handled once, keyed by its path and `seq`. Proof: the CLI test
that lets a session rest before starting the printer, which timed out before this and
passes after.
