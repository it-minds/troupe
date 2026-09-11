defmodule Troupe.UI.Headless do
  @moduledoc """
  The same event stream as the TUI, rendered as plain lines.

  For CI, scripting, and any terminal that is not one. Like every UI in Troupe it is
  only a subscriber to `Troupe.Events` — it can be killed, restarted or never started
  at all, and the session neither notices nor waits.
  """

  use GenServer

  alias Troupe.{Events, Todo}
  alias Troupe.UI.Event

  @enforce_keys [:session_id]
  defstruct [
    :session_id,
    :waiter,
    quiet: false,
    streaming?: false,
    final: nil,
    done?: false,
    started?: false,
    errored?: false
  ]

  @doc """
  Attach a printer to a session, under the UI supervisor.

  The printer adopts the *caller's* group leader rather than the supervisor's, so its
  output goes wherever the caller's does — the terminal in normal use, and a capture
  device under test.
  """
  @spec attach(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def attach(session_id, opts \\ []) do
    opts = [session_id: session_id, group_leader: Process.group_leader()] ++ opts

    Troupe.UI.Supervisor.attach(
      Supervisor.child_spec({__MODULE__, opts}, id: {__MODULE__, session_id})
    )
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name(session_id!(opts)))

  @doc """
  Block until the root agent finishes, and report an exit code.

  0 when the run ended normally, 1 when it ended in an error or the budget ran out,
  and 124 on timeout — the code `timeout(1)` uses, so a CI step reads the same.
  """
  @spec await_completion(String.t(), pos_integer()) :: non_neg_integer()
  def await_completion(session_id, timeout_ms) do
    GenServer.call(name(session_id), {:await, timeout_ms}, timeout_ms + 5_000)
  catch
    :exit, _ -> 1
  end

  @impl GenServer
  def init(opts) do
    session_id = session_id!(opts)
    Process.set_label("troupe headless #{session_id}")

    if gl = Keyword.get(opts, :group_leader), do: Process.group_leader(self(), gl)

    Events.subscribe(session_id)

    {:ok, %__MODULE__{session_id: session_id, quiet: Keyword.get(opts, :quiet, false)}}
  end

  @impl GenServer
  def handle_call({:await, _timeout_ms}, _from, %{done?: true} = state) do
    {:reply, exit_code(state), state}
  end

  def handle_call({:await, timeout_ms}, from, state) do
    timer = Process.send_after(self(), :await_timeout, timeout_ms)
    {:noreply, %{state | waiter: {from, timer}}}
  end

  @impl GenServer
  def handle_info({:troupe_event, _session_id, event}, state) do
    case Event.normalize(event) do
      nil -> {:noreply, state}
      normalized -> {:noreply, state |> render(normalized) |> maybe_complete(normalized)}
    end
  end

  def handle_info(:await_timeout, state) do
    reply(state, 124)
    {:noreply, %{state | waiter: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- rendering --------------------------------------------------------------

  defp render(state, %{type: :llm_delta, data: %{kind: :text, text: text}}) do
    if state.quiet do
      state
    else
      IO.write(text)
      %{state | streaming?: true}
    end
  end

  defp render(state, %{type: :user_input, data: data}) do
    line(state, "\n#{prefix(data.source)} #{first_line(data.text)}")
  end

  defp render(state, %{type: :tool_call_started, data: %{name: name, args: args}}) do
    line(state, "  → #{name} #{summarise(args)}")
  end

  defp render(state, %{type: :tool_call_completed, data: %{name: name, ok?: false, content: why}}) do
    line(state, "  ✗ #{name}: #{first_line(why)}")
  end

  defp render(state, %{type: :tool_call_completed, data: %{name: name, ok?: true}}) do
    line(state, "  ✓ #{name}")
  end

  defp render(state, %{type: :delegation_started, data: %{agent: agent, task: task}}) do
    line(state, "  ⇢ delegate to #{agent}: #{first_line(task)}")
  end

  defp render(state, %{type: :approval_requested, data: %{tool: tool, call_id: call_id}}) do
    line(state, "  ? approval needed for #{tool} (#{call_id}) — run with --auto-approve in CI")
  end

  defp render(state, %{type: :todo_updated, data: %{items: items}}) do
    line(state, "  ☰ task list:\n" <> indent(Todo.render(items)))
  end

  defp render(state, %{type: :compacted}) do
    line(state, "  … compacted earlier turns")
  end

  defp render(state, %{type: :watch_notice, data: %{message: message}}) do
    line(state, "  · #{message}")
  end

  defp render(state, %{type: :llm_error, data: data}) do
    state
    |> line("  ! model request failed: #{data.reason}")
    |> Map.put(:errored?, true)
  end

  defp render(state, %{type: :cancelled}), do: line(state, "  · cancelled")

  defp render(state, %{type: :budget_exhausted, data: data}) do
    line(state, "  ! budget exhausted (#{data.limit})")
  end

  defp render(state, _event), do: state

  defp line(state, text) do
    # A streamed answer leaves the cursor mid-line; start a new one before printing
    # structure, or the two run together.
    state = if state.streaming?, do: newline(state), else: state
    IO.puts(text)
    state
  end

  defp newline(state) do
    IO.write("\n")
    %{state | streaming?: false}
  end

  defp prefix("watch"), do: "[watch]"
  defp prefix("tui_todo_edit"), do: "[tasks]"
  defp prefix(_), do: ">"

  defp first_line(text) when is_binary(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 160)
  end

  defp first_line(other), do: inspect(other)

  defp summarise(args) when is_map(args) do
    args
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{first_line(to_string_safe(value))}" end)
    |> String.slice(0, 160)
  end

  defp summarise(other), do: inspect(other)

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)

  defp indent(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
  end

  # -- completion -------------------------------------------------------------

  # An agent publishes :idle from init, before it has been given anything to do, so
  # "finished" has to mean "went busy, then came back" — otherwise a headless run
  # would report success before its own first turn.
  defp maybe_complete(state, %{type: :agent_state, agent_path: ["root"], data: data}) do
    case data.state do
      :done ->
        complete(state, if(data.done_reason in [:budget_exhausted, :error], do: 1, else: 0))

      :idle when state.started? ->
        complete(state, if(state.errored?, do: 1, else: 0))

      :idle ->
        state

      _busy ->
        %{state | started?: true}
    end
  end

  defp maybe_complete(state, _event), do: state

  defp complete(state, code) do
    state = if state.streaming?, do: newline(state), else: state
    reply(state, code)
    %{state | waiter: nil, done?: true, final: code}
  end

  defp reply(%{waiter: nil}, _code), do: :ok

  defp reply(%{waiter: {from, timer}}, code) do
    Process.cancel_timer(timer)
    GenServer.reply(from, code)
  end

  defp exit_code(%{final: nil}), do: 0
  defp exit_code(%{final: code}), do: code

  defp session_id!(opts), do: Keyword.fetch!(opts, :session_id)
  defp name(session_id), do: {:via, Registry, {Troupe.Registry, {:headless, session_id}}}
end
