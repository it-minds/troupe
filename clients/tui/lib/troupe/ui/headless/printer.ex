defmodule Troupe.UI.Headless.Printer do
  @moduledoc """
  Headless renderer: prints the event stream as plain lines prefixed by
  `agent_path`, for CI and scripting. Notifies `:on_rest` when the target
  branch rests. Pending approvals are denied (use `--auto-approve`).

  A session starts working the moment it is created, and this process is started
  after that, so a quick run can have finished — and rested — before anything here
  subscribes. So what the session has already done is read back from its journal
  and handled exactly like the live stream, and a durable event that arrives both
  ways (one published while the journal was being read) is handled once.
  """

  use GenServer

  alias Troupe.Client
  alias Troupe.Client.Message

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @impl true
  def init(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    :ok = Client.subscribe(sid)
    io = Keyword.get(opts, :io, :stdio)

    case Client.watch_status(sid) do
      %{enabled: true, backend: backend} ->
        IO.puts(io, "watcher> watch mode on (backend: #{backend})")

      _ ->
        :ok
    end

    state = %{
      session_id: sid,
      target: Keyword.get(opts, :target),
      on_rest: Keyword.get(opts, :on_rest),
      io: io,
      streaming: %{},
      seen: MapSet.new()
    }

    # Subscribed first, read back second: anything published in between is in both,
    # and `seen` drops the second copy, where the other order would lose it.
    {:ok, Enum.reduce(Client.events(sid), state, &handle_event/2)}
  end

  @impl true
  def handle_info({:troupe_event, event}, state), do: {:noreply, handle_event(event, state)}

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_event(event, state) do
    case first_time(event, state) do
      {:ok, state} -> react(event, print(event, state))
      :seen -> state
    end
  end

  # Durable events carry a sequence number, unique within their session's window, so
  # the pair identifies one; a transient event has none and is never replayed anyway.
  defp first_time(%{seq: seq, agent_path: path}, state) when is_integer(seq) do
    key = {path, seq}

    if MapSet.member?(state.seen, key),
      do: :seen,
      else: {:ok, %{state | seen: MapSet.put(state.seen, key)}}
  end

  defp first_time(_event, state), do: {:ok, state}

  defp react(event, state) do
    # A session rests when its agent is done (`agent_done`, folded to `agent_state
    # :done`) or fails. `branch_state` is the older local spelling and still read.
    case event do
      %{type: :agent_state, agent_path: path, data: %{to: :done}} when path == state.target ->
        if state.on_rest, do: state.on_rest.(0)
        state

      %{type: t, agent_path: path}
      when t in [:branch_state, :branch_failed] and path == state.target ->
        rest? = t == :branch_failed or event.data.state in [:done_unread]

        if rest? and state.on_rest do
          state.on_rest.(if(t == :branch_failed, do: 1, else: 0))
        end

        state

      _ ->
        state
    end
  end

  defp print(%{type: :llm_delta}, state), do: state

  defp print(%{type: :assistant_message, agent_path: p, data: d}, state) do
    text = Message.text(d.content)
    if text != "", do: line(state, p, text)

    for tu <- Message.tool_uses(d.content),
        do: line(state, p, "→ #{tu.name} #{Jason.encode!(tu.input)}")

    state
  end

  defp print(%{type: :input, agent_path: p, data: d}, state),
    do: say(state, p, "< #{d.content}")

  # The protocol says a tool started as its own event; the message that asked for it
  # carries text only (Decision 98).
  defp print(%{type: :tool_started, agent_path: p, data: d}, state),
    do: say(state, p, "→ #{d.name} #{Jason.encode!(d.input)}")

  defp print(%{type: :tool_call_completed, agent_path: p, data: d}, state) do
    say(state, p, "#{if d.ok, do: "✓", else: "✗"} #{d.call_id}: #{String.slice(d.content, 0, 400)}")
  end

  defp print(%{type: :approval_requested, agent_path: p, data: d}, state) do
    line(state, p, "approval needed for #{d.name}; headless mode denies it (use --auto-approve)")
    Client.approve(state.session_id, d.call_id, :deny)
    state
  end

  # A headless run has nobody to ask. With options offered the first is the least
  # surprising stand-in (models list them best-first); without any, the branch is
  # told to use its judgement so the run can rest rather than block forever.
  defp print(%{type: :question_asked, agent_path: p, data: d}, state) do
    answer =
      case List.wrap(d[:options]) do
        [%{label: label} | _] -> label
        _ -> "No user is available; proceed with your best judgement."
      end

    line(state, p, "question: #{d.question} (headless: answered #{inspect(answer)})")
    Client.answer(state.session_id, d.call_id, answer)
    state
  end

  # Without this the branch waits for an answer nobody can type and the run never
  # rests. Stopping is the safe default: a headless run has a budget for a reason.
  defp print(%{type: :budget_ask_started, agent_path: p, data: d}, state) do
    detail = if d[:detail], do: " (#{d.detail})", else: ""

    line(
      state,
      p,
      "budget exhausted#{detail}; headless mode stops here (raise the budget to go further)"
    )

    Client.approve(state.session_id, d.call_id, :deny)
    state
  end

  # A warning does not stop anything; it is the one line a headless run gets while
  # there is still budget left to raise.
  defp print(%{type: :budget_warning, agent_path: p, data: d}, state),
    do: say(state, p, "warning: #{d[:detail] || d.dimension} used")

  defp print(%{type: :truncated, agent_path: p, data: %{reason: :empty} = d}, state) do
    tail = if d[:final], do: "; stopping", else: "; asking the model to continue"
    say(state, p, "the reply had no text and no tool call" <> tail)
  end

  defp print(%{type: :truncated, agent_path: p, data: d}, state) do
    tail = if d[:final], do: "; stopping", else: "; asking again in smaller steps"
    say(state, p, "the reply hit the output token cap" <> tail)
  end

  defp print(%{type: :compaction_started, agent_path: p, data: d}, state),
    do: say(state, p, "compacting the conversation (#{d[:reason] || :requested})")

  defp print(%{type: :branch_state, agent_path: p, data: d}, state),
    do: say(state, p, "[#{d.state}]#{if d[:summary], do: " " <> d.summary, else: ""}")

  defp print(%{type: :branch_failed, agent_path: p, data: d}, state),
    do: say(state, p, "[failed_unread] #{d.message}")

  defp print(%{type: :finished, agent_path: p, data: d}, state),
    do: say(state, p, "finished (#{d.reason})")

  defp print(%{type: :notice, agent_path: p, data: d}, state), do: say(state, p, d.text)

  defp print(%{type: :branch_spawned, agent_path: p, data: d}, state),
    do: say(state, p, "spawned /#{d.name} (#{d.isolation})")

  defp print(
         %{type: :mcp_status, agent_path: p, data: %{server: name, state: st, tools: tools}},
         state
       ) do
    glyph =
      case st do
        :ready -> "✓"
        :connecting -> "…"
        :error -> "✗"
        _ -> "○"
      end

    say(state, p, "mcp: #{glyph} #{name} (#{length(tools)} tools)")
  end

  defp print(_event, state), do: state

  # Every line carries the prefix, not just the first: a tool result is routinely
  # several lines long (a command's output leads with its exit code), and a bare
  # continuation line is unattributable when several branches print at once.
  defp line(state, path, text) do
    text
    |> to_string()
    |> String.split("\n")
    |> Enum.each(&IO.puts(state.io, "#{path}> #{&1}"))
  end

  defp say(state, path, text) do
    line(state, path, text)
    state
  end
end
