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

  alias Troupe.Event
  alias Troupe.LLM.Message

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
          worktree: map() | nil
        }

  defstruct session_id: nil,
            workspace: ".",
            windows: %{},
            order: [],
            notices: [],
            watch: %{enabled: false, backend: nil}

  @type t :: %__MODULE__{}

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
          summary: nil,
          message: nil,
          diff_stat: nil,
          worktree: nil
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

      :watch_trigger ->
        %{m | notices: Enum.take(["watch: #{e.data.kind} request from AI comments" | m.notices], 3)}

      _ ->
        update_window(m, root, fn w -> apply_to_window(w, e) end)
    end
  end

  defp apply_to_window(w, %Event{type: type, agent_path: path, data: d, ts: ts}) do
    case type do
      :input when d.source in [:user, :watch] ->
        w
        |> ensure_agent(path)
        |> push(path, {:user, d.content})
        |> update_agent(path, fn a -> %{a | ended_at: nil} end)
        |> Map.put(:ended_at, nil)
        |> set_state(:running, ts)

      :llm_delta ->
        w
        |> ensure_agent(path)
        |> update_agent(path, fn a -> %{a | streaming: a.streaming <> d.text} end)

      :agent_state ->
        %{w | activity: Map.put(w.activity, path, d.to), activity_since: ts}

      :assistant_message ->
        text = Message.text(d.content)
        used = used(Map.get(d, :usage) || %{})

        w =
          w
          |> ensure_agent(path)
          |> update_agent(path, fn a ->
            %{a | streaming: "", usage: add(a.usage, used), model: Map.get(d, :model) || a.model}
          end)
          |> then(fn w ->
            if text == "", do: w, else: push(w, path, {:assistant, markdown(sanitize(text))})
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
                question: one_line(d.question)
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
                agent_path: path
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
        push(ensure_agent(w, path), path, {:system, "cancelled"})

      :llm_error ->
        push(ensure_agent(w, path), path, {:system, "LLM error: #{d.message}"})

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

      :profile_switched ->
        w |> push(path, {:system, "profile switched to #{d.name}"}) |> Map.put(:profile, d.name)

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

      _ ->
        w
    end
  end

  defp set_state(w, state, _ts), do: %{w | state: state}

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

  defp ensure_agent(w, path, attrs \\ %{}),
    do: %{w | agents: Map.put_new(w.agents, path, new_agent(attrs))}

  defp update_agent(w, path, fun),
    do: %{w | agents: Map.update(w.agents, path, fun.(new_agent()), fun)}

  defp push(w, path, {kind, text}) when kind in [:user, :system],
    do: push_entry(w, path, {kind, sanitize(text)})

  defp push(w, path, entry), do: push_entry(w, path, entry)

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

          state in [nil, :idle] ->
            "#{spinner} starting"

          true ->
            "#{spinner} #{state}"
        end

      case children do
        [] ->
          main

        list ->
          main <>
            " · " <>
            Enum.map_join(list, ", ", fn {p, s} ->
              "#{p |> String.split("/") |> List.last()} #{s}"
            end)
      end
    end
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

  @doc "The same counts spelled out, with what the prompt cache served."
  @spec token_detail(%{usage: usage()}) :: String.t()
  def token_detail(%{usage: u}) do
    "↑ #{short(u.input + u.cache_write)} sent · ↓ #{short(u.output)} received" <>
      if u.cache_read > 0 or u.cache_write > 0,
        do: " · #{short(u.cache_read)} of the prompt came from cache",
        else: ""
  end

  @doc """
  The same counts as one short line each, for the side panel, which is too narrow
  for `token_detail/1`. The cache line is only there when the provider cached.
  """
  @spec token_lines(%{usage: usage()}) :: [String.t()]
  def token_lines(%{usage: u}) do
    ["↑ #{short(u.input + u.cache_write)} sent", "↓ #{short(u.output)} received"] ++
      if u.cache_read > 0, do: ["⟳ #{short(u.cache_read)} from cache"], else: []
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
  """
  @spec pane_blocks(window(), String.t(), boolean(), non_neg_integer(), integer()) :: [[line()]]
  def pane_blocks(w, agent_path, expanded?, tick, now) do
    agent = Map.get(w.agents, agent_path, new_agent())
    entries = Enum.map(agent.transcript, &entry_lines(&1, expanded?))

    streaming =
      if agent.streaming == "",
        do: [],
        else: [streaming_lines(agent.streaming)]

    pending = pending_blocks(w, agent_path)

    activity =
      case pending == [] && activity_line(w, agent_path, tick, now) do
        line when is_binary(line) -> [[{:blank, ""}, {:activity, activity_segments(line)}]]
        _ -> []
      end

    entries ++ streaming ++ activity ++ pending
  end

  @doc "A window tile's body: the root transcript with tool calls collapsed, then the activity line."
  @spec tile_lines(window(), non_neg_integer(), integer(), boolean()) :: [line()]
  def tile_lines(w, tick, now, spacer?) do
    agent = Map.get(w.agents, w.path, new_agent())
    lines = Enum.flat_map(agent.transcript, &entry_lines(&1, false))

    streaming =
      if agent.streaming == "", do: [], else: streaming_lines(agent.streaming)

    activity =
      case activity_line(w, tick, now) do
        nil ->
          []

        line ->
          if(spacer?, do: [{:blank, ""}], else: []) ++ [{:activity, activity_segments(line)}]
      end

    lines ++ streaming ++ activity
  end

  # Text still arriving is shown plain: it changes on every frame, and it becomes
  # markdown the moment the message lands.
  defp streaming_lines(text),
    do: text |> sanitize() |> String.split("\n") |> Enum.map(&{:text, &1})

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
  defp pending_blocks(%{pending: []}, _path), do: []

  defp pending_blocks(w, path) do
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
            [
              {:blank, ""},
              {:pending, "#{who}QUESTION: #{q}"},
              {:system, "type your answer and press Enter"}
            ]

          %{kind: :budget} ->
            [
              {:blank, ""},
              {:pending, "#{who}BUDGET EXHAUSTED: continue anyway? (y yes / n stop / a always)"}
            ]
        end
      end)
    ]
  end

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
