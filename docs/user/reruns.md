# Reruns on a schedule

When you publish a report built from live data in a session on the platform, Troupe may ask,
in the chat, whether to rerun it on a schedule. Say yes and the report is made again at the
times you chose, each run publishing the next version of the same
[artifact](artifacts.md), as you and on your budget. This page says when Troupe asks, what a
yes makes, and how to answer from each client. The protocol calls it a proposal
(`proposal_made`, [PROTOCOL.md](../../PROTOCOL.md)); the screens ask the question.

## When Troupe asks

At the end of a turn, never in the middle of one, when all of these hold:

- the turn published an artifact (`publish_artifact`);
- earlier in the session, a tool read live data: a page fetched (`web_fetch`), an MCP
  server's tool, or a command from the shell such as `curl`, `psql`, `sqlite3`, `gh` or
  `kubectl get`;
- the session runs on the platform and you started it: a session a trigger or another agent
  started already recurs, and a session on your computer has nothing to run a schedule
  (nothing there schedules, so nothing is proposed there);
- your team lets members schedule (on unless a team admin turned it off), you said neither
  "never" for this report nor hold five such reruns in the team, and no trigger reruns this
  artifact already.

It asks once per session. Nothing waits for your answer: the session goes on, and you may
answer later or not at all. Only you, the session's owner, answer; anybody else in the
session reads that you were asked.

## What it proposes

- **When**: from your own words in the turn ("every Monday", "daily", "weekdays",
  "monthly"), else every Monday at 06:00 UTC. You change it before saying yes: every day,
  every weekday, every week on a day, every month, at an hour UTC, or a cron of your own.
- **What each run is asked**: your instruction that led to the report, the sources it read,
  and the line that publishes the result as the next version of the same artifact, for the
  same people. You may edit it.
- **What it runs as**: your own principal in the session's team, sponsored by you, so each
  run spends your budget first, as a sponsored principal's does
  ([bundles-and-triggers.md](../admin/bundles-and-triggers.md#a-persons-own-triggers)); up to
  $1.00 a run unless you change it. Each run asks you to review it, and you are told of each.
- **What each run may do unasked**: publish the next version and the reads the session used,
  nothing else; where the profile asks before one of those, Troupe says so and offers no
  rerun, since nobody would be there to answer.

## Answering

- **Desktop app and web app**: a card in the chat, its headline the question. **Turn on**
  makes it; **Not now** leaves it for this session; **Never for this report** stops it being
  asked about that report again, in any session. Afterwards a line says what you did.
- **Console**: the same card where a session opens in the console.
- **Terminal**: a line with the question, then `/proposal yes`, `/proposal later` or
  `/proposal never`; `/proposal` alone says what is open.

Your agent is told at its next turn that the rerun exists, so it does not offer one again.

## Afterwards

The rerun is a trigger of your team's, named after the report. A team admin sees it, changes
it or stops it on the console's Triggers page. Where the platform keeps its triggers in a
repository, Turn on makes nothing: it gives you the `Trigger` file to commit there, which a
team admin completes with a principal ([triggers-from-a-repository.md](../admin/triggers-from-a-repository.md)).
