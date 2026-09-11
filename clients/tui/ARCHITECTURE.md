# Troupe architecture

Troupe is a local coding-agent harness built on the actor model. Every agent,
LLM stream, tool run, subagent, watcher and UI is a process; they share nothing
and talk only by message passing. This document is the contract the code
implements: supervision tree, agent state machine, window state machine, the
complete message protocol, the persisted event schema, and the failure matrix.

## 1. Supervision tree

```
Troupe.Application (one_for_one)
├── Troupe.Registry            Registry, :unique. Every actor: {:via, Registry, {Troupe.Registry, {session_id, key}}}
├── Troupe.Events              Registry, :duplicate. Pub/sub fan-out keyed by session_id
├── Troupe.Sessions            DynamicSupervisor
│   └── Troupe.Session         Supervisor, rest_for_one, one per session
│       ├── Session.Log        GenServer, single-writer append-only JSONL event store + publisher
│       ├── Session.Memory     GenServer, owns .troupe/memory.md (the project brief)
│       ├── Session.Approvals  GenServer, permission gate and user-question broker
│       ├── Session.Locks      GenServer, advisory per-path write locks
│       ├── Session.Branches   DynamicSupervisor, one_for_one; children are :temporary Agent.Node
│       │   └── Agent.Node     Supervisor, one_for_all, max_restarts 3 / 5s
│       │       ├── Agent.Tasks     Task.Supervisor (LLM stream tasks, tool tasks)
│       │       ├── Agent.Children  DynamicSupervisor (nested Agent.Node, recursively)
│       │       └── Agent.Server    :gen_statem, the agent
│       ├── Session.Dispatcher GenServer, command parser + window ledger, no model
│       └── Session.Watcher    GenServer, watch mode (AI comments), started last
└── Troupe.UI.Supervisor (one_for_one)
    └── Troupe.UI.TUI.Server | Troupe.UI.Headless.Printer | (nothing under `mix test`)
```

Registry keys (all under `{session_id, key}`):

| key                       | process            |
|---------------------------|--------------------|
| `:session`                | Troupe.Session     |
| `:log`                    | Session.Log        |
| `:memory`                 | Session.Memory     |
| `:approvals`              | Session.Approvals  |
| `:locks`                  | Session.Locks      |
| `:branches`               | Session.Branches   |
| `:dispatcher`             | Session.Dispatcher |
| `:watcher`                | Session.Watcher    |
| `{:node, agent_path}`     | Agent.Node         |
| `{:tasks, agent_path}`    | Agent.Tasks        |
| `{:children, agent_path}` | Agent.Children     |
| `{:agent, agent_path}`    | Agent.Server       |

`agent_path` is `"<name>-<n>"` for a branch (`code-1`) and
`"<parent>/<name>-<n>"` for a nested subagent (`code-1/explore-1`). `n` is a
per-parent counter folded from the log, so paths are stable across restarts.

Ordering guarantees that matter:

* `Session.Branches` starts before `Session.Dispatcher`; under `rest_for_one` a
  Dispatcher crash restarts only Dispatcher and Watcher. Branches keep running.
* `Session.Watcher` is last; its crash restarts nothing else.
* `Agent.Node` children are `:temporary` in `Session.Branches`: once a Node
  exhausts its own restart intensity it is gone, and the Dispatcher (which
  monitors it) records `:failed_unread`. Siblings are untouched.
* `Agent.Node` is `one_for_all`: an `Agent.Server` crash also restarts
  `Agent.Tasks` and `Agent.Children`, which kills the in-flight LLM stream,
  every tool task (and through the reaper, every OS process), and every nested
  subagent subtree. The server then rebuilds its state from the log.
* Finished branches release their Node (Decision 6): when the Dispatcher sees
  `branch_state: :done_unread` it terminates the Node. A `:done_unread` window
  therefore has no live processes; "continue" re-spawns a Node for the same
  `agent_path` and the fold over the log restores the conversation.
* The UI is a subscriber of `Troupe.Events`. Sessions never call it.

## 2. Agent state machine (`Agent.Server`, `:gen_statem`)

States: `:idle`, `:thinking`, `:acting`, `:compacting`, `:done`.

