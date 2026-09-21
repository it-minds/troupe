> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

> ## Deprecated — kept as an artifact
>
> This page documents the `troupe` terminal client. That client left this repository on
> 2026-09-14: `apps/troupe_tui` and `apps/troupe_ctl` were deleted, the packaged binary
> and its installers with them, and nothing here builds an executable any more. The
> source citations under each section point at files that now exist only in git history
> (`git show 20fe871 -- apps/troupe_ctl` and the tree at that commit).
>
> On 2026-09-21 the terminal client came back to this repository as `clients/tui`
> (Decision 666), rebuilt since as a client of the daemon, and its current documentation
> is [`clients/tui`](../../clients/tui/README.md); the graphical client's is
> [`clients/gui/docs`](../../clients/gui/docs/README.md). This page describes the client as
> it was in `apps/`, and is not brought up to date.
>
> Nothing in this directory is maintained against the code. It is here because the prose
> is worth keeping until the client repository can take it, and for no other reason.

# Workflows

Ten tasks, end to end, with what you should see at each step. Replace the plane URL,
team and profile names with your own.

1. [Sign in and run a task on the team's pods](#1-sign-in-and-run-a-task-on-the-teams-pods)
2. [Run a task locally, approve a command, plan then build](#2-run-a-task-locally-with-the-tui)
3. [Two people on one session](#3-two-people-on-one-session)
4. [Watch mode on a file](#4-watch-mode-on-a-file)
5. [Unattended run from a script](#5-run-a-task-unattended-from-a-script)
6. [A team admin sets up a principal and a scheduled trigger](#6-a-team-admin-sets-up-a-service-principal-and-a-scheduled-trigger)
7. [Another agent calls a profile through A2A](#7-another-agent-calls-a-profile-through-a2a)
8. [Attach Claude Code to the admin MCP bridge](#8-attach-claude-code-to-the-admin-mcp-bridge)
9. [Verify a session's log](#9-verify-a-sessions-log)
10. [Recover after a restart](#10-recover-after-your-laptop-or-the-pod-restarted)

---

## 1. Sign in and run a task on the team's pods

1. Sign in.

   ```bash
   troupe login https://troupe.example.com
   ```

   Expected: `Open https://… and enter the code XXXX-XXXX`. Do that in a browser.
   Then: `Logged in to https://troupe.example.com as You.` followed by `Teams:` and
   `Profiles:` lines. If `Profiles:` is missing, stop and ask a team or platform admin
   for a grant.

2. Start a session on the team's pods.

   ```bash
   troupe --remote --agent dev
   ```

   (Omit `--agent dev` if you have exactly one profile.) Expected: one line
   `20260913T101502-Ab3dEf on https://troupe.example.com (dev)`, then the terminal
   UI with an empty transcript, `build` as the profile in the header, and the tree
   panel showing `root`.

3. Type the task and press Enter.

   ```
   Make the failing test in test/parser_test.exs pass without changing the test.
   ```

   Expected: your line appears with `>`; the agent's text streams in; tool calls show
   as they start and finish; the task list appears in the side panel when the agent
   writes one.

4. Answer approvals. When the agent wants to edit a file or run a command a popup
   titled `approve edit_file?` (or `approve shell?`) appears with a diff or the
   command. Press `y` to allow this call, `a` to allow that tool for the rest of the
   session, `n` to deny. Expected: the popup closes on the keystroke and the tool
   result appears in the transcript.

5. Wait for the agent to finish. Expected: a plain-prose answer and the tree panel
   showing `root` idle with `N/40 turns · M tok`.

6. Leave. Press **Ctrl-C twice**. Expected: the terminal is yours again; the session is
   still `active` on the pod and goes dormant after about ten minutes idle.

7. Confirm it is listed.

   ```bash
   troupe --remote sessions
   ```

   Expected: `Sessions on https://troupe.example.com:` and a line
   `20260913T101502-Ab3dEf  active  dev  …` (or `dormant` later).

8. Come back later.

   ```bash
   troupe --remote resume 20260913T101502-Ab3dEf
   ```

   Expected: the same transcript replays from the start; a dormant session is woken on
   a pod (this can take a second); you can type another instruction.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/login.ex:75-85; apps/troupe_ctl/lib/troupe/cli.ex:134-145, 249-264, 318-331, 338-354
- apps/troupe_ctl/lib/troupe/ctl/remote.ex:38-51, 178-192
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:77-108; apps/troupe_tui/lib/troupe/ui/tui/view.ex:83-86, 338-390
- apps/troupe_plane/lib/troupe/plane/harness.ex:225-235, 593-619
- apps/troupe_worker/lib/troupe/worker/session/manager.ex:51

## 2. Run a task locally with the TUI

Prerequisite: a `config.yaml` with `provider`, `model` and `api_key` (see
[getting-started.md](getting-started.md#4-your-first-local-session)).

1. Start in plan mode in your repository.

   ```bash
   cd ~/src/my-project && troupe --agent plan
   ```

   Expected: the terminal UI opens; the header says `plan`. (The daemon starts itself
   the first time; there is a short pause.)

2. Ask for a plan.

   ```
   Add a --json flag to the CLI that prints the result as JSON. Plan it; do not change anything.
   ```

   Expected: the agent reads files (`read_file`, `grep`, `list_files` need no
   approval), perhaps delegates to `explore` (a second row in the tree panel), and
   writes the task list. The side panel fills with `[ ]` items. No approval popups: the
   plan agent cannot write.

3. Switch to build. Press **Tab** (or type `/build`). Expected: a notice
   `profile → build` and the header now says `build`. The task list stays.

4. Tell it to go.

   ```
   Do the list.
   ```

   Expected: items move to `[~]` then `[x]` one at a time; the first `edit_file`
   raises `approve edit_file?` with a diff.

5. Approve a shell command. When `approve shell?` appears showing, say,
   `mix test`, press `a` so tests can run for the rest of the session without asking
   again. Expected: the popup closes; later `shell` calls run without a popup; the
   decision is in the log as `allow_session`.

6. Deny something. If a command you do not want appears (say a `git push`), press
   `n`. Expected: the agent receives a readable "denied" result and explains or tries
   another way; nothing ran.

7. Cancel a turn if it wanders: press **Esc** (or `/cancel`). Expected: `cancelled`
   in the transcript; the agent is idle and waiting for your next line.

8. Finish and detach. Press Ctrl-C twice. Later:

   ```bash
   troupe sessions
   ```

   Expected: `Sessions for /home/me/src/my-project:` and your session id with its
   state.

   ```bash
   troupe resume
   ```

   reattaches to the newest session in this directory.

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:188-242, 430-439, 585
- apps/troupe_core/priv/agents/plan.md, build.md
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:86-108, 310-333
- apps/troupe_tui/lib/troupe/ui/tui/state.ex:216-218
- apps/troupe_core/lib/troupe/session/approvals.ex:199-228
- apps/troupe_core/lib/troupe/tools.ex:152-169

## 3. Two people on one session

Ada owns a remote session; Ben joins it. This works with the terminal UI, the GUI, or
one of each.

1. Ada creates the session and notes its id from the first line printed.

   ```bash
   troupe --remote --agent dev
   ```

2. Ada lets Ben in. There is no CLI command for a grant; use a script or the GUI's
   client. The protocol call on the plane's `/rpc` is:

   ```json
   {"jsonrpc":"2.0","id":1,"method":"session.grant","params":{"session_id":"20260913T101502-Ab3dEf","subject":"ben@example.com","role":"collaborator"}}
   ```

   Expected: `{"session_id", "subject", "role": "collaborator", "granted_by", "pushed": true}`.
   If the session's visibility is `team` and the team has `members_may_control`, Ben
   is already a collaborator and this step is unnecessary.

3. Ben opens the same session.

   ```bash
   troupe --remote resume 20260913T101502-Ab3dEf
   ```

   Expected: the full transcript so far, identical to Ada's, and everybody attached
   sees a presence `joined` for Ben (the GUI shows it under "who is working"; the
   terminal UI does not display presence).

4. Both type. Ada sends a long task; while the agent is busy Ben sends `also update
   the changelog`. Expected: both screens show Ben's line marked as queued
   (`input_queued`) and then accepted (`input_accepted`) when the agent takes it. There
   is one order, the session's; neither client reorders it.

5. An approval appears on both screens. Ben presses `y` first. Expected: Ben's popup
   closes; on Ada's screen the popup closes a moment later when the `approval_decided`
   event arrives. If Ada also pressed a key, she sees an `approval_resolved` event
   naming Ben and her answer has no effect.

6. Ben leaves (Ctrl-C twice). Expected: a presence `left`; Ada's session continues
   untouched.

7. Ada revokes nothing today: there is no un-grant method. A collaborator whose access
   is removed by a team-level revoke is refused on their next command with `access
   revoked`.

Sources:
- apps/troupe_plane/lib/troupe/plane/harness.ex:177-196, 413-415, 799-808
- apps/troupe_plane/lib/troupe/plane/sessions.ex:537-556
- apps/troupe_gateway/lib/troupe/gateway/connection.ex:217, 616-622
- apps/troupe_core/lib/troupe/agent/server.ex:74, 661
- apps/troupe_core/lib/troupe/session/approvals.ex:199-245
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:482-492
- apps/troupe_worker/lib/troupe/worker/auth.ex:206-219

## 4. Watch mode on a file

1. Start a local session with watch on.

   ```bash
   troupe --watch
   ```

   Expected: the header shows ` · watch`; the transcript carries a notice saying which
   backend is in use (`watch: native` or `watch: poll`). If you forgot the flag, type
   `/watch` inside the UI.

2. In your editor, add a comment to a source file and save it:

   ```python
   def total(items):
       return 0  # sum the prices of items AI!
   ```

   Expected: within about a second (native) or two (polling) the transcript shows an
   input prefixed `[watch]` with the file, line, the comment and six lines of context;
   the agent edits the function; an `approve edit_file?` popup asks you (press `y`);
   the agent removes the `AI!` comment as part of the same edit so it does not fire
   twice.

3. Ask a question without letting it edit:

   ```python
   # why is this called twice on startup AI?
   ```

   Expected: an answer in the transcript and no file changes.

4. Leave notes for the next trigger: a bare `# the API returns cents, not dollars AI`
   is collected and sent along with the next `AI!` or `AI?`, not acted on by itself.

5. If a second session tries to watch the same directory (`/watch` in another
   `troupe` on the same repository), expected: `watch: watch is exclusive per
   workspace`. Turn it off in the first (`/watch` toggles) before turning it on in the
   second.

6. Turn it off: `/watch`. Expected: notice `watch: off`.

Sources:
- apps/troupe_core/lib/troupe/watch/marker.ex:9-11, 32-35, 123-148
- apps/troupe_core/lib/troupe/session/watcher.ex:49-66, 98-114, 161-177
- apps/troupe_core/lib/troupe.ex:334-360
- apps/troupe_gateway/lib/troupe/gateway/dispatch.ex:447-453
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:335-349; apps/troupe_tui/lib/troupe/ui/tui/view.ex:105-106, 189
- apps/troupe_core/priv/agents/build.md

## 5. Run a task unattended from a script

For CI or a cron job. Locally, or on the team's pods with `--remote`.

1. Decide what happens to approvals. Two choices: let the client approve everything
   (`--auto-approve`), or have the session deny anything that would ask (put
   `approvals: deny` in `.troupe/config.yaml` in the repository for local runs; for
   remote runs the CLI has no `terms` flag, so either use `--auto-approve` or create
   the session from a script with `terms: {"approvals": "deny"}`).

2. Run it with a timeout.

   ```bash
   troupe run "Bump the version in mix.exs to 1.4.0 and update CHANGELOG.md" --headless --auto-approve --timeout 600
   ```

   Expected output, roughly:

   ```
   > Bump the version in mix.exs to 1.4.0 and update CHANGELOG.md
     ☰ task list:
       [~] [a1b2c3d4] bump mix.exs
       [ ] [e5f6a7b8] update changelog
     → read_file path=mix.exs
     ✓ read_file
     → edit_file path=mix.exs …
     ✓ approved edit_file (--auto-approve)
     ✓ edit_file
   …
   Done. Version bumped to 1.4.0 and the changelog has a 1.4.0 entry.
   ```

   Add `--quiet` to drop the streamed prose and keep only the structure lines.

3. Check the exit code.

   ```bash
   echo $?
   ```

   | Code | Meaning | What to do |
   |---|---|---|
   | 0 | finished normally | proceed |
   | 1 | error, budget exhausted, or the daemon went away | read the last `!` line |
   | 124 | timed out | the session is archived after a local run; inspect it with `troupe resume ID` or `troupe sessions` |
   | 2 | usage error | fix the command line |

4. The same on the team's pods:

   ```bash
   troupe --remote --agent dev run "Bump the version …" --headless --auto-approve --timeout 600
   ```

   Expected: `<id> on https://troupe.example.com (dev)` then the same line format. The
   remote session is not archived by the CLI when the run ends; it goes dormant on its
   own.

5. Keep the log for audit: the session id is on the first line of a remote run and in
   `troupe sessions` for a local one; `troupe verify ID` checks it (local).

Sources:
- apps/troupe_ctl/lib/troupe/ui/headless.ex:28-55, 108-180, 244-265
- apps/troupe_ctl/lib/troupe/cli.ex:208-220, 284-297, 460-467, 623, 696-699
- apps/troupe_core/lib/troupe/config.ex:46-52, 190-191
- apps/troupe_plane/lib/troupe/plane/harness.ex:315-327

## 6. A team admin sets up a service principal and a scheduled trigger

You are a team admin of `research`, which is granted the `review` profile. Everything
below is `troupe admin`, which needs `troupe login` first.

1. Create the principal that will run the trigger.

   ```bash
   troupe admin principal create research nightly-review review
   ```

   Expected: a JSON object with `subject: "svc:research/nightly-review"`, `profiles:
   ["review"]`, `enabled: true` and `secret: "…"`. **Copy the secret now**; it is not
   shown again. (The trigger itself does not need the secret; an external caller of
   `trigger.fire` or the A2A facade would.)

2. Write the trigger definition to `nightly.json`:

   ```json
   {
     "team": "research",
     "name": "nightly-review",
     "principal": "svc:research/nightly-review",
     "profile": "review",
     "source": {"kind": "schedule", "cron": "0 2 * * *"},
     "prompt_template": "Review yesterday's merged pull requests and write a summary to REVIEW.md.",
     "terms": {"max_turns": 30, "wall_clock_seconds": 1800, "approvals": "deny"},
     "visibility": "team",
     "review": "required",
     "notify": ["ada@example.com"],
     "concurrency": 1,
     "enabled": true
   }
   ```

   Cron is UTC. `approvals: deny` means any tool that would ask is refused at once,
   which is what an unattended run wants; the review profile's agents should not need
   to ask.

3. Put it.

   ```bash
   troupe admin trigger put nightly.json
   ```

   Expected: `{"trigger": {...}, "changes": {...}}` listing every field as a change.

4. Fire it once by hand to check it.

   ```bash
   troupe admin trigger run research nightly-review
   ```

   Expected: the run and, because a session was made, `session_id`, `endpoint` and a
   `token`. Firing again within the same minute returns the same run (the manual
   idempotency key names you and the minute).

5. Watch the runs.

   ```bash
   troupe admin runs research nightly-review
   ```

   Expected: one run with `state` moving `created` → `running` → `done` (or `waiting`
   if something asked for approval, `failed` if it was interrupted or ended in error,
   `skipped` if it fired over the concurrency cap).

6. Review the session. Ada (named in `notify`) is a collaborator on it and sees it in
   `troupe --remote sessions` and in the GUI. Until somebody calls `session.review`
   `{session_id}` it carries `needs_review`; there is no CLI command for the review
   call, so a script or the GUI's client does it. `sessions.list` with `needs_review:
   true` finds the ones still open.

7. Change one field later, for example switch it off:

   ```bash
   troupe admin trigger put off.json
   ```

   with `off.json` = `{"team": "research", "name": "nightly-review", "enabled": false}`.
   Expected: `changes` shows only `enabled`.

8. Rotate or retire the principal when needed:

   ```bash
   troupe admin principal rotate svc:research/nightly-review
   ```

   ```bash
   troupe admin principal disable svc:research/nightly-review
   ```

   Rotating prints a new secret once and stops the old one immediately. Disabling
   keeps its sessions.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/admin.ex:59-73, 131-170, 369-372
- apps/troupe_plane/lib/troupe/plane/admin.ex:741-800, 804-870
- apps/troupe_plane/lib/troupe/plane/triggers/trigger.ex:24-41, 72-105
- apps/troupe_plane/lib/troupe/plane/triggers.ex:199-270, 277, 339-341, 396-425, 501-507
- apps/troupe_plane/lib/troupe/plane/harness.ex:124-137, 201-211
- PROTOCOL.md:757-770

## 7. Another agent calls a profile through A2A

Brief; the full mapping is in [a2a.md](../a2a.md).

1. A team admin creates a principal granted the profile (workflow 6, step 1) and hands
   the caller `svc:<team>/<name>` and the secret.

2. The caller reads the agent card (no token needed):

   ```bash
   curl https://a2a.example.com/a2a/review/.well-known/agent-card.json
   ```

   Expected: a card with `name`, `url`, `capabilities.streaming: true`, and, with a
   credential on the same request, the bundle's skills and `version:
   "bundle:<channel>/<version>"`.

3. The caller sends a task with `Authorization: Bearer svc:research/nightly-review:<secret>`
   (or Basic with the same string) as an A2A `message/send`. Expected: a task whose id
   is a Troupe session id, in state `submitted` then `working`; with
   `configuration.blocking: true` the response holds the final answer; with
   `message/stream` it arrives as server-sent events.

4. If the agent asks for an approval the task becomes `input-required` and the status
   message names the tool and its arguments; the caller answers with a data part
   `{"decision": "allow" | "deny" | "allow_session", "call_id": …}`.

5. From your side the session looks like any other: `origin.kind` is `a2a` in
   `troupe --remote sessions` and in the GUI, it is owned by the principal, and a team
   admin can grant a person access to it with `session.grant`.

Sources:
- docs/a2a.md
- apps/troupe_a2a/lib/troupe/a2a/auth.ex:6-19, 51-63
- apps/troupe_plane/lib/troupe/plane/harness.ex:177-196, 348-368

## 8. Attach Claude Code to the admin MCP bridge

For a team or platform admin.

1. Be logged in to the plane (`troupe login …`). If you use several planes, decide
   which one the bridge should talk to.

2. Register the bridge with Claude Code:

   ```bash
   claude mcp add troupe -- troupe mcp
   ```

   With a specific plane:

   ```bash
   claude mcp add troupe -- troupe mcp --plane https://troupe.example.com
   ```

3. Start Claude Code. Expected on the bridge's stderr (visible in Claude Code's MCP
   log): `troupe mcp: bridging to https://troupe.example.com`. In the tool list you
   see `admin_overview`, `admin_teams_list`, `admin_trigger_put`, and so on — every
   admin method, whether or not your role may call it.

4. Ask the model something read-only first: "Use admin_overview and tell me which
   profiles have unhealthy pods." Expected: a JSON answer scoped to what you
   administer.

5. Destructive tools need confirmation: to erase a session the model must pass both
   `session_id` and `confirm` with the same value, and a refusal comes back as a
   readable sentence, not a crash. A method above your role answers with the role that
   was wanted.

6. Tokens are renewed by the bridge every ten minutes from your stored login; if the
   refresh fails you see `the session for … could not be renewed — log in again` and
   need to run `troupe login` again.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/mcp.ex:1-45, 54-65, 148-169
- apps/troupe_ctl/lib/troupe/cli.ex:91-95
- PROTOCOL.md:707-755

## 9. Verify a session's log

1. Find the id (`troupe sessions` locally).

2. Check it through the daemon:

   ```bash
   troupe verify 20260913T101502-Ab3dEf
   ```

   Expected: `312 events verify; the head is sha256:9c1f…` and exit code 0. A break
   prints `the chain breaks at seq 57: its prev_hash does not match the event before
   it` (or `… the sequence skips`) and exits 1.

3. Check a file offline (no daemon needed), for example a copy of the local log:

   ```bash
   troupe verify --log ~/.local/state/troupe/sessions/<workspace-hash>/20260913T101502-Ab3dEf/events.jsonl
   ```

   Expected: the same message; an unreadable path exits 2.

4. For a remote session: `troupe verify` has no remote mode. Compare the `head_hash`
   the plane shows for the session (in `sessions.list`, or in the tombstone an erase
   returns) with the head you compute from the events a reader subscription gives you,
   or ask an administrator for the decrypted segment and check it with `--log`.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/verify.ex:24-41, 54-75
- apps/troupe_ctl/lib/troupe/cli.ex:119-132, 183-186
- apps/troupe_core/lib/troupe/paths.ex:42-46
- apps/troupe_plane/lib/troupe/plane/harness.ex:255-256, 968

## 10. Recover after your laptop or the pod restarted

1. Notice the state. Locally:

   ```bash
   troupe sessions
   ```

   Remotely:

   ```bash
   troupe --remote sessions
   ```

   Expected: the session is listed `dormant`, and if it was mid-turn its status is
   `interrupted`. Nothing is running and no model call has been made since the
   restart.

2. Look before you wake it. Reading does not wake a session: `troupe --remote
   resume` *does* activate, so if you only want to read, use the GUI's inbox path or a
   script with `session.open` `mode: "read"`. Locally, `troupe resume` also
   activates only when you send something; attaching replays the log.

3. Resume it.

   ```bash
   troupe resume 20260913T101502-Ab3dEf
   ```

   (or `troupe --remote resume ID`). Expected: the transcript replays; if the session
   was interrupted the tool calls that never finished now show error results reading
   `interrupted: the session stopped before this finished`, and an approval that was
   pending is asked again. The agent waits for you.

4. Tell it to carry on:

   ```
   Continue from where you stopped.
   ```

   Expected: a normal turn. The budget counters are what they were before the restart.

5. If a remote wake-up fails with `budget_exhausted`, the team has nothing left to
   reserve; ask a team admin. If it fails with `capacity` (`every pod is full`), try
   later or ask an admin about the profile's replicas. If it says `this session is
   read-only`, the team's access to the profile was revoked; the session can be read
   but not continued.

6. To make a local daemon resume on its own after a restart (re-running unfinished
   tool calls), set `resume_on_restart: true` in `config.yaml`. The default is off on
   purpose.

Sources:
- apps/troupe_core/lib/troupe/sessions/index.ex:333-340
- apps/troupe_core/lib/troupe/agent/server.ex:280-320, 365-370
- apps/troupe_core/lib/troupe/config.ex:53-57
- apps/troupe_ctl/lib/troupe/cli.ex:222-233, 430-439
- apps/troupe_plane/lib/troupe/plane/harness.ex:225-235, 461-473, 585-638
- PROTOCOL.md:468-504
