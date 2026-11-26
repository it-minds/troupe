# Sessions

A session is one agent working in one directory, with a durable log: `active`, `dormant`
(stopped, log kept, woken when used), `read_only`, or `erased`. In the TUI `/new` starts
another beside it (`--private`, `--remote PROFILE`, `--only-me`, or `--branch` for a fork that goes on
from this one's conversation) and `/back` returns; `troupe resume latest` opens the newest
in the directory, and `troupe resume ID --headless "message"` runs one more turn on it and
exits ([command reference](cli-reference.md)). A session you erase reads
`erasure_pending` until the plane has destroyed its key. Erased on your machine, it is
erased at the plane too and goes from your machine once the key is gone; erased elsewhere,
the copy on your machine goes the next time your client signs your daemon in. Erasing one
on your machine needs that sign-in: without it the daemon erases nothing and says which
plane it is sealed at.

A session on your machine whose agent cannot read something in its log does not wake: the
message you send is refused with what the agent raised. You can wake it anyway, with `w` in
the TUI, the composer's **Wake it anyway** in the desktop app, or `troupe resume ID
--repair`: each event the agent cannot read is skipped, the log keeps it and says so, and
the transcript shows "An event from … could not be read and was skipped" where it was.

Inviting somebody into a session, archiving, renaming and keeping one at the top, its task
list, and links into the desktop app are on [sharing a session by name](sessions-shared.md).

## Starting a session

Starting a session begins with the message (*New session*, `/new`). One sentence under
it says how it runs, "Runs on the platform with dev as build · everyone on core can open
it", each word a picker; the profile is the last used with room, else the first with room,
and a line says which. `@dev`, `#plan`, `/local` in the message set those and are removed
before the agent reads it; a full profile says *Queue it* and starts when a place frees. If
two of your teams may use the profile you pick the team once (its budget pays); it is kept.
On the platform, *Only me, until I invite people* (`/new --only-me`, `troupe run
--only-me`) starts it as yours alone on the team's profile, marked *only you*, until you
[invite people](sessions-shared.md#starting-it-as-only-you). What a profile gives the session is on [profiles](profiles.md), and the terminal's screen
for it on [a new session](terminal-screen.md#a-new-session).

## How long a session lasts

A session is **Normal** unless you say otherwise: it sleeps when nothing runs, wakes when
you use it, and stays until you erase it. Two other lifespans are chosen in the same
sentence as you start it, or later from the session's ⋯ (`/lifespan` in the terminal):

- **Throwaway**, for a short question: erased a day after it goes quiet, which is
  24 hours after it last worked by default (your administrator sets 1 to 168). Its row says
  when, *throwaway · goes in 18 h*. It is not erased while it is awake, while it waits on
  an approval or a question, while it is kept at the top, or before somebody has reviewed
  a trigger's run. Erasing takes the whole session: its log, its workspace, its key and its
  invitations; what it cost and the audit stay. It may publish an artifact, which outlives
  it, and remember things in your own memory, but it proposes nothing for a team's or the
  organisation's memory. The head offers **Erase now**, and **Keep it**, which makes it
  normal. `/new --throwaway` and `troupe run --throwaway` start one.
- **Persistent**, for a report you build over days: kept until you erase it, and never
  cleared away by anything else. It still sleeps, and costs nothing asleep. `/new
  --persistent` starts one.

Only a session's owner changes its lifespan. A fork is normal unless you ask otherwise,
whatever the session it came from. A session on your computer that is throwaway is erased
by the daemon in the same way, after the same window (`throwaway_erase_after_hours` in its
[configuration](configuration.md)); a private one is erased by the plane, which
holds its key.

## Raising a session to the current configuration

A session on the platform runs on the bundle version its profile's channel had when it
started, and keeps it when your administrators publish a newer one: its agents, skills and
servers do not change under it. The session panel says which (*Configuration v12 · v14 is
current*), and `/bundle` in the terminal. Its owner moves it to the current version with
*Update* (`/bundle update`): the conversation, the goal, the task list and the files stay,
and the agent is told once that its configuration moved. While the agent works the update
waits and happens when it is done; a sleeping session takes it when it next wakes. It is
refused, saying why, when the new version no longer has the agent the session runs as.
There is no going back to an older version; an administrator republishes the old content
instead, and you update to that.

## Private session

A session on your machine sealed under your own key, listed by the
plane and opened from another device: `troupe --private`, or *Keep it private* in the
desktop app, which uses your account on this computer once you sign in. Your client hands the daemon its
sign-in to the plane, again as it renews it and after the daemon restarts, and the daemon
keeps it in memory only; one started while it had none is sealed once it has. Signing out
(`troupe logout`, or *Sign out* in the desktop app) takes it back, and nothing is sealed
until you sign in again, when each private session carries on where it stopped. One with
nothing running goes dormant on its own a while after you stop looking at it, even while
it waits on your answer, so it does not keep the daemon up; answering later wakes it, and
the turn carries on.

## Local only

**Local only** is a promise the daemon keeps, not only the client: the desktop app's
**Use this computer only**, or `local_only: true` in your own config for `troupe`
([settings](configuration-settings.md)), tells the daemon when the client connects. For the
sessions that client runs the daemon then calls no plane: `remember` to your own memory is
refused and offers the repository's, a session is not offered for steering, and it reads
the memory this machine already holds, as its first `instructions_loaded` says. While every
client attached is in Local only, the daemon's own checks with the plane wait too.

## Steering from another device

A session on your machine you offer to the plane you are
signed in to, so you can follow and steer it from the desktop app or the console on
another device (the console's *Mine*, which anybody the plane knows signs in to, not only
its administrators): `/steer on` in the terminal, or *Steer from elsewhere* in the session's
head in the desktop app. Name the people who may steer it too (`/steer on
bea@example.com`), or only follow it (`cy@example.com:observe`). Your machine keeps one
connection to the plane while it is offered and nothing listens on it; your rules and
approvals hold for every prompt, and an approval answered from elsewhere is for that one
call. Elsewhere it is listed as *Remote*, with *Offline since …* while your machine is
away, as soon as it is offered, withdrawn or goes away, since the plane tells the desktop
app and the console rather than being asked again; the desktop app names who is steering
your session as they arrive and leave; in the terminal, HQ (`/remote`) lists the sessions offered to you beside the plane's,
as `laptop` rows, and opens one to steer it. Who joins and leaves is said in the session's
window, and the status line names who is there. At your first offer the daemon signs in
for itself and keeps that sign-in in your computer's credential store, so the offer stays
online after you close the terminal or the app, and the daemon does not stop while
something is offered. After a restart the offer comes back where the daemon starts when
you log in (`troupe daemon login on`); otherwise it is shown as offered *until this
machine restarts*, and comes back only once something starts the daemon again. `/steer
off`, or *Withdraw*, ends every remote view at once; with
the last one withdrawn, signing out or `troupe logout`, the daemon lets its sign-in go.
Your team's administrators may turn offering off for the team.

A private session is offered only after you say yes to what that means
([a private session](sessions-shared.md#a-private-session)).

## Goal and loop

`/goal <text>` in the TUI sets what the session works towards; the
agent sees it on every later turn until `/goal clear`, and it survives a restart. `/loop
[n]` lets the session work towards it on its own for up to `n` turns (10 unless you say,
`loop_max_iterations`). Each turn ends with the agent saying whether the goal is met, and
the loop stops when it is, at the limit, after three failed turns in a row, when the
budget asks you, or on `/loop stop`. The status line shows how far it has got, and you can
keep typing while it runs.

## Approvals

Writing or editing a file and running a shell command ask first: the session
stops that one call and waits for allow, deny or allow-for-this-session. Anyone attached
with control rights can answer; the first answer wins and everyone is told who gave it.
Publishing an [artifact](artifacts.md) asks too, and the approval is where you say whom it
is for: the agent proposes an audience only when you named one, and otherwise you choose
it there, whatever your permission rules or `--auto-approve` say.

## Budget

Limits on turns, tokens and working time, plus your team's money budget on the plane.
When one is reached the agent says which and asks, or stops where the session's terms set a turn or time limit, as a trigger's may; it never silently continues.
The question says what the session has used and spent, and you answer with how much more
and for how long: pick a size for this run, this session or this workspace (which writes
it to the repository's `.troupe/config.yaml`, so the next session there starts with it),
or type an amount (`+25`, `+50k tokens`, `+15 min`, with `session` or `workspace` after
it). "No limit this session" lifts the limit it asked about for the rest of the session,
and the others still ask. Apart from the budget, a tool that fails ten times in a row
stops the turn and asks whether to go on, even with every limit lifted.

## Repositories

On a profile that allows GitHub, a new session on the platform offers your team's
repositories after the profile ("… with dev [on no repository] as build"); pick one or
several, with a branch where it is not the default (`owner/name@branch`), up to as many as
the profile allows. In the terminal it is `/new --repo owner/name[@branch]`, once for each,
and `troupe run --repo`. A profile that does not allow GitHub offers none, and one your team
does not list is refused, saying why. The first is cloned at the top of the session's
workspace, each other one in its own folder, `owner/name`, and the agent is told where
each is from its first turn.

While it runs, its owner attaches another (*Attach a repository* in the session's
Backstage, `/repo add owner/name[@branch]`), cloned without a restart, and takes one off
(*Take off*, `/repo remove owner/name`), which deletes its folder; the agent is told either
way. `/repo` lists them. Nobody else may, and a repository being pushed to is taken off
once the push is done. The list of sessions shows the first and how many more.

The agent pushes its work on each to a `troupe/*` branch of its own, opens a draft pull
request, reads CI on it and pushes fixes, as your organisation's GitHub App and never as
you, naming the repository where there are several; after three red CI rounds on one it
stops there, says on the pull request what still fails, and leaves the draft for a person.
Each push and pull request link is in the transcript, and Backstage shows each
repository's branch, last commit and pull request
([the GitHub App](../admin/github-runs.md#the-fix-loop)).