```
              input                    llm_done(tool calls)
   idle ───────────────▶ thinking ─────────────────────────▶ acting
    ▲                      │  ▲                                │
    │  llm_done(text only) │  │ all tool_results in, no finish │
    │  = implicit finish   │  └────────────────────────────────┘
    │                      │        (budget ok)          finish called │ budget exhausted
    │                      ▼                                          ▼
    │                   done ◀────────────────────────────────────── done
    │                      │
    └──── input ───────────┘  (continue: done -> idle -> thinking)

  thinking ──llm_done, context over threshold──▶ compacting ──llm_done──▶ (acting | thinking)
  any state ──:cancel──▶ done(:cancelled)
```

Events and transitions:

| state        | event                                          | action                                                                                        | next        |
|--------------|------------------------------------------------|-----------------------------------------------------------------------------------------------|-------------|
| idle         | `{:input, source, content}`                    | log `input`; apply pending profile; budget check; start stream task                           | thinking / done(:budget_exhausted) |
| idle         | `{:switch_profile, name}`                      | log `profile_switched` (applied at next request)                                              | idle        |
| idle         | `{:input, :tui_todo_edit, change}`             | log `todo_updated`                                                                            | idle        |
| thinking     | `{:llm_delta, ref, delta}`                     | publish transient `llm_delta`                                                                 | thinking    |
| thinking     | `{:llm_done, ref, response}`                   | log `assistant_message`; if over compaction threshold -> compacting; tool calls -> acting; text only -> done(:finished) | acting / compacting / done |
| thinking     | `{:llm_error, ref, reason}`                    | log `llm_error`                                                                               | done(:llm_error) |
| thinking     | `{:input, _, _}`, `{:switch_profile, _}`       | **postpone**                                                                                  | thinking    |
| acting       | (entry) for each tool_use in order             | allowlist/permission check -> error result, or `approval_requested` + `branch_state needs_input`, or log `tool_call_started` and start task / run inline | acting |
| acting       | `{:approval, call_id, :allow}`                 | log `approval_answered`; start task                                                           | acting      |
| acting       | `{:approval, call_id, :deny}`                  | log `approval_answered`; synthesize denial tool_result                                        | acting      |
| acting       | `{:answer, call_id, text}`                     | log `question_answered`; tool_result = text                                                   | acting      |
| acting       | `{:tool_result, call_id, result}`              | log `tool_call_completed`; when none outstanding -> `branch_state running`; next turn         | acting / thinking / done |
| acting       | `{:child_result, ref, result}`                 | log `delegation_completed` + `tool_call_completed`                                            | acting      |
| acting       | `{:DOWN, ref, :process, pid, reason}` (child)  | error tool_result for that delegation only                                                    | acting      |
| acting       | `{:DOWN, ...}` (tool task crashed)             | error tool_result for that call                                                               | acting      |
| acting       | `{:input, _, _}`, `{:switch_profile, _}`       | **postpone**                                                                                  | acting      |
| compacting   | `{:llm_done, ref, summary}`                    | log `compaction`; continue with the turn that was interrupted                                 | acting / thinking |
| compacting   | `{:llm_error, ref, _}`                         | log `llm_error`; continue without compacting                                                  | acting / thinking |
| compacting   | anything from the user                         | **postpone**                                                                                  | compacting  |
| done         | `{:input, :user, content}`                     | log `branch_state running`; log `input`; -> idle -> thinking                                  | thinking    |
| done         | `{:switch_profile, name}`                      | log `profile_switched`                                                                        | done        |
| any          | `:cancel`                                      | kill tasks + children; log `cancelled`; `branch_state done_unread`                            | done(:cancelled) |
| any          | unknown message                                | `Logger.warning`, drop                                                                        | same        |

Postponement uses `{:next_event, ...}`/`:postpone` from `:gen_statem`; nothing
is queued by hand. Every tool task and stream task is monitored; every message
from them carries the ref/call_id of the work it belongs to and stale refs are
dropped.

Budgets: `max_turns` (LLM calls), `max_input_tokens`, `max_output_tokens`,
`max_wall_clock_ms`, checked before every stream start. A child receives
`budget_share` (a fraction) of the parent's remaining turns and tokens and
reports its usage in `child_result`.

