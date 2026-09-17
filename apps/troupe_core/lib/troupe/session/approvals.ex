defmodule Troupe.Session.Approvals do
  @moduledoc """
  The permission gate for `ask` tools.

  A tool task calls `request/2` and blocks there — the *call* blocks, never the
  agent, which is free to collect other tool results meanwhile. The UI answers with
  `decide/3`. A denial comes back as a readable tool result rather than a crash, so
  the model can pick another approach.

  Callers are monitored: a tool task killed by a cancel or an agent crash is dropped
  from the pending set instead of leaving a reply nobody will ever read.

  Several clients may be watching one session, so two people can answer the same
  prompt a second apart. **First response wins**, and the second gets an
  `approval_resolved` event naming who got there first — silence would leave them
  believing they decided it.

  A session may also run with nobody to ask. `mode: :deny` is for that: every request
  is answered no on the spot, and both the request and the decision still go to the
  log, with the system as the actor, so a person reading the transcript afterwards
  sees what the agent wanted and that it was refused for want of anyone to say yes.
  The default, `:wait`, is what a session with people attached has always done.
  """

  use GenServer

  alias Troupe.Session.Log

  @enforce_keys [:session_id]
  defstruct [
    :session_id,
    mode: :wait,
    auto_approve: false,
    # A platform switch: with it on, a session may not grant itself a standing
    # permission. Every call goes back to the rule the definition carries, which is the
    # platform's, which is the point.
    managed_rules_only: false,
    pending: %{},
    resolved: %{},
    # Decisions read back from the log at start-up. A session that went dormant with an
    # approval answered but its tool not yet finished comes back, re-dispatches the call,
    # and must not ask the same person the same question again.
    decided: %{},
    session_allows: MapSet.new()
  ]

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
  is the tool's own, enforced by the agent killing the task. `{:deny, :unattended}` is
  the answer of a session running in `:deny` mode, told apart from a person's no so
  the model hears why.
  """
  @spec request(String.t(), map()) :: :allow | :deny | {:deny, :unattended}
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

    state = %__MODULE__{
      session_id: session_id,
      mode: Keyword.get(opts, :mode, :wait),
      auto_approve: Keyword.get(opts, :auto_approve, false),
      managed_rules_only: Keyword.get(opts, :managed_rules_only, false)
    }

    # Approvals are durable events precisely so they survive dormancy, and a gate that
    # forgot them on the way back would be the half of that promise nobody kept.
    {:ok, replay(state)}
  end

  defp replay(state) do
    state.session_id
    |> Log.replay()
    |> Enum.reduce(state, &fold/2)
  rescue
    # A session with no log yet — the very first start — has nothing to replay.
    _exception -> state
  catch
    :exit, _reason -> state
  end

  defp fold(%{type: "approval_decided", data: data} = event, state) do
    decision = data["decision"]

    state = %{
      state
      | decided: Map.put(state.decided, data["call_id"], answer_for(decision)),
        resolved:
          Map.put(state.resolved, data["call_id"], %{
            agent_path: event.agent || data["agent_path"],
            by: describe_actor(event.actor)
          })
    }

    if decision == "allow_session" do
      %{state | session_allows: MapSet.put(state.session_allows, data["tool"])}
    else
      state
    end
  end

  defp fold(_event, state), do: state

  defp answer_for("deny"), do: :deny
  defp answer_for(_decision), do: :allow

  defp managed(:allow_session), do: :allow
  defp managed(decision), do: decision

  @impl GenServer
  def handle_call({:request, req}, from, state) do
    cond do
      state.auto_approve ->
        {:reply, :allow, state}

      MapSet.member?(state.session_allows, req.tool) ->
        {:reply, :allow, state}

      # Already answered, and the tool is only asking again because the session came back
      # and re-dispatched it. Asking a second time would be a question the person has
      # already answered.
      Map.has_key?(state.decided, req.call_id) ->
        {:reply, Map.fetch!(state.decided, req.call_id), state}

      # Nobody to ask. Both events are written all the same — the request so the
      # transcript shows what the agent wanted, the decision so a later activation
      # finds the call answered rather than pending — and the actor is the system,
      # because no person made this choice.
      state.mode == :deny ->
        Log.append(state.session_id, req.agent_path, :approval_requested, describe(req))

        Log.append(
          state.session_id,
          req.agent_path,
          :approval_decided,
          Map.put(describe(req), "decision", "deny")
        )

        resolved = Map.put(state.resolved, req.call_id, resolved_by(req, nil))
        decided = Map.put(state.decided, req.call_id, :deny)
        {:reply, {:deny, :unattended}, %{state | resolved: resolved, decided: decided}}

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
        {:noreply, already_resolved(state, call_id)}

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        answer = if decision == :deny, do: :deny, else: :allow
        GenServer.reply(entry.from, answer)

        # `allow_session` becomes a plain `allow` where the platform holds the rules: the
        # call in front of the person is answered, and nothing standing is created. The
        # *decision that was made* still goes in the log as `allow`, because an event
        # saying `allow_session` beside a session that allows nothing would be a log that
        # disagreed with itself.
        decision = if state.managed_rules_only, do: managed(decision), else: decision

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

        resolved = Map.put(state.resolved, call_id, resolved_by(entry.req, actor))
        decided = Map.put(state.decided, call_id, answer)

        {:noreply,
         %{state | pending: pending, resolved: resolved, decided: decided, session_allows: allows}}
    end
  end

  # A second answer to a decided prompt is not an error — two people watching one
  # session is the normal case — so it is reported as an event and changes nothing.
  defp already_resolved(state, call_id) do
    case Map.fetch(state.resolved, call_id) do
      {:ok, %{agent_path: agent_path, by: by}} ->
        Log.append(state.session_id, agent_path, :approval_resolved, %{
          "call_id" => call_id,
          "resolved_by" => by
        })

        state

      :error ->
        state
    end
  end

  defp resolved_by(req, actor) do
    %{agent_path: req.agent_path, by: describe_actor(actor)}
  end

  defp describe_actor(nil), do: "system"
  defp describe_actor(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp describe_actor(%{subject: subject}) when is_binary(subject), do: subject
  defp describe_actor(_actor), do: "system"

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
