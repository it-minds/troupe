defmodule Troupe.UI.TUI.Model do
  @moduledoc """
  The TUI's view model: a fold over session events (persisted and transient),
  so the screen can be rebuilt from `Log.all/1` after a crash.

  Besides the fold it holds the presentation-neutral text helpers the view
  needs: transcript text is sanitised once when it is folded (tabs expanded,
  escape sequences and control bytes dropped), and wrapping happens in Elixir
  so the view can count rows, scroll and take a tail without handing the
  whole transcript to the renderer.
  """

  import Kernel, except: [apply: 2]

  alias Troupe.Client.Message
  alias Troupe.Event
  alias Troupe.UI.ModelError

  @typedoc "A tool call in a transcript. `lines` is `result` split for rendering; `preview` is the approval preview (a diff for edits), when one was shown."
  @type tool_entry :: %{
          id: String.t(),
          name: String.t(),
          input: String.t(),
          status: :running | :ok | :error,
          result: String.t(),
          lines: [String.t()],
          body: [line()],
          preview: String.t() | nil,
          summary: String.t()
        }

  @type entry ::
          {:user, String.t()}
          | {:assistant, [line()]}
          | {:reasoning, [line()]}
          | {:tool, tool_entry()}
          | {:system, String.t()}

  @typedoc """
  A run of text inside a line, tagged with how the view should draw it: an atom
  the view maps to a style, or a style of its own (syntax highlighting hands
  back real colours).
  """
  @type segment :: {atom() | ExRatatui.Style.t(), String.t()}

  @typedoc """
  One logical line of a rendered transcript: its kind, and either plain text
  (styled by the kind) or the segments it is made of.
  """
  @type line :: {atom(), String.t() | [segment()]}

  @typedoc """
  Tokens a window or agent has used, in `Troupe.LLM.Provider`'s normalised shape:
  `input` is input billed in full, `cache_read` input served from the provider's
  prompt cache at a fraction of the price, `cache_write` input charged a premium
  to put there. The three are disjoint.
  """
  @type usage :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer()
        }

  @type agent :: %{
          transcript: [entry()],
          streaming: String.t(),
          streaming_reasoning: String.t(),
          todos: [map()],
          name: String.t() | nil,
          model: String.t() | nil,
          usage: usage(),
          started_at: integer() | nil,
          ended_at: integer() | nil
        }

  @typedoc "One line of the observer tree: an agent, with the window it belongs to."
  @type row :: %{
          window: window(),
          path: String.t(),
          agent: agent(),
          depth: non_neg_integer(),
          root?: boolean()
        }

  @type window :: %{
          path: String.t(),
          name: String.t(),
          profile: String.t(),
          state: atom(),
          isolation: atom(),
          started_at: integer(),
          ended_at: integer() | nil,
          usage: usage(),
          agents: %{optional(String.t()) => agent()},
          pending: [map()],
          badge: boolean(),
          summary: String.t() | nil,
          message: String.t() | nil,
          diff_stat: String.t() | nil,
          goal: String.t() | nil,
          loop: %{iteration: non_neg_integer(), max: pos_integer() | nil} | nil,
          worktree: map() | nil,
          unconfirmed: %{optional(String.t()) => String.t()},
          warnings: %{optional(atom()) => map()}
        }

  defstruct session_id: nil,
            workspace: ".",
            windows: %{},
            order: [],
            notices: [],
            watch: %{enabled: false, backend: nil},
            remote: nil,
            files_version: 0,
            mcp: %{}

  @type t :: %__MODULE__{mcp: %{optional(String.t()) => map()}}

  # Tool results kept in the view model are capped here; the log keeps them whole.
  @result_cap 200_000
  @tab 4
  # Syntax highlighting is capped per block: syntect is ~0.04 ms a line.
  @highlight_cap 400
  @theme :base16_ocean_dark

  @spec new(String.t(), String.t()) :: t()
  def new(sid, workspace), do: %__MODULE__{session_id: sid, workspace: workspace}

  @spec rebuild(String.t(), String.t(), [Event.t()]) :: t()
  def rebuild(sid, workspace, events), do: Enum.reduce(events, new(sid, workspace), &apply(&2, &1))

  @spec apply(t(), Event.t()) :: t()
  def apply(%__MODULE__{} = m, %Event{} = e) do
    root = root(e.agent_path)

    case e.type do
      :branch_spawned ->
        window = %{
          path: e.agent_path,
          name: e.data.name,
          profile: e.data.name,
          state: :running,
          isolation: e.data.isolation,
          started_at: e.ts,
          ended_at: nil,
          usage: empty_usage(),
          agents: %{e.agent_path => new_agent(%{name: e.data.name, started_at: e.ts})},
          pending: [],
          badge: false,
          activity: %{},
          activity_since: e.ts,
          # The last model error per agent, until the agent next does something.
          model_errors: %{},
          summary: nil,
          message: nil,
          diff_stat: nil,
          goal: nil,
          loop: nil,
          worktree: nil,
          unconfirmed: %{},
          warnings: %{}
        }

        order = if e.agent_path in m.order, do: m.order, else: m.order ++ [e.agent_path]
        %{m | windows: Map.put_new(m.windows, e.agent_path, window), order: order}

      :window_dismissed ->
        %{
          m
          | order: List.delete(m.order, e.agent_path),
            windows: Map.delete(m.windows, e.agent_path)
        }

      :notice ->
        %{m | notices: Enum.take([e.data.text | m.notices], 3)}

      # What the remote client knows about the session behind this window: the
      # session's own state, the scopes the token carries, and whether the
      # worker connection is up. The view reads it to disable what is not
      # allowed and to say why (Decision 77).
      :remote_status ->
        %{m | remote: Map.merge(m.remote || %{}, e.data)}

      # MCP server status is transient: the latest state per server is folded
      # here so the status line and the /mcp page read from the model, and the
      # page's live query (Client.mcp_status/1) repopulates it when it opens.
      :mcp_status ->
        entry = %{
          state: e.data.state,
          tools: length(e.data.tools),
          error: e.data.error
        }

        %{m | mcp: Map.put(m.mcp, e.data.server, entry)}

      # The files panel is a fold too: a bumped version is what tells it its
      # listing is stale, without the panel subscribing to anything itself.
      :fs_changed ->
        %{m | files_version: m.files_version + 1}

      :watch_trigger ->
        %{m | notices: Enum.take(["watch: #{e.data.kind} request from AI comments" | m.notices], 3)}

      _ ->
        update_window(m, root, fn w -> w |> apply_to_window(e) |> settle(e) end)
    end
  end

  # `needs_input` only means anything while something is outstanding, and the
  # agent that would log `branch_state :running` may never get to: a killed
  # subagent cannot answer its own request, and a `y` on a budget question
  # resumes the turn. Deriving the clear from `pending` keeps the strip, the
  # status line and Enter's "go to the branch that needs you" honest whichever
  # way the last request went away.
  defp settle(%{state: :needs_input, pending: []} = w, %Event{ts: ts}),
    do: set_state(w, :running, ts)

  defp settle(w, _e), do: w

  defp apply_to_window(w, %Event{type: type, agent_path: path, data: d, ts: ts}) do
    case type do
      # A loop's iteration starts the agent's turn like any input, but nobody typed it: the
      # transcript says which iteration it is (`:loop_iteration`) rather than printing the
      # words the loop gave the model.
      :input when d.source == :loop ->
        w
        |> ensure_agent(path)
        |> update_agent(path, fn a -> %{a | ended_at: nil} end)
        |> Map.put(:ended_at, nil)
        |> set_state(:running, ts)

      :input when d.source in [:user, :watch] ->
        w
        |> ensure_agent(path)
        |> push(path, {:user, d.content})
        |> update_agent(path, fn a -> %{a | ended_at: nil} end)
        |> Map.put(:ended_at, nil)
        |> unconfirmed(d)
        |> set_state(:running, ts)

      # A remote session renders your own input before the server has seen it;
      # `input.accepted` carrying the same command id is what confirms it.
      :input_accepted ->
        %{w | unconfirmed: Map.delete(w.unconfirmed, d[:command_id])}

      # Remote tool calls announce themselves; a local one is announced by the
      # assistant message that asked for it.
      :tool_started ->
        push(
          ensure_agent(w, path),
          path,
          {:tool, new_tool(d.call_id, d.name, summarize_input(d.name, d.input))}
        )

      :remote_note ->
        push(ensure_agent(w, path), path, {:system, d.text})

      :llm_delta ->
        w
        |> ensure_agent(path)
        |> update_agent(path, fn a ->
          if d[:reasoning] do
            %{a | streaming_reasoning: (a.streaming_reasoning || "") <> d.text}
          else
            %{a | streaming: a.streaming <> d.text}
          end
        end)

      :agent_state ->
        errors = Map.get(w, :model_errors, %{})
        errors = if d.to in [nil, :idle], do: errors, else: Map.delete(errors, path)

        Map.merge(w, %{
          activity: Map.put(w.activity, path, d.to),
          activity_since: ts,
          model_errors: errors
        })

      :assistant_message ->
        text = Message.text(d.content)
        used = used(Map.get(d, :usage) || %{})
        reasoning = reasoning_so_far(w, path)

        w =
          w
          |> ensure_agent(path)
          |> update_agent(path, fn a ->
            %{
              a
              | streaming: "",
                streaming_reasoning: "",
                usage: add(a.usage, used),
                model: Map.get(d, :model) || a.model
            }
          end)
          |> then(fn w ->
            cond do
              text == "" and reasoning == "" ->
                w

              text == "" ->
                push(w, path, {:reasoning, markdown(reasoning)})

              reasoning == "" ->
                push(w, path, {:assistant, markdown(sanitize(text))})

              true ->
                w
                |> push(path, {:reasoning, markdown(reasoning)})
                |> push(path, {:assistant, markdown(sanitize(text))})
            end
          end)

        Enum.reduce(Message.tool_uses(d.content), %{w | usage: add(w.usage, used)}, fn tu, acc ->
          push(acc, path, {:tool, new_tool(tu.id, tu.name, summarize_input(tu.name, tu.input))})
        end)

      :tool_call_completed ->
        update_agent(ensure_agent(w, path), path, fn a ->
          %{a | transcript: Enum.map(a.transcript, &complete_tool(&1, d))}
        end)

      :approval_requested ->
        pending =
          w.pending ++
            [
              %{
                kind: :approval,
                call_id: d.call_id,
                agent_path: path,
                name: d.name,
                preview: d.preview
              }
            ]

        %{w | pending: pending}
        |> update_agent(path, fn a ->
          %{a | transcript: Enum.map(a.transcript, &attach_preview(&1, d))}
        end)

      :question_asked ->
        pending =
          w.pending ++
            [
              %{
                kind: :question,
                call_id: d.call_id,
                agent_path: path,
                question: one_line(d.question),
                options: question_options(d),
                multiple: d[:multiple] == true
              }
            ]

        %{w | pending: pending}

      :budget_ask_started ->
        pending =
          w.pending ++
            [
              %{
                kind: :budget,
                call_id: d.call_id,
                agent_path: path,
                detail: d[:detail] || "budget exhausted",
                dimension: d[:dimension]
              }
            ]

        %{w | pending: pending}

      :budget_ask_answered ->
        %{w | pending: Enum.reject(w.pending, &(&1.call_id == d.call_id))}

      t when t in [:approval_answered, :question_answered] ->
        %{w | pending: Enum.reject(w.pending, &(&1.call_id == d.call_id))}

      :branch_state ->
        case d.state do
          :done_unread ->
            %{w | state: :done_unread, badge: true, ended_at: ts, summary: d[:summary] || w.summary}

          # `branch_state` is window-scoped but each agent emits it from its own
          # outstanding calls, so the root answering would clear the window while a
          # delegated subagent still waits — leaving it stuck with no signal in the
          # strip, the status line or Enter's "go to the branch that needs you".
          :running when w.pending != [] ->
            w

          :running ->
            set_state(w, :running, ts)

          :needs_input ->
            %{w | state: :needs_input}
        end

      :branch_failed ->
        w
        |> push(path, {:system, "branch failed: #{d.message}"})
        |> Map.merge(%{state: :failed_unread, badge: true, ended_at: ts, message: d.message})

      :finished ->
        w = ensure_agent(w, path)
        summary = sanitize(to_string(d.summary))
        stat = if d[:diff_stat] in [nil, ""], do: "", else: "\n#{d.diff_stat}"

        # A branch that ends with plain text finishes with that text as its summary;
        # printing it again under the message it came from is pure duplication.
        rendered = {:assistant, markdown(summary)}

        head =
          if List.last(w.agents[path].transcript) == rendered,
            do: "finished (#{d.reason})",
            else: "finished (#{d.reason}): #{summary}"

        w
        |> push(path, {:system, head <> stat})
        |> update_agent(path, fn a -> %{a | ended_at: ts} end)
        |> Map.put(:diff_stat, d[:diff_stat])

      :cancelled ->
        w |> ensure_agent(path) |> push(path, {:system, "cancelled"}) |> drop_pending(path)

      # With the next step under it where there is one: on a first run with no key, the
      # first turn is where a person learns that `troupe config` sets a provider up.
      :llm_error ->
        w
        |> ensure_agent(path)
        |> push(path, {:system, "LLM error: #{d.message}"})
        |> push_step(path, ModelError.next_step(d.message))
        |> Map.put(:model_errors, Map.put(Map.get(w, :model_errors, %{}), path, d.message))

      :todo_updated ->
        update_agent(ensure_agent(w, path), path, fn a -> %{a | todos: d.items} end)

      :delegation_started ->
        w
        |> ensure_agent(d.child_path, %{name: d.agent, started_at: ts})
        |> push(path, {:system, "delegated to #{d.child_path} (#{d.agent}) — →/← views it"})

      :delegation_completed ->
        w
        |> ensure_agent(d.child_path)
        |> update_agent(d.child_path, fn a -> %{a | ended_at: ts} end)
        |> drop_pending(d.child_path)

      :profile_switched ->
        w |> push(path, {:system, "profile switched to #{d.name}"}) |> Map.put(:profile, d.name)

      # Said once in the transcript, where it happened, and kept on the window for the
      # status line, which shows it for as long as it is set.
      :goal_set ->
        w
        |> ensure_agent(path)
        |> push(path, {:system, "goal: " <> d.text})
        |> Map.put(:goal, d.text)

      :goal_cleared ->
        w |> ensure_agent(path) |> push(path, {:system, "goal cleared"}) |> Map.put(:goal, nil)

      # A loop towards the goal (issue #59): said in the transcript as it goes, and kept on
      # the window while it runs, for the status line's "loop 2/10".
      :loop_started ->
        w
        |> ensure_agent(path)
        |> push(path, {:system, "loop: up to #{d.max_iterations} iterations towards the goal"})
        |> Map.put(:loop, %{iteration: 0, max: d.max_iterations})

      :loop_iteration ->
        %{max: max} = Map.get(w, :loop) || %{max: nil}

        w
        |> ensure_agent(path)
        |> push(path, {:system, "loop iteration #{d.iteration}#{if max, do: "/#{max}", else: ""}"})
        |> Map.put(:loop, %{iteration: d.iteration, max: max})

      :loop_iteration_finished when d.outcome == "failed" ->
        push(
          ensure_agent(w, path),
          path,
          {:system, "loop iteration #{d.iteration} failed" <> said(d.detail)}
        )

      :loop_stopped ->
        w |> ensure_agent(path) |> push(path, {:system, loop_stopped(d)}) |> Map.put(:loop, nil)

      :worktree_created ->
        %{
          w
          | worktree: %{path: d.path, git_branch: d.git_branch, managed: Map.get(d, :managed, true)}
        }

      :worktree_merged ->
        w = %{w | worktree: w.worktree && Map.put(w.worktree, :merged, not d.conflicts)}

        push(
          w,
          path,
          {:system,
           if(d.conflicts,
             do: "merge had conflicts; resolve in your checkout",
             else: "merged into checkout"
           )}
        )

      :worktree_discarded ->
        push(
          %{w | worktree: w.worktree && Map.put(w.worktree, :discarded, true)},
          path,
          {:system, "worktree discarded"}
        )

      :compaction ->
        push(w, path, {:system, "context compacted (#{d.dropped_messages} messages summarized)"})

      :compaction_started ->
        push(w, path, {:system, compaction_reason(d[:reason])})

      # A warning is the one signal that arrives while there is still budget left
      # to spend, so it goes in the transcript *and* stays on the window, where the
      # tile and the token line can show the denominator the UI never had.
      :budget_warning ->
        %{w | warnings: Map.put(w.warnings, d.dimension, d)}
        |> push(path, {:system, "⚠ " <> (d[:detail] || to_string(d.dimension)) <> " used"})

      :truncated ->
        push(w, path, {:system, truncation_line(d)})

      _ ->
        w
    end
  end

  defp compaction_reason(:context_overflow),
    do: "the prompt no longer fit the context window — compacting and retrying the turn"

  defp compaction_reason(_requested), do: "compacting the conversation"

  defp truncation_line(%{reason: :empty, final: true}),
    do: "the reply had no text and no tool call again — stopping rather than reporting success"

  defp truncation_line(%{reason: :empty}),
    do: "the reply had no text and no tool call — asking the model to continue"

  defp truncation_line(%{final: true}),
    do: "the reply hit the output token cap again — stopping rather than reporting success"

  defp truncation_line(%{calls: n}) when is_integer(n) and n > 0,
    do: "the reply hit the output token cap mid-tool-call"

  defp truncation_line(_d), do: "the reply hit the output token cap — asking again in smaller steps"

  defp set_state(w, state, _ts), do: %{w | state: state}

  # Only the optimistic copy of an input carries a command id worth waiting on:
  # one that came off the wire is already confirmed by definition.
  defp unconfirmed(w, %{optimistic: true, command_id: id, content: text}) when is_binary(id),
    do: %{w | unconfirmed: Map.put(w.unconfirmed, id, text)}

  defp unconfirmed(w, _data), do: w

  # An agent that is gone never logs `approval_answered`/`question_answered`, so
  # its request would sit in `pending` forever: unanswerable (Approvals dropped
  # its entry when the pid died) and, because of the guard above, blocking every
  # later `:running`. Delegation ending and cancellation are the two points where
  # the whole subtree is known to be dead.
  defp drop_pending(w, path) do
    prefix = path <> "/"

    %{
      w
      | pending:
          Enum.reject(w.pending, fn p ->
            p.agent_path == path or String.starts_with?(p.agent_path, prefix)
          end)
    }
  end

  defp new_tool(id, name, input) do
    %{
      id: id,
      name: name,
      input: one_line(input),
      status: :running,
      result: "",
      lines: [],
      body: [],
      preview: nil,
      summary: ""
    }
  end

  defp complete_tool({:tool, %{id: id} = t}, %{call_id: id} = d) do
    result =
      (d.content || "")
      |> String.slice(0, @result_cap)
      |> sanitize()
      |> String.replace_suffix("\n", "")

    status = if d.ok, do: :ok, else: :error
    t = %{t | status: status, result: result, lines: String.split(result, "\n")}
    t = %{t | summary: summary(t)}
    {:tool, %{t | body: build_body(t)}}
  end

  defp complete_tool(entry, _), do: entry

  defp attach_preview({:tool, %{id: id} = t}, %{call_id: id} = d) when is_binary(d.preview),
    do: {:tool, %{t | preview: sanitize(d.preview)}}

  defp attach_preview(entry, _), do: entry

  # Options come off the log as maps with atom keys (`Codec` restores them) and
  # from a live event as the same shape, but a session recorded before options
  # existed has no key at all — hence the default rather than a match.
  defp question_options(data) do
    data
    |> Map.get(:options)
    |> List.wrap()
    |> Enum.map(fn opt ->
      %{
        label: one_line(Map.get(opt, :label, "")),
        description: opt |> Map.get(:description) |> describe()
      }
    end)
    |> Enum.reject(&(&1.label == ""))
  end

  defp describe(nil), do: nil
  defp describe(text), do: one_line(text)

  # What a collapsed tool line says after `name input`: the outcome, in a few words.
  defp summary(%{status: :error, lines: lines}) do
    first = lines |> Enum.map(&String.trim/1) |> Enum.find("", &(&1 != ""))
    n = length(lines)
    String.slice(first, 0, 80) <> if(n > 1, do: " (#{n} lines)", else: "")
  end

  # `finish` is followed by its own system line; its result ("finishing") says nothing.
  defp summary(%{status: :ok, name: "finish"}), do: ""

  defp summary(%{status: :ok} = t) do
    case diff_stat(t) do
      nil ->
        case Enum.reject(t.lines, &(&1 == "")) do
          [] -> ""
          [only] when byte_size(only) <= 60 -> String.trim(only)
          lines -> "#{length(lines)} lines"
        end

      stat ->
        stat
    end
  end

  defp diff_stat(%{name: n, preview: "--- " <> _ = p}) when n in ["edit_file", "write_file"] do
    lines = String.split(p, "\n")
    ins = Enum.count(lines, &(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
    del = Enum.count(lines, &(String.starts_with?(&1, "-") and not String.starts_with?(&1, "---")))
    "+#{ins} -#{del}"
  end

  defp diff_stat(_), do: nil

  defp summarize_input("shell", %{"command" => c}), do: c
  defp summarize_input("web_fetch", %{"url" => u}), do: u

  defp summarize_input("todo_write", %{"items" => items}) when is_list(items),
    do: "#{length(items)} items"

  defp summarize_input(_, %{"path" => p}), do: p
  defp summarize_input("delegate", %{"agent" => a}), do: a
  defp summarize_input("finish", %{"summary" => s}), do: String.slice(s, 0, 60)
  defp summarize_input("ask_user", %{"question" => q}), do: q
  defp summarize_input(_, input), do: input |> Jason.encode!() |> String.slice(0, 60)

  defp new_agent(attrs \\ %{}) do
    Map.merge(
      %{
        transcript: [],
        streaming: "",
        streaming_reasoning: "",
        todos: [],
        name: nil,
        model: nil,
        usage: empty_usage(),
        started_at: nil,
        ended_at: nil
      },
      attrs
    )
  end

  # The reasoning accumulated while the turn streamed, before the message's
  # `assistant_message` folds it into a transcript entry.
  defp reasoning_so_far(%{agents: agents}, path) do
    agents
    |> Map.get(path, new_agent())
    |> Map.get(:streaming_reasoning, "")
  end

  defp ensure_agent(w, path, attrs \\ %{}),
    do: %{w | agents: Map.put_new(w.agents, path, new_agent(attrs))}

  defp update_agent(w, path, fun),
    do: %{w | agents: Map.update(w.agents, path, fun.(new_agent()), fun)}

  defp push(w, path, {kind, text}) when kind in [:user, :system],
    do: push_entry(w, path, {kind, sanitize(text)})

  defp push(w, path, entry), do: push_entry(w, path, entry)

  defp push_step(w, _path, nil), do: w
  defp push_step(w, path, step), do: push(w, path, {:system, step})

  defp push_entry(w, path, entry),
    do: update_agent(w, path, fn a -> %{a | transcript: a.transcript ++ [entry]} end)

  defp update_window(m, path, fun) do
    case Map.get(m.windows, path) do
      nil -> m
      w -> %{m | windows: Map.put(m.windows, path, fun.(w))}
    end
  end

  @spec root(String.t()) :: String.t()
  def root(path), do: path |> String.split("/") |> hd()

  @spec windows(t()) :: [window()]
  def windows(%__MODULE__{} = m), do: Enum.map(m.order, &Map.fetch!(m.windows, &1))

  @doc """
  The loop this screen's session is running, `%{iteration, max}`, as its events say, or
  `nil` when none runs: the session's own window's, like `goal/1`.
  """
  @spec loop(t()) :: %{iteration: non_neg_integer(), max: pos_integer() | nil} | nil
  def loop(%__MODULE__{windows: windows}) do
    case Map.get(windows, "root") do
      %{loop: %{} = loop} -> loop
      _ -> nil
    end
  end

  @doc """
  The goal this screen's session has, as its events say, for the status line: the one on
  the session's own window, `"root"`. A branch is a session of its own and keeps its goal
  on its own window.
  """
  @spec goal(t()) :: String.t() | nil
  def goal(%__MODULE__{windows: windows}) do
    case Map.get(windows, "root") do
      %{goal: goal} -> goal
      _ -> nil
    end
  end

  # How a loop ended, in the transcript: the evidence when the goal is met, the reason
  # otherwise, in words rather than the log's tokens.
  defp loop_stopped(%{reason: "goal_complete"} = d),
    do: "loop done after #{iterations(d.iterations)}: the goal is met" <> said(d.summary)

  defp loop_stopped(d),
    do: "loop stopped after #{iterations(d.iterations)}: #{loop_reason(d.reason)}" <> said(d.detail)

  defp loop_reason("max_iterations"), do: "it reached its limit"
  defp loop_reason("failures"), do: "too many iterations failed in a row"
  defp loop_reason("budget"), do: "the budget is spent and asks you first"
  defp loop_reason("requested"), do: "stopped on request"
  defp loop_reason("cancelled"), do: "the turn was cancelled"
  defp loop_reason("goal_cleared"), do: "the goal was cleared"
  defp loop_reason("interrupted"), do: "the session stopped while it ran"
  defp loop_reason("agent_done"), do: "the agent takes no more input"
  defp loop_reason(other), do: other

  defp iterations(1), do: "1 iteration"
  defp iterations(n), do: "#{n} iterations"

  defp said(text) when is_binary(text) and text != "", do: " — " <> text
  defp said(_text), do: ""

  @doc """
  MCP servers as the `/mcp` page and the status line read them: the latest
  folded status per server, sorted by name. The fold is transient (driven by
  `:mcp_status` events) so it may be empty after a crash until the page's live
  query repopulates it.
  """
  @spec mcp_servers(t()) :: [
          %{name: String.t(), state: atom(), tools: non_neg_integer(), error: String.t() | nil}
        ]
  def mcp_servers(%__MODULE__{mcp: mcp}) do
    mcp
    |> Enum.map(fn {name, %{state: state, tools: tools, error: error}} ->
      %{name: name, state: state, tools: tools, error: error}
    end)
    |> Enum.sort_by(& &1.name)
  end

  def mcp_servers(_), do: []

  @doc "The agents of a window in display order: the root first, then its subagents by path."
  @spec agent_paths(window()) :: [String.t()]
  def agent_paths(w) do
    children =
      w.agents
      |> Map.delete(w.path)
      |> Enum.sort_by(fn {path, agent} -> {agent.started_at || 0, path} end)
      |> Enum.map(&elem(&1, 0))

    [w.path | children]
  end

  @spec attention_summary(t()) :: String.t()
  def attention_summary(%__MODULE__{} = m) do
    ws = windows(m)
    needs = Enum.count(ws, &(&1.state == :needs_input))
    done = Enum.count(ws, &(&1.state == :done_unread and &1.badge))
    failed = Enum.count(ws, &(&1.state == :failed_unread and &1.badge))

    [
      needs > 0 && "#{needs} need input",
      done > 0 && "#{done} done",
      failed > 0 && "#{failed} failed"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "idle"
      parts -> Enum.join(parts, ", ")
    end
  end

  @spec elapsed(window(), integer()) :: String.t()
  def elapsed(w, now_ms) do
    ms = (w.ended_at || now_ms) - w.started_at
    s = div(max(ms, 0), 1000)

    "#{String.pad_leading(Integer.to_string(div(s, 60)), 2, "0")}:#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}"
  end

  @spinner ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @doc "The spinner glyphs the activity line cycles through."
  @spec spinner_glyphs() :: [String.t()]
  def spinner_glyphs, do: @spinner

  @doc "One line describing what the branch is doing right now, or nil when resting."
  @spec activity_line(window(), non_neg_integer(), integer()) :: String.t() | nil
  def activity_line(w, tick, now), do: activity_line(w, w.path, tick, now)

  @doc """
  What one agent of a window is doing right now, or nil when it rests: the
  root agent's line is the window's, a subagent's comes from its own state,
  running tools and pending items.
  """
  @spec activity_line(window(), String.t(), non_neg_integer(), integer()) :: String.t() | nil
  def activity_line(%{state: s}, _path, _tick, _now)
      when s in [:done_unread, :failed_unread, :dismissed],
      do: nil

  def activity_line(w, path, tick, now) do
    agent = Map.get(w.agents, path, new_agent())

    if path != w.path and agent.ended_at != nil do
      nil
    else
      spinner = Enum.at(@spinner, rem(tick, 10))
      since = elapsed(%{w | started_at: w.activity_since, ended_at: nil}, now)
      state = Map.get(w.activity, path)
      tools = running_tools(agent)
      waiting? = Enum.any?(w.pending, &(&1.agent_path == path))

      children =
        Enum.reject(w.activity, fn {p, s} ->
          not String.starts_with?(p, path <> "/") or s == :done
        end)

      main =
        cond do
          waiting? or (path == w.path and w.state == :needs_input) ->
            "waiting for you"

          state == :thinking ->
            "#{spinner} thinking (#{since})"

          state == :compacting ->
            "#{spinner} compacting context (#{since})"

          state == :acting and tools != [] ->
            "#{spinner} running #{Enum.join(tools, ", ")} (#{since})"

          state == :acting ->
            "#{spinner} working (#{since})"

          state in [nil, :idle] and tools != [] ->
            "#{spinner} running #{Enum.join(tools, ", ")}"

          # Stopped, not starting: no spinner, and the reason where the user is looking.
          state in [nil, :idle] and is_map_key(Map.get(w, :model_errors, %{}), path) ->
            "model error: #{w.model_errors[path]}"

          # An agent that has said it is resting is not doing anything, and saying
          # "starting" about it — forever, with a spinner — was the root agent's normal
          # appearance while the user chatted with it. `nil` still means starting,
          # because then nothing has been heard from the agent at all.
          state == :idle ->
            nil

          state == nil ->
            "#{spinner} starting"

          true ->
            "#{spinner} #{state}"
        end

      # An idle agent has no line of its own, but a subagent still working under it does.
      case {main, children} do
        {main, []} -> main
        {nil, list} -> child_summary(list)
        {main, list} -> main <> " · " <> child_summary(list)
      end
    end
  end

  defp child_summary(children) do
    Enum.map_join(children, ", ", fn {p, s} ->
      "#{p |> String.split("/") |> List.last()} #{s}"
    end)
  end

  ## Observer

  @doc """
  Every agent in the session as observer rows: each window's root agent first,
  then the subagents it delegated to, deepest path last.
  """
  @spec observer_rows(t()) :: [row()]
  def observer_rows(%__MODULE__{} = m) do
    Enum.flat_map(windows(m), fn w ->
      w
      |> agent_paths()
      |> Enum.map(fn p ->
        %{
          window: w,
          path: p,
          agent: Map.fetch!(w.agents, p),
          depth: length(String.split(p, "/")) - 1,
          root?: p == w.path
        }
      end)
    end)
  end

  @doc """
  What one agent is doing: a pending approval or question outranks everything
  (that agent is the one waiting for you), then a resting window's own state,
  then the agent's last `agent_state`.
  """
  @spec agent_state(row()) :: atom()
  def agent_state(%{window: w, path: p, agent: a, root?: root?}) do
    cond do
      Enum.any?(w.pending, &(&1.agent_path == p)) -> :needs_input
      root? and w.state in [:done_unread, :failed_unread] -> w.state
      a.ended_at != nil -> :done
      Map.has_key?(w.activity, p) -> Map.fetch!(w.activity, p)
      running_tools(a) != [] -> :acting
      true -> :idle
    end
  end

  @doc "The tool calls an agent has in flight, as `name input` strings."
  @spec running_tools(agent()) :: [String.t()]
  def running_tools(agent) do
    for {:tool, %{status: :running, name: name, input: input}} <- agent.transcript,
        do: "#{name} #{String.slice(input, 0, 24)}"
  end

  @doc "How long an agent has been going (or ran for, once it is done)."
  @spec agent_elapsed(row(), integer()) :: String.t()
  def agent_elapsed(%{window: w, agent: a}, now_ms),
    do: elapsed(%{started_at: a.started_at || w.started_at, ended_at: a.ended_at}, now_ms)

  @doc "The directory an agent works in: the branch's worktree when it has one."
  @spec working_dir(window(), String.t()) :: String.t()
  def working_dir(%{worktree: %{path: path}}, _workspace), do: path
  def working_dir(_window, workspace), do: workspace

  @doc "A zero usage."
  @spec empty_usage() :: usage()
  def empty_usage, do: %{input: 0, output: 0, cache_read: 0, cache_write: 0}

  @doc "Sums two usages."
  @spec add(usage(), usage()) :: usage()
  def add(a, b) do
    %{
      input: a.input + b.input,
      output: a.output + b.output,
      cache_read: a.cache_read + b.cache_read,
      cache_write: a.cache_write + b.cache_write
    }
  end

  # An `assistant_message` written before the cache figures existed simply has none.
  defp used(reported) do
    %{
      input: Map.get(reported, :input_tokens, 0),
      output: Map.get(reported, :output_tokens, 0),
      cache_read: Map.get(reported, :cache_read, 0),
      cache_write: Map.get(reported, :cache_write, 0)
    }
  end

  @doc """
  Compact token counts for a tile or a tree row: `↑12.4k ↓3.1k`, sent and
  received. `↑` is what was billed in full — input read back from the provider's
  prompt cache is most of a long conversation's prompt and a fraction of its
  price, so it is left to `token_detail/1` rather than inflating the headline.
  """
  @spec tokens(%{usage: usage()}) :: String.t()
  def tokens(%{usage: u}), do: "↑#{short(u.input + u.cache_write)} ↓#{short(u.output)}"

  @doc """
  The same counts spelled out, with what the prompt cache served and — once a
  budget warning has fired — how close the tightest ceiling is. Cumulative counts
  with no denominator were the whole of what the UI said about limits, so the
  first signal a user got was the branch stopping.
  """
  @spec token_detail(%{usage: usage()}) :: String.t()
  def token_detail(%{usage: u} = a) do
    "↑ #{short(u.input + u.cache_write)} sent · ↓ #{short(u.output)} received" <>
      if(u.cache_read > 0 or u.cache_write > 0,
        do: " · #{short(u.cache_read)} of the prompt came from cache",
        else: ""
      ) <> headroom_suffix(a)
  end

  @doc """
  The tightest limit a warning has fired for, as `82% of input tokens`, or `""`
  when nothing has crossed the threshold. Windows carry the warnings; an agent
  map does not, so it reads as empty there.
  """
  @spec headroom_note(map()) :: String.t()
  def headroom_note(%{warnings: warnings}) when map_size(warnings) > 0 do
    {_dim, w} = Enum.max_by(warnings, fn {_dim, w} -> w[:fraction] || 0.0 end)
    "#{round((w[:fraction] || 0.0) * 100)}% of #{dimension_label(w.dimension)}"
  end

  def headroom_note(_a), do: ""

  # Spelled out here rather than read from `Agent.Headroom`: the UI may call
  # `Troupe.Client` and the pure data modules and nothing else, and five words
  # are not worth a new exception to that.
  defp dimension_label(:turns), do: "turns"
  defp dimension_label(:input), do: "input tokens"
  defp dimension_label(:output), do: "output tokens"
  defp dimension_label(:wall), do: "wall clock"
  defp dimension_label(:context), do: "context window"
  defp dimension_label(other), do: to_string(other)

  defp headroom_suffix(a) do
    case headroom_note(a) do
      "" -> ""
      note -> " · ⚠ " <> note
    end
  end

  @doc """
  The same counts as one short line each, for the side panel, which is too narrow
  for `token_detail/1`. The cache line is only there when the provider cached.
  """
  @spec token_lines(%{usage: usage()}) :: [String.t()]
  def token_lines(%{usage: u} = a) do
    ["↑ #{short(u.input + u.cache_write)} sent", "↓ #{short(u.output)} received"] ++
      if(u.cache_read > 0, do: ["⟳ #{short(u.cache_read)} from cache"], else: []) ++
      case headroom_note(a) do
        "" -> []
        note -> ["⚠ " <> note]
      end
  end

  @doc "Every token a window or agent has accounted for, cached input included."
  @spec total_tokens(%{usage: usage()}) :: non_neg_integer()
  def total_tokens(%{usage: u}), do: u.input + u.output + u.cache_read + u.cache_write

  defp short(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp short(n), do: "#{n}"

  ## Transcript lines

  @doc "The one-line form of a tool call: glyph, name, input and (once done) its outcome."
  @spec tool_head(tool_entry()) :: String.t()
  def tool_head(%{status: status, name: name, input: input, summary: summary}) do
    "#{status_glyph(status)} #{name} #{input}" <>
      if(summary == "", do: "", else: " · " <> summary)
  end

  defp status_glyph(:running), do: "⋯"
  defp status_glyph(:ok), do: "✓"
  defp status_glyph(:error), do: "✗"

  @doc """
  Everything the activated pane shows for one agent, as blocks of tagged
  logical lines: one block per transcript entry, then the text being streamed,
  the activity line and whatever the window is waiting on. Blocks let the view
  keep the same entry at the top when tool output is expanded or collapsed.

  `selection` is the reader's in-progress answer to a multiple-choice question
  (`%{call_id, selected}`), which lives in the UI process rather than the log:
  it is a cursor, not a decision, and it dies with the frame if the question is
  answered elsewhere.
  """
  @spec pane_blocks(window(), String.t(), boolean(), non_neg_integer(), integer(), map() | nil) ::
          [[line()]]
  def pane_blocks(w, agent_path, expanded?, tick, now, selection \\ nil) do
    agent = Map.get(w.agents, agent_path, new_agent())
    entries = Enum.map(agent.transcript, &entry_lines(&1, expanded?))

    reasoning =
      if agent.streaming_reasoning in ["", nil],
        do: [],
        else: [reasoning_lines(agent.streaming_reasoning, expanded?)]

    streaming =
      if agent.streaming == "",
        do: [],
        else: [streaming_lines(agent.streaming)]

    pending = pending_blocks(w, agent_path, selection)

    activity =
      case pending == [] && activity_line(w, agent_path, tick, now) do
        line when is_binary(line) -> [[{:blank, ""}, {:activity, activity_segments(line)}]]
        _ -> []
      end

    entries ++ reasoning ++ streaming ++ activity ++ pending
  end

  @doc "A window tile's body: the root transcript with tool calls collapsed, then the activity line."
  @spec tile_lines(window(), non_neg_integer(), integer(), boolean()) :: [line()]
  def tile_lines(w, tick, now, spacer?) do
    agent = Map.get(w.agents, w.path, new_agent())
    lines = Enum.flat_map(agent.transcript, &entry_lines(&1, false))

    reasoning =
      if agent.streaming_reasoning in ["", nil],
        do: [],
        else: reasoning_lines(agent.streaming_reasoning, false)

    streaming =
      if agent.streaming == "", do: [], else: streaming_lines(agent.streaming)

    activity =
      case activity_line(w, tick, now) do
        nil ->
          []

        line ->
          if(spacer?, do: [{:blank, ""}], else: []) ++ [{:activity, activity_segments(line)}]
      end

    lines ++ reasoning ++ streaming ++ activity
  end

  # Text still arriving is shown plain: it changes on every frame, and it becomes
  # markdown the moment the message lands.
  defp streaming_lines(text),
    do: text |> sanitize() |> String.split("\n") |> Enum.map(&{:text, &1})

  # Reasoning is collapsible: the header line always shows (that the model is
  # thinking is itself worth seeing), and the body only when `e` has expanded
  # output. The same shape renders a folded-in `{:reasoning, lines}` entry.
  defp reasoning_lines(text, expanded?) do
    head = {:reasoning_head, [{:reasoning_marker, "💭 "}, {:reasoning_title, "reasoning"}]}
    if expanded?, do: [head | reasoning_body(text)], else: [head]
  end

  defp reasoning_body(text),
    do: text |> sanitize() |> String.split("\n") |> Enum.map(&{:reasoning_body, &1})

  defp entry_lines({:user, text}, _expanded?) do
    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map(fn
      {l, 0} -> {:user, [{:user_marker, "> "}, {:user, l}]}
      {l, _} -> {:user, [{:gutter, "  "}, {:user, l}]}
    end)
  end

  defp entry_lines({:assistant, lines}, _expanded?), do: lines

  # A folded-in reasoning block collapses exactly like streaming reasoning, with
  # the header plus the body when output is expanded.
  defp entry_lines({:reasoning, lines}, expanded?) do
    head = {:reasoning_head, [{:reasoning_marker, "💭 "}, {:reasoning_title, "reasoning"}]}
    if expanded?, do: [head | lines], else: [head]
  end

  defp entry_lines({:system, text}, _expanded?),
    do: Enum.map(String.split(text, "\n"), &{:system, "· " <> &1})

  defp entry_lines({:tool, t}, expanded?) do
    head = {head_kind(t.status), head_segments(t)}
    if expanded?, do: [head | t.body], else: [head]
  end

  defp head_segments(%{status: status, name: name, input: input, summary: summary}) do
    [
      {:tool_glyph, status_glyph(status)},
      {:tool_name, " " <> name},
      {:tool_arg, " " <> input}
    ] ++ if(summary == "", do: [], else: [{:tool_note, " · " <> summary}])
  end

  defp activity_segments(line) do
    {glyph, rest} = String.split_at(line, 1)

    if glyph in @spinner,
      do: [{:activity_glyph, glyph}, {:activity, rest}],
      else: [{:activity, line}]
  end

  defp head_kind(:running), do: :tool_running
  defp head_kind(:ok), do: :tool_ok
  defp head_kind(:error), do: :tool_err

  # Built once, when the call completes: the per-frame path only slices it.
  defp build_body(%{name: "finish"}), do: []

  defp build_body(%{preview: preview, lines: lines, result: result, summary: summary} = t) do
    diff =
      if is_binary(preview) and String.starts_with?(preview, "--- "),
        do: preview |> String.split("\n") |> Enum.map(&diff_line/1),
        else: []

    body =
      if result == "" or Enum.map(lines, &String.trim/1) == [summary],
        do: [],
        else: body_lines(t)

    diff ++ body
  end

  # `read_file` returns numbered lines: show them as source, with the numbers in
  # their own gutter and the code highlighted for the file's language.
  defp body_lines(%{name: "read_file", input: path, lines: lines}) do
    numbered = Enum.map(lines, &split_number/1)

    if numbered != [] and Enum.all?(numbered, &(&1 != nil)),
      do: numbered_source(numbered, language_of(path)),
      else: Enum.map(lines, &{:body, &1})
  end

  defp body_lines(%{lines: lines}), do: Enum.map(lines, &{:body, &1})

  # `read_file` right-aligns the number in five columns and follows it with a tab,
  # which `sanitize/1` expands to the next stop: an eight-column gutter. Splitting
  # on that fixed width keeps the code's own indentation out of the separator.
  @gutter_width 8

  defp split_number(line) when byte_size(line) >= @gutter_width do
    {prefix, code} = String.split_at(line, @gutter_width)

    case Regex.run(~r/^\s*(\d+)\s+$/, prefix) do
      [_, number] -> {number, code}
      _ -> nil
    end
  end

  defp split_number(_line), do: nil

  defp numbered_source(numbered, language) do
    code = Enum.map_join(numbered, "\n", &elem(&1, 1))

    numbered
    |> Enum.zip(highlight(code, language, length(numbered)))
    |> Enum.map(fn {{number, _}, segments} ->
      {:code_num, [{:linenum, String.pad_leading(number, 5)}, {:code_rail, " │ "} | segments]}
    end)
  end

  ## Markdown

  @doc """
  Assistant text as lines: fenced code becomes a highlighted block with a rule
  above and below it, headings, bullets, quotes and horizontal rules get their
  own kind, and the rest is prose with inline code and bold picked out.
  """
  @spec markdown(String.t()) :: [line()]
  def markdown(text) when is_binary(text), do: text |> String.split("\n") |> block([])

  defp block([], acc), do: Enum.reverse(acc)

  defp block(["```" <> info | rest], acc) do
    {code, after_code} = Enum.split_while(rest, &(not fence?(&1)))
    block(Enum.drop(after_code, 1), Enum.reverse(code_block(code, info)) ++ acc)
  end

  defp block([line | rest], acc), do: block(rest, [prose(line) | acc])

  defp fence?(line), do: line |> String.trim() |> String.starts_with?("```")

  defp code_block(code, info) do
    label = info |> String.trim() |> String.split(~r/\s/) |> hd()
    language = if label == "", do: nil, else: label
    highlighted = highlight(Enum.join(code, "\n"), language, length(code))

    [rule_above(label)] ++
      Enum.map(highlighted, &{:code, &1}) ++
      [{:code_tail, [{:muted, "└"}, {:fill, "─"}]}]
  end

  defp rule_above(""), do: {:code_head, [{:muted, "┌"}, {:fill, "─"}]}

  defp rule_above(label),
    do: {:code_head, [{:muted, "┌─ "}, {:code_lang, label}, {:muted, " "}, {:fill, "─"}]}

  defp prose(line) do
    cond do
      match = Regex.run(~r/^(\#{1,6})\s+(.*)$/, line) ->
        [_, hashes, text] = match
        {:heading, [{:muted, hashes <> " "} | inline(text)]}

      match = Regex.run(~r/^(\s*)([-*+])\s+(.*)$/, line) ->
        [_, lead, _marker, text] = match
        {:bullet, [{:bullet_marker, lead <> "• "} | inline(text)]}

      match = Regex.run(~r/^(\s*)(\d+[.)])\s+(.*)$/, line) ->
        [_, lead, marker, text] = match
        {:bullet, [{:bullet_marker, lead <> marker <> " "} | inline(text)]}

      match = Regex.run(~r/^>\s?(.*)$/, line) ->
        [_, text] = match
        {:quote, inline(text)}

      Regex.match?(~r/^\s*(-{3,}|\*{3,}|_{3,})\s*$/, line) ->
        {:rule, [{:fill, "─"}]}

      true ->
        {:text, inline(line)}
    end
  end

  # Inline markup worth the trouble in a coding harness: `code` and **bold**.
  # The markers are dropped, so a row is as wide as what it shows.
  defp inline(text) do
    case Regex.split(~r/(`[^`\n]+`|\*\*[^*\n]+\*\*)/, text, include_captures: true, trim: true) do
      [] -> [{:text, text}]
      parts -> Enum.map(parts, &inline_part/1)
    end
  end

  defp inline_part("`" <> _ = part), do: {:code_inline, String.slice(part, 1..-2//1)}
  defp inline_part("**" <> _ = part), do: {:strong, String.slice(part, 2..-3//1)}
  defp inline_part(part), do: {:text, part}

  @doc "The syntect language for a path, from its extension."
  @spec language_of(String.t()) :: String.t() | nil
  def language_of(path) when is_binary(path) do
    case path |> Path.extname() |> String.trim_leading(".") do
      "" -> nil
      ext -> ext
    end
  end

  def language_of(_), do: nil

  # Highlighting happens once, where the event is folded, and only up to a size:
  # syntect costs about 0.04 ms a line, which a long file would make felt.
  defp highlight(code, language, line_count) do
    lines = String.split(code, "\n")

    if language && line_count <= @highlight_cap do
      code
      |> ExRatatui.CodeBlock.highlight(language, @theme)
      |> Enum.map(fn %{spans: spans} -> Enum.flat_map(spans, &token/1) end)
      |> pad_to(lines)
    else
      Enum.map(lines, &[{:code, &1}])
    end
  end

  # syntect keeps the line's newline on its last token; a span may not contain one.
  defp token(%{content: content, style: style}) do
    case String.replace(content, ~r/[\r\n]/, "") do
      "" -> []
      text -> [{style, text}]
    end
  end

  # syntect drops a trailing empty line; the gutter still needs a row for it.
  defp pad_to(highlighted, lines) when length(highlighted) >= length(lines),
    do: Enum.take(highlighted, length(lines))

  defp pad_to(highlighted, lines),
    do: highlighted ++ List.duplicate([{:code, ""}], length(lines) - length(highlighted))

  defp diff_line("+++" <> _ = l), do: {:diff_meta, l}
  defp diff_line("---" <> _ = l), do: {:diff_meta, l}
  defp diff_line("@@" <> _ = l), do: {:diff_meta, l}
  defp diff_line("+" <> _ = l), do: {:diff_add, l}
  defp diff_line("-" <> _ = l), do: {:diff_del, l}
  defp diff_line(l), do: {:body, l}

  # Whatever the window waits on, shown at the end of every agent's pane so the
  # keys that answer it (y / n / a, Enter) are explained where the reader looks.
  defp pending_blocks(%{pending: []}, _path, _selection), do: []

  defp pending_blocks(w, path, selection) do
    [
      Enum.flat_map(w.pending, fn item ->
        who = if item.agent_path == path, do: "", else: "[#{item.agent_path}] "

        case item do
          %{kind: :approval, name: name, preview: preview} ->
            [
              {:blank, ""},
              {:pending, "#{who}APPROVAL: #{name} (y allow / n deny / a allow for session)"}
              | (preview || "") |> sanitize() |> String.split("\n") |> Enum.map(&diff_line/1)
            ]

          %{kind: :question, question: q} ->
            [{:blank, ""}, {:pending, "#{who}QUESTION: #{q}"}] ++
              question_lines(item, selection)

          %{kind: :budget} ->
            [
              {:blank, ""},
              {:pending, "#{who}BUDGET EXHAUSTED: continue anyway? (y yes / n stop / a always)"}
            ]

          # Never raise here: the renderer's caller drops the frame on an
          # exception, which reads as a frozen terminal.
          %{kind: kind} ->
            [{:blank, ""}, {:pending, "#{who}WAITING: #{kind}"}]
        end
      end)
    ]
  end

  # A question with no options is still just an input box.
  defp question_lines(%{options: []}, _selection),
    do: [{:system, "type your answer and press Enter"}]

  defp question_lines(item, selection) do
    selected = selected_labels(item, selection)

    options =
      item.options
      |> Enum.with_index(1)
      |> Enum.map(fn {opt, n} -> option_line(opt, n, item.multiple, opt.label in selected) end)

    options ++ [{:system, hint(item.multiple)}]
  end

  defp option_line(opt, n, multiple?, chosen?) do
    marker = if multiple?, do: if(chosen?, do: "[x] ", else: "[ ] "), else: ""
    detail = if opt.description, do: " — " <> opt.description, else: ""
    tag = if chosen?, do: :pending, else: :body
    {tag, [{:bullet_marker, "  #{n}. "}, {tag, marker <> opt.label}, {:muted, detail}]}
  end

  defp hint(true),
    do: "digits toggle · Enter sends the ticked options · or type an answer and press Enter"

  defp hint(false), do: "press a digit to choose · or type an answer and press Enter"

  # The reader's ticks only count while they belong to the question on screen: a
  # question answered and replaced by another must not inherit them.
  defp selected_labels(%{call_id: id}, %{call_id: id, selected: selected}), do: selected
  defp selected_labels(_item, _selection), do: []

  ## Text: sanitising, measuring, wrapping

  @doc """
  Makes text safe to lay out: expands tabs to 4-column stops (the renderer
  would drop them, gluing `read_file`'s line numbers to the code), strips ANSI
  escape sequences (the ESC would vanish and leave `[32m` litter) and drops
  other control bytes except newlines.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(text) when is_binary(text) do
    text = Regex.replace(~r/\e\[[0-?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[@-Z\\-_]?/u, text, "")

    if Regex.match?(~r/[\x00-\x09\x0B-\x1F\x7F]/u, text) do
      text |> String.split("\n") |> Enum.map_join("\n", &clean_line/1)
    else
      text
    end
  end

  def sanitize(other), do: sanitize(to_string(other))

  @doc """
  Sanitises text that has to fit on one row — a tool head's argument, a pending
  question. Model output is routinely multi-line (an `ask_user` question, a
  heredoc in a `shell` command), and a newline inside a rendered span aborts the
  frame, so the whole screen stays blank until the text scrolls away.
  """
  @spec one_line(String.t()) :: String.t()
  def one_line(text) do
    text |> sanitize() |> String.replace(~r/\s*\n\s*/, " ") |> String.trim()
  end

  defp clean_line(line) do
    line
    |> String.replace(~r/[\x00-\x08\x0A-\x1F\x7F]/u, "")
    |> expand_tabs()
  end

  defp expand_tabs(line) do
    case String.split(line, "\t") do
      [_only] ->
        line

      [first | rest] ->
        {out, _col} =
          Enum.reduce(rest, {first, cell_width(first)}, fn seg, {acc, col} ->
            pad = @tab - rem(col, @tab)
            {acc <> String.duplicate(" ", pad) <> seg, col + pad + cell_width(seg)}
          end)

        out
    end
  end

  @doc "Terminal cells a string occupies: wide East Asian glyphs and emoji count 2, combining marks 0."
  @spec cell_width(String.t()) :: non_neg_integer()
  def cell_width(text) do
    if ascii?(text),
      do: byte_size(text),
      else: text |> String.graphemes() |> Enum.reduce(0, &(&2 + grapheme_width(&1)))
  end

  defp ascii?(text), do: not Regex.match?(~r/[^\x00-\x7F]/, text)

  defp grapheme_width(<<cp::utf8, _::binary>>) do
    cond do
      cp < 0x0300 -> 1
      combining?(cp) -> 0
      wide?(cp) -> 2
      true -> 1
    end
  end

  defp grapheme_width(_), do: 1

  defp combining?(cp),
    do: cp in 0x0300..0x036F or cp in 0x200B..0x200F or cp in 0x20D0..0x20FF or cp == 0xFE0F

  defp wide?(cp) do
    cp in 0x1100..0x115F or cp in 0x2E80..0x303E or cp in 0x3041..0x33FF or
      cp in 0x3400..0x4DBF or cp in 0x4E00..0x9FFF or cp in 0xA000..0xA4CF or
      cp in 0xAC00..0xD7A3 or cp in 0xF900..0xFAFF or cp in 0xFE30..0xFE4F or
      cp in 0xFF00..0xFF60 or cp in 0xFFE0..0xFFE6 or cp in 0x1F300..0x1F64F or
      cp in 0x1F900..0x1F9FF or cp in 0x20000..0x3FFFD
  end

  @doc """
  Splits one logical line into rows of at most `width` cells, never trimming:
  leading whitespace and indentation survive on every row. `:word` breaks at
  the last space when there is one (prose); `:char` breaks anywhere (code and
  tool output, where a mid-word break beats a shifted column).
  """
  @spec wrap(String.t(), pos_integer(), :char | :word) :: [String.t()]
  def wrap(text, width, mode) when is_binary(text) and width > 0 do
    [{:text, text}]
    |> wrap_segments(width, width, mode)
    |> Enum.map(&segment_text/1)
  end

  @doc "Rows a logical line takes at `width`; one when it fits (bytes bound cells, so no wrapping needed to tell)."
  @spec height(String.t(), pos_integer(), :char | :word) :: pos_integer()
  def height(line, width, _mode) when byte_size(line) <= width, do: 1
  def height(line, width, mode), do: length(wrap(line, width, mode))

  @doc "The plain text of a line or of a list of segments."
  @spec line_text(line() | [segment()]) :: String.t()
  def line_text({_kind, text}) when is_binary(text), do: text
  def line_text({_kind, segments}) when is_list(segments), do: segment_text(segments)
  def line_text(segments) when is_list(segments), do: segment_text(segments)

  defp segment_text(segments), do: Enum.map_join(segments, fn {_tag, text} -> text end)

  @doc "A line's segments, tagged with its own kind when it is plain text."
  @spec segments(line()) :: [segment()]
  def segments({kind, text}) when is_binary(text), do: [{kind, text}]
  def segments({_kind, segments}) when is_list(segments), do: segments

  # Segment tags that draw a rail or gutter rather than content: they are dropped
  # when a slice of a row is copied.
  @rail_tags [:gutter, :code_rail, :quote_rail, :linenum]

  @doc """
  Splits one *wrapped* row's segments at two cell columns into
  `{before, inside, after}`, each a segment list in the original order with the
  original tags. `:end` means "to the end of the row". A wide glyph is never
  cut: it belongs to the part that has room for it, so the three pieces always
  reassemble into the row.
  """
  @spec split_row(line(), non_neg_integer(), non_neg_integer() | :end) ::
          {[segment()], [segment()], [segment()]}
  def split_row(line, from, to) do
    from = max(from, 0)
    to = if to == :end, do: :end, else: max(to, from)
    {pre, ins, post} = line |> segments() |> split_segments(from, to, 0, {[], [], []})
    {Enum.reverse(pre), Enum.reverse(ins), Enum.reverse(post)}
  end

  defp split_segments([], _from, _to, _col, acc), do: acc

  defp split_segments([{tag, text} | rest], from, to, col, {pre, ins, post}) do
    width = cell_width(text)

    {head, tail} =
      if from > col, do: take_cells(text, min(from - col, width)), else: {"", text}

    {inside, after_} =
      case to do
        :end -> {tail, ""}
        n -> take_cells(tail, max(n - max(col, from), 0))
      end

    acc = {keep(pre, tag, head), keep(ins, tag, inside), keep(post, tag, after_)}
    split_segments(rest, from, to, col + width, acc)
  end

  defp keep(acc, _tag, ""), do: acc
  defp keep(acc, tag, text), do: [{tag, text} | acc]

  @doc """
  The plain text of one *wrapped* row between two cell columns (`:end` for the
  rest of the row), with rails and gutters dropped: a selection is what the
  reader sees, and nobody wants `│ ` prefixes on their clipboard.
  """
  @spec row_slice(line(), non_neg_integer(), non_neg_integer() | :end) :: String.t()
  def row_slice(line, from, to) do
    {_pre, inside, _post} = split_row(line, from, to)
    inside |> Enum.reject(fn {tag, _text} -> tag in @rail_tags end) |> segment_text()
  end

  @doc """
  The rail drawn down the left of a line kind: `{first row, later rows}`. It is
  emitted as a real segment when a line is wrapped, so the view never has to
  know which row it is looking at, and a wrapped bullet or code line keeps its
  text in one column.
  """
  @spec rail(atom()) :: {segment() | nil, segment() | nil}
  def rail(kind) when kind in [:body, :diff_add, :diff_del, :diff_meta], do: {gutter(), gutter()}
  def rail(:code), do: {{:code_rail, "│ "}, {:code_rail, "│ "}}
  def rail(:code_num), do: {nil, {:gutter, "        "}}
  def rail(kind) when kind in [:code_head, :code_tail], do: {nil, nil}
  def rail(:bullet), do: {nil, gutter()}
  def rail(:quote), do: {{:quote_rail, "▏"}, {:quote_rail, "▏"}}
  def rail(kind) when kind in [:reasoning_head, :reasoning_body], do: {gutter(), gutter()}
  def rail(_kind), do: {nil, nil}

  defp gutter, do: {:gutter, "  "}

  defp rail_width(nil), do: 0
  defp rail_width({_tag, text}), do: cell_width(text)

  @doc "Total visual rows of tagged lines at `width`."
  @spec row_count([line()], pos_integer()) :: non_neg_integer()
  def row_count(lines, width),
    do: Enum.reduce(lines, 0, fn line, acc -> acc + line_height(line, width) end)

  @doc """
  Visual rows `offset` to `offset + count - 1` of tagged lines wrapped at
  `width`. Only the lines in view are wrapped; the rest are just measured.
  """
  @spec rows([line()], pos_integer(), non_neg_integer(), non_neg_integer()) :: [line()]
  def rows(_lines, _width, _offset, count) when count <= 0, do: []
  def rows([], _width, _offset, _count), do: []

  def rows([line | rest], width, offset, count) do
    h = line_height(line, width)

    if offset >= h do
      rows(rest, width, offset - h, count)
    else
      taken = line |> wrap_line(width) |> Enum.drop(offset) |> Enum.take(count)
      taken ++ rows(rest, width, 0, count - length(taken))
    end
  end

  @doc """
  The last `count` visual rows of tagged lines at `width`, measured from the
  end: a tile never pays for the transcript above the rows it shows.
  """
  @spec tail_rows([line()], pos_integer(), non_neg_integer()) :: [line()]
  def tail_rows(_lines, _width, count) when count <= 0, do: []

  def tail_rows(lines, width, count) do
    {taken, n} =
      lines
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn line, {acc, n} ->
        rows = wrap_line(line, width)
        acc = {rows ++ acc, n + length(rows)}
        if elem(acc, 1) >= count, do: {:halt, acc}, else: {:cont, acc}
      end)

    Enum.drop(taken, max(n - count, 0))
  end

  # Measuring never builds a string, and a line whose bytes fit its first row is
  # one row without any character work at all: a cell is never more than a byte.
  defp line_height({kind, _} = line, width) do
    {first, rest} = rail(kind)
    segs = segments(line)
    first_w = room(width, first)

    cond do
      byte_total(segs) <= first_w ->
        1

      Enum.reduce(segs, 0, fn {tag, text}, acc -> acc + measure(tag, text) end) <= first_w ->
        1

      true ->
        length(wrap_segments(segs, first_w, room(width, rest), wrap_mode(kind)))
    end
  end

  defp byte_total(segs) do
    Enum.reduce(segs, 0, fn
      {:fill, _text}, acc -> acc
      {_tag, text}, acc -> acc + byte_size(text)
    end)
  end

  defp wrap_line({kind, _} = line, width) do
    {first, rest} = rail(kind)
    first_w = room(width, first)
    rest_w = room(width, rest)

    line
    |> segments()
    |> wrap_segments(first_w, rest_w, wrap_mode(kind))
    |> Enum.with_index()
    |> Enum.map(fn
      {row, 0} -> {kind, prepend(first, row)}
      {row, _} -> {kind, prepend(rest, row)}
    end)
  end

  # A fill stretches into whatever is left, so it never decides how tall a line is.
  defp measure(:fill, _text), do: 0
  defp measure(_tag, text), do: cell_width(text)

  defp room(width, rail), do: max(width - rail_width(rail), 1)

  defp prepend(nil, row), do: row
  defp prepend(rail, row), do: [rail | row]

  # Wrapping segments keeps every token with the style it was given: a row is
  # filled segment by segment, and a segment too long for what is left is split.
  defp wrap_segments(segments, first_w, rest_w, mode),
    do: fill(segments, first_w, rest_w, mode, [], [], first_w)

  defp fill([], _fw, _rw, _mode, [_ | _] = rows, [], _room), do: Enum.reverse(rows)
  defp fill([], _fw, _rw, _mode, rows, cur, _room), do: Enum.reverse([Enum.reverse(cur) | rows])

  defp fill([{_tag, ""} | rest], fw, rw, mode, rows, cur, room),
    do: fill(rest, fw, rw, mode, rows, cur, room)

  # A rule stops one column short of the edge, where the scrollbar rides.
  defp fill([{:fill, char} | rest], fw, rw, mode, rows, cur, room) do
    bar = String.duplicate(char, max(room - 1, 0))
    fill(rest, fw, rw, mode, rows, [{:muted, bar} | cur], 0)
  end

  defp fill([{tag, text} = seg | rest], fw, rw, mode, rows, cur, room) do
    width = cell_width(text)

    cond do
      width <= room ->
        fill(rest, fw, rw, mode, rows, [seg | cur], room - width)

      cur != [] and not fits_any?(text, room, mode) ->
        fill([seg | rest], fw, rw, mode, [Enum.reverse(cur) | rows], [], rw)

      true ->
        # A word with no break point inside an empty row is cut: something must
        # be consumed or the fill would not terminate.
        {head, tail} =
          case split_at(text, room, mode) do
            {"", _} -> take_cells(text, max(room, 1))
            split -> split
          end

        rows = [Enum.reverse([{tag, head} | cur]) | rows]
        fill([{tag, tail} | rest], fw, rw, mode, rows, [], rw)
    end
  end

  # In word mode a segment that has no break point inside `room` moves to the
  # next row whole rather than being cut mid-word.
  defp fits_any?(_text, room, :char), do: room > 0
  defp fits_any?(text, room, :word), do: elem(split_at(text, room, :word), 0) != ""

  defp split_at(text, room, :char), do: take_cells(text, max(room, 1))

  defp split_at(text, room, :word) do
    {head, tail} = take_cells(text, max(room, 1))

    cond do
      tail == "" ->
        {head, tail}

      String.starts_with?(tail, " ") ->
        {head, String.trim_leading(tail, " ")}

      (pos = last_space(head)) != nil and pos > 0 ->
        {binary_part(head, 0, pos), binary_part(head, pos + 1, byte_size(head) - pos - 1) <> tail}

      true ->
        {"", text}
    end
  end

  defp last_space(text) do
    case :binary.matches(text, " ") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # Cuts `text` after `room` cells. ASCII is one byte per cell, so the common
  # case is two binary_parts and no grapheme walk.
  defp take_cells(text, room) do
    cond do
      ascii?(text) and byte_size(text) <= room -> {text, ""}
      ascii?(text) -> {binary_part(text, 0, room), binary_part(text, room, byte_size(text) - room)}
      true -> take_graphemes(String.graphemes(text), room, [])
    end
  end

  defp take_graphemes([], _room, acc), do: {rev_join(acc), ""}

  defp take_graphemes([g | rest] = all, room, acc) do
    width = grapheme_width(g)

    if width <= room,
      do: take_graphemes(rest, room - width, [g | acc]),
      else: {rev_join(acc), Enum.join(all)}
  end

  defp rev_join(acc), do: acc |> Enum.reverse() |> Enum.join()

  defp wrap_mode(k) when k in [:body, :diff_add, :diff_del, :diff_meta, :code, :code_num],
    do: :char

  defp wrap_mode(_), do: :word
end
