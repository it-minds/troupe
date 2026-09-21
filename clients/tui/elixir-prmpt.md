# Build Troupe: an actor-model coding harness with a TUI, in Elixir

You are building, from an empty directory, a local coding agent harness in Elixir. It ships as one self-contained executable per platform (Linux, macOS, Windows) built with Burrito, so users need no Erlang or Elixir installed. A coding harness is the runtime around an LLM that lets it work on a codebase: it runs the agent loop, exposes tools (read, edit, search, shell), streams model output, enforces permissions and budgets, and persists sessions. The feature set borrows three ideas: watch mode from Aider (AI comments in files trigger the agent), task lists and plan/build execution from opencode, and named, configurable subagents.

The defining property is that it is built all the way down on the actor model and OTP. Every agent is a process. Every in-flight LLM request is a process. Every tool execution is a process. Subagents are child processes. The file watcher and the TUI are processes. Processes share nothing, communicate only by message passing, and failure is handled by supervision rather than defensive code.

The defining *interaction* is that the user is never blocked. There is no resident assistant and no root conversation. The root of a session is a **dispatcher**: a plain process with no model attached that parses commands like `/code fix the failing test` or `/worktree add rate limiting`, spawns an independent **branch** (a supervised agent subtree) for each, and returns control immediately. Every branch is a window in the TUI. Branches run concurrently, side by side, on the same machine, and the user keeps issuing commands while they work. A window that needs the user (an approval, a question) blinks; the user activates it, answers, and focus flows back to where they were. When nothing is running, the harness is truly idle: zero LLM calls, zero tokens, for as long as it sits there. Multi-agent work is the default shape of the product, not a feature bolted onto a chat loop.

Work autonomously to completion. Do not ask me questions. When something is ambiguous, pick the option most consistent with this document, record it in `DECISIONS.md` with one line of rationale, and keep going.

## Stack

Elixir 1.20 (`elixir: "~> 1.20"`, 1.20.4 or later) on Erlang/OTP 28, pinned in `.tool-versions` together with the exact Zig version the pinned Burrito release requires (Burrito 1.5 hard-pins Zig 0.15.2 at time of writing; check). Mix project `troupe`. Your training data may predate 1.20 and current Burrito: read the v1.20 CHANGELOG and the Burrito README before writing code, and prefer their current idioms.

1.20 gradually type checks every line and infers types from guards, patterns, and clause order with no annotations. Design for it: keep the message protocol as tagged tuples and structs matched in function heads with guards, so the checker can narrow types and flag dead clauses in the state machine. Do not add Dialyzer. The compiler's type checker is the static analysis gate, and type warnings are fixed at the source, never silenced by laundering values through loosely typed helpers.

Dependencies: `req` (HTTP and SSE), `jason`, `telemetry`, `file_system` (native watch backends), `yaml_elixir` (config and agent frontmatter), `ex_ratatui` (TUI), `burrito` (packaging), `stream_data` for property tests, `credo` in dev. Every dependency must compile on 1.20. No Ecto, no Phoenix, no database. No MuonTrap: it has no Windows support, so OS process control goes through the reaper described under Tools.

## Supervision tree

The supervision tree mirrors the work. Branches are peers under the session, not children of a conversation. This is the core idea, not an implementation detail.

```
Troupe.Application (one_for_one)
├── Troupe.Registry            unique keys, every actor named via {:via, Registry, {session_id, agent_path}}
├── Troupe.Events              Registry with duplicate keys, pub/sub fan-out
├── Troupe.Sessions            DynamicSupervisor
│   └── Troupe.Session         Supervisor, rest_for_one, one per session
│       ├── Session.Log        single-writer append-only event store
│       ├── Session.Approvals  permission gate and user-question broker
│       ├── Session.Locks      advisory per-path write locks for shared-isolation branches
│       ├── Session.Branches   DynamicSupervisor, one_for_one; one child per dispatched command
│       │   └── Agent.Node     branch root (Supervisor, one_for_all)
│       │       ├── Agent.Tasks     Task.Supervisor for this agent's LLM streams and tool runs
│       │       ├── Agent.Children  DynamicSupervisor for nested subagents
│       │       │   └── Agent.Node  ...recursively
│       │       └── Agent.Server    :gen_statem, the agent itself
│       ├── Session.Dispatcher command parser and window ledger; no model, no budget
│       └── Session.Watcher    watch mode actor, last so its crashes never restart branches
└── Troupe.UI.Supervisor
    └── TUI.Server | Headless.Printer
```

