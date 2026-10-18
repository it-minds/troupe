---
number: 916
title: "No first-run screen in the desktop app waits on one reply: an answer late past a stated time says so and gives the buttons back, a lost answer or a reopened socket asks the daemon where the run stands, and a newer record means the run finished; a finished plane run lands where a start does, and a device-code sign-in opens the provider's page"
date: 2026-10-18
status: accepted
issue: 739
paths:
  - clients/gui/apps/desktop/src/views/Onboarding/hooks.ts
  - clients/gui/apps/desktop/src/views/Onboarding/Setup.tsx
  - clients/gui/apps/desktop/src/views/Onboarding/FirstRun.tsx
  - clients/gui/apps/desktop/src/App.tsx
  - clients/gui/apps/desktop/src/hooks.ts
  - clients/gui/apps/desktop/src/views/SignIn.tsx
  - clients/gui/apps/desktop/src-tauri/capabilities/default.json
  - clients/gui/packages/client/src/setup.ts
  - clients/gui/packages/client/test/setup-finished.test.ts
  - clients/gui/packages/client/test/support/daemon.ts
  - clients/gui/apps/desktop/test/first-run-finish.test.tsx
symbols:
  - setupFinishedSince
  - finishedFlow
  - useSetupFlow
gist: "First-run answers wait setupTiming.patienceMs (20 s) then say so; lost answer or reopened socket re-asks setup.get; a newer record is a finish; plane finish lands at start; device code opens the browser"
---

# No first-run screen waits on one reply

## Context

Issue #739: on the desktop app's first run, choosing a plane and pressing **Finish and
sign in** left the app on "Finishing…" for good. The daemon had taken the finish (its
`setup.get` said `needed: false`, the flow back at `where`), and the app never heard. The
screen left the first run only from the `.then` of that one `setup.answer`; a reply that
never came, a socket that went in its place, or a reconnect moved nothing, and nothing
else in the app asked. The fake daemon reproduces it: a `finish` it does whose answer it
holds back leaves the tip on "Finishing…".

## Decision

1. **The daemon's record is the truth about a run, not the reply that carries it.** A run
   finished since a screen last heard is one whose `completed` record is newer, or a first
   run the daemon no longer wants (`setupFinishedSince`). The finished flow a lost answer
   would have carried is built from what the person answered (`finishedFlow`); the session
   a local run asked for is then unknown, and the run ends on the list.
2. **An answer has a stated wait.** `setupTiming.patienceMs`, 20 seconds. Past it, the
   daemon is asked where the run stands; finished, the screen moves on. Otherwise the step
   says "The daemon has not answered in 20 seconds", the buttons come back (Back among
   them), and the answer is still taken if it comes. The first read of the flow has the
   same wait and an **Ask again** button.
3. **A lost answer asks.** An answer whose socket went (anything but the daemon's own
   refusal) asks `setup.get` at once, over a new socket, and shows where the run stands.
4. **A socket that opens again asks.** `useDaemon` counts the reopenings (`opened`), and
   the first run and the Setup screen ask the daemon where the run stands at each. The
   first run holds its flow from its first screen, the theme included, so a run finished
   meanwhile (in the terminal client, say) ends it there too.
5. **A "done" flow is never a screen with no way out.** It is normally never drawn, since
   finishing moves the app on; where it is, it says what is next with a button that goes
   there, and offers the run again.
6. **A finished plane run lands where a start does.** Local only is turned off and the
   app goes to its start screen: the sign-in, signing in to the address the run named, or
   the form when it named none. Signed in to a plane that does not serve this version, the
   start screen is where the refusal is said in words (Decision 874's banner); there is no
   sign-in to go to.
7. **A device-code sign-in opens the provider's page.** The code is shown, and the shell's
   `openExternal` opens `verification_uri_complete` (or `verification_uri`); the link stays
   for opening it again.
8. **The shell's HTTP scope covers every port.** `http://*` and `https://*` match only the
   scheme's own port, so a plane at `https://troupe.example:8443` was refused before a
   request left ("url not allowed on the configured scope"). `http://*:*` and
   `https://*:*` are added; the scope was meant as "anywhere" and now is.

## Consequences

- A stuck finish is reproduced in `test/first-run-finish.test.tsx` with the fake daemon's
  `loseReply` (`hold`, `drop`) and `dropClients()`; the same file sweeps sign-in against
  planes answering as 0.18, 0.19 and 0.20 do (their policy recommends themselves): the app
  signs in, shows the team's sessions, asks the shell about the recommended version and is
  told there is nothing to move to, since the shell never moves back on its own.
- A key check slower than 20 seconds says it is late, and still lands when the provider
  answers.
- The daemon is unchanged: `setup.get` and `setup.answer` already said everything needed.
