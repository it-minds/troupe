# Glossary

Troupe's own words, one definition each, in alphabetical order. A page that uses one of
them for the first time links here.

### Agent

What talks to the model: a markdown file of instructions, the tools it may use and,
optionally, which model. A session starts with one, `build` (reads, edits and runs
commands) or `plan` (reads and proposes, never writes), and it may hand parts of its task
to subagents. Your own configuration, a workspace or a bundle can add more.

### Approval

The question a session asks before a tool that changes something runs: writing or editing
a file, running a command, and whatever else a configuration says asks. The answers are
allow, deny, or allow that tool for the rest of the session. Anyone attached with control
can answer and the first answer wins; with nobody attached, the call waits, or is denied
where the configuration says so.

### Branch

A session opened from another one in the terminal UI (`/code`, `/worktree`), with a window
of its own, often in its own worktree. Branches run side by side, and a window that needs
you says so.

### Budget

The limits after which a session stops and asks. On every agent: model calls, input tokens,
output tokens and time, set in `config.yaml`. On a plane, money as well: per team, per
person and for the platform. Reaching one asks, or stops when nobody can be asked; it never
carries on silently.

### Bundle

The agents, skills and MCP servers a profile's sessions carry, published on the plane in
versions. A session keeps the version that was current when it started.

### Client

Anything that attaches to sessions over [PROTOCOL.md](../PROTOCOL.md): the terminal UI
(`troupe`), the desktop app, the web app a plane serves at `/app`, or a program of yours.
None of them can do anything the protocol does not offer every client.

### Console

The plane's administration pages, at `/admin`: fleet, identity, teams, budgets, profiles,
policy, bundles, triggers, principals and the audit trail. Each button calls a method that
the admin API offers as well, over JSON-RPC and MCP.

### Daemon

`troupe-daemon`, the harness on your machine. It holds the sessions that run here, and
every client on the machine attaches to it. `troupe` runs one inside itself while it is
open when none is running on its own.

### Gateway

A proxy in front of model providers, such as LiteLLM or vLLM, reached with one URL and one
key. Troupe talks to one as an OpenAI-compatible provider with a `base_url`, and records the
cost a gateway reports for each call.

### Goal and loop

A goal is what a session is working towards (`/goal <text>` in the terminal UI); the agent
sees it on every turn until it is cleared. `/loop` lets the session work towards it on its
own, for a number of turns, until the agent says the goal is met or a limit is reached.

### Harness

The code that runs agents: the agent loop, the tools and the log. The same harness runs in
the daemon on your machine and on a worker pod.

### Log

A session's append-only, hash-chained record of everything that happened in it: each input,
model call, tool run and approval, and what the calls cost. The log is the session: every
view of it, every restart and every audit is read back from the log.

### MCP server

A program that gives an agent more tools over the Model Context Protocol: a database, a
browser, an issue tracker. Yours live in `mcp.json`, in the shape other agent tools use; a
workspace's and a bundle's are added to them.

### Operator

The Kubernetes controller that turns a profile into a namespace of worker pods, and the
policy into what those pods may do. It holds the cluster privileges and has no public
endpoint.

### Plane

The server your team signs in to. It knows who you are, which teams you are in, which
profiles they may use, where each remote session runs and what it cost, and never what a
session said.

### Policy

The platform's rules for every profile, as a `TroupePolicy`: which images, which hosts a
worker may reach, which ceilings apply. The operator refuses a profile that breaks it, and
so does the cluster on Kubernetes 1.30 or later.

### Principal

Whoever acts: a person, signed in through your identity provider, or a service principal.
Every event in a log names the principal behind it.

### Profile

A kind of worker, written as a `WorkerProfile`: an image, a model, tools, storage and which
bundle channel it follows. A remote session runs on one, and a team may use the profiles
granted to it.

### Project brief

`.troupe/memory.md` in a workspace: a short note on where things are and how to build and
test, which every agent reads first. A `librarian` session writes it and keeps it current.

### Provider

Where the model is: Anthropic, OpenAI, or any endpoint that speaks the OpenAI API. You bring
the key; Troupe calls it and counts what each call used.

### Service principal

A credential a team owns for work nobody starts by hand, named `svc:<team>/<name>`. It signs
in as a person does and can hold no admin role.

### Session

One agent, and the agents it delegates to, working in one workspace, with its log. It lives
in the daemon or on a worker pod, not in the window you look at it through, and it is
`active`, `dormant` (stopped with its log kept, woken when opened), `read_only` or `erased`;
a session being erased is `erasure_pending` until its key is destroyed.

### Skill

Instructions for one kind of job, in a directory with a `SKILL.md`, which an agent reads
when the job comes up. Yours, a workspace's and a bundle's, in the shape other agent tools
use.

### Team

A group from your identity provider that an administrator has enabled. It carries a budget,
how long its sessions are kept and the profiles it may use; who is in it is the identity
provider's business, not Troupe's.

### Trigger

A job that starts a session with no person at the keyboard, on a schedule or fired from
outside, as a service principal and on a budget of its own. Its sessions are flagged for
review until somebody has looked.

### Worker

A pod that runs the harness for the plane. A profile has one or more; each holds many
sessions, and a client reaches it directly over a WebSocket with a short-lived token.

### Workspace

The directory a session works in, usually a repository's checkout. Its `.troupe/` directory
holds what the repository wants: settings, agents, skills, MCP servers, workflows and the
project brief.

### Worktree

A git worktree Troupe makes so a branch works on its own copy of the checkout, merged or
discarded when it is done.