Replay: on start the server folds its own events (`Troupe.Agent.State.apply/2`)
then decides where it is:

* status done -> `:done`;
* last assistant message has tool calls not completed -> `:acting`, re-running
  started-but-not-completed calls (at-least-once; documented) and re-registering
  pending approvals/questions with `Session.Approvals`, and re-spawning
  outstanding delegations as fresh children;
* otherwise the last message is user input or a completed tool turn ->
  `:thinking` (new stream);
* no events at all -> log the spec's initial input and start.

Completed tool calls are never re-executed: the fold keeps their results.

## 3. Window state machine (`Session.Dispatcher` ledger)

```
   dispatch          approval/question        answered
  ─────────▶ running ────────────────▶ needs_input ───────▶ running
               │  finish / budget / cancel / llm_error              d
               ▼                                                 ─────▶ dismissed
           done_unread ──── input (continue) ────▶ running
               ▲
   Node exceeds restart intensity
  running ───────────────────────────▶ failed_unread ──── d ────▶ dismissed
```

The ledger is a fold over persisted events:

| event                              | transition                                   |
|------------------------------------|----------------------------------------------|
| `branch_spawned`                   | (new) -> `:running`                          |
| `branch_state %{state: s}`         | -> `s` (`:running`, `:needs_input`, `:done_unread`) |
| `branch_failed`                    | -> `:failed_unread`                          |
| `cancelled`                        | marks the window cancelled (no state change) |
| `window_dismissed`                 | -> `:dismissed`                              |

`:done_unread` and `:failed_unread` are resting states. Nothing is removed
without a `window_dismissed` event, and that event is only written when the
user asks — `{:dismiss, agent_path}`, or `{:cancel, agent_path}`, which stops
the branch and then removes the window it stopped (Decision 57). Because the
cancelled mark is folded from the log, a Dispatcher that restarts between the
`cancelled` event and the branch coming to rest still removes the window.

On (re)start the Dispatcher folds the log, re-monitors live Nodes,
re-spawns branches whose ledger state is `:running` or `:needs_input` and
which have no live Node, and terminates Nodes of `:done_unread` windows.

## 4. Message protocol

All tuples are matched in function heads with guards. Unknown messages are
logged and dropped. `ref` is a `reference()`; `call_id` is the provider's
tool_use id (string). Every request the agent sends to a task carries a ref and
a timeout.

### 4.1 Into the session (public client API, synchronous calls allowed)

| message / call                                              | to                 | reply                                   |
|-------------------------------------------------------------|--------------------|-----------------------------------------|
| `{:command, name, args, source}` `source :: :user | :watch | :cli` | Dispatcher   | `{:ok, agent_path} | {:error, reason}`  |
| `{:input, source, content}` `source :: :user | :watch | :tui_todo_edit` | Agent.Server (send) | none                          |
| `{:switch_profile, name}`                                   | Agent.Server (send)| none                                    |
| `:cancel`                                                   | Agent.Server (send)| none                                    |
| `{:dismiss, agent_path}`                                    | Dispatcher (call)  | `:ok | {:error, reason}`                |
| `{:cancel, agent_path}` (stop, discard worktree, dismiss)   | Dispatcher (call)  | `:ok | {:error, reason}`                |
| `{:approval, call_id, :allow | :deny | :allow_session}`     | Approvals (call)   | `:ok | {:error, :unknown_call}`         |
| `{:answer, call_id, text}`                                  | Approvals (call)   | `:ok | {:error, :unknown_call}`         |
| `{:merge, agent_path}` / `{:discard, agent_path}`           | Dispatcher (call)  | `{:ok, info} | {:error, reason}`        |
| `:context` / `{:put_config, config}`                        | Dispatcher (call)  | `{workspace, config}` / `:ok`           |
| `{:auto_approve, bool}`                                     | Approvals (call)   | `:ok`                                   |
| `{:put_config, config}`                                     | Watcher (call)     | `:ok`                                   |

### 4.2 Into `Agent.Server` (always async `send`)

