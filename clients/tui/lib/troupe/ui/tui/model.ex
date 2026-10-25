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

  @typedoc "A tool call in a transcript. `lines` is `result` split for rendering; `preview` is the approval preview (a diff for edits), when one was shown; `started_at` and `ended_at` are the times its events carried, for the duration its frame's header says (TUI Decision 161)."
  @type tool_entry :: %{
          id: String.t(),
          name: String.t(),
          input: String.t(),
          status: :running | :ok | :error,
          result: String.t(),
          lines: [String.t()],
          body: [line()],
          preview: String.t() | nil,
          summary: String.t(),
          started_at: integer() | nil,
          ended_at: integer() | nil
        }

  @typedoc """
  What the model thought before it answered, drawn as a reasoning frame (TUI Decision
  161): its lines, and how long it thought when the live deltas said when it began.
  """
  @type reasoning :: %{lines: [line()], ms: non_neg_integer() | nil}

  @typedoc """
  A command the person ran (`!cmd`, Decision 152): what they typed, what it printed
  (streamed while it runs, then the tail the harness kept), and how it ended. `agent` is
  false for one kept from the agent (`!!cmd`); `where` names the plane's profile whose
  pod ran it, and is nil for a session on this machine.
  """
  @type shell_entry :: %{
          id: String.t(),
          command: String.t(),
          output: String.t(),
          lines: [String.t()],
          status: :running | :exited | :timeout | :killed | :failed,
          exit_status: integer() | nil,
          reason: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          agent: boolean(),
          where: String.t() | nil
        }

  @typedoc """
  A document `show` put on the scratchpad (root Decision 870), as the card that stands
  where its call was (TUI Decision 159): never its words, which `/scratch` opens.
  `version` counts the writes of its name, the first included.
  """
  @type scratch_card :: %{
          call_id: String.t() | nil,
          name: String.t(),
          path: String.t(),
          kind: String.t(),
          title: String.t(),
          size: non_neg_integer(),
          version: pos_integer()
        }

  @type entry ::
          {:user, String.t()}
          | {:assistant, [line()]}
          | {:reasoning, reasoning()}
          | {:tool, tool_entry()}
          | {:shell, shell_entry()}
          | {:scratch, scratch_card()}
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

  @typedoc """
  What one turn cost, as the event that ends it says (root Decision 769): its model calls,
  their usage summed, the micro-dollars of the calls that were priced, and how many were not.
  """
  @type turn :: %{
          calls: non_neg_integer(),
          usage: usage(),
          cost_micros: non_neg_integer(),
          unpriced: non_neg_integer()
        }

  @typedoc """
  One agent of a window. `reasoning_at` is when the reasoning being streamed began;
  `open_from` the first entry after a budget stop, from which nothing in its transcript is
  collapsed (TUI Decision 161).
  """
  @type agent :: %{
          transcript: [entry()],
          streaming: String.t(),
          streaming_reasoning: String.t(),
          reasoning_at: integer() | nil,
          todos: [map()],
          name: String.t() | nil,
          model: String.t() | nil,
          usage: usage(),
          started_at: integer() | nil,
          ended_at: integer() | nil,
          open_from: non_neg_integer() | nil
        }

  @typedoc "What a window's turns cost so far: their model calls, the micro-dollars priced, and the calls nobody priced."
  @type spend :: %{
          calls: non_neg_integer(),
          cost_micros: non_neg_integer(),
          unpriced: non_neg_integer()
        }

  @typedoc "A loop towards the goal while it runs: which one, and where it is."
  @type loop :: %{id: String.t() | nil, iteration: non_neg_integer(), max: pos_integer() | nil}

  @typedoc "One line of the observer tree: an agent, with the window it belongs to."
  @type row :: %{
          window: window(),
          path: String.t(),
          agent: agent(),
          depth: non_neg_integer(),
          root?: boolean()
        }

  @typedoc """
  A window: one agent's branch and the subagents it delegated to. `state` is derived by
  the fold (`:idle`, `:running`, `:needs_input`, `:done_unread`, `:failed_unread`), from
  what is `pending`, from `outcome`, how the window's own agent's last turn ended (`nil`
  while it works), and from `started`, whether its agent has been given anything to do
  at all (TUI Decision 155: a window nobody asked anything of is idle, not running);
  `badge` says the window has ended since it was last opened. `session_id` is the
  branch's own session, when its window was opened with one, and `cost` what its own
  agent's turns cost, as the events that end them say (Decision 139); `last_turn` is the
  last of those turns, from its end until the next one starts (TUI Decision 160).
  `curtain` counts the phases of each kind the window's own agent has been through in its
  turn (thinking, acting, compacting), which choose the curtain line's flourish so none
  repeats within a turn (TUI Decision 161).
  """
  @type window :: %{
          path: String.t(),
          name: String.t(),
          profile: String.t(),
          state: atom(),
          outcome: :done | :failed | nil,
          started: boolean(),
          session_id: String.t() | nil,
          cost: spend(),
          last_turn: turn() | nil,
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
          loop: loop() | nil,
          worktree: map() | nil,
          unconfirmed: %{optional(String.t()) => String.t()},
          drawn_inputs: %{optional(String.t()) => String.t()},
          warnings: %{optional(atom()) => map()},
          curtain: %{optional(atom()) => pos_integer()}
        }

  defstruct session_id: nil,
            workspace: ".",
            windows: %{},
            order: [],
            notices: [],
            watch: %{enabled: false, backend: nil},
            remote: nil,
            files_version: 0,
            # Bumped by each `scratch_updated`: an open `/scratch` lists again from it.
            scratch_version: 0,
            mcp: %{},
            # Who else is attached to the session now, from presence (root #58): by
            # `{subject, via}`, so a person here and on another device are two.
            present: %{}

  @type t :: %__MODULE__{mcp: %{optional(String.t()) => map()}}

  # Tool results kept in the view model are capped here; the log keeps them whole.
  @result_cap 200_000
  @tab 4
  # Syntax highlighting is capped per block: syntect is ~0.04 ms a line.
  @highlight_cap 400
  @theme :base16_ocean_dark
  @no_spend %{calls: 0, cost_micros: 0, unpriced: 0}

  @spec new(String.t(), String.t()) :: t()
  def new(sid, workspace), do: %__MODULE__{session_id: sid, workspace: workspace}

  @spec rebuild(String.t(), String.t(), [Event.t()]) :: t()
  def rebuild(sid, workspace, events), do: Enum.reduce(events, new(sid, workspace), &apply(&2, &1))

  @doc """
  Whether this is a laptop's session steered from here through the plane (root #58): the
  laptop's daemon says so in `initialize` (`capabilities.relayed`), and answers an approval
  from here once, never for the rest of the session.
  """
  @spec relayed?(t()) :: boolean()
  def relayed?(%__MODULE__{remote: %{relayed?: true}}), do: true
  def relayed?(_model), do: false

  @spec apply(t(), Event.t()) :: t()
  def apply(%__MODULE__{} = m, %Event{} = e) do
    root = root(e.agent_path)

    case e.type do
      :branch_spawned ->
        # A branch opens with its prompt and is working from the start; the session's own
        # window opens with none, and is idle until something is asked of its agent.
        started = (e.data[:prompt] || "") != ""

        window = %{
          path: e.agent_path,
          name: e.data.name,
          profile: e.data.name,
          state: if(started, do: :running, else: :idle),
          outcome: nil,
          started: started,
          session_id: e.data[:session_id],
          cost: @no_spend,
          last_turn: nil,
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
          # The lines drawn for inputs the agent has not yet taken, by command id.
          drawn_inputs: %{},
          warnings: %{},
          curtain: %{}
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

      # Somebody joined or left (root #58): a line in the session's own window, and who is
      # here now for the status line. Focusing and typing are not news.
      :presence ->
        presence(m, e.data)

      # What the daemon says of watch, whoever turned it on or off (root Decision 844).
      :watch_changed ->
        %{m | watch: %{enabled: e.data.enabled, backend: e.data[:backend]}}

      # What the remote client knows about the session behind this window: the
      # session's own state, the scopes the token carries, and whether the
      # worker connection is up. The view reads it to disable what is not
      # allowed and to say why (Decision 77).
      :remote_status ->
        %{m | remote: Map.merge(m.remote || %{}, e.data)}

      # The files panel is a fold too: a bumped version is what tells it its
      # listing is stale, without the panel subscribing to anything itself.
      :fs_changed ->
        %{m | files_version: m.files_version + 1}

      # A document on the scratchpad (TUI Decision 159): its card in the window, and a
      # bumped version, which is what tells an open `/scratch` its listing is stale.
      :scratch_updated ->
        update_window(%{m | scratch_version: m.scratch_version + 1}, root, fn w ->
          w |> apply_to_window(e) |> settle(e)
        end)

      _ ->
        update_window(m, root, fn w -> w |> apply_to_window(e) |> settle(e) end)
    end
  end

  # A window's state is derived here, once, from what its events said: the daemon sends
  # none (the old harness's `branch_state` went with it). It needs you while anything in
  # it is pending, a subagent's request as much as its own agent's, and otherwise says
  # where that agent is: working, or at rest after a turn that finished or failed.
  # Deriving it from `pending` keeps the strip, the status line and Enter's "go to the
  # branch that needs you" honest whichever way the last request went away: a killed
  # subagent never answers its own, and a `y` on a budget question resumes the turn.
  defp settle(w, %Event{} = e) do
    w = w |> begun(e) |> turn(e)
    %{w | state: window_state(w)}
  end

  defp window_state(%{pending: [_ | _]}), do: :needs_input
  defp window_state(%{outcome: :done}), do: :done_unread
  defp window_state(%{outcome: :failed}), do: :failed_unread
  defp window_state(%{started: false}), do: :idle
  defp window_state(_w), do: :running

  # What says a window's agent has been given something to do (TUI Decision 155): its
  # own work, never a note about it. A session's own window opens with the session and
  # hears that it was created, that its agent started and what its start asks, and is
  # idle through all of it; it used to read `running` from its first frame.
  @work ~w(input assistant_message llm_delta tool_started approval_requested question_asked
           budget_ask_started cancelled llm_error call_usage)a

  defp begun(%{started: true} = w, _e), do: w
  defp begun(w, %Event{type: type}) when type in @work, do: %{w | started: true}

  defp begun(w, %Event{type: :agent_state, data: %{to: to}} = e) do
    if to in [nil, :idle, :done] and e.transient?, do: w, else: %{w | started: true}
  end

  defp begun(w, _e), do: w

  # Where the window's own agent is. At rest as the log says it: `turn_ended`, `cancelled`
  # and `agent_done` arrive as a durable `agent_state`, while the live one says `idle`
  # once before the agent has even taken its task, so it is no rest. Working again on any
  # word that it works, live or not. The end is unread (`badge`) until the window is
  # opened; a subagent's own end is its parent's business, not its window's.
  defp turn(%{path: path} = w, %Event{type: :agent_state, agent_path: path, data: d} = e) do
    case {d.to, e.transient?} do
      {to, false} when to in [:idle, :done] ->
        failure = failure(w, to, d[:reason], d[:detail])
        outcome = if failure, do: :failed, else: :done
        %{w | outcome: outcome, message: failure, badge: true, ended_at: e.ts}

      {to, _transient?} when to in [nil, :idle, :done] ->
        w

      _working ->
        working(w)
    end
  end

  defp turn(w, _e), do: w

  # A turn that starts puts the last one's figures away: the side box says nothing of a
  # turn while it runs (TUI Decision 160), as the line under it never did.
  defp working(w),
    do: %{w | outcome: nil, message: nil, ended_at: nil, started: true, last_turn: nil}

  # Why a rest is a failure, in words, or nil when it is none: the line the headless
  # printer draws between a run that finished and one that ended short, save that a cancel
  # is the person's own doing and leaves the window done (Decision 7).
  defp failure(_w, :done, reason, _detail) when reason not in [nil, "finished"],
    do: "the agent ended #{reason}"

  defp failure(_w, _to, "tool_failures", _detail),
    do: "a tool kept failing, and the harness stopped the turn"

  defp failure(_w, _to, "agent_failed", detail), do: crashed(detail)

  defp failure(_w, _to, "cancelled", _detail), do: nil

  defp failure(%{path: path} = w, _to, _reason, _detail) do
    case Map.get(w, :model_errors, %{}) do
      %{^path => message} -> "the model request failed: #{message}"
      _ -> nil
    end
  end

  # A root that crashed as often as it may be restarted, in one line with the first line
  # of what it raised (Decision 727).
  defp crashed(detail) when is_binary(detail) and detail != "",
    do: "the agent kept crashing, and its session stopped: " <> one_line(detail)

  defp crashed(_detail), do: "the agent kept crashing, and its session stopped"

  defp apply_to_window(w, %Event{type: type, agent_path: path, data: d, ts: ts} = e) do
    case type do
      # A loop's iteration starts the agent's turn like any input, but nobody typed it: the
      # transcript says which iteration it is (`:loop_iteration`) rather than printing the
      # words the loop gave the model.
      :input when d.source == :loop ->
        w
        |> ensure_agent(path)
        |> update_agent(path, fn a -> %{a | ended_at: nil} end)
        |> working()
        |> new_curtain(path)

      :input when d.source in [:user, :watch] ->
        w
        |> ensure_agent(path)
        |> draw_input(path, d)
        |> update_agent(path, fn a -> %{a | ended_at: nil} end)
        |> unconfirmed(d)
        |> working()
        |> new_curtain(path)

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
          {:tool, new_tool(d.call_id, d.name, summarize_input(d.name, d.input), ts)}
        )

      # A budget that ran out is a stop: nothing after it is collapsed (TUI Decision 161).
      :remote_note ->
        w = ensure_agent(w, path)
        w = if budget_stop?(d.text), do: open_from_here(w, path), else: w
        push(w, path, {:system, d.text})

      # The `show` call that wrote it becomes its card, so the transcript never holds the
      # document's words; one whose call is not on screen gets a card of its own.
      :scratch_updated ->
        card = Map.take(d, [:call_id, :name, :path, :kind, :title, :size, :version])
        w = ensure_agent(w, path)
        call = d.call_id

        if is_binary(call) and
             Enum.any?(w.agents[path].transcript, &match?({:tool, %{id: ^call}}, &1)) do
          update_agent(w, path, fn a ->
            %{a | transcript: Enum.map(a.transcript, &card_for(&1, call, card))}
          end)
        else
          push(w, path, {:scratch, card})
        end

      # The agent the window's own agent is, as it started and whenever it is switched (root
      # Decision 841): what its header says it runs (TUI Decision 156). The transcript
      # says so in the note beside this.
      :agent_named when path == w.path and is_binary(d.name) ->
        %{w | profile: d.name}
        |> ensure_agent(path)
        |> update_agent(path, &%{&1 | name: d.name})

      # A subagent is named by the agent it runs as it starts, so the window's side panel
      # says `explore#1 (explore)`, not the window's own agent (D113).
      :agent_named when is_binary(d.name) ->
        w |> ensure_agent(path) |> update_agent(path, &%{&1 | name: d.name})

      # A saved comment started a branch of this session (root Decision 844): said in the
      # session's own transcript, where the person would otherwise see nothing of it.
      :watch_triggered ->
        push(ensure_agent(w, path), path, {:system, watch_line(d)})

      # The person's own command (Decision 152): a block of its own, opened when it
      # starts, filled as it prints, and settled by the durable `user_shell`, which is all a
      # replay has of it. Whichever of the three comes first opens the block.
      :shell_started ->
        shell(w, path, d.run_id, &%{&1 | command: d.command, agent: d.agent, where: d[:where]})

      :shell_output ->
        shell(w, path, d.run_id, fn s ->
          if s.status == :running, do: put_output(s, s.output <> d.text), else: s
        end)

      :user_shell ->
        shell(w, path, d.run_id, fn s ->
          s
          |> Map.merge(Map.take(d, [:command, :status, :exit_status, :reason, :timeout_ms, :agent]))
          |> Map.put(:where, d[:where])
          |> put_output(d.output)
        end)

      :llm_delta ->
        w
        |> ensure_agent(path)
        |> update_agent(path, fn a ->
          if d[:reasoning] do
            at = if a.streaming_reasoning in ["", nil], do: ts, else: Map.get(a, :reasoning_at)

            %{a | streaming_reasoning: (a.streaming_reasoning || "") <> d.text}
            |> Map.put(:reasoning_at, at)
          else
            %{a | streaming: a.streaming <> d.text}
          end
        end)

      # An agent has ended when the log says it is done (`agent_done`): a subagent that
      # finished, or one a restart closed, says nothing more and shows no spinner.
      :agent_state ->
        errors = Map.get(w, :model_errors, %{})
        errors = if d.to in [nil, :idle], do: errors, else: Map.delete(errors, path)

        w
        |> curtain_phase(path, d.to)
        |> Map.merge(%{
          activity: Map.put(w.activity, path, d.to),
          activity_since: ts,
          model_errors: errors
        })
        |> then(fn w ->
          if d.to == :done and not e.transient?,
            do: w |> ensure_agent(path) |> update_agent(path, &%{&1 | ended_at: ts}),
            else: w
        end)
        # The session stops after it, so the transcript is where it is read, as a model
        # error is.
        |> then(fn w ->
          if d[:reason] == "agent_failed" and not e.transient?,
            do: w |> ensure_agent(path) |> push(path, {:system, crashed(d[:detail])}),
            else: w
        end)
        |> turn_cost(path, d, e.transient?)

      :assistant_message ->
        text = Message.text(d.content)
        used = used(Map.get(d, :usage) || %{})
        reasoning = reasoning_so_far(w, path)
        thought = thought(w, path, ts)

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
            |> Map.put(:reasoning_at, nil)
          end)
          |> then(fn w ->
            cond do
              text == "" and reasoning == "" ->
                w

              text == "" ->
                push(w, path, {:reasoning, %{lines: markdown(reasoning), ms: thought}})

              reasoning == "" ->
                push(w, path, {:assistant, text |> sanitize() |> markdown() |> frame()})

              true ->
                w
                |> push(path, {:reasoning, %{lines: markdown(reasoning), ms: thought}})
                |> push(path, {:assistant, text |> sanitize() |> markdown() |> frame()})
            end
          end)

        Enum.reduce(Message.tool_uses(d.content), %{w | usage: add(w.usage, used)}, fn tu, acc ->
          push(
            acc,
            path,
            {:tool, new_tool(tu.id, tu.name, summarize_input(tu.name, tu.input), ts)}
          )
        end)

      # A model call that drew no reply, the summariser's (root Decision 769): counted as a
      # reply's usage is.
      :call_usage ->
        used = used(d.usage)

        %{w | usage: add(w.usage, used)}
        |> ensure_agent(path)
        |> update_agent(path, fn a -> %{a | usage: add(a.usage, used)} end)

      # The call is over, and so is an approval or a question it was still waiting for: a
      # cancel closes each call it stops with one of these, and so does a tool that timed
      # out waiting. Neither is ever answered.
      :tool_call_completed ->
        ended? = &(&1.kind in [:approval, :question] and &1.call_id == d.call_id)

        %{w | pending: Enum.reject(w.pending, ended?)}
        |> ensure_agent(path)
        |> update_agent(path, fn a ->
          %{a | transcript: Enum.map(a.transcript, &complete_tool(&1, d, ts))}
        end)

      :approval_requested ->
        w
        |> ask(%{
          kind: :approval,
          call_id: d.call_id,
          agent_path: path,
          name: d.name,
          preview: d.preview,
          delegation: d[:delegation],
          rule: d[:rule]
        })
        |> update_agent(path, fn a ->
          %{a | transcript: Enum.map(a.transcript, &attach_preview(&1, d))}
        end)

      :question_asked ->
        ask(w, %{
          kind: :question,
          call_id: d.call_id,
          agent_path: path,
          question: one_line(d.question),
          options: question_options(d),
          multiple: d[:multiple] == true,
          preview: d[:preview]
        })

      # The budget question (Decision 120): its words and options come from the question
      # it rides on, which the translation folds into this event.
      # A budget stop: from here on nothing in the agent's transcript is collapsed (TUI
      # Decision 161), so what happened after the money ran out is all on screen.
      :budget_ask_started ->
        w
        |> ensure_agent(path)
        |> open_from_here(path)
        |> ask(%{
          kind: :budget,
          call_id: d.call_id,
          agent_path: path,
          detail: d[:detail] || "budget exhausted",
          dimension: d[:dimension],
          question: one_line(d[:question] || ""),
          options: d[:options] || [],
          multiple: false
        })

      t when t in [:budget_ask_answered, :tool_failures_ask_answered] ->
        %{w | pending: Enum.reject(w.pending, &(&1.call_id == d.call_id))}

      t when t in [:approval_answered, :question_answered] ->
        %{w | pending: Enum.reject(w.pending, &(&1.call_id == d.call_id))}

      # A question this client asks at the session's start (TUI Decision 154): onboarding,
      # then the brief, answered with one key.
      :local_question ->
        ask(w, %{
          kind: :local,
          call_id: d.id,
          agent_path: path,
          question: one_line(d.question),
          keys: d.keys,
          default: d.default,
          preview: d[:preview]
        })

      :local_question_answered ->
        %{w | pending: Enum.reject(w.pending, &(&1.call_id == d.id))}

      # A cancel stops the agent's subagents with it, and they say nothing more: what each
      # was last doing goes, and it ended here.
      :cancelled ->
        w
        |> ensure_agent(path)
        |> push(path, {:system, "cancelled"})
        |> drop_pending(path)
        |> end_under(path, ts)

      # With the next step under it where there is one: on a first run with no key, the
      # first turn is where a person learns that `troupe config` sets a provider up.
      :llm_error ->
        w
        |> ensure_agent(path)
        |> push(path, {:system, "LLM error: #{d.message}"})
        |> push_step(path, ModelError.next_step(d))
        |> Map.put(:model_errors, Map.put(Map.get(w, :model_errors, %{}), path, d.message))

      :todo_updated ->
        update_agent(ensure_agent(w, path), path, fn a -> %{a | todos: d.items} end)

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
        |> Map.put(:loop, %{id: d[:loop_id], iteration: 0, max: d.max_iterations})

      :loop_iteration ->
        %{max: max} = Map.get(w, :loop) || %{max: nil}

        w
        |> ensure_agent(path)
        |> push(path, {:system, "loop iteration #{d.iteration}#{if max, do: "/#{max}", else: ""}"})
        |> Map.put(:loop, %{id: d[:loop_id], iteration: d.iteration, max: max})

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

      # A merge that conflicted was aborted, the checkout left as it was (Decision 647):
      # there is nothing to resolve there, and the branch is merged by hand or not at all.
      :worktree_merged ->
        w = %{w | worktree: w.worktree && Map.put(w.worktree, :merged, not d.conflicts)}

        push(
          w,
          path,
          {:system,
           if(d.conflicts,
             do:
               "merge aborted: it conflicts with the checkout, which is as it was; " <> by_hand(w),
             else: "merged into checkout"
           )}
        )

      :worktree_discarded ->
        push(
          %{w | worktree: w.worktree && Map.put(w.worktree, :discarded, true)},
          path,
          {:system, "worktree discarded"}
        )

      # A warning is the one signal that arrives while there is still budget left
      # to spend, so it goes in the transcript *and* stays on the window, where the
      # tile and the token line can show the denominator the UI never had.
      :budget_warning ->
        %{w | warnings: Map.put(w.warnings, d.dimension, d)}
        |> push(path, {:system, "⚠ " <> (d[:detail] || to_string(d.dimension)) <> " used"})

      _ ->
        w
    end
  end

  # What the turn cost, once, in the line under it (Decision 139): the event that ends a
  # turn carries it, and a live `agent_state` never does, so nothing is said while it runs.
  # The window's own agent's turn carries what its subagents spent (root Decision 769), so
  # only that one is added to what the window cost: a subagent's would count twice. It is
  # also the window's `last_turn`, which the side box says (TUI Decision 160); where that
  # box is drawn, the view draws the line as nothing (`transcript_blocks/3`), and the line
  # still ends its turn (TUI Decision 161).
  defp turn_cost(w, path, %{turn: %{calls: calls} = turn}, false) when calls > 0 do
    w = if path == w.path, do: %{w | cost: spent(w.cost, turn), last_turn: turn}, else: w
    w |> ensure_agent(path) |> push(path, {:system, turn_line(turn)})
  end

  defp turn_cost(w, _path, _data, _transient?), do: w

  # Only the optimistic copy of an input carries a command id worth waiting on:
  # one that came off the wire is already confirmed by definition.
  defp unconfirmed(w, %{optimistic: true, command_id: id, content: text}) when is_binary(id),
    do: %{w | unconfirmed: Map.put(w.unconfirmed, id, text)}

  defp unconfirmed(w, _data), do: w

  # One line per input, however many copies of it arrive (Decision 117). A line typed here
  # is drawn as it is sent, one sent while the agent works is written as `input_queued`,
  # and every one is written as the `user_input` the agent takes it as: all of them name
  # the send's command id. The first copy draws the line, and the `user_input`, always the
  # last, forgets the id. A copy that says something else is drawn as well: a task edit
  # is queued as the edit and taken as the agent's note of it.
  defp draw_input(w, path, %{command_id: id, content: text} = d) when is_binary(id) do
    w = if w.drawn_inputs[id] == text, do: w, else: push(w, path, {:user, text})

    if Map.get(d, :optimistic, false) or Map.get(d, :queued, false),
      do: %{w | drawn_inputs: Map.put(w.drawn_inputs, id, text)},
      else: %{w | drawn_inputs: Map.delete(w.drawn_inputs, id)}
  end

  # A log written before `user_input` carried the id draws each copy it has.
  defp draw_input(w, path, d), do: push(w, path, {:user, d.content})

  # An agent that is gone never logs `approval_answered`/`question_answered`, so
  # its request would sit in `pending` forever: unanswerable (Approvals dropped
  # its entry when the pid died) and holding its window in `:needs_input` for
  # good. Delegation ending and cancellation are the two points where
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

  # The agents under `path`, stopped with it: none of them is doing anything any more, and
  # the ones still going when it happened ended then.
  defp end_under(w, path, ts) do
    under? = &String.starts_with?(&1, path <> "/")

    agents =
      Map.new(w.agents, fn
        {p, %{ended_at: nil} = a} -> if under?.(p), do: {p, %{a | ended_at: ts}}, else: {p, a}
        other -> other
      end)

    %{w | agents: agents, activity: Map.reject(w.activity, fn {p, _to} -> under?.(p) end)}
  end

  defp new_tool(id, name, input, ts) do
    %{
      id: id,
      name: name,
      input: one_line(input),
      status: :running,
      result: "",
      lines: [],
      body: [],
      preview: nil,
      summary: "",
      started_at: ts,
      ended_at: nil
    }
  end

  # A result's trailing newlines are not lines: a command that ends its output with
  # two or three of them would draw that many blank rows under it (issue #182).
  defp complete_tool({:tool, %{id: id} = t}, %{call_id: id} = d, ts) do
    result =
      (d.content || "")
      |> String.slice(0, @result_cap)
      |> sanitize()
      |> String.trim_trailing()

    status = if d.ok, do: :ok, else: :error
    t = %{t | status: status, result: result, lines: String.split(result, "\n")}
    t = t |> Map.put(:ended_at, ts) |> then(&%{&1 | summary: summary(&1)})
    {:tool, %{t | body: t |> build_body() |> frame()}}
  end

  defp complete_tool(entry, _d, _ts), do: entry

  # How long the reasoning that ends with this message took, when its first delta said
  # when it began; a replayed log has no deltas, and so no duration.
  defp thought(%{agents: agents}, path, ts) do
    case agents do
      %{^path => %{reasoning_at: at}} when is_integer(at) and is_integer(ts) -> max(ts - at, 0)
      _ -> nil
    end
  end

  defp budget_stop?(text), do: String.starts_with?(text, "budget exhausted")

  # The first budget stop holds: everything from there on is open.
  defp open_from_here(w, path) do
    update_agent(w, path, fn a ->
      Map.put(a, :open_from, Map.get(a, :open_from) || length(a.transcript))
    end)
  end

  # The curtain line's phases start again with each turn of the window's own agent.
  defp new_curtain(%{path: path} = w, path), do: Map.put(w, :curtain, %{})
  defp new_curtain(w, _path), do: w

  # A phase is a change of what the window's own agent does: thinking, acting, compacting.
  # The count of each kind picks the flourish (`Frames.curtain/3`), so the third time it
  # thinks in a turn reads differently from the first.
  @phases [:thinking, :acting, :compacting]

  defp curtain_phase(%{path: path, activity: activity} = w, path, to) when to in @phases do
    if Map.get(activity, path) == to do
      w
    else
      Map.update(w, :curtain, %{to => 1}, &Map.update(&1, to, 1, fn n -> n + 1 end))
    end
  end

  defp curtain_phase(w, _path, _to), do: w

  defp card_for({:tool, %{id: id}}, id, card), do: {:scratch, card}
  defp card_for(entry, _id, _card), do: entry

  defp attach_preview({:tool, %{id: id} = t}, %{call_id: id} = d) when is_binary(d.preview),
    do: {:tool, %{t | preview: sanitize(d.preview)}}

  defp attach_preview(entry, _), do: entry

  # The block for a run, changed by `fun`, or a new one at the end when there is none yet.
  defp shell(w, path, id, fun) do
    w = ensure_agent(w, path)
    transcript = w.agents[path].transcript

    if Enum.any?(transcript, &match?({:shell, %{id: ^id}}, &1)) do
      update_agent(w, path, fn a ->
        %{a | transcript: Enum.map(a.transcript, &change_shell(&1, id, fun))}
      end)
    else
      push(w, path, {:shell, fun.(new_shell(id))})
    end
  end

  defp change_shell({:shell, %{id: id} = s}, id, fun), do: {:shell, fun.(s)}
  defp change_shell(entry, _id, _fun), do: entry

  defp new_shell(id) do
    %{
      id: id,
      command: "",
      output: "",
      lines: [],
      status: :running,
      exit_status: nil,
      reason: nil,
      timeout_ms: nil,
      agent: true,
      where: nil
    }
  end

  # Kept to its tail, like a tool's result: the log has the rest.
  defp put_output(s, output) do
    output = output |> sanitize() |> tail(@result_cap)
    %{s | output: output, lines: output |> String.trim_trailing() |> String.split("\n")}
  end

  defp tail(text, cap) do
    case String.length(text) - cap do
      cut when cut > 0 -> String.slice(text, cut, cap)
      _ -> text
    end
  end

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

  defp by_hand(%{worktree: %{git_branch: branch}}) when is_binary(branch),
    do: "merge #{branch} by hand"

  defp by_hand(_w), do: "merge its branch by hand"

  defp summarize_input("shell", %{"command" => c}), do: c
  defp summarize_input("web_fetch", %{"url" => u}), do: u
  # Never the document: its title and name until the card stands in its place.
  defp summarize_input("show", %{} = input), do: "#{input["title"]} · #{input["name"]}"

  defp summarize_input("todo_write", %{"items" => items}) when is_list(items),
    do: "#{length(items)} items"

  defp summarize_input(_, %{"path" => p}), do: p
  defp summarize_input("read_branch", %{} = input), do: read_branch_input(input)
  # One in the background, and the call that stops it (root Decision 853).
  defp summarize_input("delegate", %{"agent" => a, "wait" => false}), do: a <> ", in the background"
  defp summarize_input("delegate", %{"agent" => a}), do: a
  defp summarize_input("stop_child", %{"child" => c}), do: c
  defp summarize_input("finish", %{"summary" => s}), do: String.slice(s, 0, 60)
  defp summarize_input("ask_user", %{"question" => q}), do: q
  defp summarize_input(_, input), do: input |> Jason.encode!() |> String.slice(0, 60)

  # What `read_branch` was asked to read, in words: the list, a branch, a subagent of it,
  # and its diff when that was asked for, rather than the call's JSON (D113).
  defp read_branch_input(input) do
    what =
      case {input["session_id"], input["child"]} do
        {id, child} when is_binary(id) and is_binary(child) -> "#{id}, subagent #{child}"
        {id, _} when is_binary(id) -> id
        {_, child} when is_binary(child) -> "subagent #{child}"
        _ -> "the branches"
      end

    if input["diff"] == true, do: what <> ", with its diff", else: what
  end

  defp new_agent(attrs \\ %{}) do
    Map.merge(
      %{
        transcript: [],
        streaming: "",
        streaming_reasoning: "",
        reasoning_at: nil,
        todos: [],
        name: nil,
        model: nil,
        usage: empty_usage(),
        started_at: nil,
        ended_at: nil,
        open_from: nil
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

  # One entry per call: a call re-run after the daemon restarted asks again under the same
  # id, and is still the one thing to answer, where it used to be drawn twice. The new
  # asking replaces the old, at the end, as the most recent.
  defp ask(w, item),
    do: %{w | pending: Enum.reject(w.pending, &(&1.call_id == item.call_id)) ++ [item]}

  defp push_entry(w, path, entry),
    do: update_agent(w, path, fn a -> %{a | transcript: a.transcript ++ [entry]} end)

  defp presence(m, %{state: state, subject: subject} = d) when state in ["joined", "left"] do
    key = {subject, d[:via]}
    who = d[:name] || subject || "somebody"
    from = if d[:via] == "plane", do: " from another device", else: ""

    {present, line} =
      case state do
        "joined" -> {Map.put(m.present, key, %{name: who, via: d[:via]}), "#{who} joined#{from}"}
        "left" -> {Map.delete(m.present, key), "#{who} left#{from}"}
      end

    m = %{m | present: present}

    case m.order do
      [own | _] -> update_window(m, own, &push(ensure_agent(&1, own), own, {:system, line}))
      [] -> m
    end
  end

  defp presence(m, _data), do: m

  @doc """
  Who else is attached to the session now, as the status line names them: each person,
  `(another device)` after one steering from elsewhere.
  """
  @spec present(t()) :: [String.t()]
  def present(%__MODULE__{present: present}) do
    present
    |> Map.values()
    |> Enum.map(fn
      %{name: name, via: "plane"} -> "#{name} (another device)"
      %{name: name} -> name
    end)
    |> Enum.sort()
  end

  defp update_window(m, path, fun) do
    case Map.get(m.windows, path) do
      nil -> m
      w -> %{m | windows: Map.put(m.windows, path, fun.(w))}
    end
  end

  @spec root(String.t()) :: String.t()
  def root(path), do: path |> String.split("/") |> hd()

  @doc """
  The windows on screen, in the order they opened: the branches, numbered by the digit
  that opens each. The session's own window, `"root"`, is command mode's (TUI Decision
  155), not a branch beside them: it is folded like any other, for its goal, its loop, the
  start's questions and the session's own lines, and listed only once its agent has been
  given work of its own (a `troupe run` task, a loop, a watch trigger, a pod session's
  input, or a session from before command mode).
  """
  @spec windows(t()) :: [window()]
  def windows(%__MODULE__{} = m) do
    m.order
    |> Enum.map(&Map.fetch!(m.windows, &1))
    |> Enum.filter(&listed?/1)
  end

  defp listed?(%{path: "root"} = w), do: Map.get(w, :started, true)
  defp listed?(_w), do: true

  @doc "The session's own window, `\"root\"`, listed or not; `nil` before its first event."
  @spec session_window(t()) :: window() | nil
  def session_window(%__MODULE__{windows: windows}), do: Map.get(windows, "root")

  @doc """
  The question a session's start asks that is still open, as `{window, question}`, or
  `nil`: whichever window it is in, the session's own included, which is where the start
  asks it (TUI Decision 154) and which command mode does not list.
  """
  @spec asking(t()) :: {String.t(), map()} | nil
  def asking(%__MODULE__{} = m) do
    Enum.find_value(m.order, fn path ->
      case local_question(Map.fetch!(m.windows, path)) do
        nil -> nil
        question -> {path, question}
      end
    end)
  end

  @doc """
  The tightest limit any window's warnings have come near, as `headroom_note/1` says it
  with the window it is in (`build-1: 82% of input tokens`), or `nil` when none has.
  """
  @spec headroom(t()) :: String.t() | nil
  def headroom(%__MODULE__{} = m) do
    m.windows
    |> Map.values()
    |> Enum.flat_map(fn w -> Enum.map(w.warnings, fn {_dim, warn} -> {w.path, warn} end) end)
    |> Enum.max_by(fn {_path, warn} -> warn[:fraction] || 0.0 end, fn -> nil end)
    |> case do
      nil -> nil
      {path, warn} -> "#{path}: " <> headroom_note(%{warnings: %{warn.dimension => warn}})
    end
  end

  @doc """
  The last line a window's agent produced, for command mode's row: what it is writing as
  it streams, and otherwise its transcript's last entry that is not a note about it (what
  a turn cost, which the row has a column for, or that its session resumed): the last
  line of a reply, a tool call's head, a command's head with how it ended. With nothing
  but notes, the last note; before anything at all, what it is doing.
  """
  @spec last_line(window(), non_neg_integer(), integer()) :: String.t()
  def last_line(w, tick, now) do
    agent = Map.get(w.agents, w.path, new_agent())
    streaming = agent.streaming |> sanitize() |> String.split("\n") |> last_said()

    cond do
      streaming != "" -> streaming
      (said = said_last(agent.transcript)) != "" -> said
      true -> activity_line(w, tick, now) || ""
    end
  end

  defp said_last(transcript) do
    {notes, said} = Enum.split_with(transcript, &match?({:system, _}, &1))

    case List.last(said) || List.last(notes) do
      nil -> ""
      {:shell, _} = entry -> entry |> entry_lines(false) |> hd() |> line_text()
      entry -> entry |> entry_lines(false) |> Enum.map(&line_text/1) |> last_said()
    end
  end

  defp last_said(lines) do
    lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> List.last("")
  end

  @doc """
  The loop this screen's session is running, `%{id, iteration, max}`, as its events say,
  or `nil` when none runs: the session's own window's, like `goal/1`.
  """
  @spec loop(t()) :: loop() | nil
  def loop(%__MODULE__{windows: windows}) do
    case Map.get(windows, "root") do
      %{loop: %{} = loop} -> loop
      _ -> nil
    end
  end

  @doc """
  Takes the loop `id` off the window: the session answered that none runs, though no
  event has said so. A daemon that stopped mid-loop wrote no `loop_stopped`, and a
  restore records how the loop ended only when the session is next activated. Only that
  loop: one that started since the question was asked is its own events' to report.
  """
  @spec loop_ended(t(), String.t() | nil) :: t()
  def loop_ended(%__MODULE__{} = m, id) do
    update_window(m, "root", fn
      %{loop: %{id: ^id}} = w -> %{w | loop: nil}
      w -> w
    end)
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
  MCP servers as the status line reads them: the state per server the `/mcp`
  page's live query last found, sorted by name. Empty until the page first opens.
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

  @doc """
  A `watch_triggered` as one line (root Decision 844): the file and comment, and what it
  started, or why nothing did. `agent` is the agent's name, or the window's once it has one.
  """
  @spec watch_line(map()) :: String.t()
  def watch_line(%{error: reason} = d) when is_binary(reason),
    do: "watch: #{comment_at(d[:markers])} could not start #{d.agent}: #{reason}"

  def watch_line(d), do: "watch: #{comment_at(d[:markers])} started #{d.agent}"

  defp comment_at([%{} = marker | rest]) do
    one = "#{marker["file"]}:#{marker["line"]} \"#{marker["comment"]}\""
    if rest == [], do: one, else: "#{one} and #{length(rest)} more"
  end

  defp comment_at(_markers), do: "a comment"

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

  @doc """
  Marks a window read: it is open, so how it ended has been seen. The screen does this
  when a window is activated, and for the open one whenever it ends.
  """
  @spec seen(t(), String.t()) :: t()
  def seen(%__MODULE__{windows: windows} = m, path) do
    case windows do
      %{^path => %{badge: true} = w} -> %{m | windows: Map.put(windows, path, %{w | badge: false})}
      _ -> m
    end
  end

  @doc """
  What the status line says about the windows, part by part and in this order: how many
  need you, and how many ended, done or failed, since they were last opened. Empty when
  none does.
  """
  @spec attention(t()) :: [{:needs_input | :done_unread | :failed_unread, String.t()}]
  def attention(%__MODULE__{} = m) do
    ws = windows(m)

    [
      needs_input: {Enum.count(ws, &(&1.state == :needs_input)), "need input"},
      done_unread: {Enum.count(ws, &(&1.state == :done_unread and &1.badge)), "done"},
      failed_unread: {Enum.count(ws, &(&1.state == :failed_unread and &1.badge)), "failed"}
    ]
    |> Enum.filter(fn {_state, {n, _word}} -> n > 0 end)
    |> Enum.map(fn {state, {n, word}} -> {state, "#{n} #{word}"} end)
  end

  @doc ~S|`attention/1` as one line: `"1 need input, 2 done"`, or `"idle"`.|
  @spec attention_summary(t()) :: String.t()
  def attention_summary(%__MODULE__{} = m) do
    case attention(m) do
      [] -> "idle"
      parts -> Enum.map_join(parts, ", ", &elem(&1, 1))
    end
  end

  @spec elapsed(window(), integer()) :: String.t()
  def elapsed(w, now_ms) do
    ms = (w.ended_at || now_ms) - w.started_at
    s = div(max(ms, 0), 1000)

    "#{String.pad_leading(Integer.to_string(div(s, 60)), 2, "0")}:#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}"
  end

  # The mark, turning (#228): the lit half goes round clockwise, a quarter every quarter
  # second, off the clock rather than the frame rate, so it turns at one calm pace however
  # often the screen is drawn. The same glyph sits in the corner of a working window.
  @spinner ~w(◐ ◓ ◑ ◒)
  @turn_ms 250

  @doc "The glyphs the mark turns through while an agent works."
  @spec spinner_glyphs() :: [String.t()]
  def spinner_glyphs, do: @spinner

  @doc "The turning mark at `now`, in milliseconds: a quarter turn every #{@turn_ms} ms."
  @spec spinner(integer()) :: String.t()
  def spinner(now), do: Enum.at(@spinner, Integer.mod(div(now, @turn_ms), length(@spinner)))

  @doc "One line describing what the branch is doing right now, or nil when resting."
  @spec activity_line(window(), non_neg_integer(), integer()) :: String.t() | nil
  def activity_line(w, tick, now), do: activity_line(w, w.path, tick, now)

  @doc """
  What one agent of a window is doing right now, or nil when it rests: the
  root agent's line is the window's, a subagent's comes from its own state,
  running tools and pending items.
  """
  @spec activity_line(window(), String.t(), non_neg_integer(), integer()) :: String.t() | nil
  def activity_line(%{state: s} = w, path, _tick, _now)
      when s in [:idle, :done_unread, :failed_unread, :dismissed] do
    # A window at rest has nothing going on, but a model that failed still says why,
    # where the person is looking.
    case Map.get(w, :model_errors, %{}) do
      %{^path => message} -> "model error: #{message}"
      _ -> nil
    end
  end

  def activity_line(w, path, _tick, now) do
    agent = Map.get(w.agents, path, new_agent())

    if path != w.path and agent.ended_at != nil do
      nil
    else
      spinner = spinner(now)
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
            "#{spinner} running #{how_many(tools)} (#{since})"

          state == :acting ->
            "#{spinner} working (#{since})"

          state in [nil, :idle] and tools != [] ->
            "#{spinner} running #{how_many(tools)}"

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

  # What runs and how many (TUI Decision 161): one call by itself, several with their count.
  defp how_many([one]), do: one
  defp how_many(tools), do: "#{length(tools)} tools: " <> Enum.join(tools, ", ")

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

  # A reply's usage arrives in this module's shape: `Troupe.Remote.Translate` reads the
  # wire's `input_tokens` and `output_tokens`, and a journal holds what it translated.
  # An `assistant_message` written before the cache figures existed simply has none.
  defp used(reported) do
    %{
      input: Map.get(reported, :input, 0),
      output: Map.get(reported, :output, 0),
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
  What the side box says of the window's last turn (TUI Decision 160), in `turn_line/1`'s
  words: its calls and the money, `↑` sent and cached, `↓` received. Two figures share a
  line where `width` columns hold both, and each takes its own where they do not: the
  side panel is 30 to 60 columns, too narrow for `turn_line/1`.
  """
  @spec turn_box(turn(), pos_integer()) :: [String.t()]
  def turn_box(%{calls: calls} = turn, width),
    do: fit([[calls(calls), money(turn)] | usage_rows(turn.usage)], width)

  @doc """
  What the side box says of the session under the last turn (TUI Decision 160): the calls
  and money of the window's ended turns, once one has ended, the window's tokens in the
  turn's words, and the tightest limit a warning has fired for, where the limit is.
  """
  @spec session_box(window(), pos_integer()) :: [String.t()]
  def session_box(%{usage: u} = w, width) do
    spend =
      case Map.get(w, :cost, @no_spend) do
        %{calls: 0} -> []
        spend -> [[calls(spend.calls), money(spend)]]
      end

    fit(spend ++ usage_rows(u), width) ++
      case headroom_note(w) do
        "" -> []
        note -> ["⚠ " <> note]
      end
  end

  defp usage_rows(u) do
    [
      ["↑ #{short(u.input + u.cache_write)} sent", "#{short(u.cache_read)} cached"],
      ["↓ #{short(u.output)} received"]
    ]
  end

  defp fit(rows, width) do
    Enum.flat_map(rows, fn figures ->
      line = Enum.join(figures, " · ")
      if cell_width(line) <= width, do: [line], else: figures
    end)
  end

  @doc """
  The window with the lines that said what its own agent's turns cost left out of that
  agent's transcript, for a screen wide enough for the side box, which says it there (TUI
  Decision 160). The fold keeps them, for the narrow screen that has no side box. A
  subagent's line says what its own task cost, which the side box does not, and stays.
  The pane and the tiles draw those lines as nothing instead (`transcript_blocks/3` with
  `turn_lines: false`), since each still ends its turn (TUI Decision 161).
  """
  @spec without_turn_lines(window()) :: window()
  def without_turn_lines(%{path: path, agents: agents} = w) do
    case agents do
      %{^path => a} ->
        kept = Enum.reject(a.transcript, &turn_entry?/1)
        %{w | agents: %{agents | path => %{a | transcript: kept}}}

      _ ->
        w
    end
  end

  # The line `turn_cost/4` writes: nothing else in a transcript starts with `turn: `.
  defp turn_entry?({:system, "turn: " <> _}), do: true
  defp turn_entry?(_entry), do: false

  @doc """
  What one turn cost, as the line under it says (Decision 139): its model calls, what was
  sent and billed in full (`↑`, as the window's own count reads it), what the prompt cache
  served, what came back, and the money. A turn nobody priced says so, rather than that it
  was free.
  """
  @spec turn_line(turn()) :: String.t()
  def turn_line(%{calls: calls, usage: u} = turn) do
    "turn: #{calls(calls)} · ↑ #{short(u.input + u.cache_write)} sent · " <>
      "#{short(u.cache_read)} cached · ↓ #{short(u.output)} received · " <> money(turn)
  end

  defp calls(1), do: "1 call"
  defp calls(n), do: "#{n} calls"

  @doc """
  What a window's turns have cost so far, in the words a turn's line uses (`$0.02`, `no
  price`), or `""` before any turn ended (TUI Decision 155's collection).
  """
  @spec cost(%{cost: spend()} | map()) :: String.t()
  def cost(%{cost: %{calls: 0}}), do: ""
  def cost(%{cost: %{} = spend}), do: money(spend)
  def cost(_w), do: ""

  @doc "What every window of the session has cost, as `cost/1` says it."
  @spec total_cost(t()) :: String.t()
  def total_cost(%__MODULE__{windows: windows}) do
    windows
    |> Map.values()
    |> Enum.reduce(@no_spend, &spent(&2, Map.get(&1, :cost, @no_spend)))
    |> then(&cost(%{cost: &1}))
  end

  defp spent(a, b) do
    %{
      calls: a.calls + b.calls,
      cost_micros: a.cost_micros + b.cost_micros,
      unpriced: a.unpriced + b.unpriced
    }
  end

  defp money(%{calls: n, unpriced: n}), do: "no price"
  defp money(%{cost_micros: micros, unpriced: 0}), do: dollars(micros)
  defp money(%{cost_micros: micros, unpriced: 1}), do: dollars(micros) <> ", 1 call unpriced"
  defp money(%{cost_micros: micros, unpriced: n}), do: dollars(micros) <> ", #{n} calls unpriced"

  # In whole numbers, rounded half up, as `@troupe/client`'s `turnLine` works it out, so the
  # desktop app says the same to the cent (Decision 144).
  defp dollars(0), do: "$0.00"
  defp dollars(micros) when micros < 10_000, do: "under a cent"

  defp dollars(micros) do
    cents = div(micros + 5_000, 10_000)
    "$#{div(cents, 100)}." <> String.pad_leading("#{rem(cents, 100)}", 2, "0")
  end

  @doc "Every token a window or agent has accounted for, cached input included."
  @spec total_tokens(%{usage: usage()}) :: non_neg_integer()
  def total_tokens(%{usage: u}), do: u.input + u.output + u.cache_read + u.cache_write

  # A float printed `1.0e3` past a thousand thousands; millions are `M`, and the tenth is
  # worked out in whole numbers, rounded half up, as `@troupe/client` does (Decision 144).
  defp short(n) when n >= 1_000_000, do: tenths(n, 1_000_000) <> "M"
  defp short(n) when n >= 1000, do: tenths(n, 1000) <> "k"
  defp short(n), do: "#{n}"

  defp tenths(n, unit) do
    t = div(n * 10 + div(unit, 2), unit)
    "#{div(t, 10)}.#{rem(t, 10)}"
  end

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

  ## Frames (TUI Decision 161)

  @typedoc """
  How much of a transcript is drawn open (TUI Decision 161, `docs/design/frames.md`).
  `detail` is the session's `transcript.detail`: `:quiet`, a turn's answer with its working
  one strip above it; `:tools`, tool frames open and reasoning collapsed; `:everything`,
  nothing collapsed. `open` holds the turns `e` turned the other way, by their number in
  the agent's transcript. `turn_lines` false leaves out the lines that say what the
  window's own agent's turns cost, which the side box says where it is drawn (TUI
  Decision 160). `now` times what still runs.
  """
  @type view :: %{
          detail: :quiet | :tools | :everything,
          open: MapSet.t(non_neg_integer()),
          turn_lines: boolean(),
          now: integer()
        }

  @details [:quiet, :tools, :everything]

  @doc "What `transcript.detail` takes, the default first."
  @spec details() :: [atom()]
  def details, do: @details

  @doc "The level a `transcript.detail` value names, or `nil` for one that names none."
  @spec detail(term()) :: :quiet | :tools | :everything | nil
  def detail(value) when is_atom(value) and value in @details, do: value

  def detail(value) when is_binary(value),
    do: Enum.find(@details, &(Atom.to_string(&1) == String.downcase(String.trim(value))))

  def detail(_value), do: nil

  @doc """
  A view from what a caller has: a map of the view's keys, or `true` for everything open
  and `false` for quiet, which is how a pane was drawn before there were levels.
  """
  @spec view(map() | boolean()) :: view()
  def view(true), do: view(%{detail: :everything})
  def view(false), do: view(%{detail: :quiet})

  def view(%{} = v),
    do:
      Map.merge(
        %{detail: :quiet, open: MapSet.new(), turn_lines: true, now: 0, once_only: false},
        v
      )

  # Every frame body past `@frame_cap` lines keeps its first `@frame_keep` and says how many
  # more there are, expanding in place when its turn is opened.
  @frame_cap 24
  @frame_keep 20
  @frame_rail "▎ "

  @doc """
  Everything the activated pane shows for one agent, as blocks of tagged
  logical lines: one block per transcript entry, then the text being streamed,
  the curtain line and whatever the window is waiting on. Blocks let the view
  keep the same entry at the top when a turn is opened or closed.

  `view` says how much is drawn open (`view/1`); `true` and `false` still mean
  everything and quiet. `selection` is the reader's in-progress answer to a
  multiple-choice question (`%{call_id, selected}`), which lives in the UI process
  rather than the log: it is a cursor, not a decision, and it dies with the frame if the
  question is answered elsewhere. `gate` is the reader's draft of an answer to a
  delegation at the gate (`gate_draft/2`, TUI Decision 157), a cursor of the same kind.
  """
  @spec pane_blocks(
          window(),
          String.t(),
          map() | boolean(),
          non_neg_integer(),
          integer(),
          map() | nil,
          map() | nil
        ) :: [[line()]]
  def pane_blocks(w, agent_path, view, tick, now, selection \\ nil, gate \\ nil) do
    view = view |> view() |> Map.put(:now, now)

    Enum.map(transcript_blocks(w, agent_path, view), &elem(&1, 1)) ++
      live_blocks(w, agent_path, view, tick, now, selection, gate)
  end

  @doc """
  The transcript's part of `pane_blocks/7`: one `{key, block}` per entry, in order. The key
  is the entry with how it is drawn, and decides the block, so a height measured for a key
  holds for as long as the key comes back the same (`View`'s memory of heights).

  A transcript is read as turns (`turn_starts/1`): what follows a person's line, a
  command they ran or a loop's iteration, up to the line that says what the turn cost.
  Within a turn the answer is the model's prose after its last call (a `finish` aside);
  its working is the reasoning, the calls and the prose between them. Quiet draws the
  working as one strip where it began, `▸ 7 steps · grep, read_file · 14s`, and the
  answer as a prose frame; `tools` opens the tool frames under a `▾` strip and keeps
  reasoning to its header; `everything` collapses nothing. A failed call is drawn open
  at every level, and so is everything after a budget stop.
  """
  @spec transcript_blocks(window(), String.t(), map() | boolean()) :: [{term(), [line()]}]
  def transcript_blocks(w, agent_path, view) do
    view = view(view)
    agent = Map.get(w.agents, agent_path, new_agent())

    ctx = %{
      open_from: Map.get(agent, :open_from),
      hide_cost?: not view.turn_lines and agent_path == w.path,
      now: view.now
    }

    agent.transcript
    |> turns()
    |> Enum.with_index()
    |> Enum.flat_map(fn {{first, entries}, n} ->
      turn_blocks(entries, first, turn_level(view, n), ctx)
    end)
  end

  @doc """
  Where each turn of a transcript begins, by entry: a person's line, a command they ran
  (`!`), a loop's iteration, and whatever follows the line saying what the last turn cost.
  `e` opens and closes a turn by its place in this list.
  """
  @spec turn_starts([entry()]) :: [non_neg_integer()]
  def turn_starts(transcript), do: transcript |> turns() |> Enum.map(&elem(&1, 0))

  @doc "The number of the turn entry `index` is in, given `turn_starts/1`."
  @spec turn_of([non_neg_integer()], non_neg_integer()) :: non_neg_integer()
  def turn_of(starts, index), do: max(Enum.count(starts, &(&1 <= index)) - 1, 0)

  @doc "The level a turn is drawn at: the session's, or the other way when `e` turned it."
  @spec turn_level(view(), non_neg_integer()) :: :quiet | :tools | :everything
  def turn_level(view, n) do
    if MapSet.member?(view.open, n), do: flip(view.detail), else: view.detail
  end

  defp flip(:everything), do: :quiet
  defp flip(_level), do: :everything

  defp turns([]), do: []

  defp turns(transcript) do
    {done, current, _closed?} =
      transcript
      |> Enum.with_index()
      |> Enum.reduce({[], [], false}, fn {entry, i}, {done, current, closed?} ->
        if current != [] and (closed? or opens_turn?(entry)),
          do: {[Enum.reverse(current) | done], [{entry, i}], closes_turn?(entry)},
          else: {done, [{entry, i} | current], closes_turn?(entry)}
      end)

    [Enum.reverse(current) | done]
    |> Enum.reverse()
    |> Enum.map(fn [{_entry, first} | _] = pairs -> {first, Enum.map(pairs, &elem(&1, 0))} end)
  end

  defp opens_turn?({kind, _}) when kind in [:user, :shell], do: true
  defp opens_turn?({:system, "loop iteration" <> _}), do: true
  defp opens_turn?(_entry), do: false

  defp closes_turn?(entry), do: turn_entry?(entry)

  defp turn_blocks(entries, first, level, ctx) do
    indexed = Enum.with_index(entries, first)
    at = fn i -> if ctx.open_from != nil and i >= ctx.open_from, do: :everything, else: level end

    last_call =
      Enum.reduce(indexed, nil, fn
        {{:tool, %{name: name}}, i}, _last when name != "finish" -> i
        _other, last -> last
      end)

    steps = for {{:tool, t}, i} <- indexed, at.(i) == level, t.name != "finish", do: t
    strip = if steps != [], do: strip_line(steps, level, ctx.now)

    strip_at =
      strip &&
        Enum.find_value(indexed, fn {entry, i} ->
          at.(i) == level and role(entry, i, last_call) not in [:other, :answer] and i
        end)

    Enum.map(indexed, fn {entry, i} ->
      role = role(entry, i, last_call)
      mode = {role, at.(i), strip != nil and at.(i) == level, ctx.hide_cost?}
      above = if i == strip_at, do: [strip], else: []
      {{entry, mode, above}, above ++ entry_block(entry, mode)}
    end)
  end

  # What an entry is to its turn: the answer, the working (reasoning, the prose between
  # calls, a call), a call that failed, or none of those (a person's line, a note, a card).
  defp role({:assistant, _}, i, last_call) when last_call == nil or i > last_call, do: :answer
  defp role({:assistant, _}, _i, _last_call), do: :narration
  defp role({:reasoning, _}, _i, _last_call), do: :reasoning
  defp role({:tool, %{status: :error}}, _i, _last_call), do: :failed
  defp role({:tool, _}, _i, _last_call), do: :step
  defp role(_entry, _i, _last_call), do: :other

  # `{role, level, stripped?, hide_cost?}`: stripped is whether the working at this level
  # went into the turn's strip.
  defp entry_block({:system, "turn: " <> _}, {_role, _level, _stripped?, true}), do: []
  defp entry_block({:assistant, lines}, {_role, :everything, _, _}), do: prose_frame(lines, :full)
  defp entry_block({:assistant, lines}, {:answer, _level, _, _}), do: prose_frame(lines, :capped)
  defp entry_block({:assistant, _lines}, {:narration, :quiet, true, _}), do: []
  defp entry_block({:assistant, lines}, {:narration, _level, _, _}), do: prose_frame(lines, :capped)
  defp entry_block({:reasoning, r}, {_role, :everything, _, _}), do: reasoning_frame(r)
  defp entry_block({:reasoning, _r}, {_role, :quiet, true, _}), do: []
  defp entry_block({:reasoning, r}, _mode), do: [reasoning_head(r.ms, false)]
  defp entry_block({:tool, t}, {_role, :everything, _, _}), do: tool_frame(t, :full)
  defp entry_block({:tool, t}, {:failed, _level, _, _}), do: tool_frame(t, :capped)
  defp entry_block({:tool, t}, {:step, :tools, _, _}), do: tool_frame(t, :capped)
  defp entry_block({:tool, _t}, {:step, :quiet, _, _}), do: []
  defp entry_block(entry, {_role, level, _, _}), do: entry_lines(entry, level == :everything)

  # The strip: what the working of a turn came to, where it began, closed (▸) at quiet and
  # open (▾) above the frames it stands for otherwise.
  defp strip_line(steps, level, now) do
    n = length(steps)
    failed = Enum.count(steps, &(&1.status == :error))
    names = steps |> Enum.map(& &1.name) |> Enum.uniq()
    shown = Enum.take(names, 4)
    more = length(names) - length(shown)

    {:strip,
     [
       {:strip_glyph, if(level == :quiet, do: "▸ ", else: "▾ ")},
       {:strip, "#{n} #{if n == 1, do: "step", else: "steps"}"}
     ] ++
       if(failed > 0, do: [{:strip_failed, " · #{failed} failed"}], else: []) ++
       [
         {:strip,
          " · " <> Enum.join(shown, ", ") <> if(more > 0, do: " and #{more} more", else: "")}
       ] ++ took(span(steps, now))}
  end

  # From the first call's start to the last one's end, or to now while one still runs.
  defp span(steps, now) do
    starts = for %{started_at: at} <- steps, is_integer(at), do: at
    ends = for s <- steps, do: Map.get(s, :ended_at) || if(s.status == :running, do: now)
    ends = Enum.filter(ends, &is_integer/1)
    if starts != [] and ends != [], do: Enum.max(ends) - Enum.min(starts)
  end

  # A duration under a second says nothing a person reads for.
  defp took(ms) when is_integer(ms) and ms >= 1000, do: [{:strip, " · " <> seconds(ms)}]
  defp took(_ms), do: []

  @doc "A duration as a frame's header says it: `14s`, `4m 2s`."
  @spec seconds(non_neg_integer()) :: String.t()
  def seconds(ms) do
    s = div(ms, 1000)
    if s < 60, do: "#{s}s", else: "#{div(s, 60)}m #{rem(s, 60)}s"
  end

  # The model's prose on the rendered surface, framed as it was folded (`frame/1`): every
  # line behind the frame's rail, a code, diff or data block inside it a frame of its own
  # with its label and no second surface.
  defp prose_frame(lines, mode), do: cap_nested(lines, mode)

  # A call: its head on the chat, what came back on the surface under it, framed as the
  # call completed.
  defp tool_frame(t, mode), do: [{head_kind(t.status), head_segments(t)} | cap(t.body, mode)]

  defp reasoning_frame(%{lines: lines, ms: ms}) do
    body = Enum.map(lines, &{:reasoning_body, line_text(&1)})
    [reasoning_head(ms, true) | frame(body)]
  end

  defp reasoning_head(ms, open?) do
    {:reasoning_head,
     [
       {:reasoning_marker, if(open?, do: "▾ ", else: "▸ ")},
       {:reasoning_title, "thinking"}
     ] ++
       if(is_integer(ms) and ms >= 1000, do: [{:reasoning_title, " · " <> seconds(ms)}], else: [])}
  end

  @doc """
  Lines behind the rendered surface's rail (TUI Decision 161): a `:frame` segment first,
  which wrapping repeats on every row and the view draws on the surface's background
  where the terminal has one. Copying leaves it out, as it does every rail.
  """
  @spec frame([line()]) :: [line()]
  def frame(lines), do: Enum.map(lines, &framed/1)

  defp framed({kind, text}) when is_binary(text), do: {kind, [{:frame, @frame_rail}, {kind, text}]}
  defp framed({kind, segments}), do: {kind, [{:frame, @frame_rail} | segments]}

  # Framed lines past the cap: the first of them and a framed line saying how many more.
  defp cap(lines, :full), do: lines

  defp cap(lines, :capped) do
    case length(lines) - @frame_keep do
      more when length(lines) > @frame_cap ->
        Enum.take(lines, @frame_keep) ++ [framed(more_line(more))]

      _ ->
        lines
    end
  end

  defp more_line(1), do: {:more, "… 1 more line"}
  defp more_line(n), do: {:more, "… #{n} more lines"}

  # A block between its rules inside prose collapses past the cap as any frame does; the
  # prose around it never does, since it is the answer. Most replies have no such block,
  # and are handed back as they were folded rather than rebuilt at every frame.
  defp cap_nested(lines, :full), do: lines

  defp cap_nested(lines, :capped),
    do: if(long_block?(lines, nil), do: cap_nested(lines, [], nil), else: lines)

  defp long_block?([], _count), do: false
  defp long_block?([{:code_head, _} | rest], nil), do: long_block?(rest, 0)
  defp long_block?([{:code_tail, _} | rest], n) when is_integer(n), do: long_block?(rest, nil)
  defp long_block?([_line | _rest], n) when is_integer(n) and n >= @frame_cap, do: true
  defp long_block?([_line | rest], n) when is_integer(n), do: long_block?(rest, n + 1)
  defp long_block?([_line | rest], nil), do: long_block?(rest, nil)

  defp cap_nested([], acc, nil), do: Enum.reverse(acc)
  defp cap_nested([], acc, inner), do: Enum.reverse(acc, Enum.reverse(inner))

  defp cap_nested([{:code_head, _} = head | rest], acc, nil), do: cap_nested(rest, [head | acc], [])

  defp cap_nested([{:code_tail, _} = tail | rest], acc, inner) when is_list(inner),
    do: cap_nested(rest, [tail | Enum.reverse(cap(Enum.reverse(inner), :capped), acc)], nil)

  defp cap_nested([line | rest], acc, nil), do: cap_nested(rest, [line | acc], nil)
  defp cap_nested([line | rest], acc, inner), do: cap_nested(rest, acc, [line | inner])

  @doc """
  What is still arriving, after the transcript's blocks: the reasoning being streamed (at
  the level of the turn it belongs to), the reply being written on the surface it lands
  on, the curtain line, and what the window waits on, which is never collapsed.
  """
  @spec live_blocks(
          window(),
          String.t(),
          map() | boolean(),
          non_neg_integer(),
          integer(),
          map() | nil,
          map() | nil
        ) :: [[line()]]
  def live_blocks(w, agent_path, view, tick, now, selection \\ nil, gate \\ nil) do
    view = view(view)
    agent = Map.get(w.agents, agent_path, new_agent())
    level = turn_level(view, max(length(turn_starts(agent.transcript)) - 1, 0))

    reasoning =
      case {agent.streaming_reasoning, level} do
        {text, _level} when text in ["", nil] -> []
        {_text, :quiet} -> []
        {text, level} -> [live_reasoning(text, Map.get(agent, :reasoning_at), now, level)]
      end

    streaming = if agent.streaming == "", do: [], else: [frame(streaming_lines(agent.streaming))]
    pending = pending_blocks(w, agent_path, selection, gate, view.once_only)

    activity =
      case pending == [] && curtain_segments(w, agent_path, tick, now) do
        [_ | _] = segments -> [[{:blank, ""}, {:activity, segments}]]
        _ -> []
      end

    reasoning ++ streaming ++ activity ++ pending
  end

  defp live_reasoning(text, at, now, level) do
    ms = if is_integer(at), do: max(now - at, 0)
    head = reasoning_head(ms, level == :everything)
    if level == :everything, do: [head | frame(reasoning_body(text))], else: [head]
  end

  @doc """
  A window tile's body: the root transcript as quiet draws it, then the activity line,
  then the question the start asks when it asks one there; `asked?` false leaves the
  question to whoever draws it on its own (command mode's "waiting for you"), and
  `turn_lines?` false leaves out the lines a side box says (TUI Decision 160). A tile is a
  glance: it says what is running in facts alone, and the pane draws the curtain line.
  """
  @spec tile_lines(window(), non_neg_integer(), integer(), boolean(), boolean(), boolean()) ::
          [line()]
  def tile_lines(w, tick, now, spacer?, asked? \\ true, turn_lines? \\ true) do
    agent = Map.get(w.agents, w.path, new_agent())
    view = view(%{detail: :quiet, turn_lines: turn_lines?, now: now})
    lines = w |> transcript_blocks(w.path, view) |> Enum.flat_map(&elem(&1, 1))

    streaming =
      if agent.streaming == "", do: [], else: frame(streaming_lines(agent.streaming))

    # Waiting on nothing but the start's question, where it is drawn elsewhere, is no
    # activity of the window's own: command mode says it once, under "waiting for you".
    only_asked? = not asked? and w.pending != [] and Enum.all?(w.pending, &(&1.kind == :local))

    activity =
      case not only_asked? && activity_line(w, tick, now) do
        line when is_binary(line) ->
          if(spacer?, do: [{:blank, ""}], else: []) ++ [{:activity, activity_segments(line)}]

        _none ->
          []
      end

    # A question the start asks is answered from the command line (TUI Decision 154), so
    # the tile it shows in says it too.
    asked =
      case asked? && local_question(w) do
        item when is_map(item) -> local_lines(item)
        _none -> []
      end

    lines ++ streaming ++ activity ++ asked
  end

  # Text still arriving is shown plain: it changes on every frame, and it becomes
  # markdown the moment the message lands.
  defp streaming_lines(text),
    do: text |> sanitize() |> String.split("\n") |> Enum.map(&{:text, &1})

  defp reasoning_body(text),
    do: text |> sanitize() |> String.split("\n") |> Enum.map(&{:reasoning_body, &1})

  ## The curtain line (TUI Decision 161)

  # The flourish, by what the window's own agent is doing and how many times it has done
  # that this turn: the second time it thinks reads differently from the first, and past
  # the end of a list the line is its facts alone. Theatre, dry, never sorry and never a
  # person; the set is `docs/design/frames.md`'s, and nowhere else: not the headless
  # printer, `troupe bench`, CI or `--json`, which never draw this line.
  @curtain %{
    starting: ["the house lights go down"],
    thinking: [
      "the actors are powdering their nose",
      "running lines in the wings",
      "the prompter finds the page"
    ],
    acting: ["fetching props", "shifting the scenery", "the stagehands are at it"],
    reading: ["reading the script", "checking the prompt book", "rereading the second act"],
    compacting: ["cutting the second act", "trimming for time"]
  }

  @reads ~w(read_file grep glob list_files git_read read_branch read_output recall web_fetch)

  @doc "The curtain line's written set, by what it is said over."
  @spec curtain_set() :: %{atom() => [String.t()]}
  def curtain_set, do: @curtain

  @doc """
  The curtain line the pane draws while a turn runs (TUI Decision 161): the flourish as a
  prefix, then the facts, `activity_line/4`'s words, which are always there and always in
  the same place — `◐ the actors are powdering their nose — thinking (00:12)`. Waiting on
  a person, a model error and a subagent's own pane get the facts alone, and so does a
  phase past the end of its list; `nil` when nothing runs.
  """
  @spec curtain_line(window(), String.t(), non_neg_integer(), integer()) :: String.t() | nil
  def curtain_line(w, path, tick, now) do
    case curtain_segments(w, path, tick, now) do
      [] -> nil
      segments -> segment_text(segments)
    end
  end

  defp curtain_segments(w, path, tick, now) do
    case activity_line(w, path, tick, now) do
      line when is_binary(line) ->
        case {activity_segments(line), flourish(w, path)} do
          {[{:activity_glyph, glyph}, {:activity, facts}], words} when is_binary(words) ->
            [{:activity_glyph, glyph}, {:curtain, " " <> words <> " —"}, {:activity, facts}]

          {segments, _none} ->
            segments
        end

      nil ->
        []
    end
  end

  defp flourish(%{path: path} = w, path) do
    agent = Map.get(w.agents, path, new_agent())
    kind = Map.get(w.activity, path)
    count = Map.get(Map.get(w, :curtain, %{}), kind, 1)

    case {kind, running_names(agent)} do
      {nil, []} -> Enum.at(@curtain.starting, 0)
      {nil, names} -> Enum.at(phrases(names), 0)
      {:thinking, _names} -> Enum.at(@curtain.thinking, count - 1)
      {:compacting, _names} -> Enum.at(@curtain.compacting, count - 1)
      {:acting, [_ | _] = names} -> Enum.at(phrases(names), count - 1)
      {:acting, []} -> Enum.at(@curtain.acting, count - 1)
      _other -> nil
    end
  end

  defp flourish(_w, _path), do: nil

  defp phrases(names),
    do: if(Enum.all?(names, &(&1 in @reads)), do: @curtain.reading, else: @curtain.acting)

  defp running_names(agent),
    do: for({:tool, %{status: :running, name: name}} <- agent.transcript, do: name)

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

  defp entry_lines({:reasoning, %{ms: ms} = r}, expanded?),
    do: if(expanded?, do: reasoning_frame(r), else: [reasoning_head(ms, false)])

  defp entry_lines({:system, text}, _expanded?),
    do: Enum.map(String.split(text, "\n"), &{:system, "· " <> &1})

  defp entry_lines({:tool, t}, expanded?) do
    head = {head_kind(t.status), head_segments(t)}
    if expanded?, do: [head | t.body], else: [head]
  end

  # One line, expanded or not: the document is `/scratch`'s to show (TUI Decision 159).
  defp entry_lines({:scratch, card}, _expanded?) do
    [
      {:tool_ok,
       [
         {:tool_glyph, "▤"},
         {:tool_name, " " <> card.title},
         {:tool_arg, " · " <> card.name},
         {:tool_note, " · " <> scratch_note(card)}
       ]}
    ]
  end

  # The person's command, marked as theirs with its `!`, then what it printed: the last
  # rows of it, or all with the turn opened (`e`), since a person ran it to read it.
  defp entry_lines({:shell, s}, expanded?) do
    head = {:user, [{:user_marker, "! "}, {:user, s.command}] ++ shell_notes(s)}
    [head | shell_body(s.lines, expanded?)]
  end

  @doc """
  The scratchpad documents this screen's windows were shown, for `/scratch` (TUI
  Decision 159): a fold over the cards, as the rest of the screen is, so a screen that
  attaches late or comes back has them from the replay. The latest card of each name in
  each window, its `window` beside it, in the order each name was first shown.
  """
  @spec scratch_documents(t()) :: [map()]
  def scratch_documents(%__MODULE__{} = m) do
    for path <- m.order,
        w = m.windows[path],
        w != nil,
        {_agent, a} <- Enum.sort_by(w.agents, &elem(&1, 0)),
        {:scratch, card} <- a.transcript,
        reduce: [] do
      docs ->
        doc = Map.put(card, :window, path)

        case Enum.find_index(docs, &(&1.window == path and &1.name == card.name)) do
          nil -> docs ++ [doc]
          i -> List.update_at(docs, i, &if(card.version >= &1.version, do: doc, else: &1))
        end
    end
  end

  @doc """
  A scratchpad document's words as lines for `/scratch`'s pane: Markdown drawn as an
  assistant's reply is, the other kinds as they were written.
  """
  @spec document_lines(String.t(), String.t()) :: [line()]
  def document_lines("markdown", content), do: content |> sanitize() |> markdown()

  def document_lines(_kind, content),
    do: content |> sanitize() |> String.split("\n") |> Enum.map(&{:text, &1})

  @doc """
  A scratchpad document's size and how often it was written, as its card and `/scratch`
  say them (TUI Decision 159): `840 B · new`, then `2.3 kB · updated 2 times`, the count
  every write of its name, the first included.
  """
  @spec scratch_note(%{size: non_neg_integer(), version: pos_integer()}) :: String.t()
  def scratch_note(%{size: size, version: version}),
    do: doc_size(size) <> " · " <> if(version > 1, do: "updated #{version} times", else: "new")

  defp doc_size(size) when size >= 1_000_000, do: "#{Float.round(size / 1_000_000, 1)} MB"
  defp doc_size(size) when size >= 1_000, do: "#{Float.round(size / 1_000, 1)} kB"
  defp doc_size(size), do: "#{size} B"

  @doc "How a person's command stands, in a few words: running, its exit, a kill."
  @spec shell_status(shell_entry()) :: String.t()
  def shell_status(%{status: :running}), do: "running · Esc kills it"
  def shell_status(%{status: :exited, exit_status: status}), do: "exit #{status}"

  def shell_status(%{status: :timeout, timeout_ms: ms}) when is_integer(ms),
    do: "timed out after #{Float.round(ms / 1000, 1)} s and was killed"

  def shell_status(%{status: :timeout}), do: "timed out and was killed"
  def shell_status(%{status: :killed}), do: "killed"
  def shell_status(%{reason: reason}) when is_binary(reason), do: "could not run: " <> reason
  def shell_status(_s), do: "could not run"

  defp shell_notes(s) do
    where = if s.where, do: [{:tool_note, " · on " <> s.where}], else: []
    kept = if s.agent, do: [], else: [{:tool_note, " · kept from the agent"}]
    where ++ [{:tool_note, " · " <> shell_status(s)}] ++ kept
  end

  @shell_rows 20

  defp shell_body([""], _expanded?), do: []

  defp shell_body(lines, false) when length(lines) > @shell_rows do
    hidden = length(lines) - @shell_rows

    [{:system, "  … #{hidden} earlier #{if hidden == 1, do: "line", else: "lines"}"}] ++
      plain(Enum.take(lines, -@shell_rows))
  end

  defp shell_body(lines, _expanded?), do: plain(lines)

  # A tool frame's header (TUI Decision 161): glyph, name, target, outcome and, from a
  # second up, how long it took.
  defp head_segments(%{status: status, name: name, input: input, summary: summary} = t) do
    took =
      case {Map.get(t, :started_at), Map.get(t, :ended_at)} do
        {from, to} when is_integer(from) and is_integer(to) and to - from >= 1000 ->
          [{:tool_note, " · " <> seconds(to - from)}]

        _ ->
          []
      end

    [
      {:tool_glyph, status_glyph(status)},
      {:tool_name, " " <> name},
      {:tool_arg, " " <> input}
    ] ++ if(summary == "", do: [], else: [{:tool_note, " · " <> summary}]) ++ took
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
  # their own gutter and the code highlighted for the file's language. A read of part
  # of a file opens with the range it shows, and one cut at the size cap ends with a
  # note that says so; both stay plain lines around the source.
  defp body_lines(%{name: "read_file", input: path, lines: lines}) do
    {head, rest} =
      case lines do
        ["(lines " <> _ = range | rest] -> {[range], rest}
        _ -> {[], lines}
      end

    numbered = rest |> Enum.map(&split_number/1) |> Enum.take_while(&(&1 != nil))

    cut =
      case Enum.drop(rest, length(numbered)) do
        [] -> []
        ["", "[truncated:" <> _ = note] -> [note]
        _other -> nil
      end

    if numbered != [] and cut != nil,
      do: plain(head) ++ numbered_source(numbered, language_of(path)) ++ plain(cut),
      else: plain(lines)
  end

  defp body_lines(%{lines: lines}), do: plain(lines)

  defp plain(lines), do: Enum.map(lines, &{:body, &1})

  # `read_file` writes the number, a tab and the line, and `sanitize/1` has expanded
  # the tab to the next `@tab` stop by now: `7   code`, `1000    code`. Splitting at
  # the stop the number's own width implies keeps the code's indentation out of the
  # separator. A file that ends in a newline ends in an empty numbered line, which
  # the result's trimming leaves as the number alone.
  defp split_number(line) do
    case Regex.run(~r/^\d+/, line) do
      [number] ->
        {gutter, code} = String.split_at(line, (div(byte_size(number), @tab) + 1) * @tab)
        if String.trim_trailing(gutter) == number, do: {number, code}

      nil ->
        nil
    end
  end

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
  own kind, and the rest is prose with inline code and bold picked out. A blank
  line beside a fence, or at either end of the message, is dropped: the rules
  already set the block apart, and each one was a blank row (issue #182).

  A frame of its own inside the prose (TUI Decision 161) for each fenced block: code with
  its language, and its path when the fence names one (```` ```elixir lib/p.ex ````); a
  `diff` with its path and `+n −m`; `csv`, `tsv` and `json` as data, a table with its row
  count when it parses as one and source when it does not. A pipe table is drawn as a
  table, and a nested list indents with its marker. What this does not draw is left as
  written: raw HTML, images, footnotes, and a table wider than 100 columns, which says so.
  """
  @spec markdown(String.t()) :: [line()]
  def markdown(text) when is_binary(text),
    do: text |> String.split("\n") |> trim_blank() |> block([])

  defp trim_blank(lines) do
    lines
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&blank?/1)
    |> Enum.reverse()
  end

  defp blank?(line), do: String.trim(line) == ""

  defp block([], acc), do: Enum.reverse(acc)

  defp block(["```" <> info | rest], acc) do
    {code, after_code} = Enum.split_while(rest, &(not fence?(&1)))
    rest = after_code |> Enum.drop(1) |> Enum.drop_while(&blank?/1)
    block(rest, Enum.reverse(fenced(code, info)) ++ Enum.drop_while(acc, &blank_prose?/1))
  end

  defp block([line | rest] = lines, acc) do
    case pipe_table(lines) do
      {table, rest} -> block(rest, Enum.reverse(table) ++ acc)
      nil -> block(rest, [prose(line) | acc])
    end
  end

  # The blank lines already emitted before a fence: prose with nothing in it.
  defp blank_prose?({:text, [{:text, text}]}), do: blank?(text)
  defp blank_prose?(_line), do: false

  defp fence?(line), do: line |> String.trim() |> String.starts_with?("```")

  # What a fence holds, by its info string's first word; a second word that looks like a
  # path is the path the block's header names.
  defp fenced(body, info) do
    [label | more] = info |> String.trim() |> String.split(~r/\s+/)
    path = Enum.find(more, &(&1 =~ ~r/[\/.]/))

    case String.downcase(label) do
      kind when kind in ["diff", "patch"] -> diff_block(body, path)
      "csv" -> data_block(body, "csv", ",", path)
      "tsv" -> data_block(body, "tsv", "\t", path)
      "json" -> json_block(body, path)
      _code -> code_block(body, label, path)
    end
  end

  defp code_block(code, label, path) do
    language = if label == "", do: nil, else: label
    highlighted = highlight(Enum.join(code, "\n"), language, length(code))

    [rule_above(label, path && " · " <> path)] ++
      Enum.map(highlighted, &{:code, &1}) ++ [rule_below()]
  end

  defp rule_above("", nil), do: {:code_head, [{:muted, "┌"}, {:fill, "─"}]}
  defp rule_above("", note), do: rule_above("code", note)

  defp rule_above(label, note) do
    {:code_head,
     [{:muted, "┌─ "}, {:code_lang, label}] ++
       if(note, do: [{:muted, note}], else: []) ++ [{:muted, " "}, {:fill, "─"}]}
  end

  defp rule_below, do: {:code_tail, [{:muted, "└"}, {:fill, "─"}]}

  # A diff in a fence: its path (the fence's, else its own `+++` line's) and what it adds
  # and removes, then its lines coloured as an edit's are.
  defp diff_block(body, path) do
    path =
      path ||
        Enum.find_value(body, fn
          "+++ " <> to -> to |> String.trim() |> String.replace_prefix("b/", "")
          _line -> nil
        end)

    added = Enum.count(body, &(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
    gone = Enum.count(body, &(String.starts_with?(&1, "-") and not String.starts_with?(&1, "---")))
    note = if(path, do: " · " <> path, else: "") <> " +#{added} −#{gone}"

    [rule_above("diff", note)] ++
      Enum.map(body, fn line -> {:code, [diff_line(line)]} end) ++ [rule_below()]
  end

  # Comma- or tab-separated rows: a table under its header row when every row has as many
  # cells as the header, the source as written when they do not.
  defp data_block(body, label, sep, path) do
    rows = body |> Enum.reject(&blank?/1) |> Enum.map(&csv_cells(&1, sep))

    case rows do
      [head | [_ | _] = rest] ->
        if Enum.all?(rest, &(length(&1) == length(head))),
          do: data_table(label, head, rest, body, path),
          else: code_block(body, label, path)

      _ ->
        code_block(body, label, path)
    end
  end

  # An array of flat objects is a table, its columns the keys in the order they first
  # appear; anything else JSON can say is shown as its source.
  defp json_block(body, path) do
    with {:ok, [_ | _] = items} <- Jason.decode(Enum.join(body, "\n"), objects: :ordered_objects),
         true <- Enum.all?(items, &flat_object?/1) do
      columns =
        items
        |> Enum.flat_map(fn %Jason.OrderedObject{values: v} -> Enum.map(v, &elem(&1, 0)) end)
        |> Enum.uniq()

      rows =
        Enum.map(items, fn %Jason.OrderedObject{values: v} ->
          Enum.map(columns, fn key ->
            v |> List.keyfind(key, 0, {key, nil}) |> elem(1) |> scalar()
          end)
        end)

      data_table("json", columns, rows, body, path)
    else
      _ -> code_block(body, "json", path)
    end
  end

  defp flat_object?(%Jason.OrderedObject{values: values}),
    do: Enum.all?(values, fn {_key, v} -> not is_list(v) and not is_struct(v) end)

  defp flat_object?(_item), do: false

  defp scalar(nil), do: ""
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value), do: to_string(value)

  defp data_table(label, head, rows, body, path) do
    n = length(rows)
    note = " · #{n} #{if n == 1, do: "row", else: "rows"}" <> if(path, do: " · " <> path, else: "")

    case table_lines(head, List.duplicate(:left, length(head)), rows, :code) do
      nil -> code_block(body, label, path)
      lines -> [rule_above(label, note) | lines] ++ [rule_below()]
    end
  end

  defp csv_cells(line, sep), do: line |> String.graphemes() |> csv(sep, "", [], false)

  defp csv([], _sep, cell, cells, _quoted?),
    do: [cell | cells] |> Enum.reverse() |> Enum.map(&String.trim/1)

  defp csv(["\"", "\"" | rest], sep, cell, cells, true),
    do: csv(rest, sep, cell <> "\"", cells, true)

  defp csv(["\"" | rest], sep, cell, cells, quoted?), do: csv(rest, sep, cell, cells, not quoted?)
  defp csv([sep | rest], sep, cell, cells, false), do: csv(rest, sep, "", [cell | cells], false)
  defp csv([c | rest], sep, cell, cells, quoted?), do: csv(rest, sep, cell <> c, cells, quoted?)

  # A pipe table: a row of cells, the rule under it (`|---|:--:|`), and the rows that
  # follow while each has a pipe in it.
  defp pipe_table([head, rule | rest]) do
    if String.contains?(head, "|") and table_rule?(rule) do
      {rows, rest} = Enum.split_while(rest, &(String.contains?(&1, "|") and not blank?(&1)))
      aligns = rule |> pipe_cells() |> Enum.map(&align/1)
      head = pipe_cells(head)
      rows = Enum.map(rows, &pipe_cells/1)

      case table_lines(head, aligns, rows, :table) do
        nil -> {too_wide([head | rows]), rest}
        lines -> {lines, rest}
      end
    end
  end

  defp pipe_table(_lines), do: nil

  defp table_rule?(line), do: line =~ ~r/^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/

  defp pipe_cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp align(cell) do
    case {String.starts_with?(cell, ":"), String.ends_with?(cell, ":")} do
      {true, true} -> :center
      {false, true} -> :right
      _ -> :left
    end
  end

  # Said plainly rather than drawn badly: a table too wide for a terminal is its source.
  defp too_wide(rows) do
    [{:text, [{:muted, "(a table too wide to draw here, as written:)"}]}] ++
      Enum.map(rows, &{:table, [{:muted, "| " <> Enum.join(&1, " | ") <> " |"}]})
  end

  @cell_cap 32
  @table_max 100

  # A table's lines, the header bold over a rule, each column as wide as its widest cell
  # up to a cap past which a cell is cut with `…`; `nil` when it is wider than a terminal
  # can be expected to show. `kind` is the lines' kind: `:table` in prose, `:code` inside
  # a data frame's rules.
  defp table_lines(head, aligns, rows, kind) do
    columns = Enum.max([length(head) | Enum.map(rows, &length/1)])
    pad = fn cells -> cells ++ List.duplicate("", columns - length(cells)) end
    cells = Enum.map([head | rows], fn row -> row |> pad.() |> Enum.map(&cell_text/1) end)
    aligns = pad_aligns(aligns, columns)

    widths =
      cells
      |> Enum.zip_with(& &1)
      |> Enum.map(fn column ->
        column |> Enum.map(&cell_width/1) |> Enum.max() |> min(@cell_cap)
      end)

    if Enum.sum(widths) + 3 * (columns - 1) > @table_max do
      nil
    else
      [head_cells | row_cells] = cells

      rule =
        {kind, [{:table_rail, Enum.map_join(widths, "─┼─", &String.duplicate("─", &1))}]}

      [{kind, table_row(head_cells, widths, aligns, :strong)}, rule] ++
        Enum.map(row_cells, &{kind, table_row(&1, widths, aligns, :text)})
    end
  end

  defp pad_aligns(aligns, columns),
    do: Enum.take(aligns ++ List.duplicate(:left, columns), columns)

  defp cell_text(cell) do
    if cell_width(cell) > @cell_cap,
      do: elem(take_cells(cell, @cell_cap - 1), 0) <> "…",
      else: cell
  end

  defp table_row(cells, widths, aligns, tag) do
    [cells, widths, aligns]
    |> Enum.zip()
    |> Enum.map(fn {cell, width, align} -> {tag, aligned(cell, width, align)} end)
    |> Enum.intersperse({:table_rail, " │ "})
  end

  defp aligned(cell, width, :left), do: cell <> spaces(width - cell_width(cell))
  defp aligned(cell, width, :right), do: spaces(width - cell_width(cell)) <> cell

  defp aligned(cell, width, :center) do
    room = width - cell_width(cell)
    spaces(div(room, 2)) <> cell <> spaces(room - div(room, 2))
  end

  defp spaces(n), do: String.duplicate(" ", max(n, 0))

  # A nested list's marker changes with its depth, two columns a level, and the rows an
  # item wraps onto line up under its text (`rails/1`).
  @markers ~w(• ◦ ▪)

  defp prose(line) do
    cond do
      match = Regex.run(~r/^(\#{1,6})\s+(.*)$/, line) ->
        [_, hashes, text] = match
        {:heading, [{:muted, hashes <> " "} | inline(text)]}

      match = Regex.run(~r/^(\s*)([-*+])\s+(.*)$/, line) ->
        [_, lead, _marker, text] = match
        depth = div(cell_width(lead), 2)
        marker = Enum.at(@markers, rem(depth, length(@markers)))
        {:bullet, [{:bullet_marker, spaces(2 * depth) <> marker <> " "} | inline(text)]}

      match = Regex.run(~r/^(\s*)(\d+[.)])\s+(.*)$/, line) ->
        [_, lead, marker, text] = match
        depth = div(cell_width(lead), 2)
        {:bullet, [{:bullet_marker, spaces(2 * depth) <> marker <> " "} | inline(text)]}

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
  # A laptop's session steered from here through the plane (`once_only`) is answered once:
  # allowing a tool for the rest of the session is the laptop's person's to give, at the
  # laptop, so neither the key nor the words offer it.
  defp pending_blocks(%{pending: []}, _path, _selection, _gate, _once_only), do: []

  defp pending_blocks(w, path, selection, gate, once_only) do
    keys = if once_only, do: "y allow once / n deny", else: "y allow / n deny / a allow for session"

    [
      Enum.flat_map(w.pending, fn item ->
        who = if item.agent_path == path, do: "", else: "[#{item.agent_path}] "

        case item do
          # A delegation a person asked to see first (root Decision 850, TUI Decision 157).
          %{kind: :approval, delegation: %{} = _delegation} ->
            gate_lines(item, who, gate, once_only)

          %{kind: :approval, name: name, preview: preview} = item ->
            [
              {:blank, ""},
              {:pending, "#{who}APPROVAL: #{name} (#{keys})"}
              | asked_by(item) ++
                  ((preview || "") |> sanitize() |> String.split("\n") |> Enum.map(&diff_line/1))
            ]

          # A question about a text — the prompt a workspace's command would send (troupe
          # Decision 814) — has it under the question, line for line, before the answers.
          %{kind: :question, question: q} ->
            [{:blank, ""}, {:pending, "#{who}QUESTION: #{q}"}] ++
              preview_lines(item) ++ question_lines(item, selection)

          # The budget question is drawn as the question it rides on (Decision 120): the
          # harness's words, its options numbered, and an amount typed.
          %{kind: :budget} ->
            [{:blank, ""}, {:pending, "#{who}BUDGET: #{budget_words(item)}"}] ++
              question_lines(item, selection)

          %{kind: :local} ->
            local_lines(item)

          # Never raise here: the renderer's caller drops the frame on an
          # exception, which reads as a frozen terminal.
          %{kind: kind} ->
            [{:blank, ""}, {:pending, "#{who}WAITING: #{kind}"}]
        end
      end)
    ]
  end

  # A call a per-tool rule of the configuration asks about (root #658) says which rule and
  # whose; allowing it for the session does not stop the next such call asking.
  defp asked_by(%{rule: %{"rule" => rule} = said}) when is_binary(rule) do
    whose =
      case said do
        %{"scope" => "enforced"} -> "your organisation"
        %{"scope" => "org"} -> "your organisation's defaults"
        # A pod session's: the worker profile it runs on, named by the source.
        %{"scope" => "profile"} -> "the worker profile"
        %{"scope" => scope} when is_binary(scope) -> scope
        _unsaid -> "the configuration"
      end

    where = if is_binary(said["source"]), do: " (#{said["source"]})", else: ""

    [
      {:system,
       "  asked by the rule ask #{sanitize(rule)}, from #{whose}#{where}: every such call asks"}
    ]
  end

  defp asked_by(_item), do: []

  @doc """
  A question the start asks (TUI Decision 154): what it is about first (the files, or one
  file's diff, coloured as an edit's), then the question with its keys, the default in
  capitals as a terminal prompt writes it, and what the keys do.
  """
  @spec local_lines(map()) :: [line()]
  def local_lines(item) do
    preview =
      (item.preview || "")
      |> sanitize()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> diff_line() |> indent_line() end)

    [{:blank, ""} | preview] ++
      [{:pending, "QUESTION: #{item.question} [#{keys_label(item)}]"}, {:system, local_hint(item)}]
  end

  defp indent_line({tag, text}), do: {tag, "  " <> text}

  ## The delegation gate (root Decision 850, TUI Decision 157)

  @gate_parts [
    {"goal", "Goal"},
    {"context", "Context"},
    {"constraints", "Constraints"},
    {"deliverable", "Deliverable"},
    {"do_not", "Do not"}
  ]

  @doc "The brief's parts in order, each with the name the gate shows it by."
  @spec gate_parts() :: [{String.t(), String.t()}]
  def gate_parts, do: @gate_parts

  @doc """
  The person's draft of an answer to the delegation the gate shows: the parts they edited
  (`edits`), the subagent they switched it to (`agent`), and where the keys are (`step`:
  `nil`; `:edit`, choosing a part; `{:edit, part}`, editing one in the box; `:switch`,
  choosing an agent; `:deny`, typing a word back). A draft for another call is a fresh one.
  """
  @spec gate_draft(map() | nil, map()) :: map()
  def gate_draft(%{call_id: id} = draft, %{call_id: id}), do: draft
  def gate_draft(_draft, item), do: %{call_id: item.call_id, edits: %{}, agent: nil, step: nil}

  @doc "The subagent a draft sends the brief to: the one switched to, else the one asked for."
  @spec gate_agent(map(), map()) :: String.t()
  def gate_agent(draft, item), do: draft.agent || item.delegation["agent"]

  @doc "A part of the brief as the draft has it: as edited, else as the agent wrote it."
  @spec gate_part(map(), map(), String.t()) :: String.t()
  def gate_part(draft, item, part),
    do: Map.get(draft.edits, part) || get_in(item.delegation, ["brief", part]) || ""

  @doc """
  What `approval.respond` carries for a draft besides its word: `agent` when it was
  switched, `brief` with the parts edited; nothing when neither.
  """
  @spec gate_answer(map(), map()) :: map()
  def gate_answer(draft, item) do
    agent = gate_agent(draft, item)

    %{}
    |> then(&if(agent != item.delegation["agent"], do: Map.put(&1, "agent", agent), else: &1))
    |> then(&if(draft.edits != %{}, do: Map.put(&1, "brief", draft.edits), else: &1))
  end

  # The whole thing before the child starts: the agent and where its definition is, the
  # tools and permissions it will hold, its depth and budget share, the brief's five parts
  # as they will be sent, and what the keys do now.
  defp gate_lines(item, who, draft, once_only) do
    d = item.delegation
    draft = gate_draft(draft, item)
    asked = d["agent"]
    agent = gate_agent(draft, item)
    always = if once_only, do: "", else: " · a always for #{agent}"

    [
      {:blank, ""},
      {:pending,
       "#{who}DELEGATE to #{agent}#{if agent != asked, do: " (switched from #{asked})", else: ""}: " <>
         "run it? (y run · e edit · s switch · n deny#{always})"},
      {:system, "  /agents #{asked} opens its definition: #{definition_where(d["definition"])}"},
      {:system,
       "  depth #{d["depth"]} of #{d["max_depth"]} · #{share(d["budget_share"])} of the budget · " <>
         "tools: #{gate_tools(d["tools"])}"}
    ] ++ switched_line(d, agent, asked) ++ brief_lines(draft, item) ++ step_lines(draft, item)
  end

  defp definition_where(definition) when is_map(definition) do
    [definition["layer"], definition["path"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp definition_where(_none), do: "its definition"

  defp share(n) when is_number(n), do: "#{round(n * 100)}%"
  defp share(_none), do: "a share"

  defp gate_tools(tools) when is_list(tools) and tools != [] do
    Enum.map_join(tools, ", ", fn tool -> "#{tool["name"]} #{tool["permission"]}" end)
  end

  defp gate_tools(_none), do: "its own"

  defp switched_line(_d, agent, agent), do: []

  defp switched_line(d, agent, _asked) do
    about = Enum.find_value(d["agents"] || [], "", &(&1["name"] == agent && &1["description"]))
    [{:system, "  #{agent} runs it instead, with its own tools and budget: #{about}"}]
  end

  defp brief_lines(draft, item) do
    Enum.flat_map(@gate_parts, fn {part, label} ->
      edited? = Map.has_key?(draft.edits, part)
      tag = if edited?, do: :diff_add, else: :body
      [first | rest] = draft |> gate_part(item, part) |> sanitize() |> String.split("\n")
      mark = if edited?, do: " (edited)", else: ""
      [{tag, "#{label}#{mark}: #{first}"} | Enum.map(rest, &{tag, "  " <> &1})]
    end)
  end

  defp step_lines(%{step: nil}, _item), do: []

  defp step_lines(%{step: :edit}, _item) do
    parts =
      @gate_parts |> Enum.with_index(1) |> Enum.map_join(" · ", fn {{_p, l}, n} -> "#{n} #{l}" end)

    [{:system, "edit which part? #{parts} · Esc back"}]
  end

  defp step_lines(%{step: {:edit, part}}, _item) do
    {_part, label} = List.keyfind(@gate_parts, part, 0, {part, part})

    [
      {:system,
       "editing #{label}: change it in the box; Enter keeps it, Shift-Enter starts a line · Esc back"}
    ]
  end

  defp step_lines(%{step: :switch}, item) do
    agents =
      (item.delegation["agents"] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {a, n} ->
        {:body,
         [
           {:bullet_marker, "  #{n}. "},
           {:body, a["name"] || ""},
           {:muted, " — " <> (a["description"] || "")}
         ]}
      end)

    agents ++ [{:system, "a digit sends the brief there · Esc back"}]
  end

  defp step_lines(%{step: :deny}, _item),
    do: [
      {:system,
       "deny: type a word back for the agent that delegated, or nothing, then Enter · Esc back"}
    ]

  defp keys_label(item),
    do: Enum.map_join(item.keys, "/", &if(&1 == item.default, do: String.upcase(&1), else: &1))

  @local_words %{"y" => "yes", "n" => "no", "r" => "each file first"}

  defp local_hint(item) do
    Enum.map_join(item.keys, " · ", &"#{&1} #{@local_words[&1]}") <>
      " · Enter #{@local_words[item.default]}"
  end

  @doc """
  The question a session's start asks that is still open in a window, or `nil`: what the
  command line's and the window's keys answer while nothing is typed (TUI Decision 154).
  """
  @spec local_question(window()) :: map() | nil
  def local_question(w), do: Enum.find(w.pending, &(&1.kind == :local))

  @doc "What Enter answers a question the start asks: its default, in words (`yes`, `no`)."
  @spec local_default(map()) :: String.t()
  def local_default(item), do: @local_words[item.default]

  # A daemon from before the question carried its words sends the limit alone.
  defp budget_words(%{question: question}) when is_binary(question) and question != "", do: question
  defp budget_words(item), do: "#{Map.get(item, :detail, "a limit is reached")} — continue?"

  defp preview_lines(%{preview: preview}) when is_binary(preview) and preview != "" do
    lines = preview |> sanitize() |> String.split("\n") |> Enum.map(&{:body, "  │ " <> &1})
    lines ++ [{:blank, ""}]
  end

  defp preview_lines(_item), do: []

  # A question with no options is still just an input box.
  defp question_lines(%{options: []}, _selection),
    do: [{:system, "type your answer and press Enter"}]

  defp question_lines(item, selection) do
    selected = selected_labels(item, selection)

    options =
      item.options
      |> Enum.with_index(1)
      |> Enum.map(fn {opt, n} -> option_line(opt, n, item.multiple, opt.label in selected) end)

    options ++ [{:system, hint(item)}]
  end

  defp option_line(opt, n, multiple?, chosen?) do
    marker = if multiple?, do: if(chosen?, do: "[x] ", else: "[ ] "), else: ""
    detail = if opt.description, do: " — " <> opt.description, else: ""
    tag = if chosen?, do: :pending, else: :body
    {tag, [{:bullet_marker, "  #{n}. "}, {tag, marker <> opt.label}, {:muted, detail}]}
  end

  defp hint(%{kind: :budget}),
    do:
      "press a digit to choose · or type an amount (+25, +25 session, +25 workspace) and press Enter"

  defp hint(%{multiple: true}),
    do: "digits toggle · Enter sends the ticked options · or type an answer and press Enter"

  defp hint(_single), do: "press a digit to choose · or type an answer and press Enter"

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

  # Both variation selectors: VS16 asks for an emoji, VS15 (after ⏺, the done mark) for
  # text, and neither takes a cell of its own.
  defp combining?(cp),
    do:
      cp in 0x0300..0x036F or cp in 0x200B..0x200F or cp in 0x20D0..0x20FF or
        cp in [0xFE0E, 0xFE0F]

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

  @doc "The plain text of a line or of a list of segments, a frame's rail left out."
  @spec line_text(line() | [segment()]) :: String.t()
  def line_text({_kind, text}) when is_binary(text), do: text
  def line_text({_kind, segments}) when is_list(segments), do: segment_text(segments)
  def line_text(segments) when is_list(segments), do: segment_text(segments)

  defp segment_text(segments) do
    Enum.map_join(segments, fn
      {:frame, _rail} -> ""
      {_tag, text} -> text
    end)
  end

  @doc "A line's segments, tagged with its own kind when it is plain text."
  @spec segments(line()) :: [segment()]
  def segments({kind, text}) when is_binary(text), do: [{kind, text}]
  def segments({_kind, segments}) when is_list(segments), do: segments

  # Segment tags that draw a rail or gutter rather than content: they are dropped
  # when a slice of a row is copied.
  @rail_tags [:frame, :gutter, :code_rail, :quote_rail, :linenum]

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
  def rail(:reasoning_body), do: {gutter(), gutter()}
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
    {lead, segs, first, rest} = rails(line)
    width = room(width, lead)
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
    {lead, segs, first, rest} = rails(line)
    width = room(width, lead)
    first_w = room(width, first)
    rest_w = room(width, rest)

    segs
    |> wrap_segments(first_w, rest_w, wrap_mode(kind))
    |> Enum.with_index()
    |> Enum.map(fn
      {row, 0} -> {kind, prepend(lead, prepend(first, row))}
      {row, _} -> {kind, prepend(lead, prepend(rest, row))}
    end)
  end

  # A line's rails as wrapping draws them: a frame's rail outermost, on every row (TUI
  # Decision 161); inside it the kind's own, save the plain gutter, which the frame's takes
  # the place of; and a list item's later rows indented as far as its text, however deep
  # the list is nested.
  defp rails({kind, _} = line) do
    case segments(line) do
      [{:frame, _} = frame | segs] ->
        {first, rest} = kind_rails(kind, segs, true)
        {frame, segs, first, rest}

      segs ->
        {first, rest} = kind_rails(kind, segs, false)
        {nil, segs, first, rest}
    end
  end

  defp kind_rails(:bullet, [{:bullet_marker, marker} | _], _framed?),
    do: {nil, {:gutter, String.duplicate(" ", cell_width(marker))}}

  defp kind_rails(kind, _segs, framed?) do
    case rail(kind) do
      {{:gutter, _}, {:gutter, _}} when framed? -> {nil, nil}
      rails -> rails
    end
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

  defp wrap_mode(k) when k in [:body, :diff_add, :diff_del, :diff_meta, :code, :code_num, :table],
    do: :char

  defp wrap_mode(_), do: :word
end