`Session.Branches` starts before `Session.Dispatcher` on purpose: under `rest_for_one`, a Dispatcher crash restarts the Dispatcher and the Watcher but leaves every running branch untouched. The Dispatcher's state (which branches exist, their window states, what has been dismissed) is a fold over the session log, so it rebuilds itself on restart without asking anyone.

Consequences you must preserve: when a branch dies, its in-flight LLM stream, its tool runs, their OS processes, and its entire nested subagent subtree die with it. No orphans, ever, on any platform. Branches never depend on each other: one crashing, hanging, or waiting for approval has no effect on its siblings. Sessions never depend on the UI: the UI is just another subscriber to `Troupe.Events`, and it can crash, restart, and reattach without touching a running session. No process makes an LLM call unless a branch is running. You may refine the shape, but justify every change in `DECISIONS.md`.

## The dispatcher

`Session.Dispatcher` is a GenServer. It receives `{:command, name, args, source}` from the TUI, the CLI, or the Watcher, resolves `name` against the loaded agent definitions, and spawns an `Agent.Node` under `Session.Branches` with a fresh `branch_id`, the resolved definition, a budget from that definition, and the isolation mode. It replies with the branch's `agent_path` before the branch has done anything. It holds no conversation and calls no model.

It maintains the **window ledger**: for each branch, one of `:running`, `:needs_input`, `:done_unread`, `:failed_unread`, `:dismissed`. Transitions come from events: a branch entering an `ask` tool or an `ask_user` tool moves to `:needs_input` and back to `:running` when answered; `finish` or budget exhaustion moves to `:done_unread`; a Node exceeding restart intensity moves to `:failed_unread`; the user dismisses. `:done_unread` and `:failed_unread` are resting states, not exits: a finished window stays until the user dismisses it, and dismissal is itself a logged event. Nothing the user has not looked at is ever removed for them.

Free text at the dispatcher without a leading `/` is not a command. It is rejected with a one-line hint listing the available commands. There is no default agent and no routing model. If the user wants an LLM to interpret intent, they invoke one with `/ask`.

## The agent actor

`Agent.Server` is a `:gen_statem` with at least these states: `:idle`, `:thinking` (an LLM stream process is running), `:acting` (tool runs and possibly approvals outstanding), `:compacting`, `:done`. Input arriving while busy (from the user in the activated window, or from the watcher) is postponed using gen_statem postpone, not dropped and not queued in a hand-rolled list. Cancellation is valid from any state and kills the current stream and tool tasks.

The agent's mailbox never blocks. The LLM request runs in its own task process and streams back as messages. Multiple tool calls from one model turn run concurrently, and results are reassembled in tool_call order before the next turn.

A branch that has finished (`finish` tool called, or budget exhausted) is in `:done` and makes no further LLM calls. The user can activate a `:done_unread` window and send a follow-up; that transitions the same server back to `:idle` with its conversation intact and moves the window to `:running`. This is how a finished branch is continued without re-dispatching.

Define the complete message protocol in `ARCHITECTURE.md` and implement exactly that. Minimum set: `{:command, name, args, source}`, `{:input, source, content}` where source is `:user | :watch | :tui_todo_edit`, `{:llm_delta, ref, delta}`, `{:llm_done, ref, response}`, `{:llm_error, ref, reason}`, `{:tool_result, call_id, result}`, `{:approval, call_id, :allow | :deny}`, `{:answer, call_id, text}`, `{:child_result, ref, result}`, `{:branch_state, agent_path, state}`, `{:switch_profile, name}`, `{:dismiss, agent_path}`, `{:DOWN, ...}`, `:cancel`. Every request carries a ref and a timeout. Unknown messages are logged and dropped, never a crash.

No synchronous calls between agents. `GenServer.call` / `:gen_statem.call` is allowed only from the public client API into a session and from an agent into non-agent session actors (Log, Approvals, Locks) that never call back. Agent to agent, parent to child, child to parent, and dispatcher to branch traffic is async `send` with refs and monitors, because mutual calls deadlock.