| message                                              | from                     |
|------------------------------------------------------|--------------------------|
| `{:input, source, content}`                          | client API, Watcher, TUI |
| `{:switch_profile, name}`                            | client API / TUI         |
| `:cancel`                                            | client API / TUI         |
| `{:llm_delta, ref, delta}`                           | stream task (provider)   |
| `{:llm_done, ref, response}`                         | stream task              |
| `{:llm_error, ref, reason}`                          | stream task              |
| `{:tool_result, call_id, result}`                    | tool task                |
| `{:approval, call_id, :allow | :deny}`               | Approvals                |
| `{:answer, call_id, text}`                           | Approvals                |
| `{:child_result, ref, result}`                       | child Agent.Server       |
| `{:DOWN, ref, :process, pid, reason}`                | monitors (tasks, children) |

`response :: %{content: [block], usage: usage, stop_reason: atom, model: binary}`, where
`usage :: %{input_tokens, output_tokens, cache_read, cache_write}`. The three input
figures are disjoint and normalised by each adapter, so the prompt was
`input_tokens + cache_read + cache_write` tokens long whatever the provider
reports natively (Decision 59). A budget spends `input_tokens + cache_write`.
`result :: {:ok, binary} | {:error, binary}`

### 4.3 From agents to session actors (synchronous call allowed; they never call back)

| call                                                       | to         |
|------------------------------------------------------------|------------|
| `Log.append(session, agent_path, type, data)`              | Log        |
| `Log.events(session, agent_path)` / `Log.all(session)`     | Log        |
| `Approvals.register(session, call_id, agent_pid, agent_path, kind, payload)` | Approvals |
| `Approvals.session_allowed?(session, tool)`                | Approvals  |
| `Locks.acquire(session, path, agent_path)` / `release`     | Locks      |

### 4.4 Between agents and the dispatcher (async only)

| message                                   | from -> to                                       |
|-------------------------------------------|--------------------------------------------------|
| `{:child_result, ref, result}`            | child Agent.Server -> parent Agent.Server        |
| `{:input, :user, prompt}`                 | parent -> child (initial prompt is in the Node spec instead, so the child logs it itself) |
| `{:DOWN, ...}`                            | Node monitors -> Dispatcher / parent             |
| `{:expect_write, path, content_hash}`     | write/edit tools -> Watcher                      |
| `{:command, "code" | "plan", payload, :watch}` | Watcher -> Dispatcher (cast)                |

### 4.5 Published events (`Troupe.Events`)

Subscribers receive `{:troupe_event, %Troupe.Event{}}`. Persisted events are
published by `Session.Log` after the write succeeds, so a subscriber never sees
something that is not on disk. Transient events (`llm_delta`, `agent_state`,
`notice`) are published directly and never persisted.

```
%Troupe.Event{session_id, seq, ts, agent_path, type, data, transient?}
```

Persisted event types and data:

| type                   | agent_path      | data                                                                 |
|------------------------|-----------------|----------------------------------------------------------------------|
| `session_started`      | `"session"`     | `%{workspace, session_id}`                                           |
| `branch_spawned`       | branch          | `%{branch_id, name, prompt, isolation, source, definition_name}`     |
| `branch_state`         | branch          | `%{state, reason, summary}`                                          |
| `branch_failed`        | branch          | `%{reason}`                                                          |
| `window_dismissed`     | branch          | `%{}`                                                                |
| `worktree_created`     | branch          | `%{path, git_branch}`                                                |
| `worktree_merged`      | branch          | `%{output, conflicts}`                                               |
| `worktree_discarded`   | branch          | `%{}`                                                                |
| `input`                | agent           | `%{source, content}`                                                 |
| `assistant_message`    | agent           | `%{content, usage, model, stop_reason}` (usage as above; an event written before Decision 59 has no cache keys and folds as zero) |
| `tool_call_started`    | agent           | `%{call_id, name, input}`                                            |
| `tool_call_completed`  | agent           | `%{call_id, ok, content}`                                            |
| `approval_requested`   | agent           | `%{call_id, name, input, preview}`                                   |
| `approval_answered`    | agent           | `%{call_id, decision}`                                               |
| `question_asked`       | agent           | `%{call_id, question}`                                               |
| `question_answered`    | agent           | `%{call_id, text}`                                                   |
| `delegation_started`   | agent           | `%{call_id, child_path, agent, prompt}`                              |
| `delegation_completed` | agent           | `%{call_id, child_path, ok, content, usage}`                         |
| `todo_updated`         | agent           | `%{items, source}`                                                   |
| `profile_switched`     | agent           | `%{name}`                                                            |
| `compaction`           | agent           | `%{summary, dropped_messages}`                                       |
| `llm_error`            | agent           | `%{reason}`                                                          |
| `cancelled`            | agent           | `%{}`                                                                |
| `finished`             | agent           | `%{summary, reason, diff_stat}`                                      |
| `watch_trigger`        | `"watcher"`     | `%{kind, markers}`                                                   |
| `session_closed`       | `"session"`     | `%{branches, done, failed, forced}`                                  |

