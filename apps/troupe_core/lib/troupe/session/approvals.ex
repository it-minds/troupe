defmodule Troupe.Session.Approvals do
  @moduledoc """
  The permission gate for `ask` tools.

  A tool task calls `request/2` and blocks there — the *call* blocks, never the
  agent, which is free to collect other tool results meanwhile. The UI answers with
  `decide/3`. A denial comes back as a readable tool result rather than a crash, so
  the model can pick another approach.

  Callers are monitored: a tool task killed by a cancel or an agent crash is dropped
  from the pending set instead of leaving a reply nobody will ever read.
  """

  use GenServer

  alias Troupe.Session.Log

  @enforce_keys [:session_id]
  defstruct [:session_id, auto_approve: false, pending: %{}, session_allows: MapSet.new()]

  @type decision :: :allow | :deny | :allow_session

  # -- client -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.approvals(session_id))
  end

  @doc """
  Ask for permission, blocking until someone decides.

  `:infinity` is deliberate: a human may take a minute, and the timeout that matters
  is the tool's own, enforced by the agent killing the task.
  """
  @spec request(String.t(), map()) :: :allow | :deny
  def request(session_id, %{call_id: _, tool: _} = req) do
    GenServer.call(Troupe.Registry.approvals(session_id), {:request, req}, :infinity)
  catch
    # The gate restarting is not a reason to crash the tool task; it is a denial the
    # model can read and work around.
    :exit, _ -> :deny
  end

  @doc "Answer an outstanding request. First response wins."
  @spec decide(String.t(), String.t(), decision(), Troupe.Protocol.Event.Actor.t() | nil) :: :ok
  def decide(session_id, call_id, decision, actor \\ nil) do
    GenServer.cast(Troupe.Registry.approvals(session_id), {:decide, call_id, decision, actor})
  end

  @doc "Approve everything from now on, as `--auto-approve` does."
  @spec set_auto_approve(String.t(), boolean()) :: :ok
  def set_auto_approve(session_id, value) do
    GenServer.call(Troupe.Registry.approvals(session_id), {:auto_approve, value})
  end

  @doc "Requests waiting for a decision, for the UI to render."
  @spec pending(String.t()) :: [map()]
  def pending(session_id), do: GenServer.call(Troupe.Registry.approvals(session_id), :pending)

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe approvals #{session_id}")

    {:ok,
     %__MODULE__{
       session_id: session_id,
       auto_approve: Keyword.get(opts, :auto_approve, false)
     }}
  end

  @impl GenServer
  def handle_call({:request, req}, from, state) do
    cond do
      state.auto_approve ->
        {:reply, :allow, state}

      MapSet.member?(state.session_allows, req.tool) ->
        {:reply, :allow, state}

      true ->
        {caller, _tag} = from
        monitor = Process.monitor(caller)

        pending = Map.put(state.pending, req.call_id, %{from: from, monitor: monitor, req: req})

        # Durable, not ephemeral: an approval outlives dormancy and may be answered
        # days later, so it has to be in the log rather than only on the wire.
        Log.append(state.session_id, req.agent_path, :approval_requested, describe(req))

        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_call({:auto_approve, value}, _from, state) do
    # Turning auto-approve on releases everyone already waiting: the user just said
    # yes to everything, and leaving them blocked would be a surprising deadlock.
    state = if value, do: release_all(state), else: state
    {:reply, :ok, %{state | auto_approve: value}}
  end

  def handle_call(:pending, _from, state) do
    {:reply, Enum.map(state.pending, fn {_id, entry} -> entry.req end), state}
  end

  @impl GenServer
  def handle_cast({:decide, call_id, decision, actor}, state) do
    case Map.pop(state.pending, call_id) do
      {nil, _} ->
        {:noreply, state}

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        answer = if decision == :deny, do: :deny, else: :allow
        GenServer.reply(entry.from, answer)

        allows =
          if decision == :allow_session,
            do: MapSet.put(state.session_allows, entry.req.tool),
            else: state.session_allows

        Log.append(
          state.session_id,
          entry.req.agent_path,
          :approval_decided,
          Map.put(describe(entry.req), "decision", Atom.to_string(decision)),
          actor
        )

        {:noreply, %{state | pending: pending, session_allows: allows}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    pending =
      state.pending
      |> Enum.reject(fn {_id, entry} -> entry.monitor == monitor end)
      |> Map.new()

    {:noreply, %{state | pending: pending}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The log is JSON, so the request crosses into it as plain data.
  defp describe(req) do
    %{
      "call_id" => req.call_id,
      "tool" => req.tool,
      "args" => req.args,
      "agent_path" => req.agent_path
    }
  end

  defp release_all(state) do
    Enum.each(state.pending, fn {_id, entry} ->
      Process.demonitor(entry.monitor, [:flush])
      GenServer.reply(entry.from, :allow)
    end)

    %{state | pending: %{}}
  end
end