## Failure semantics

Let it crash, with one deliberate exception: a tool that raises, times out, or exits becomes an error `tool_result` for the model and the agent keeps running, because the model needs the feedback to self-correct. Everywhere else, do not wrap the agent loop in `try/rescue`.

Branch failure: if a branch's Node exceeds its restart intensity, the Dispatcher receives `:DOWN`, marks the window `:failed_unread` with the reason, and every other branch is unaffected. Nested subagent failure inside a branch: the parent agent receives `:DOWN`, converts it into an error result for that delegation only, and siblings are unaffected.

Persistence and recovery: `Session.Log` writes JSONL to the platform state dir (`$XDG_STATE_HOME/troupe` on Linux and macOS, `%LOCALAPPDATA%\troupe` on Windows) under `sessions/<workspace-hash>/<session-id>/events.jsonl`, never into the user's repo. Every event is tagged with `agent_path`, monotonic `seq`, and timestamp. Log writes are synchronous from the agent's perspective, so an agent never acts on something that was not persisted. Agent state (conversation, todo list, active profile) is a fold over its own events: on start or restart, `Agent.Server` rebuilds state by replaying them. Log `tool_call_started` before a run and `tool_call_completed` with its result after. On replay, completed calls are never re-executed. Calls that started but never completed are re-run (at-least-once) and this is documented. On session resume, branches that were `:running` are re-spawned and continue; `:done_unread`, `:failed_unread`, and `:needs_input` windows come back exactly as they were. Outstanding nested delegations are re-spawned as fresh children.

Budgets are per branch and message-based, with no shared counter actor. Each branch's root agent gets its limits (max turns, input/output tokens, wall clock) from its definition, overridable per command. Inside a branch, budgets are hierarchical: a nested delegation carries a `budget_share` slice from its parent, and the child reports usage back in its result. On exhaustion the agent goes to `:done` with reason `:budget_exhausted` and makes no further LLM calls; the window moves to `:done_unread`. The Dispatcher has no budget because it never calls a model.

## Agents, profiles, and subagents

An agent definition is a markdown file with YAML frontmatter. The body is the system prompt. Frontmatter: `description`, `mode` (`primary | subagent`), `model`, `isolation` (`shared | worktree`, primary only, default `shared`), `tools` (allowlist), `permissions` (per tool: `auto | ask | deny`), `max_turns`, `budget_share`. The filename is the name. Every `primary` definition is a command: `/<name> <prompt>`. `subagent` definitions are reachable only through `delegate`. Precedence is project `.troupe/agents/` over the global config dir's `agents/` over built-ins. Definitions load once at session start into an immutable snapshot passed down in Node specs; no global definitions process.

`model` is either a provider model id or one of the aliases `default` and `cheap`, resolved from config (`models.default`, `models.cheap`; `TROUPE_MODEL` sets `default`). This is how a cheap model runs exploration and synthesis while an expensive one does the editing, without the model ever choosing a model: it chooses an agent by name and the harness resolves the rest.

Built-ins:

- `code` (primary, all tools, `shared`, `default` model): the workhorse. `/code fix the flaky test in auth`.
- `worktree` (primary, all tools, `worktree` isolation, `default` model): same prompt as `code`, runs in its own git worktree. `/worktree add rate limiting to the API`.
- `plan` (primary, read-only tools plus the todo tools, writes and shell denied, `default` model): investigates and writes a task list. `/plan how should we split the billing module`.
- `ask` (primary, read-only tools plus `read_branch`, `cheap` model): answers a question across the session. Its `read_branch` tool returns the final summary and todo list of any finished branch, so it can synthesize what several branches concluded. `/ask what did the three worktree branches change, and do they conflict`. Nothing holds the thread across branches; this is how the user gets one on demand, cheaply, without anything resident.
- `general` (subagent, all tools, `default` model).
- `explore` (subagent, read-only, `cheap` model).

Each branch runs a primary profile, and the profile can be switched inside that branch: Tab in an activated window sends `{:switch_profile, name}`, applied at the next turn boundary. System prompt, tools, and permissions change; conversation and todo list persist. This is how plan-then-build works: `/plan` investigates and writes the task list, the user reads it, activates the window, switches the profile to `code`, and says go.

