> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../history/AUDIT.md).

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

# Troupe from the user's seat

Troupe runs a coding agent for you. You give it a task in a directory; it reads,
edits, runs commands and reports back. What makes it different from a chat window is
where the work lives: a session is a process on a server (a worker pod your team
runs) or in a small daemon on your own machine, and the window you look at it through
is only a window. Close the terminal and the session carries on. Open it again from
another machine and you see the same transcript. Two people can open the same session
at the same time.

This page names the things you will meet. [getting-started.md](getting-started.md)
gets you to a first session; [features.md](features.md) lists everything you can do;
[workflows.md](workflows.md) walks through the common tasks end to end.

## Three ways in

| Way in | What it is | When to use it |
|---|---|---|
| `troupe` in a directory | The terminal UI, talking to a daemon on your own machine. Sessions work on the files in that directory. | Your own laptop, your own repository, your own model key. |
| `troupe --remote` | The same terminal UI, but the session runs on one of your team's worker pods. The plane picks the pod; your terminal connects to it directly. | Work that should be billed to the team, run on the team's model access, and be visible to teammates. |
| The GUI | A web page that signs in to the plane and shows the team's sessions. It lives in its own repository: [troupe-gui user guide](../../clients/gui/docs/user/README.md). | Reading, starting and steering remote sessions from a browser, and answering approvals from an inbox. |

Two more callers exist that are not people: a script can speak the protocol directly
to a daemon or a pod, and another agent can call a profile through the A2A facade.
Both are covered in [features.md](features.md) and, for the protocol itself, in
[PROTOCOL.md](../../PROTOCOL.md).

The terminal UI in this repository is the reference client and the protocol's test
harness; it does everything the protocol allows but is plain. The GUI is the
polished face and today covers remote sessions only.

## Words you will meet

**Plane.** The server your team signs in to. It knows who you are, which teams you are
in, which profiles those teams may use, and where every remote session is. It never
holds what a session said or did.

**Team.** A group from your organisation's identity provider that an administrator has
enabled on the plane. A team has a budget, a retention period and a list of profiles it
may use. You are in a team because your identity provider says so; nobody edits
membership in Troupe.

**Profile.** A kind of worker pod: an image, a model endpoint, a set of MCP servers,
some storage. Your team is granted profiles; a remote session is created *on* a
profile. If you have exactly one profile you never have to name it.

**Session.** One agent tree working in one directory, with a durable log of everything
that happened. A session is `active` (running), `dormant` (stopped, but its log is
kept and it can be woken), `read_only` (kept but can no longer be woken) or `erased`
(gone). Locally the directory is one on your disk; on a pod it is the pod's
workspace for that session.

**Agent.** The thing that talks to the model. A session starts with one primary agent
(`build` by default, or `plan`) which may delegate to subagents (`general`,
`explore`). An agent is defined by a markdown file, and your team's bundle or your own
config can add more.

**Approval.** Some tools ask before they run: writing a file, editing a file, running a
shell command. The session stops that one tool call and waits for a person to say
allow, deny, or allow-for-this-session. Anybody attached with control rights can
answer; the first answer wins and everybody else is told who answered.

**Budget.** Every agent has limits: turns, tokens, wall-clock time. A team also has a
money budget on the plane that remote sessions reserve against. When a limit is
reached the agent stops and says which limit; it does not silently continue.

**Bundle.** The configuration a profile's sessions carry: agent definitions, skills and
MCP servers, published by an administrator in versions. A session is pinned to the
version current when it was created.

**Trigger and principal.** A trigger is a scheduled or externally fired job that
creates a session as a service principal (a non-person identity owned by a team).
Sessions made this way are flagged for review until somebody looks at them.

## What Troupe never does

* **It never reads your session content on the plane.** The plane stores who, which
  profile, which state, how much it cost. The transcript lives in the pod's log and in
  encrypted object storage that only pods can open. Administrators see metadata only;
  there is no administrative method that returns what a session said.
* **It never writes into your repository except through a tool you can see.** Every
  change to files goes through `write_file`, `edit_file`, `shell`, `publish`,
  `import` or a file upload you made yourself, and each of those is either an approval
  prompt or a durable event in the log. Nothing Troupe keeps for itself (config, logs,
  credentials) lands in your working directory.
* **It never approves its own shell commands unattended.** An unattended session
  either waits for a person or is configured to deny. There is no "auto" mode on the
  server side; `--auto-approve` is a choice a client makes for itself, and the log
  records that client as the approver.
* **It never runs a personal connector without your consent.** Offering your own MCP
  server to a session takes a second, deliberate confirmation, and every other
  participant sees that the session now uses something on your machine.

## Where to go next

* [getting-started.md](getting-started.md) — install, sign in, first session.
* [features.md](features.md) — every feature, with how to use it and its limits.
* [workflows.md](workflows.md) — step-by-step tasks.
* [cli-reference.md](cli-reference.md) — every command, flag, key and file path.
* [troubleshooting.md](troubleshooting.md) — what a symptom means and what to do.
* [../whitepaper.md](../whitepaper.md) — how it works underneath.
* [../admin/README.md](../admin/README.md) — the platform operator's side.
* [../developer/README.md](../developer/README.md) — building it.

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:5-10, 181-186, 244-248, 686-687
- apps/troupe_plane/lib/troupe/plane/harness.ex:5-9, 81-92, 172-192 (remote.ex), 561-576
- apps/troupe_plane/lib/troupe/plane/admin.ex:355-363
- apps/troupe_plane/lib/troupe/plane/repo.ex:5-8
- apps/troupe_core/lib/troupe/config.ex:46-57
- apps/troupe_core/lib/troupe/paths.ex:5-7
- apps/troupe_core/lib/troupe/session/approvals.ex:14-23
- apps/troupe_core/lib/troupe/session/client_tools.ex:9-20
- apps/troupe_core/lib/troupe/agent/definition.ex:11-12
- apps/troupe_core/priv/agents/build.md, plan.md, general.md, explore.md
- README.md:318-322
- docs/history/AUDIT.md §1.7