Transient: `llm_delta %{ref, text}`, `agent_state %{from, to}`, `notice %{text}`.

## 4.6 Workspace survey

`Troupe.Workspace.Survey.build/2` is called once in `Agent.Server.init/1`, after
`ensure_worktree/1`, and the result is held on the server's `Data` (never on
`Agent.State`, which stays a pure fold over events). `Prompt.request/2` renders
it into a `# Workspace` section of the system prompt: project markers with
package names, language mix by file count, and the file list — or per-directory
counts when the list is too large. It is a derived cache: nothing persists it,
replay ignores it, and `list_files` remains the authority on current contents.

## 4.7 Project brief (codebase memory)

`.troupe/memory.md` in the workspace is a durable, human-editable brief: YAML
frontmatter (`built_at`, `head`, `files`) plus ordered `## ` sections
(`Overview`, `Layout`, `Commands`, `Conventions`, `Notes`). `Troupe.Memory` is
the pure format module — parse, render, `put_section/3`, `add_note/3`,
`stale?/2`, `to_prompt/2` — and parsing is lossless, so unknown headings and
text before the first heading survive a rewrite.

`Session.Memory` owns the file: single writer within a session, each mutation
re-reads from disk before merging and replaces by rename. Its path comes from
the *session* workspace, so a worktree branch reads and writes the user's
checkout rather than a copy of its own: one brief per repository.

`Agent.Server.init/1` fetches the rendered block once, beside `Survey.build/2`,
and `Prompt.system/3` renders it as `# Project brief` ahead of `# Workspace`.
Once a brief is present the survey's listing budget drops to
`memory.survey_chars`, so its `Layout` section supersedes the raw file dump.
Fetched once, never per turn, for the same reason as the survey: the system
prompt must stay byte-stable or the provider's prompt cache stops hitting — so a
`remember` during a branch reaches the *next* agent, not the current turn.

The `remember` tool (`:auto`; the only file it can reach is the brief) writes a
section or appends a dated note. The `librarian` profile rebuilds the brief and
is dispatched once per session by the Dispatcher when `Session.Memory.status/2`
is `:absent` or `:stale`, as a `source: :memory` window that dismisses itself on
completion; the guard is `counters["librarian"]`, folded from the log, so it
survives a restart and a resume.

Like the survey, the brief is derived and never authoritative: it is not an
event, replay ignores it, and `list_files`/`grep`/`read_file` remain the truth
about current contents.

## 5. Tools

`Troupe.Tool` behaviour: `name/0`, `description/0`, `schema/0`,
`default_permission/0`, `run(args, ctx)`. `ctx` is `%Troupe.Tool.Context{}`
with `workspace`, `isolation`, `session_id`, `agent_path`, `call_id`,
`definition`, `definitions`, `depth`. Tool tasks run under `Agent.Tasks`; the
runner (`Troupe.Tool.Runner`) is the one place `rescue`/`catch` is used: a
raise, exit or timeout becomes `{:error, text}`. Every OS process runs under
`reaper` through `Troupe.OS.Process`, whose Port is owned by the tool task.

`web_fetch` is the only tool that reaches the network: a GET, capped in what it
reads off the socket and in what it returns, with the response reduced to text
before the model sees it. It defaults to permission `ask`, so the URL is shown
to the user before the request is made (Decision 58).