Subagents are spawned inside a branch through the `delegate` tool with an `agent` parameter. The tool's description is generated from the subagent definitions, including each one's model alias and description, so the model can choose on cost and capability. Delegation is fan-out/join within a turn: the model emits several `delegate` calls in one turn, they run concurrently as children, and the results are reassembled before the next turn. Top-level concurrency is the user's, via commands, not the model's. Tool allowlists are enforced by the harness, not trusted to the model: a call outside the allowlist, or a `deny` permission, returns an error tool_result and the tool never runs. Delegation depth is capped (default 3), and exceeding it is an error tool_result.

## Isolation

Two branches editing one working tree with no shared picture is the failure mode this design invites, so isolation is declared at dispatch, never inferred.

`shared`: the branch works in the user's checkout. `write_file` and `edit_file` acquire a per-path lock from `Session.Locks` for the duration of the call. Contention returns an error tool_result naming the holding branch, so the model can retry or work elsewhere. Locks are advisory: `shell` cannot be locked, and the tool description says so.

`worktree`: at spawn, the branch runs `git worktree add .troupe/worktrees/<branch_id> -b troupe/<branch_id>` and that worktree becomes the branch's workspace root for path confinement. `.troupe/worktrees/` is added to `.git/info/exclude`. On `finish`, the branch commits its changes on its own `troupe/` branch inside the worktree and the window shows the diff stat. The user's checkout is never committed to automatically. From the window the user chooses `/merge` (merge with a merge commit into the checked-out branch; conflicts are shown and left for the user) or `/discard` (remove the worktree and delete the `troupe/` branch). A dismissed worktree window without either choice keeps the worktree and says so.

## Task list

Each agent owns a todo list in its state. Tools: `todo_write` replaces the whole list (items: `id`, `content`, `status` of `pending | in_progress | completed | cancelled`), and `todo_read` returns it. At most one item is `in_progress` per agent. A write violating that returns an error tool_result. The list is persisted via events and survives restarts through replay.

Execution discipline goes in the built-in prompts, verbatim: "For any task with more than two steps, write the todo list first. Mark an item `in_progress` before starting it and `completed` immediately after. When items are independent, delegate them to subagents in one turn so they run in parallel; prefer `explore` for reading and searching because it is cheaper." Each window shows its branch's list with each nested subagent's list under its delegation. The user can cancel or add items from the window. That sends `{:input, :tui_todo_edit, change}`, and the change is reflected in the agent's next request context.

## Watch mode

`Session.Watcher` implements Aider-style AI comments, toggled with `--watch` or `/watch`. It has two interchangeable backends behind one behaviour: `file_system` where its native watcher is available, and a polling backend (mtime and size scan of non-ignored files) used automatically when it is not. On Linux, `file_system` needs `inotifywait`, which a clean machine does not have, so the single binary must still work there via polling, with a one-line TUI notice. Both backends ignore `.gitignore`d paths, `.git/`, and `.troupe/worktrees/`, and bursts of changes are debounced (default 300ms) into one scan.

Markers are comments in any common syntax (`#`, `//`, `--`, `;`, `%`, `/* */`, `<!-- -->`) that start or end with `AI`, case-insensitive. A comment ending in `AI!` is a change request; the watcher sends `{:command, "code", payload, :watch}` to the Dispatcher, which spawns a `code` branch like any other. A comment ending in `AI?` is a question; it spawns a `plan` branch, which cannot edit. Bare `AI` comments anywhere in the workspace are collected as context and sent along with the next trigger. The payload carries each marker's file, line, comment text, and surrounding code. The built-in prompt instructs the agent to remove processed markers as part of its edit. Watch-spawned windows appear, blink, and rest exactly like user-spawned ones.

The harness must never trigger itself. Before any file write, the write and edit tools send `{:expect_write, path, content_hash}` to the watcher, which drops change events whose current content hash matches an expected write.

## LLM providers

Internal message format is provider-neutral content blocks (text, tool_use, tool_result). Behaviour `Troupe.LLM.Provider` with `stream(request, reply_to, ref)`, executed inside the agent's task process. Retries with jittered backoff on 429 and 5xx happen inside that process; the agent only ever sees a final outcome or error. Several branches sharing one API key will hit rate limits together; that is absorbed here, per stream, and never surfaces as a crash.

