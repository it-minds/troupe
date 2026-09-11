defmodule Troupe.UI.TUI.Model do
  @moduledoc """
  The TUI's view model: a fold over session events (persisted and transient),
  so the screen can be rebuilt from `Log.all/1` after a crash.
  """

  import Kernel, except: [apply: 2]

  alias Troupe.Event
  alias Troupe.LLM.Message

  @type entry ::
          {:user, String.t()}
          | {:assistant, String.t()}
          | {:tool, String.t(), String.t(), String.t(), :running | :ok | :error, String.t()}
          | {:system, String.t()}

  @type agent :: %{transcript: [entry()], streaming: String.t(), todos: [map()]}

  @type window :: %{
          path: String.t(),
          name: String.t(),
          profile: String.t(),
          state: atom(),
          isolation: atom(),
          started_at: integer(),
          ended_at: integer() | nil,
          tokens: non_neg_integer(),
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
          tokens: 0,
          agents: %{e.agent_path => new_agent()},
          pending: [],
          badge: false,
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
        w |> ensure_agent(path) |> push(path, {:user, d.content}) |> set_state(:running, ts)

      :llm_delta ->
        w
        |> ensure_agent(path)
        |> update_agent(path, fn a -> %{a | streaming: a.streaming <> d.text} end)

      :assistant_message ->
        text = Message.text(d.content)
        usage = Map.get(d, :usage) || %{}
        tokens = w.tokens + Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)

        w =
          w
          |> ensure_agent(path)
          |> update_agent(path, fn a -> %{a | streaming: ""} end)
          |> then(fn w -> if text == "", do: w, else: push(w, path, {:assistant, text}) end)

        Enum.reduce(Message.tool_uses(d.content), %{w | tokens: tokens}, fn tu, acc ->
          push(acc, path, {:tool, tu.id, tu.name, summarize_input(tu.name, tu.input), :running, ""})
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

      :question_asked ->
        pending =
          w.pending ++
            [%{kind: :question, call_id: d.call_id, agent_path: path, question: d.question}]

        %{w | pending: pending}

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
        line =
          "finished (#{d.reason}): #{d.summary}" <>
            if(d[:diff_stat] in [nil, ""], do: "", else: "\n#{d.diff_stat}")

        w |> ensure_agent(path) |> push(path, {:system, line}) |> Map.put(:diff_stat, d[:diff_stat])

      :cancelled ->
        push(ensure_agent(w, path), path, {:system, "cancelled"})

      :llm_error ->
        push(ensure_agent(w, path), path, {:system, "LLM error: #{d.message}"})

      :todo_updated ->
        update_agent(ensure_agent(w, path), path, fn a -> %{a | todos: d.items} end)

      :delegation_started ->
        w
        |> ensure_agent(d.child_path)
        |> push(path, {:system, "delegated to #{d.child_path} (#{d.agent})"})

      :profile_switched ->
        w |> push(path, {:system, "profile switched to #{d.name}"}) |> Map.put(:profile, d.name)

      :worktree_created ->
        %{w | worktree: %{path: d.path, git_branch: d.git_branch}}

      :worktree_merged ->
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
        push(w, path, {:system, "worktree discarded"})

      :compaction ->
        push(w, path, {:system, "context compacted (#{d.dropped_messages} messages summarized)"})

      _ ->
        w
    end
  end

  defp set_state(w, state, _ts), do: %{w | state: state}

  defp complete_tool({:tool, id, name, input, _status, _result}, %{call_id: id} = d) do
    {:tool, id, name, input, if(d.ok, do: :ok, else: :error), String.slice(d.content || "", 0, 300)}
  end

  defp complete_tool(entry, _), do: entry

  defp summarize_input("shell", %{"command" => c}), do: c

  defp summarize_input("todo_write", %{"items" => items}) when is_list(items),
    do: "#{length(items)} items"

  defp summarize_input(_, %{"path" => p}), do: p
  defp summarize_input("delegate", %{"agent" => a}), do: a
  defp summarize_input("finish", %{"summary" => s}), do: String.slice(s, 0, 60)
  defp summarize_input("ask_user", %{"question" => q}), do: q
  defp summarize_input(_, input), do: input |> Jason.encode!() |> String.slice(0, 60)

  defp new_agent, do: %{transcript: [], streaming: "", todos: []}

  defp ensure_agent(w, path), do: %{w | agents: Map.put_new(w.agents, path, new_agent())}

  defp update_agent(w, path, fun),
    do: %{w | agents: Map.update(w.agents, path, fun.(new_agent()), fun)}

  defp push(w, path, entry),
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

  @spec tokens(window()) :: String.t()
  def tokens(%{tokens: t}) when t >= 1000, do: "#{Float.round(t / 1000, 1)}k tok"
  def tokens(%{tokens: t}), do: "#{t} tok"

  @doc "Plain-text lines of an agent's transcript (tool calls collapsed unless expanded)."
  @spec transcript_lines(agent(), boolean()) :: [String.t()]
  def transcript_lines(agent, expanded?) do
    lines =
      Enum.flat_map(agent.transcript, fn
        {:user, text} ->
          ["> " <> text]

        {:assistant, text} ->
          String.split(text, "\n")

        {:system, text} ->
          Enum.map(String.split(text, "\n"), &("· " <> &1))

        {:tool, _id, name, input, status, result} ->
          head = "#{status_glyph(status)} #{name} #{input}"

          if expanded? and result != "",
            do: [head | Enum.map(String.split(result, "\n"), &("    " <> &1))],
            else: [head]
      end)

    if agent.streaming == "", do: lines, else: lines ++ String.split(agent.streaming, "\n")
  end

  defp status_glyph(:running), do: "⋯"
  defp status_glyph(:ok), do: "✓"
  defp status_glyph(:error), do: "✗"
end
