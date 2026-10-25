defmodule Troupe.Protocol.Schema do
  @moduledoc """
  What is in each event's `data` and each command's params, as data.

  This is the definition the JSON Schema in `protocol/schema/v1/` is generated from, so
  the published schema cannot drift from what the server means. It is also what
  `mix troupe.schema.diff` compares against the committed copy, which is what stops a
  field being quietly removed or retyped between releases.

  Within major version 1 the rules are: fields may be added; fields may not be removed,
  renamed, retyped, or newly made required; event types and enum values may be added.
  A rename is a removal and an addition, and it is the removal that breaks clients.
  """

  @type shape :: %{String.t() => %{type: type(), required: boolean()}}
  @type type ::
          :string
          | :integer
          | :number
          | :boolean
          | :object
          | :array
          | :text_or_blob
          | :any
          | {:array, type()}

  defp required(type), do: %{type: type, required: true}
  defp optional(type), do: %{type: type, required: false}

  # -- durable events ---------------------------------------------------------

  @doc "Every durable event type and the shape of its `data`."
  @spec events() :: %{String.t() => shape()}
  def events do
    %{
      # `kind` is `team` for a session on a pod and `local` for one on a laptop;
      # `origin` says what started it — a person, a trigger, a run — when it was not a
      # person typing.
      "session_created" => %{
        "workspace" => required(:string),
        "profile" => required(:string),
        "visibility" => required(:string),
        "bundle_version" => optional(:string),
        "kind" => optional(:string),
        # Who it belongs to, where anybody was told; and what it was allowed to see —
        # the agent, skill and MCP server names the grant resolved to, or absent for no
        # restriction, which is what a local session and an unnarrowed grant both mean.
        "owner" => optional(:string),
        "entitlements" => optional(:object),
        "origin" => optional(:object),
        # The session this one was made as a branch of, when a client said so.
        "parent" => optional(:string)
      },
      # The child's first event, and the only place the lineage is written down in the log.
      # `parent` carries the id, the seq forked at and the parent's head hash there, so a
      # reader holding only the child can say what it came from and a verifier can say the
      # claim is about a real point in a real chain.
      #
      # The parent gets nothing. It is not amended, not notified, and a fork of a dormant
      # session does not wake it — which is what makes forking cost the person who forks
      # and nobody else.
      "session_forked" => %{
        "parent" => required(:object),
        "reason" => required(:string)
      },
      "agent_started" => %{
        "profile" => required(:string),
        "mode" => required(:string),
        "bundle_version" => optional(:string)
      },
      "agent_restarted" => %{
        "replayed_events" => required(:integer),
        "interrupted" => optional(:boolean),
        "incomplete_calls" => optional({:array, :string})
      },
      # `command_id` is the send the input was taken from, as its `input_accepted` names it:
      # what a client that drew the line when it was typed knows it by. A harness note,
      # which nobody sent, has none, and neither has a log written before it did. One from
      # `subagent` is the end of a child its parent started in the background, handed to the
      # parent once (Decision 853): `child_path` is the child, `ended` how it ended
      # (`finished`, `cut_short`, `stopped`, `cancelled`, `interrupted` or `failed`).
      "user_input" => %{
        "source" => required(:string),
        "text" => required(:string),
        "command_id" => optional(:string),
        "child_path" => optional({:array, :string}),
        "ended" => optional(:string)
      },
      # A command the person ran in the session's workspace (`shell.run`, Decision 813),
      # written by the root agent under its actor when it ends. `output` is the tail capped
      # at the session's `tool_output_limit`, with the `read_output` marker when it was cut;
      # `ended` is `exited` (with `exit_status`), `timeout`, `killed` or `failed` (with
      # `reason`); `agent` says whether the next model call is given it.
      "user_shell" => %{
        "run_id" => required(:string),
        "command" => required(:string),
        "output" => required(:string),
        "ended" => required(:string),
        "agent" => required(:boolean),
        "exit_status" => optional(:integer),
        "reason" => optional(:string),
        "timeout_ms" => optional(:integer),
        "duration_ms" => optional(:integer),
        "command_id" => optional(:string)
      },
      "input_queued" => %{
        "command_id" => required(:string),
        "author" => required(:string),
        "text" => required(:string)
      },
      "input_accepted" => %{
        "command_id" => required(:string),
        "author" => required(:string)
      },
      # `prompt_bytes`: what the prompt was made of, in bytes — `system` (`brief` a part of
      # it), `tools`, `conversation` (`tool_results` a part of it) and `total` (Decision
      # 769). Absent from a log written before it. `system_changed` and `tools_changed`:
      # whether the system prompt and the tools differ from the agent's call before, absent
      # on its first and on the first after a restart; `turn_context`: the sections a stable
      # system prompt sent with this call (issue #465, Decision 815).
      "llm_request" => %{
        "model" => required(:string),
        "message_count" => required(:integer),
        "tools" => required({:array, :string}),
        "profile" => required(:string),
        "prompt_bytes" => optional(:object),
        "system_changed" => optional(:boolean),
        "tools_changed" => optional(:boolean),
        "turn_context" => optional({:array, :string}),
        # The block that call put into the conversation: `at`, the index of the message it
        # goes after, `text`, and `sent`, each section's digest; folded on replay so a
        # restarted agent sends the prefix it sent before (Decision 863).
        "turn_context_block" => optional(:object),
        # What a turn's first call took and offers to the turn's end: `digest`, and `tools`
        # and `skills` when they differ from the last written whole; folded on replay so an
        # agent restarted in the middle of the turn offers what it began with (Decision 876).
        "turn_hold" => optional(:object)
      },
      "llm_response" => %{
        "message" => required(:object),
        "usage" => optional(:object),
        "stop_reason" => optional(:string),
        "model" => optional(:string),
        # What the gateway in front of the provider said about the call it billed:
        # `request_id` and `cost_micros`. Optional because an event written before there
        # was a gateway to ask carries neither, and because a gateway may answer with
        # one and not the other.
        "gateway" => optional(:object),
        # What became of the thinking the call handed back, present only when anything
        # did: refused as bound to another conversation and the call sent again without it
        # (Decision 805), or the blocks the thinking-binding beta dropped (Decision 815);
        # and what the API's `anthropic-thinking-prefix-mismatch` header said of the edit,
        # its `key=value` pairs cut to its own words (Decision 863).
        "thinking_resent" => optional(:boolean),
        "thinking_dropped" => optional(:integer),
        "prefix_mismatch" => optional(:string)
      },
      # `reason` is a sentence a person can act on (Decision 659), not a term. `note` is a
      # root's: what its conversation was told, which a replay puts back (Decision 693).
      # `stopped` is the call the agent gave up on at its timeout and stopped: `model`, and
      # `usage` and `gateway` when it had reported what it used (Decision 788).
      "llm_error" => %{
        "reason" => required(:string),
        "note" => optional(:string),
        "stopped" => optional(:object)
      },
      # A reply the output cap cut (`max_tokens`) or that said nothing (`empty`): `note`
      # when the model was asked again, `calls` when tool calls cut mid-argument were
      # answered with an error, `final` when it had been asked once already and the agent
      # ends under `output_truncated` or `empty_reply` (Decision 659).
      "truncated" => %{
        "reason" => required(:string),
        "note" => optional(:string),
        "calls" => optional(:integer),
        "final" => optional(:boolean)
      },
      "tool_call_started" => %{
        "call_id" => required(:string),
        "name" => required(:string),
        "args" => required(:object),
        # Which credential an MCP call goes out as: `"profile"` or `"person:<subject>"`.
        # Absent for every other tool, because a built-in runs as the pod and a
        # client-hosted tool runs on somebody's laptop, and neither is a choice anybody
        # made.
        "identity" => optional(:string),
        # The same question with its other half: whose credential *and* whose session.
        # A field is never retyped within a major version, so the pair arrives beside
        # `identity` rather than in place of it — and `identity` keeps meaning exactly
        # what it meant to every reader written before there were two halves.
        "principal" => optional(:object)
      },
      "tool_call_completed" => %{
        "call_id" => required(:string),
        "name" => required(:string),
        "ok" => required(:boolean),
        # Text, or `{"blob", "size", "preview", "truncated"}` when it was too large to
        # put on the wire.
        "content" => required(:text_or_blob),
        # How a `shell` call's command ended (Decision 837): `exit_status` when it exited,
        # `timed_out: true` when its timeout killed it. Absent on every other tool and on
        # a call that did not run; `ok` is true for a command that ran, whatever its status.
        "exit_status" => optional(:integer),
        "timed_out" => optional(:boolean),
        # A waited-for `delegate`'s: what its subagent reported it spent, in `turn`'s shape,
        # which is the parent's turn's too.
        "spent" => optional(:object),
        # A `publish_artifact`'s: what it published on the plane (#62), `id`, `version`,
        # `url`, `title` and `visibility`.
        "artifact" => optional(:object)
      },
      "tool_results" => %{"results" => required(:array)},
      "todo_updated" => %{"items" => required(:array), "source" => optional(:string)},
      # The agent a session or branch runs, changed (Decision 841): the layer the new one was
      # read from, the tools it holds that the old did not and the other way round, and the
      # switch's `command_id`. Written under whoever switched it.
      "profile_switched" => %{
        "from" => optional(:string),
        "to" => required(:string),
        "layer" => optional(:string),
        "tools_added" => optional({:array, :string}),
        "tools_removed" => optional({:array, :string}),
        "command_id" => optional(:string)
      },
      # What the agent's system prompt was read from at this turn (Decision 706): the
      # instruction files, what they import, and the brief, as `context.get` lists them,
      # each with `scope`, `path`, `size`, `chars`, `budget`, `share`, `status`,
      # `trimmed`, `skipped`, `imported_by`, `unfollowed` and `hash` (Decision 798), and
      # `reason`, in words, for a file left out (Decision 806).
      # Written when the set or a file changed since the agent's last turn. `memory` is each
      # memory document read (#55), as the plane names it: `scope` (organisation, team,
      # profile, user), `name`, `version` and `hash`, so the log says which version of each
      # the turns from here run under.
      "instructions_loaded" => %{
        "budget" => required(:integer),
        "used" => required(:integer),
        "files" => required(:array),
        "searched" => optional({:array, :string}),
        "memory" => optional(:array)
      },
      # The organisation's memory documents an agent reads changed while the session ran
      # (#55): a save on the plane reached it, and its next turn read the new ones. Each
      # change is `scope`, `name`, `from` and `to`, the versions, `null` for none; `message`
      # is the sentence a client shows as it is.
      "memory_changed" => %{
        "changes" => required(:array),
        "message" => required(:string)
      },
      # The session's goal, written by the root agent under whoever set or cleared it, and
      # carrying the `command_id` of the `session.goal.*` call that asked.
      "goal_set" => %{"text" => required(:string), "command_id" => optional(:string)},
      "goal_cleared" => %{"command_id" => optional(:string)},
      # A loop towards the goal (`session.loop.*`, Decision 679), written under the root
      # agent's path by the session's loop process. `loop_started` carries the protocol
      # command that asked; an iteration's `command_id` is the one its input carries, which
      # the root's `input_accepted` echoes. `outcome` is `continue`, `complete`, `failed`
      # or `stopped`; `reason` is `goal_complete`, `max_iterations`, `failures`, `budget`,
      # `requested`, `cancelled`, `goal_cleared`, `interrupted` or `agent_done`.
      "loop_started" => %{
        "loop_id" => required(:string),
        "max_iterations" => required(:integer),
        "max_failures" => required(:integer),
        "goal" => required(:string),
        "command_id" => optional(:string)
      },
      "loop_iteration_started" => %{
        "loop_id" => required(:string),
        "iteration" => required(:integer),
        "command_id" => required(:string)
      },
      "loop_iteration_finished" => %{
        "loop_id" => required(:string),
        "iteration" => required(:integer),
        "outcome" => required(:string),
        "detail" => optional(:string)
      },
      "loop_stopped" => %{
        "loop_id" => required(:string),
        "reason" => required(:string),
        "iterations" => required(:integer),
        "detail" => optional(:string),
        "summary" => optional(:string),
        "command_id" => optional(:string)
      },
      # `task` is the child's first message: the brief's parts under their names. `brief`
      # is the parts themselves, `goal`, `context`, `constraints`, `deliverable` and
      # `do_not` (Decision 847); absent from a log written before briefs had them. `wait` is
      # `false` for a child started in the background, whose `delegate` call answered at once
      # (Decision 853), and absent otherwise.
      "delegation_started" => %{
        "call_id" => required(:string),
        "agent" => required(:string),
        "child_path" => required({:array, :string}),
        "task" => required(:string),
        "brief" => optional(:object),
        "wait" => optional(:boolean)
      },
      "compacted" => %{
        "summary" => required(:string),
        # `threshold`, or `context_overflow` when the provider refused the prompt and
        # compacting is how the turn was sent again (Decision 659).
        "reason" => optional(:string),
        "conversation" => optional(:array),
        # The summariser's own call, in the words `llm_request` and `llm_response` use for
        # one (Decision 769). Absent from a log written before it.
        "model" => optional(:string),
        "prompt_bytes" => optional(:object),
        "usage" => optional(:object),
        "gateway" => optional(:object)
      },
      "budget_exhausted" => %{"limit" => required(:string)},
      # The budget is spent and the agent asks before the next model call (Decision 660).
      # The question itself is a `question_asked` under the same `call_id`.
      "budget_ask_started" => %{
        "call_id" => required(:string),
        "dimension" => required(:string),
        "used" => required(:integer),
        "limit" => required(:integer),
        "detail" => required(:string)
      },
      # `allow` (one more slice, `grant` says how much), `always` (the limit asked about,
      # named in `lifted`, is lifted for this agent and its subagents; the others still
      # ask — Decision 687), `raise` (`limit` goes up by `amount` for `scope` — `run`,
      # `session` or `workspace`, the last also written to the file `path` names —
      # Decision 699), `unclear` (the answer could not be read, `note` says why, and the
      # question is asked again under the next id) or `deny` (`budget_exhausted` follows).
      "budget_ask_answered" => %{
        "call_id" => required(:string),
        "decision" => required(:string),
        "grant" => optional(:object),
        "lifted" => optional(:string),
        "scope" => optional(:string),
        "limit" => optional(:string),
        "amount" => optional(:integer),
        "path" => optional(:string),
        "note" => optional(:string)
      },
      # One tool has failed `failures` times in a row and the agent asks before its next
      # model call whether the turn goes on (Decision 687). The question itself is a
      # `question_asked` under the same `call_id`, with options `stop` and `continue`.
      "tool_failures_ask_started" => %{
        "call_id" => required(:string),
        "tool" => required(:string),
        "failures" => required(:integer),
        "detail" => required(:string)
      },
      # `continue` (the tool's count starts again) or `stop` (`turn_ended` follows, with
      # `reason: tool_failures`).
      "tool_failures_ask_answered" => %{
        "call_id" => required(:string),
        "decision" => required(:string)
      },
      # Something the configuration did to the session that the person is told, once a
      # session, under the root: `key` is the setting, `message` the sentence a client
      # shows as it is. The one there is: an organisation's enforced `max_tokens` (`limit`,
      # from `source`, the plane's URL or the managed file) shortened the thinking `model`'s
      # `effort` asks for to `thinking` tokens, 0 where it left none (issue #644).
      "config_note" => %{
        "key" => required(:string),
        "message" => required(:string),
        "source" => optional(:string),
        "limit" => optional(:integer),
        "model" => optional(:string),
        "effort" => optional(:string),
        "thinking" => optional(:integer)
      },
      # A limit is near (Decision 655): once per dimension per agent.
      "budget_warning" => %{
        "dimension" => required(:string),
        "used" => required(:integer),
        "limit" => required(:integer),
        "fraction" => required(:number),
        "detail" => required(:string)
      },
      # `turn` here, on `turn_ended` and on `cancelled` is what the turn the event ends cost:
      # `calls`, the four token figures summed, `cost_micros` and `unpriced` (Decision 769).
      # A `finish` writes `summary` as its report reads, the parts under their names, and
      # `report` as the parts: `summary`, `ran`, `passed`, `unverified`, `needs`, and
      # `changed` as Troupe counted it — `files` (`path`, `added`, `removed`, `whole`), the
      # totals, `commands` not counted, `session_id` and `agent` to read the diff by, and
      # `said` when the agent named changes of its own (Decision 847). A child its parent
      # ended in the background (Decision 853) is `stopped` with `by`, its parent's path,
      # `cancelled`, `interrupted` or `failed`, its `summary` and `report` saying what it had
      # done, written by its parent.
      "agent_done" => %{
        "reason" => required(:string),
        "summary" => optional(:string),
        "report" => optional(:object),
        "limit" => optional(:string),
        "turn" => optional(:object),
        "by" => optional({:array, :string})
      },
      # A root agent that had finished took new input as a turn: `from` (`finished`), and
      # `source`, the input's, as `user_input` names it. Written before the turn it starts.
      "agent_woken" => %{"from" => required(:string), "source" => required(:string)},
      # The agent's turn is over and it waits for input: the durable twin of `agent_state`
      # reaching `idle`, for a client that was not listening when it happened (issue #127).
      # `reason` only when the harness ended it: `tool_failures` (Decision 687), or
      # `agent_failed`, the root crashing as often as its Node allows, with `detail` saying
      # what it raised; its session stops after it (Decision 727); or `waiting`, a subagent
      # resting until a child it started in the background ends, with no `turn` (Decision 853).
      "turn_ended" => %{
        "reason" => optional(:string),
        "detail" => optional(:string),
        "turn" => optional(:object)
      },
      # Input that arrived after an agent finished. Recorded rather than dropped: it is
      # the difference between "the user said nothing" and "the user said something and
      # nobody was listening".
      "input_after_done" => %{"source" => required(:string)},
      # `stopped`: the model call the cancel stopped, as on `llm_error` (Decision 788).
      "cancelled" => %{"turn" => optional(:object), "stopped" => optional(:object)},
      # A delegation a person asked to see first (Decision 850) asks with `tool: delegate`
      # and what the gate shows under `delegation`: `agent`; `definition` (`name`, `layer`,
      # `path`, `description`), which `agents.get` opens; `brief`, the five parts; `tools`,
      # each `{name, permission}` the child will hold; `budget_share`; `depth` and
      # `max_depth`; and `agents`, each `{name, description}` it could go to instead.
      # A call a per-tool rule of the configuration asks about (#658) carries that `rule`:
      # `action`, `rule` as written, `tool`, `pattern`, `scope` (the layer), `source`.
      "approval_requested" => %{
        "call_id" => required(:string),
        "tool" => required(:string),
        "args" => required(:object),
        "agent_path" => required({:array, :string}),
        "delegation" => optional(:object),
        "rule" => optional(:object)
      },
      # A delegation's decision names the `agent` it went to when it was allowed, the
      # `brief` as the person edited it and which parts (`edited`), and the person's word
      # back with a denial (`reason`). `allow_session` lets that agent run unasked for the
      # session.
      "approval_decided" => %{
        "call_id" => required(:string),
        "tool" => required(:string),
        "args" => required(:object),
        "agent_path" => required({:array, :string}),
        "decision" => required(:string),
        "agent" => optional(:string),
        "brief" => optional(:object),
        "edited" => optional({:array, :string}),
        "reason" => optional(:string)
      },
      # `ask_user` (Decision 651): the agent hands a decision to a person and waits.
      # `preview` is text the question is about, shown as it is beneath it: the prompt a
      # workspace's command would send, when it asks before it is first sent (Decision 814).
      "question_asked" => %{
        "call_id" => required(:string),
        "agent_path" => required({:array, :string}),
        "question" => required(:string),
        "options" => required(:array),
        "multiple" => required(:boolean),
        "preview" => optional(:string)
      },
      "question_answered" => %{
        "call_id" => required(:string),
        "text" => required(:string)
      },
      "approval_resolved" => %{
        "call_id" => required(:string),
        "resolved_by" => required(:string)
      },
      # A workspace's command that asked before it was first sent and was not (Decision
      # 814): `reason` says why and how to run it later, a sentence a person can act on;
      # `command_id` is the `commands.run` that asked.
      "command_declined" => %{
        "name" => required(:string),
        "reason" => required(:string),
        "command_id" => optional(:string)
      },
      # What the session may touch: `[{name, kind, root, mode}]`. Resolved once, at
      # creation, and recorded so that a replay can tell what was allowed at the time.
      "mounts_resolved" => %{"mounts" => required(:array)},
      # The agent and skill files a session found and did not read, each `{kind, name, path,
      # reason}`: on a pod, a working copy's file of a name the bundle has or a built-in
      # agent's, which those beat unless the profile allows the repository's; in a git
      # worktree, one the main checkout has not committed (Decision 826). Written at a start
      # whose list differs from the one the log last recorded, an empty list included.
      "files_skipped" => %{"files" => required(:array)},
      # Something other than a person started this session, and this is the whole of what
      # that was: which of the seven sources, under which trigger document, on whose
      # authority, against which idempotency key, carrying what.
      #
      # `payload_digest` is a hash and never a payload — a webhook body is content, and
      # content does not belong in an event that outlives the session that received it.
      # It and `revision` are optional because a session started before either existed
      # has neither, and a value invented here would read as one that was measured.
      "trigger_fired" => %{
        "source" => required(:string),
        "idempotency_key" => required(:string),
        "principal" => required(:object),
        "revision" => optional(:string),
        "payload_digest" => optional(:string)
      },
      "published" => %{
        "source" => required(:string),
        "destination" => required(:string),
        "hash" => required(:string),
        "bytes" => required(:integer),
        "direction" => required(:string)
      },
      # A file `onboard_write` wrote (Decision 823): under the workspace's `.troupe/`
      # (`target: repo`), an `AGENTS.md` of the workspace's (`workspace`, Decision 827) or
      # under the person's config directory (`user`), at `path` from that root, shown as
      # `file`; from `source`, whose sha256 was `source_hash`; `action` is `created` or
      # `replaced`.
      "onboarded" => %{
        "target" => required(:string),
        "path" => required(:string),
        "file" => required(:string),
        "source" => required(:string),
        "source_hash" => required(:string),
        "action" => required(:string)
      },
      # What onboarding would do in the session's workspace, said at every start while it is
      # due and the person has not said no for that version (Decisions 827 and 835); nothing
      # was written. `reasons`: `first`
      # (other tools' files, nothing onboarded: `proposals` counts what `troupe onboard`
      # would propose by kind), `outdated` (onboarded under `onboarded_version` of the rules,
      # older than `onboarding_version`) and `brief` (the brief written by `brief_version` of
      # the librarian's survey, older than `survey_version`). `message` says it all in a
      # line a client shows as it is; `command` is what to run. What a client's start asks
      # next (Decision 835): `due` (`first`, `outdated` or `none`) for onboarding,
      # `brief_due` (`first`, `stale`, `outdated` or `none`) for the brief, and `counts`, the
      # workspace's files it would ask about (`files`, `write`, `create_agents_md`);
      # `onboard.plan` lists them.
      "onboarding_suggested" => %{
        "reasons" => required({:array, :string}),
        "message" => required(:string),
        "workspace" => optional(:string),
        "command" => optional(:string),
        "proposals" => optional(:object),
        "onboarding_version" => optional(:integer),
        "onboarded_version" => optional(:integer),
        "survey_version" => optional(:integer),
        "brief_version" => optional(:integer),
        "due" => optional(:string),
        "brief_due" => optional(:string),
        "counts" => optional(:object)
      },
      # A saved `AI!` or `AI?` comment started a branch of this session (Decision 844):
      # `agent` (`quick` or `answer`) as the session `session_id`, in this session's
      # checkout, for the comments in `markers` (`file`, `line`, `comment`); `mode` is
      # `change` or `question`. `error` instead of `session_id` says why none started.
      "watch_triggered" => %{
        "agent" => required(:string),
        "mode" => required(:string),
        "markers" => required(:array),
        "session_id" => optional(:string),
        "error" => optional(:string)
      },
      "session_dormant" => %{"last_seq" => required(:integer)},
      "session_activated" => %{"epoch" => required(:string), "pod" => optional(:string)},
      "session_resumed" => %{
        "dormant_ms" => required(:integer),
        "moved" => required(:boolean)
      },
      # The session's configuration changed under it, which happens only at activation and
      # only when the version it was pinned to has been retired. Durable, because the
      # model is entitled to know its tools may have changed.
      "config_upgraded" => %{
        "channel" => required(:string),
        "from" => optional(:integer),
        "to" => required(:integer),
        "hash" => required(:string),
        # Re-resolved at this activation: a publish can add an entry the team is not
        # entitled to, so the event that says the configuration moved says what the
        # session may now see.
        "entitlements" => optional(:object)
      },
      "session_read_only" => %{"reason" => required(:string)},
      "session_archived" => %{},
      "session_erased" => %{},
      "fs_changed" => %{
        "path" => required(:string),
        "hash" => required(:string),
        "size" => required(:integer)
      },
      # A document `show` wrote to the session's scratchpad, or replaced (Decision 870):
      # everything a client shows of it but its words, which `fs.read` of `path` returns.
      # `version` counts the writes of that name in the session, from 1; `call_id` is the
      # `show` call that wrote it, so a transcript can put the card where the call was.
      "scratch_updated" => %{
        "name" => required(:string),
        "path" => required(:string),
        "kind" => required(:string),
        "title" => required(:string),
        "size" => required(:integer),
        "hash" => required(:string),
        "version" => required(:integer),
        "call_id" => optional(:string)
      },
      # A capability somebody minted over this session: a link that carries a role rather
      # than a name. Durable, because a share is a decision about who may read what was
      # said, and a decision of that kind that left no trace would be one nobody could
      # audit after the fact.
      #
      # `id` is the share's public identifier and never the secret — the secret is shown to
      # whoever minted it, once, and the plane keeps a salted digest. An event carrying it
      # would put a working credential in a log that outlives the session.
      #
      # `role` is `observe` or `control`. Never `admin`: a capability that could administer
      # a session could grant further capabilities, and a link that can mint links is a link
      # nobody can reason about.
      "share_created" => %{
        "id" => required(:string),
        "role" => required(:string),
        "expires_at" => required(:string),
        "audience" => optional(:string)
      },
      "share_revoked" => %{"id" => required(:string), "reason" => optional(:string)},
      "acl_granted" => %{"subject" => required(:string), "role" => required(:string)},
      # A person invited into this session by name, or the invitation taken back (#765):
      # whom, at which role (`observe` or `control`), and by whom. Durable, for the reason
      # a share is: who was let in to read what was said is part of what happened.
      "session_invited" => %{
        "subject" => required(:string),
        "role" => required(:string),
        "by" => required(:string),
        "display_name" => optional(:string),
        "by_name" => optional(:string)
      },
      "session_uninvited" => %{
        "subject" => required(:string),
        "by" => required(:string),
        "display_name" => optional(:string),
        "by_name" => optional(:string)
      },
      "acl_revoked" => %{"subject" => required(:string), "role" => required(:string)},
      # Client-hosted tools. Durable, all three, because a tool that ran on somebody's
      # laptop is part of what happened in this session and a replay that did not say so
      # would be a transcript with a hole in it.
      "tools_registered" => %{
        "tools" => required({:array, :string}),
        "connection" => required(:string),
        "consent" => required(:object)
      },
      "tools_unregistered" => %{
        "tools" => required({:array, :string}),
        "connection" => required(:string),
        "reason" => required(:string),
        "actor" => optional(:string)
      },
      "session_tainted" => %{
        "kind" => required(:string),
        "tools" => required({:array, :string}),
        "actor" => required(:string),
        "display_name" => optional(:string)
      }
    }
  end

  @doc "Ephemeral event types. Droppable, never persisted, and never part of a replay."
  @spec ephemeral_events() :: %{String.t() => shape()}
  def ephemeral_events do
    %{
      "llm_delta" => %{
        "kind" => required(:string),
        "text" => optional(:string),
        "id" => optional(:string),
        "name" => optional(:string),
        "fragment" => optional(:string)
      },
      "agent_state" => %{
        "state" => required(:string),
        "profile" => required(:string),
        "agent" => required({:array, :string}),
        "todos" => required(:array),
        "budget" => required(:object),
        "done_reason" => optional(:string)
      },
      "progress" => %{"message" => required(:string)},
      # Never durable, and not by a filter: presence is published through a function that
      # has no path to the log at all. `state` is `joined`, `left`, `focused` or `typing`.
      "presence" => %{
        "subject" => required(:string),
        "state" => required(:string),
        "display_name" => optional(:string),
        "via" => optional(:string),
        "agent" => optional({:array, :string})
      },
      "summary_diff" => %{"changed" => required(:object)},
      "watch_notice" => %{"message" => required(:string)},
      # Watch went on or off for this session, or changed backend (Decision 844);
      # `watch.get` says the same at any time.
      "watch_changed" => %{"enabled" => required(:boolean), "backend" => required(:string)},
      # A person's command while it runs (Decision 813): started, then its output as it
      # comes. Its end is the durable `user_shell`, which carries the tail either way.
      "shell_started" => %{
        "run_id" => required(:string),
        "command" => required(:string),
        "agent" => required(:boolean)
      },
      "shell_output" => %{"run_id" => required(:string), "text" => required(:string)}
    }
  end

  # -- commands ---------------------------------------------------------------

  @doc "Every command method and the shape of its params."
  @spec commands() :: %{String.t() => shape()}
  def commands do
    %{
      "initialize" => %{
        "protocol_version" => required(:string),
        "client_info" => required(:object),
        "capabilities" => optional(:object),
        "auth" => optional(:object)
      },
      "subscribe" => %{
        "command_id" => required(:string),
        "topic" => required(:string),
        "level" => optional(:string),
        "from_seq" => optional(:integer)
      },
      "unsubscribe" => %{"subscription_id" => required(:string)},
      "session.list" => %{"filter" => optional(:object)},
      "session.get" => %{"session_id" => required(:string)},
      "session.create" => %{
        "command_id" => required(:string),
        "workspace" => required(:string),
        "profile" => optional(:string),
        "prompt" => optional(:string),
        "worktree" => optional(:string),
        "worktree_name" => optional(:string),
        "config" => optional(:object),
        "parent" => optional(:string),
        "workflow" => optional(:string),
        "private" => optional(:boolean)
      },
      "session.archive" => %{
        "command_id" => required(:string),
        "session_id" => required(:string)
      },
      "question.answer" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "call_id" => required(:string),
        "text" => required(:string)
      },
      "session.pin" => %{"command_id" => required(:string), "session_id" => required(:string)},
      "session.unpin" => %{"command_id" => required(:string), "session_id" => required(:string)},
      "session.erase" => %{"command_id" => required(:string), "session_id" => required(:string)},
      # A private session another device sealed last, taken over on this one (Decision 785):
      # the daemon's only, since a pod holds no private session.
      "session.claim" => %{"command_id" => required(:string), "session_id" => required(:string)},
      # A person invited by name into a private session sealed here, and the invitation
      # taken back (#765): the daemon's, since only it holds the session's key. `role` is
      # `observe` (the default) or `control`. A pod session is invited at the plane.
      "session.invite" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "person" => required(:string),
        "role" => optional(:string)
      },
      "session.uninvite" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "person" => required(:string)
      },
      "session.invites" => %{"session_id" => required(:string)},
      # Somebody's private session shared with this machine's person, read from the plane's
      # sealed copy with the keys in their own slot, after `after_seq`.
      "session.read_sealed" => %{
        "session_id" => required(:string),
        "after_seq" => optional(:integer)
      },
      # A second session from this one's conversation as it stands (Decision 812): the
      # daemon's; a pod session is forked through the plane's method of the same name.
      "session.fork" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "config" => optional(:object)
      },
      "input.send" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "text" => required(:string)
      },
      "turn.cancel" => %{
        "command_id" => required(:string),
        "session_id" => required(:string)
      },
      # A command the person typed, run in the session's workspace (Decision 813): `control`,
      # and the session's owner or an `admin`. `agent: false` keeps it from the agent.
      # Activating, as input is. `shell.cancel` kills one that runs.
      "shell.run" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "command" => required(:string),
        "agent" => optional(:boolean),
        "timeout_ms" => optional(:integer)
      },
      "shell.cancel" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "run_id" => required(:string)
      },
      "profile.switch" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "profile" => required(:string)
      },
      # Setting and clearing activate a dormant session, like `profile.switch`; reading
      # the goal is answered from the log and wakes nothing.
      "session.goal.set" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "text" => required(:string)
      },
      "session.goal.get" => %{"session_id" => required(:string)},
      "session.goal.clear" => %{
        "command_id" => required(:string),
        "session_id" => required(:string)
      },
      # A loop towards the goal. Starting one activates a dormant session; stopping one
      # does not, because a dormant session's loop is not running. Reading it is reading
      # the log.
      "session.loop.start" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "max_iterations" => optional(:integer)
      },
      "session.loop.stop" => %{
        "command_id" => required(:string),
        "session_id" => required(:string)
      },
      "session.loop.get" => %{"session_id" => required(:string)},
      # A delegation's answer (Decision 850) may carry `agent`, a subagent the request offered
      # to send it to instead; `brief`, the parts the person edited, held to the brief's
      # shape; and `reason`, a word back with `deny`. A wrong one is `invalid_params`, and
      # the request waits on.
      "approval.respond" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "call_id" => required(:string),
        "decision" => required(:string),
        "agent" => optional(:string),
        "brief" => optional(:object),
        "reason" => optional(:string)
      },
      "todo.edit" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "action" => required(:string),
        "id" => optional(:string),
        "content" => optional(:string)
      },
      # Files, resolved through the session's mount table and scope-checked like every
      # other command. Reading is `observe`; putting a file into a workspace is steering
      # the session and needs `control`.
      "fs.list" => %{
        "session_id" => required(:string),
        "path" => optional(:string)
      },
      "fs.read" => %{
        "session_id" => required(:string),
        "path" => required(:string)
      },
      "fs.upload" => %{
        "session_id" => required(:string),
        "path" => required(:string),
        "content" => required(:string),
        "command_id" => optional(:string)
      },
      # The session's scratchpad documents (Decision 870): the latest of each name, in the
      # order each was first shown, from its log. Read one with `fs.read` of its `path`.
      "scratch.list" => %{"session_id" => required(:string)},
      "blob.get" => %{
        "session_id" => required(:string),
        "blob" => required(:string),
        "range" => optional(:array)
      },
      "fleet.get" => %{},
      "workspace.recent" => %{"limit" => optional(:integer)},
      "workspace.search" => %{"query" => required(:string), "limit" => optional(:integer)},
      "workflows.list" => %{"workspace" => required(:string)},
      # The primaries, and with `subagents` the subagents too, each row with its `mode`
      # (Decision 852), for a workspace or for a session, which on a pod is its bundle's
      # agents: one or the other is named (#594).
      "agents.list" => %{
        "workspace" => optional(:string),
        "session_id" => optional(:string),
        "subagents" => optional(:boolean)
      },
      # One agent whole, checked, written and taken away (#503, Decision 841). Reading and
      # checking answer on a pod too; writing is the daemon's, and a pod refuses it.
      # `scope` is `user` or `project` (`workspace` is taken as `project`). `if_hash` is
      # the `hash` `agents.get` gave: a file changed since is not written over (Decision 852).
      "agents.get" => %{
        "name" => required(:string),
        "workspace" => optional(:string),
        "session_id" => optional(:string)
      },
      "agents.validate" => %{
        "source" => required(:string),
        "name" => optional(:string),
        "workspace" => optional(:string),
        "session_id" => optional(:string)
      },
      "agents.put" => %{
        "command_id" => required(:string),
        "name" => required(:string),
        "scope" => required(:string),
        "source" => required(:string),
        "if_hash" => optional(:string),
        "workspace" => optional(:string),
        "session_id" => optional(:string)
      },
      "agents.delete" => %{
        "command_id" => required(:string),
        "name" => required(:string),
        "scope" => required(:string),
        "workspace" => optional(:string),
        "session_id" => optional(:string)
      },
      # The slash commands a client may offer for a session, agents included; reading
      # the table wakes nothing.
      "commands.list" => %{"session_id" => required(:string)},
      # A command a markdown file defines, run by the harness: its prompt, with
      # `arguments` for `$ARGUMENTS`, sent as the session's input (Decision 763).
      "commands.run" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "name" => required(:string),
        "arguments" => optional(:string)
      },
      "memory.get" => %{"workspace" => required(:string)},
      # Every file the session's next prompt is read from, with its scope and its share
      # of the budget (Decision 706); reading it wakes nothing.
      "context.get" => %{"session_id" => required(:string)},
      "mcp.status" => %{"session_id" => required(:string)},
      # With `id`, one fact; without, the whole brief (Decision 839).
      "memory.forget" => %{
        "command_id" => required(:string),
        "workspace" => required(:string),
        "id" => optional(:string)
      },
      # A no to rewriting a brief an older survey wrote, remembered for that survey's
      # version (Decision 835).
      "memory.decline" => %{"workspace" => required(:string), "command_id" => optional(:string)},
      # What a session's start asks, onboarding then the brief (Decision 835); the
      # daemon's alone. `apply` and `decline` act on the items named by `ids`, or on all
      # (`all: true`); `apply` with `all` never creates an `AGENTS.md` that is not there.
      "onboard.plan" => %{"workspace" => required(:string)},
      "onboard.apply" => %{
        "workspace" => required(:string),
        "ids" => optional({:array, :string}),
        "all" => optional(:boolean),
        "command_id" => optional(:string)
      },
      "onboard.decline" => %{
        "workspace" => required(:string),
        "ids" => optional({:array, :string}),
        "all" => optional(:boolean),
        "command_id" => optional(:string)
      },
      "worktree.list" => %{"workspace" => optional(:string), "status" => optional(:boolean)},
      "worktree.remove" => %{
        "command_id" => required(:string),
        "path" => required(:string),
        "force" => optional(:boolean)
      },
      "worktree.merge" => %{
        "command_id" => required(:string),
        "workspace" => required(:string),
        "path" => required(:string),
        "message" => optional(:string)
      },
      "worktree.discard" => %{
        "command_id" => required(:string),
        "workspace" => required(:string),
        "path" => required(:string)
      },
      "watch.set" => %{
        "command_id" => required(:string),
        "workspace" => required(:string),
        "enabled" => optional(:boolean),
        "session_id" => optional(:string)
      },
      # Whether a workspace is watched, how, and by which session (Decision 844); the
      # daemon's, since a pod's session never watches.
      "watch.get" => %{"workspace" => required(:string)},
      # Presence. No `command_id`: it is not an effect to be replayed, and a client that
      # retried one would be asserting something it no longer knows to be true.
      "presence.set" => %{
        "session_id" => required(:string),
        "state" => required(:string),
        "agent" => optional({:array, :string})
      },
      "tools.register" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "tools" => required(:array),
        "consent" => optional(:object)
      },
      "tools.unregister" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "tools" => optional({:array, :string})
      },
      # Who the machine's user is: a label on what they do, for local transports, since a
      # pod knows who is calling from the token. `plane_token` is held in memory only.
      "identity.get" => %{},
      "identity.link" => %{
        "command_id" => required(:string),
        "subject" => required(:string),
        "display_name" => optional(:string),
        "plane_url" => optional(:string),
        "plane_token" => optional(:string)
      },
      "identity.unlink" => %{"command_id" => required(:string)},
      # The person signed out at a client: the token goes, the label stays (issue #381).
      "identity.sign_out" => %{
        "command_id" => required(:string),
        "plane_url" => required(:string),
        "subject" => optional(:string)
      },
      # A laptop's session offered to the plane for steering from another device, shared
      # with `[{person, role}]`, and taken back (#58): the daemon's only.
      "remote.offer" => %{
        "command_id" => required(:string),
        "session_id" => required(:string),
        "share" => optional({:array, :object})
      },
      "remote.withdraw" => %{
        "command_id" => required(:string),
        "session_id" => required(:string)
      },
      # The plane's new signing key, accepted by the fingerprint its person was shown (#657).
      "identity.accept_plane_key" => %{
        "command_id" => required(:string),
        "fingerprint" => required(:string),
        "plane_url" => optional(:string)
      },
      # The machine's settings — the daemon's; a worker refuses a session's token them.
      # The key goes in through `config.models` and `config.set` and never comes back out:
      # `config.get` reports `api_key_set`, and a secret key's value as `****`. `config.set`
      # takes the model panel's fields (`provider` and the rest), or one key by name (`key`,
      # or `path` for a name with a dot in it) with its `value` and the `scope` to write
      # (#57); `config.changed` then goes to every client. With a `session_id`,
      # `config.get` is that running session's configuration instead, what is in force in it,
      # which a pod answers its session's own token too; `explain` (`text` or `json`, for
      # `key` when one is named) adds what `troupe config --explain` says of it.
      "config.get" => %{
        "workspace" => optional(:string),
        "session_id" => optional(:string),
        "explain" => optional(:string),
        "key" => optional(:string)
      },
      "config.models" => %{
        "provider" => optional(:string),
        "base_url" => optional({:nullable, :string}),
        "api_key" => optional(:string),
        "auth" => optional(:string)
      },
      "config.set" => %{
        "command_id" => required(:string),
        "provider" => optional(:string),
        "base_url" => optional({:nullable, :string}),
        "auth" => optional(:string),
        "api_key" => optional(:string),
        "models" => optional(:object),
        "workspace" => optional(:string),
        "key" => optional(:string),
        "path" => optional({:array, :string}),
        "value" => optional(:any),
        "scope" => optional(:string)
      },
      "config.import" => %{
        "command_id" => required(:string),
        "from" => required(:string),
        "workspace" => optional(:string)
      },
      # A plane's `me.client_defaults` answer, fetched by a client signed in to it, kept as
      # this machine's copy of the organisation's defaults and limits (Decision 869).
      "config.organisation" => %{
        "command_id" => required(:string),
        "plane_url" => required(:string),
        "document" => required(:object),
        "workspace" => optional(:string)
      },
      # A plane's `me.memory` answer, fetched beside it by a client signed in to the plane,
      # kept as this machine's copy of the organisation's memory (#55) and given to the
      # sessions running here for their next turn.
      "config.memory" => %{
        "command_id" => required(:string),
        "plane_url" => required(:string),
        "document" => required(:object)
      },
      # The person's own memory document on the plane (#55), read and saved through the
      # daemon's sign-in: the whole `text` over the `version` edited, or one `append`ed entry.
      "me.memory" => %{},
      # Where this machine's copy of the plane's memory stands, for the person's own
      # debugging: what it holds, what is in force, what each session here last read.
      "me.memory.status" => %{},
      "me.memory.put" => %{
        "command_id" => required(:string),
        "text" => optional(:string),
        "version" => optional(:integer),
        "append" => optional(:string)
      },
      # A page, a document or a file published on the plane as the person (#62), through
      # the daemon's sign-in: `files` each `{path, bytes}` (base64) and an optional
      # `content_type`; `id` republishes one of theirs; `session_id` names where it came from.
      "artifact.publish" => %{
        "command_id" => required(:string),
        "title" => required(:string),
        "kind" => required(:string),
        "visibility" => required(:string),
        "files" => required(:array),
        "id" => optional(:string),
        "note" => optional(:string),
        "session_id" => optional(:string)
      },
      # The person's own artifacts on the plane (#62), for a client's "Publish a new version
      # of…": `mine`, `shared` or `visibility` narrows it, as the plane's `artifact.list`.
      "artifact.list" => %{
        "mine" => optional(:boolean),
        "shared" => optional(:boolean),
        "visibility" => optional(:string)
      },
      # A first run's questions (Decision 705) — the daemon's only, like the settings
      # they write; a worker answers `method_not_found`. `answer` is the named step's
      # answer, whose shape the step decides; the key goes in through it and never
      # comes back out.
      "setup.get" => %{},
      "setup.answer" => %{
        "command_id" => required(:string),
        "step" => required(:string),
        "answer" => optional(:object)
      },
      # The person's own MCP servers and skills (Decision 700) — the daemon's only, like
      # the settings; a worker answers `method_not_found`. A file is named to import
      # (`from`, copied, or read in place with `link`), or one server is written
      # (`name` and `server`); `scope` is `user` or `workspace`. `mcp.status` above is
      # what a session runs, and `mcp.list` with a `session_id` joins the two.
      "mcp.list" => %{"workspace" => optional(:string), "session_id" => optional(:string)},
      "mcp.add" => %{
        "command_id" => required(:string),
        "scope" => optional(:string),
        "workspace" => optional(:string),
        "name" => optional(:string),
        "server" => optional(:object),
        "from" => optional(:string),
        "link" => optional(:boolean)
      },
      "mcp.remove" => %{
        "command_id" => required(:string),
        "scope" => optional(:string),
        "workspace" => optional(:string),
        "name" => optional(:string),
        "include" => optional(:string)
      },
      "mcp.check" => %{
        "workspace" => optional(:string),
        "session_id" => optional(:string),
        "name" => optional(:string),
        "server" => optional(:object)
      },
      # A person's sign-in to a server that wants them (Decision 741) — the daemon's only:
      # it listens for the browser on this machine and keeps the tokens, and a client opens
      # the URL it answers. `mcp.list`'s `auth` says how a sign-in stands.
      "mcp.sign_in" => %{
        "command_id" => required(:string),
        "name" => required(:string),
        "workspace" => optional(:string),
        "session_id" => optional(:string)
      },
      # Signing out asks the provider to revoke the refresh token first (Decision 872);
      # `all` signs out of every server signed in to on this machine, for `troupe logout`.
      "mcp.sign_out" => %{
        "command_id" => required(:string),
        "name" => optional(:string),
        "all" => optional(:boolean),
        "workspace" => optional(:string),
        "session_id" => optional(:string)
      },
      # One of the person's servers outside any session (Decision 748) — the daemon's only:
      # its tools with their schemas, and a call made with the person's sign-in, for a
      # client that offers them to a session on a pod. The token never comes back.
      "mcp.tools" => %{
        "name" => required(:string),
        "workspace" => optional(:string),
        "session_id" => optional(:string)
      },
      "mcp.call" => %{
        "command_id" => required(:string),
        "name" => required(:string),
        "tool" => required(:string),
        "arguments" => optional(:object),
        "workspace" => optional(:string),
        "session_id" => optional(:string)
      },
      "skills.list" => %{"workspace" => optional(:string)},
      "skills.add" => %{
        "command_id" => required(:string),
        "scope" => optional(:string),
        "workspace" => optional(:string),
        "from" => required(:string),
        "link" => optional(:boolean)
      },
      "skills.remove" => %{
        "command_id" => required(:string),
        "scope" => optional(:string),
        "workspace" => optional(:string),
        "name" => optional(:string),
        "include" => optional(:string)
      },
      # Stop between turns, for `troupe update` (Decision 865) — the daemon's only; a
      # worker answers `method_not_found`. The answer is `stopping`, or why not.
      "daemon.stop" => %{}
    }
  end

  @doc """
  Requests the **server** sends the client, and the shape of their params.

  `tool.invoke` exists because a client-hosted tool runs where the client is, so the
  agent's call has to travel outwards over a connection the client already holds — there
  is nothing to dial back to, and a laptop behind a NAT could not be dialled anyway.
  `config.changed` is a notification, with no answer: the daemon telling every client
  that a settings file it writes has changed (#57), so one client shows what another set.
  `agents.changed` is one too, for an agent a client saved or took away (Decision 841).
  """
  @spec server_requests() :: %{String.t() => shape()}
  def server_requests do
    %{
      "tool.invoke" => %{
        "call_id" => required(:string),
        "name" => required(:string),
        "arguments" => required(:object)
      },
      "config.changed" => %{
        "scope" => required(:string),
        "path" => required(:string),
        "keys" => required({:array, :string}),
        "workspace" => optional(:string)
      },
      # An agent a client saved or took away (Decision 841), told to every client so each
      # list follows; `workspace` for a project one.
      "agents.changed" => %{
        "name" => required(:string),
        "scope" => required(:string),
        "path" => required(:string),
        "action" => required(:string),
        "workspace" => optional(:string)
      }
    }
  end

  # -- JSON Schema ------------------------------------------------------------

  @doc "Every document that belongs in `protocol/schema/v1/`, keyed by its relative path."
  @spec documents() :: %{Path.t() => map()}
  def documents do
    durable =
      for {type, shape} <- events(),
          into: %{},
          do: {"events/#{type}.json", document("events", type, shape)}

    ephemeral =
      for {type, shape} <- ephemeral_events(),
          into: %{},
          do: {"events/#{type}.json", document("events", type, shape)}

    commands =
      for {method, shape} <- commands(),
          into: %{},
          do: {"commands/#{method}.json", document("commands", method, shape)}

    # Under `commands/` too, and deliberately: a client that has to *answer* one needs
    # its shape published exactly as much as one it sends, and a second directory would
    # only make it easier to publish one and forget the other.
    server =
      for {method, shape} <- server_requests(),
          into: %{},
          do: {"commands/#{method}.json", document("commands", method, shape)}

    durable
    |> Map.merge(ephemeral)
    |> Map.merge(commands)
    |> Map.merge(server)
  end

  defp document(kind, name, shape) do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://troupe.dev/schema/v1/#{kind}/#{name}.json",
      "title" => name,
      "type" => "object",
      "properties" => Map.new(shape, fn {field, spec} -> {field, json_type(spec.type)} end),
      "required" =>
        shape |> Enum.filter(&elem(&1, 1).required) |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
      # Fields may be added within a major version, so a document with more than this
      # is valid — that is the compatibility rule, written into the schema itself.
      "additionalProperties" => true
    }
  end

  defp json_type({:array, inner}), do: %{"type" => "array", "items" => json_type(inner)}
  defp json_type(:text_or_blob), do: %{"type" => ["string", "object"]}
  defp json_type({:nullable, inner}), do: %{"type" => [Atom.to_string(inner), "null"]}
  defp json_type(:object), do: %{"type" => "object"}
  # Any JSON value: a setting's value is whatever that setting's type is.
  defp json_type(:any), do: %{}
  defp json_type(type), do: %{"type" => Atom.to_string(type)}

  # -- compatibility ----------------------------------------------------------

  @type incompatibility ::
          {:removed_document, Path.t()}
          | {:removed_field, Path.t(), String.t()}
          | {:retyped_field, Path.t(), String.t(), map(), map()}
          | {:newly_required, Path.t(), String.t()}

  @doc """
  Every breaking change from a committed set of documents to a current one.

  Empty means the change is compatible. A new document or a new optional field is not
  listed, because adding either is exactly what clients are built to tolerate.
  """
  @spec incompatibilities(%{Path.t() => map()}, %{Path.t() => map()}) :: [incompatibility()]
  def incompatibilities(committed, current) do
    Enum.flat_map(committed, fn {path, old} ->
      case Map.fetch(current, path) do
        :error -> [{:removed_document, path}]
        {:ok, new} -> document_incompatibilities(path, old, new)
      end
    end)
  end

  defp document_incompatibilities(path, old, new) do
    old_properties = Map.get(old, "properties", %{})
    new_properties = Map.get(new, "properties", %{})
    old_required = MapSet.new(Map.get(old, "required", []))
    new_required = MapSet.new(Map.get(new, "required", []))

    removed_or_retyped =
      Enum.flat_map(old_properties, fn {field, old_type} ->
        case Map.fetch(new_properties, field) do
          :error -> [{:removed_field, path, field}]
          {:ok, ^old_type} -> []
          {:ok, new_type} -> [{:retyped_field, path, field, old_type, new_type}]
        end
      end)

    newly_required =
      new_required
      |> MapSet.difference(old_required)
      |> Enum.map(&{:newly_required, path, &1})

    Enum.sort(removed_or_retyped ++ newly_required)
  end

  @doc "One breaking change, in a sentence a person can act on."
  @spec describe(incompatibility()) :: String.t()
  def describe({:removed_document, path}), do: "#{path}: removed; clients still expect it"

  def describe({:removed_field, path, field}),
    do: "#{path}: field #{field} was removed or renamed"

  def describe({:retyped_field, path, field, old, new}) do
    "#{path}: field #{field} changed type from #{inspect(old)} to #{inspect(new)}"
  end

  def describe({:newly_required, path, field}) do
    "#{path}: field #{field} is now required; older clients do not send it"
  end

  # -- validation -------------------------------------------------------------

  @doc """
  Check one event's `data` against its shape.

  Unknown event types pass: a client — or a test — reading a log written by a newer
  version must tolerate what it has never heard of, and so must this.
  """
  @spec validate_event(String.t(), map()) :: :ok | {:error, [String.t()]}
  def validate_event(type, data) do
    case Map.get(events(), type) || Map.get(ephemeral_events(), type) do
      nil -> :ok
      shape -> validate(shape, data)
    end
  end

  @doc "Check a map against a shape."
  @spec validate(shape(), map()) :: :ok | {:error, [String.t()]}
  def validate(shape, data) do
    problems =
      Enum.flat_map(shape, fn {field, spec} ->
        case {Map.fetch(data, field), spec.required} do
          {:error, true} -> ["missing required field #{field}"]
          {:error, false} -> []
          {{:ok, nil}, _} -> []
          {{:ok, value}, _} -> type_problem(field, spec.type, value)
        end
      end)

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp type_problem(field, type, value) do
    if matches?(type, value), do: [], else: ["#{field} should be #{inspect(type)}"]
  end

  defp matches?(:string, value), do: is_binary(value)
  defp matches?(:integer, value), do: is_integer(value)
  defp matches?(:number, value), do: is_number(value)
  defp matches?(:boolean, value), do: is_boolean(value)
  defp matches?(:object, value), do: is_map(value)
  defp matches?(:array, value), do: is_list(value)
  defp matches?(:text_or_blob, value), do: is_binary(value) or is_map(value)
  defp matches?(:any, _value), do: true

  defp matches?({:array, inner}, value) do
    is_list(value) and Enum.all?(value, &matches?(inner, &1))
  end
end