Implement three adapters. Anthropic Messages API with native tool use and SSE. OpenAI-compatible Chat Completions with function calling and SSE, working against any base URL (LiteLLM, vLLM, Mistral and similar). Fake, a deterministic scripted provider that records every request it receives, used by all tests and selectable in release builds via `TROUPE_PROVIDER=fake` plus a script file, so packaged binaries can be smoke-tested without a model.

Track token usage from provider responses. When context passes a configurable fraction of the model window, enter `:compacting`: a summarizer call replaces older turns with a summary, keeping the system prompt, the last N turns, the current todo list, and any unresolved tool calls. Log the compaction as an event.

## Tools

Behaviour `Troupe.Tool`: `name/0`, `description/0`, `schema/0` (JSON Schema), `default_permission/0`, `run(args, ctx)` returning `{:ok, content} | {:error, reason}`. `ctx` carries the branch's workspace root and isolation mode.

Built-ins: `read_file` (line ranges, output capped), `write_file`, `edit_file` (exact string replacement that fails on zero or multiple matches, preserving the file's existing line endings), `list_files` (glob), `grep` (ripgrep when present, built-in fallback otherwise), `shell`, `todo_write`, `todo_read`, `delegate` (the child's final summary comes back to the parent, never its transcript), `finish` (how an agent returns its result; for a branch root this ends the branch), `ask_user` (blocks the call until the user answers in the window; may offer `options` the user picks by number, singly or with `multiple`; moves the window to `:needs_input`; permission `auto`), `read_branch` (returns another finished branch's final summary and todo list from the log; `ask` only).

`shell` runs `bash` on Linux and macOS. On Windows it uses `bash` from Git for Windows when found, otherwise `pwsh`, otherwise `powershell.exe`. The tool description tells the model which OS and shell it has. Default timeout 120s, output capped.

Every shell command runs under `reaper`, a small helper you write in Zig (`native/reaper/`) and cross-compile per target with the same Zig toolchain Burrito already requires (Linux targets as static musl). The contract is identical on every OS: reaper starts the command with stdin from the null device, blocks reading its own stdin, and on EOF kills the command's entire process tree, then exits with the command's status. On Unix it uses `setsid` and signals the process group (TERM, a 2s grace, then KILL). On Windows it assigns the child to a Job Object with kill-on-close. The Elixir tool task owns the Port running reaper, so every way the owner can die (cancel, agent crash, supervisor shutdown, the whole VM being SIGKILLed or force-terminated) closes the pipe and reaps the tree.

Every path is resolved against the branch's workspace root with symlinks followed (and junctions on Windows, with case-insensitive comparison and drive letters and UNC paths handled), and anything escaping it is rejected. `ask` tools and `ask_user` block the call (not the agent) until `Session.Approvals` sends the answer. Every approval and question event carries the `agent_path` so the right window blinks. A denial becomes a tool_result the model can read.

## TUI

`troupe` run in a directory opens the TUI with that directory as the workspace. The screen is a tiling window manager for branches with a notification tray, and it should borrow those interaction rules directly.

Layout: a **command line** at the bottom, always focused by default and always accepting commands regardless of what is running; a **window strip** of one pane per non-dismissed branch, each showing the branch name, state, elapsed time, token use, and a live tail of its transcript; and an **activated pane**, when one is activated, that expands to show that branch's full streaming markdown transcript with collapsible tool calls, its todo list, and its nested agent tree. Windows are ordered by creation and keep their position for their whole life. Completed and failed windows dim; they do not close.

Attention: a window in `:needs_input` blinks its border and shows what it needs (the approval with a diff preview for writes and edits or the full command for shell; or the agent's question). A window entering `:done_unread` or `:failed_unread` gets a highlight badge until activated. The command line shows a one-line summary of pending attention (`2 need input, 1 done`). No window ever steals focus on its own.

Keys: `1`–`9` or Enter on a window activates it; Esc returns focus to the command line, leaving the window where it was; `y`/`n`/`a` answer an approval in the activated window (allow, deny, allow-for-session); typing in an activated window and pressing Enter sends `{:input, :user, text}` or `{:answer, call_id, text}` to that branch; Tab in an activated window switches its profile; `x` cancels the activated branch; `d` dismisses a resting window; Ctrl-C twice quits. Commands: `/<agent> <prompt>` for every primary agent (`/code`, `/worktree`, `/plan`, `/ask` built in), `/watch`, `/cancel [path]`, `/dismiss [path]`, `/merge [path]`, `/discard [path]`, `/agents`, `/sessions`, `/resume`. `@file` completion works on the command line and in activated windows.

Build it on ExRatatui (Rust ratatui via Rustler, crossterm backend, precompiled NIFs for Linux x86_64/aarch64, macOS x86_64/aarch64, and Windows x86_64). `TUI.Server` is an `ExRatatui.App` subscribed to `Troupe.Events`. Use ExRatatui's headless test backend for snapshot tests.

The TUI must never slow an agent down. It coalesces incoming deltas and redraws at most 30 times per second, and when its mailbox passes a threshold it collapses queued deltas rather than processing them one by one. After a crash or restart it rebuilds the screen, including every window and its state, from the session log.

Headless mode (`troupe run code "task" --headless`) renders the same event stream as plain lines prefixed by `agent_path`, for CI and scripting, and exits when the branch rests.

## CLI and config

`troupe` (TUI), `troupe --watch`, `troupe run [AGENT] "task" [--headless] [--worktree] [--auto-approve]` (AGENT defaults to `code`), `troupe resume [SESSION_ID]`, `troupe --version`. Read arguments through Burrito's argv helper so they survive the wrapper. Config in YAML in the platform config dir (`$XDG_CONFIG_HOME/troupe/config.yaml` on Linux and macOS, `%APPDATA%\troupe\config.yaml` on Windows), overridden key-wise by project `.troupe/config.yaml`, overridden by env (`TROUPE_PROVIDER`, `TROUPE_BASE_URL`, `TROUPE_API_KEY`, `TROUPE_MODEL`). Config keys include `models.default`, `models.cheap`, and `max_branches` (default 8; the Dispatcher refuses a command past it with a message, never queues silently). Client API for tests and embedding: `Troupe.start_session/1`, `dispatch/3`, `send_input/3`, `subscribe/1`, `cancel/2`, `dismiss/2`, `resume/1`.

Emit `:telemetry` events for LLM request start/stop, tool start/stop, state transitions, and window state transitions. Registry naming must make `:observer` show the branches and their nested delegation trees legibly.

## Packaging and distribution

Burrito wraps the release into one executable per target: `linux_x86_64`, `linux_aarch64`, `macos_x86_64`, `macos_aarch64`, `windows_x86_64`. Output names `troupe-<version>-<target>` (`.exe` on Windows). Windows on ARM runs the x86_64 build under emulation.

Build each target on a native runner in a CI matrix (GitHub Actions syntax, which Forgejo Actions also runs), one `BURRITO_TARGET` per job. Do not attempt a single-host build of all targets: the precompiled NIF download and `file_system`'s macOS backend both resolve against the build host. The workflow produces all five artifacts plus a `SHA256SUMS` file. Also provide `scripts/build-local` that builds the current host's target for development.

Burrito's prebuilt Linux ERTS is musl-based at time of writing. The ExRatatui NIF in the payload must match the ERTS libc: use ExRatatui's Burrito packaging guide as the reference, and prove the result by running the Linux binary in both a glibc and a musl container.

Installers take a configurable base URL (`TROUPE_RELEASE_URL`) so artifacts can live on a Forgejo release or an S3-compatible bucket rather than hardwired to one host. They detect OS and architecture, download the matching artifact and `SHA256SUMS`, verify the checksum and abort on mismatch, and never execute anything unverified.

`install.sh` (Linux and macOS, POSIX sh) installs to `~/.local/bin/troupe` and adds that to PATH in `~/.zshrc`, `~/.bashrc`, or `~/.profile` only if missing. `install.ps1` (Windows PowerShell 5.1 and 7) installs to `%LOCALAPPDATA%\Programs\troupe\troupe.exe` and adds it to the user PATH. Both are idempotent, upgrade in place, keep the previous binary for rollback, and support uninstall (removing the binary, the PATH entry, and Burrito's extracted payload cache, and keeping config and state unless purge is requested). Downloading with curl or `Invoke-WebRequest` avoids the macOS quarantine attribute. Document Gatekeeper and SmartScreen behaviour for unsigned binaries in the README.

## Forbidden

A central GenServer that everything funnels through. A model attached to the Dispatcher, or any LLM call while no branch is running. Elixir's `Agent` module used as a state bag. ETS or `:persistent_term` as shared mutable conversation state. Bare `spawn` without supervision, link, or monitor. `Process.sleep` in tests to wait for async work (use `assert_receive` and telemetry). Any agent-to-agent synchronous call. Any path where a slow UI applies backpressure to an agent. Any window closing, or focus moving, without the user doing it. Any OS process started outside reaper.

## Working order

First write `ARCHITECTURE.md`: supervision tree, agent state machine (states, events, transitions), window state machine, full message protocol, and a failure matrix listing for each process what kills it, what restarts, and what the user and the model observe. Then scaffold the project, the Fake provider, and the done-definition below as failing tests. Build the core until green (dispatcher and a single branch first, then concurrent branches), then reaper, then isolation, then watch mode, then the TUI, then real providers. Spike a Burrito build of the skeleton for all five targets early, before the TUI, so packaging problems surface while the codebase is small. Finish with the CI matrix and installers.

## Done means all of these pass, with command output shown

Core:

1. `elixir --version` reports 1.20.x on OTP 28. `mix compile --force --warnings-as-errors` succeeds with zero type warnings, plus `mix format --check-formatted`, `mix credo --strict`, and `mix test` green across 10 consecutive runs (`for i in $(seq 10); do mix test || exit 1; done`).
2. Single-branch loop: `dispatch("code", ...)` with a Fake that scripts `read_file`, then `edit_file`, then `finish`. The file on disk has changed, the event log contains the expected sequence, and the window ends `:done_unread`.
3. Parallelism: three tool calls in one turn, each taking 500ms, complete in under 1s total.
4. Crash recovery: `Process.exit(agent_server, :kill)` during `:acting`. The Node restarts it, state (conversation, todo list, profile) is rebuilt from the log, the branch finishes, and no completed tool call executed twice.
5. Tool isolation: a tool that raises yields an error tool_result and the agent server pid is unchanged.
6. Cancellation: cancel during a `shell` call running a 60s sleep that spawns a grandchild. Both processes are gone within 1s, verified by OS pid.
7. Hard VM death: SIGKILL the VM (or `taskkill /F` on Windows) during the same command. Child and grandchild are gone within 3s.
8. Budget: with `max_turns: 2`, the branch stops with `:budget_exhausted`, the window is `:done_unread`, and the Fake provider records exactly 2 calls.
9. Path confinement: `../../etc/passwd` and a symlink pointing outside the workspace are rejected. On Windows, also `..\..\Windows\System32`, another drive letter, a UNC path, a junction, and a case-variant of the workspace path used to escape it.
10. Approvals: an `ask` tool blocks until allow; deny produces a readable denial tool_result. The `{:branch_state, _, :needs_input}` event carries the correct `agent_path`.
11. Property test: random interleavings of dispatch, input, cancel, dismiss, profile switches, and unknown messages never crash a branch or the Dispatcher, and every branch always ends in `:idle` or `:done`.
12. `edit_file` on a CRLF file keeps CRLF line endings.

Dispatcher and branches:

13. Concurrency: four `/code` commands in quick succession produce four running branches with distinct `agent_path`s; the Fake records four interleaved streams; all four rest `:done_unread`. In a second test one branch crashes past its restart intensity; its window is `:failed_unread` and the other three finish.
14. No orphans: killing a branch Node leaves zero live processes under its subtree, verified via Registry lookup and `Process.alive?`.
15. Truly idle: a session open for 60s with no commands makes zero Fake calls and has no `Agent.Node` alive. A session with two `:done_unread` windows behaves the same.
16. Dispatcher crash: `Process.exit(dispatcher, :kill)` while two branches run. Both branches' Fake call counts keep increasing, and the restarted Dispatcher's window ledger matches the pre-crash one.
17. Resume: a session with one `:running`, one `:needs_input`, and one `:done_unread` branch is stopped and resumed. The running branch continues, the waiting one still waits with the same pending call, and the done one is still `:done_unread`. Dismissed windows do not come back.
18. Continue: sending input to a `:done_unread` branch returns it to `:running`, and the next Fake request contains the prior conversation.
19. `max_branches`: the ninth command with the default config is refused with a message and no Node is started.
20. Definitions: a project `.troupe/agents/explore.md` overrides the built-in. An `explore` subagent calling `write_file` gets an error result and the file is untouched. Depth past the cap is rejected. The generated `delegate` description names each subagent's model alias.
21. Profiles: under `plan`, `write_file` and `shell` are rejected. After Tab to `code` in that window, the next Fake request contains the prior conversation and the todo list and uses the code tool set.
22. Todo: two `in_progress` items return an error tool_result. A window cancel of an item appears in the agent's next Fake request.
23. `ask`: with two finished branches in the log, `/ask` on the `cheap` alias resolves to the configured cheap model, and its `read_branch` results appear in its Fake request.

Isolation:

24. Shared locks: two `shared` branches `edit_file` the same path at once. One succeeds, the other gets an error tool_result naming the holder, and both branches finish.
25. Worktree: a `/worktree` branch writes a file. The user's checkout does not contain it and `git status` there is clean. After `/merge` the file is present and a merge commit exists. A second `/worktree` branch followed by `/discard` leaves no worktree and no `troupe/` branch.

Watch mode, run once per backend (native and polling):

26. Writing `# make this return 42 AI!` to a watched file spawns exactly one `code` branch whose first Fake request contains the file, line, and comment, with a bare `AI` comment from another file included as context. Five writes within 300ms produce one branch. The harness's own edit to that file does not retrigger. A `.gitignore`d file with a marker is ignored. An `AI?` marker spawns a `plan` branch that cannot write files.

TUI:

27. Snapshot tests on ExRatatui's headless backend cover the window strip with `:running`, `:needs_input`, `:done_unread`, and `:failed_unread` windows, an activated pane with transcript and todo list, an approval prompt with diff, and an `ask_user` question.
28. Focus: an approval arriving in window 2 while window 1 is activated does not move focus; Esc, `2`, `y`, Esc returns to the command line with window 1 unchanged.
29. Killing `TUI.Server` mid-stream leaves every branch running with unchanged Fake call counts, and the TUI restarts and redraws every window from the log.
30. Backpressure: flooding 10k deltas across four branches while the TUI renders slowly does not increase any branch's turn latency, and the TUI mailbox stays bounded.

Packaging:

31. The CI matrix produces all five artifacts and `SHA256SUMS`. On each native runner, the artifact prints `troupe --version` and completes `troupe run code --headless` against a Fake script that exercises `write_file` and `shell` through reaper.
32. The Linux x86_64 binary does the same in clean `ubuntu:24.04` and `alpine` containers with no Erlang, no Elixir, and no inotify-tools installed, with watch mode falling back to polling.
33. Warm start to first TUI frame is under 2s on Linux. Cold first-run extraction time and binary size are reported per target.
34. Installers: `install.sh` in a clean `ubuntu:24.04` container with a zsh user, and `install.ps1` on the Windows runner, each install, re-run as a clean upgrade, and uninstall leaving no files outside config and state. A corrupted artifact fails the checksum and nothing is installed.

Acceptance:

35. Manual, with a real model: `fixtures/sample_repo` contains a small Elixir project with one failing test. `troupe run code "make the tests pass" --workspace fixtures/sample_repo --headless --auto-approve` ends with that project's tests green.
36. Manual, with a real model: in the TUI, dispatch `/worktree` twice with unrelated tasks and `/plan` once within ten seconds. All three windows stream concurrently, the command line stays responsive throughout, an approval in one window blinks without moving focus, and `/ask what changed` after they rest summarizes all three from the log.

## Out of scope

Web UI, MCP client, multi-node distribution, a resident assistant or free-text routing at the dispatcher, auto-commit or undo in the user's checkout, auto-update, code signing and notarization, native Windows ARM builds. Do not block them: the Tool behaviour must allow an MCP adapter later, nothing should assume a single node beyond the local Registry, and the TUI must not preclude serving it over ExRatatui's SSH transport later.

## Final report

End with a short report: each done item and the command that proves it, every deviation from this document with its `DECISIONS.md` entry, binary size and cold/warm start per target, and known limitations.
