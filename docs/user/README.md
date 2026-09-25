# Troupe for users

Troupe runs a coding agent for you. You give it a task in a directory; it reads, edits,
runs commands and reports back. The work lives in a **session**: a process on one of your
team's worker pods, or in the daemon on your own machine, and the window you look at it
through is only a window. Close it and the session carries on; open it from another
machine and you see the same transcript; two people can open the same session at once.

## Ways in

| Way in | What it is | Its documentation |
|---|---|---|
| `troupe` | the terminal UI, on the daemon on your machine; `troupe --remote` for your team's plane | [clients/tui](../../clients/tui/README.md) |
| The desktop app, or the GUI at your plane's `/app` | the graphical client: sessions on your machine and on the plane in one list, approvals from an inbox. **Use this computer only** on the sign-in screen skips signing in and never contacts a plane | [clients/gui](../../clients/gui/README.md); installing the unsigned desktop builds: [install.md](../../clients/gui/docs/install.md) |
| Your own program | anything that speaks [PROTOCOL.md](../../PROTOCOL.md) to a daemon or a pod | the protocol |
| Another agent | a profile called through the A2A facade | [a2a.md](../a2a.md) |

`install.sh` / `install.ps1` at the repository root install `troupe` and `troupe-daemon`
from the latest release. `troupe login <plane URL>` signs you in with a code you type in
your browser; you sign in where you always do, and Troupe never has a password of its own.

## Words you will meet

**Plane.** The server your team signs in to. It knows who you are, which teams you are in,
which profiles they may use and where every remote session runs. Never what one said.

**Team.** A group from your organisation's identity provider that an administrator has
enabled. It carries a budget, a retention period and the profiles it may use. You are in a
team because your identity provider says so; nobody edits membership in Troupe.

**Profile.** A kind of worker: an image, a model, some tools, some storage. A remote
session is created on one; with only one, you never have to name it.

**Session.** One agent working in one directory, with a durable log of everything that
happened: `active`, `dormant` (stopped, log kept, can be woken), `read_only`, or `erased`.

**Agent.** The thing that talks to the model. A session starts with one — `build`, or
`plan` for a proposal first — which may delegate to others. An agent is a markdown file;
your team's bundle or your own config can add more.

**Goal.** What a session is working towards: `/goal <text>` in the terminal UI. The agent
sees it on every later turn until `/goal clear`, and it survives a restart.

**Loop.** `/loop [n]` lets the session work towards its goal on its own, for up to `n`
turns (10 unless you say, `loop_max_iterations` in the config). Each turn ends with the
agent saying whether the goal is met, and the loop stops when it is, at the limit, after
three failed turns in a row, when the budget asks you, or on `/loop stop`. The status line
shows how far it has got, and you can keep typing while it runs.

**Approval.** Writing or editing a file and running a shell command ask first. The session
stops that one call and waits for allow, deny or allow-for-this-session. Anyone attached
with control rights can answer; the first answer wins and everyone is told who gave it.

**Budget.** Limits on turns, tokens and time, plus your team's money budget on the plane.
When one is reached the agent says which and asks, or stops; it never silently continues.

**Bundle.** The agents, skills and MCP servers a profile's sessions carry, published in
versions. A session is pinned to the version current when it started.

**Trigger.** A scheduled or externally fired job that starts a session as a service
principal. Such sessions are flagged for review until somebody looks at them.

## What Troupe never does

- **It never reads your session on the plane.** The plane holds who, which profile, which
  state and what it cost. The transcript lives in the pod's log and in storage encrypted
  under keys the plane cannot use. No administrative method returns what a session said.
- **It never writes where you cannot see.** Every file change goes through a tool that is
  either an approval prompt or a durable event in the log, and nothing Troupe keeps for
  itself lands in your working directory.
- **It never approves its own commands unattended.** An unattended session waits for a
  person or is configured to deny. `--auto-approve` is a choice a client makes for itself,
  and the log records that client as the approver.
- **It never uses your machine unasked.** Offering your own tool server to a session takes
  a deliberate confirmation, and everyone on the session sees it.

How it works underneath: [../../ARCHITECTURE.md](../../ARCHITECTURE.md). Running the
platform: [../admin/README.md](../admin/README.md).