## 6. Failure matrix

| process             | what kills it                                   | what restarts                                                             | user observes                                  | model observes                                   |
|---------------------|-------------------------------------------------|---------------------------------------------------------------------------|------------------------------------------------|--------------------------------------------------|
| Tool task           | raise / exit / timeout in a tool                | nothing (task is `:temporary`); agent gets DOWN or timeout                 | tool call shown as error in transcript         | error `tool_result`, keeps running               |
| LLM stream task     | provider crash after retries, network failure   | nothing; agent gets `llm_error` or DOWN                                    | window `:done_unread` with reason `:llm_error` | nothing (no further calls)                       |
| Agent.Server        | bug, `Process.exit(:kill)`                      | Agent.Node (one_for_all) restarts Server, Tasks, Children; state from log  | window stays `:running`; tail resumes          | started-not-completed tool calls re-run          |
| Agent.Node          | > 3 restarts in 5 s                             | nothing (`:temporary` in Branches); Dispatcher marks `:failed_unread`      | window `:failed_unread` with reason            | nothing                                          |
| Nested Agent.Node   | same                                            | nothing; parent gets DOWN                                                 | delegation shows error in parent window        | error `tool_result` for that delegation only     |
| Session.Branches    | bug (very unlikely; it holds no logic)          | rest_for_one restarts Branches, Dispatcher, Watcher; Dispatcher re-spawns `:running` branches from the log | running windows restart | in-flight tool calls re-run |
| Session.Dispatcher  | bug, `Process.exit(:kill)`                      | Dispatcher and Watcher restart; ledger folded from log; branches untouched | nothing (ledger identical)                     | nothing                                          |
| Session.Watcher     | backend crash                                   | Watcher only                                                              | one-line notice                                | nothing                                          |
| Session.Approvals   | bug                                             | rest_for_one: Approvals, Locks, Branches, Dispatcher, Watcher restart; pending questions re-registered by agents on replay | running windows restart | in-flight calls re-run |
| Session.Locks       | bug                                             | as above from Locks                                                       | as above                                       | as above                                         |
| Session.Log         | disk error                                      | whole session restarts (rest_for_one from the first child)                | all windows restart from log                   | in-flight calls re-run                           |
| TUI.Server          | render bug                                      | UI.Supervisor restarts it; screen rebuilt from `Log.all/1`                | brief flicker, same windows                    | nothing                                          |
| Whole VM            | SIGKILL / taskkill                              | nothing; `troupe resume` replays                                          | on resume: running branches continue           | in-flight calls re-run                           |
| Reaper child tree   | Port closed for any reason                      | n/a; reaper kills the process tree                                        | tool call ends with error/cancelled            | error `tool_result` (if agent still alive)       |

## 7. Persistence

`$TROUPE_STATE_DIR` or the platform state dir, then
`sessions/<workspace-hash>/<session-id>/events.jsonl`, one JSON object per
line, `seq` monotonic per session. `Session.Log` is the only writer; `append`
is a synchronous call that returns after `IO.binwrite` succeeded and the event
was published. On start the Log reads the file to restore `seq` and its
in-memory copy.

`Session.Dispatcher.close/2` ends a session: it refuses while branches are
active or managed worktrees are neither merged nor discarded (`force?` overrides
and is recorded on the event), then appends `session_closed` and has the Log
stamp `closed_at` into `meta.json`. `Log.close_on_disk/3` does the same for a
persisted session with no running Log, which is safe because a stopped session
has no writer. `session_closed` is a terminal record: nothing folds it, so
replay is unaffected and it reaches the TUI model through the same inert path as
`session_started`. Starting or resuming a session drops `closed_at` again.

## 8. Concurrency rules

* No synchronous call between agents, or from a session actor into an agent.
* `GenServer.call` only from the client API into session actors and from an
  agent into Log/Approvals/Locks/Memory.
* Top-level concurrency is the user's (commands). In-turn concurrency is the
  model's (multiple tool calls, `delegate` fan-out) and is bounded by the turn.
* The TUI coalesces deltas and redraws at most 30 times per second; when its
  mailbox exceeds a threshold it collapses queued deltas. It never applies
  backpressure to a session.
