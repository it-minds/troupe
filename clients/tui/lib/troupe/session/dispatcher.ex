defmodule Troupe.Session.Dispatcher do
  @moduledoc """
  Command parser and window ledger. Holds no conversation, calls no model,
  has no budget. Its state is a fold over the session log.
  """

  use GenServer
  require Logger

  alias Troupe.Agent.{Budget, Spec}
  alias Troupe.{Agents, Events, Telemetry}
  alias Troupe.Agents.Definition
  alias Troupe.Session
  alias Troupe.Session.{Branches, Log, Worktree}

  @resting [:done_unread, :failed_unread]
  @active [:running, :needs_input]

  defstruct [
    :session_id,
    :workspace,
    :config,
    :definitions,
    :provider,
    ledger: %{},
    counters: %{},
    monitors: %{}
  ]

  @type window :: %{
          agent_path: String.t(),
          name: String.t(),
          branch_id: String.t(),
          state: :running | :needs_input | :done_unread | :failed_unread | :dismissed,
          isolation: :shared | :worktree,
          prompt: String.t(),
          reason: atom() | nil,
          summary: String.t() | nil,
          message: String.t() | nil,
          created_seq: non_neg_integer(),
          source: atom(),
          worktree: map() | nil,
          diff_stat: String.t() | nil
        }

  @type report :: %{
          session_id: String.t(),
          branches: non_neg_integer(),
          done: non_neg_integer(),
          failed: non_neg_integer(),
          active: [String.t()],
          worktrees: [String.t()],
          text: String.t()
        }

  ## API

  def start_link(%{session_id: sid} = opts) do
    GenServer.start_link(__MODULE__, opts, name: Session.via(sid, :dispatcher))
  end

  @spec command(String.t(), String.t(), String.t() | map(), atom()) ::
          {:ok, String.t()} | {:error, String.t()}
  def command(sid, name, args, source),
    do: GenServer.call(Session.via(sid, :dispatcher), {:command, name, args, source}, 30_000)

  @spec command_async(String.t(), String.t(), String.t() | map(), atom()) :: :ok
  def command_async(sid, name, args, source),
    do: GenServer.cast(Session.via(sid, :dispatcher), {:command, name, args, source})

  @spec windows(String.t()) :: [window()]
  def windows(sid), do: GenServer.call(Session.via(sid, :dispatcher), :windows)

  @spec dismiss(String.t(), String.t()) :: :ok | {:error, String.t()}
  def dismiss(sid, path), do: GenServer.call(Session.via(sid, :dispatcher), {:dismiss, path})

  @spec continue(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def continue(sid, path, text),
    do: GenServer.call(Session.via(sid, :dispatcher), {:continue, path, text}, 30_000)

  @spec merge(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def merge(sid, path), do: GenServer.call(Session.via(sid, :dispatcher), {:merge, path}, 120_000)

  @spec discard(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def discard(sid, path),
    do: GenServer.call(Session.via(sid, :dispatcher), {:discard, path}, 120_000)

  @spec switch_profile(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def switch_profile(sid, path, name),
    do: GenServer.call(Session.via(sid, :dispatcher), {:switch_profile, path, name})

  @spec commands(String.t()) :: [String.t()]
  def commands(sid), do: GenServer.call(Session.via(sid, :dispatcher), :commands)

  @doc """
  Ends the session: refuses while branches are active or worktrees unresolved
  (unless `force?`), then writes `session_closed` and stamps `meta.json`.
  Returns a report of what the session did.
  """
  @spec close(String.t(), boolean()) :: {:ok, report()} | {:error, String.t()}
  def close(sid, force? \\ false),
    do: GenServer.call(Session.via(sid, :dispatcher), {:close, force?}, 30_000)

  @doc "`true` when the session has at least one branch and none is active."
  @spec finished?(String.t()) :: boolean()
  def finished?(sid), do: GenServer.call(Session.via(sid, :dispatcher), :finished?)

  ## Server

  @impl true
  def init(%{session_id: sid} = opts) do
    Events.subscribe(sid)

    state = %__MODULE__{
      session_id: sid,
      workspace: opts.workspace,
      config: opts.config,
      definitions: opts.definitions,
      provider: opts.provider
    }

    events = Log.all(sid)
    state = Enum.reduce(events, state, &fold(&2, &1))

    if events == [] do
      Log.append(sid, "session", :session_started, %{workspace: opts.workspace, session_id: sid})
    end

    {:ok, reconcile(state)}
  end

  @impl true
  def handle_call({:command, name, args, source}, _from, state) do
    case dispatch(state, name, args, source) do
      {:ok, path, state} -> {:reply, {:ok, path}, state}
      {:error, msg} -> {:reply, {:error, msg}, state}
    end
  end

  def handle_call(:windows, _from, state) do
    {:reply, state.ledger |> Map.values() |> Enum.sort_by(& &1.created_seq), state}
  end

  def handle_call(:commands, _from, state) do
    {:reply, state.definitions |> Agents.primaries() |> Enum.map(& &1.name), state}
  end

  def handle_call({:close, force?}, _from, state) do
    report = report(state)

    case blockers(report, force?) do
      [] ->
        Log.append(state.session_id, "session", :session_closed, %{
          branches: report.branches,
          done: report.done,
          failed: report.failed,
          forced: force? and (report.active != [] or report.worktrees != [])
        })

        :ok = Log.mark_closed(state.session_id)
        {:reply, {:ok, report}, state}

      blockers ->
        {:reply, {:error, Enum.join(blockers, "; ") <> "; use force to close anyway"}, state}
    end
  end


    case Map.get(state.ledger, path) do
      %{state: s} when s in @resting ->
        Log.append(state.session_id, path, :window_dismissed, %{})
        {:reply, :ok, state}

      %{state: s} ->
        {:reply,
         {:error, "window #{path} is #{s}; only finished or failed windows can be dismissed"},
         state}

      nil ->
        {:reply, {:error, "no window #{path}"}, state}
    end
  end

  def handle_call({:continue, path, text}, _from, state) do
    case Map.get(state.ledger, path) do
      nil ->
        {:reply, {:error, "no window #{path}"}, state}

      %{state: :dismissed} ->
        {:reply, {:error, "window #{path} was dismissed"}, state}

      window ->
        state =
          if Session.whereis(state.session_id, {:agent, path}),
            do: state,
            else: spawn_node(state, window, nil)

        case Session.whereis(state.session_id, {:agent, path}) do
          nil ->
            {:reply, {:error, "branch #{path} could not be started"}, state}

          pid ->
            send(pid, {:input, :user, text})
            {:reply, :ok, state}
        end
    end
  end

  def handle_call({:switch_profile, path, name}, _from, state) do
    case {Map.get(state.ledger, path), Map.get(state.definitions, name)} do
      {nil, _} ->
        {:reply, {:error, "no window #{path}"}, state}

      {_, %Definition{mode: :primary}} ->
        case Session.whereis(state.session_id, {:agent, path}) do
          nil -> Log.append(state.session_id, path, :profile_switched, %{name: name})
          pid -> send(pid, {:switch_profile, name})
        end

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, "unknown profile #{name}"}, state}
    end
  end

  def handle_call({:merge, path}, _from, state) do
    case worktree_window(state, path) do
      {:ok, window} ->
        result = Worktree.merge(state.workspace, window.branch_id)

        {output, conflicts} =
          case result do
            {:ok, out} -> {out, false}
            {:error, out} -> {out, true}
          end

        Log.append(state.session_id, path, :worktree_merged, %{output: output, conflicts: conflicts})

        {:reply, result, state}

      {:error, msg} ->
        {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:discard, path}, _from, state) do
    case worktree_window(state, path) do
      {:ok, window} ->
        result = Worktree.discard(state.workspace, window.branch_id)
        Log.append(state.session_id, path, :worktree_discarded, %{})
        {:reply, result, state}

      {:error, msg} ->
        {:reply, {:error, msg}, state}
    end
  end

  @impl true
  def handle_cast({:command, name, args, source}, state) do
    case dispatch(state, name, args, source) do
      {:ok, _path, state} ->
        {:noreply, state}

      {:error, msg} ->
        Events.notify(state.session_id, "dispatcher", :notice, %{text: "command rejected: #{msg}"})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:troupe_event, %{transient?: true}}, state), do: {:noreply, state}

  def handle_info({:troupe_event, event}, state) do
    before = Map.get(state.ledger, root(event.agent_path))
    state = fold(state, event)
    after_w = Map.get(state.ledger, root(event.agent_path))

    if before && after_w && before.state != after_w.state do
      Telemetry.transition(:window, %{
        session_id: state.session_id,
        agent_path: after_w.agent_path,
        from: before.state,
        to: after_w.state
      })
    end

    # Release the Node of a finished branch, unless the branch was continued in the meantime
    # (a newer branch_state is already in the log and this event is stale).
    state =
      if after_w && after_w.state in @resting && event.type == :branch_state &&
           latest_branch_state_seq(state.session_id, after_w.agent_path) == event.seq do
        stop_node(state, after_w.agent_path)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {path, monitors} ->
        state = %{state | monitors: monitors}

        case Map.get(state.ledger, path) do
          %{state: s} when s in @active ->
            Log.append(state.session_id, path, :branch_failed, %{message: inspect(reason)})
            {:noreply, state}

          _ ->
            {:noreply, state}
        end
    end
  end

  def handle_info(msg, state) do
    Logger.warning("dispatcher dropped unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Dispatch

  defp dispatch(state, name, args, source) do
    {prompt, opts} = normalize_args(args)
    active = state.ledger |> Map.values() |> Enum.count(&(&1.state in @active))

    case Map.get(state.definitions, name) do
      %Definition{mode: :primary} = def ->
        if active >= state.config.max_branches do
          {:error,
           "max_branches (#{state.config.max_branches}) reached; wait for a branch to finish or cancel one"}
        else
          n = Map.get(state.counters, name, 0) + 1
          path = "#{name}-#{n}"
          isolation = Map.get(opts, :isolation) || def.isolation

          window = %{
            agent_path: path,
            name: name,
            branch_id: path,
            state: :running,
            isolation: isolation,
            prompt: prompt,
            reason: nil,
            summary: nil,
            message: nil,
            created_seq: 0,
            source: source,
            worktree: nil,
            diff_stat: nil,
            budget: Map.get(opts, :budget, %{})
          }

          event =
            Log.append(state.session_id, path, :branch_spawned, %{
              branch_id: path,
              name: name,
              prompt: prompt,
              isolation: isolation,
              source: source,
              budget: Map.get(opts, :budget, %{})
            })

          window = %{window | created_seq: event.seq}

          state = %{
            state
            | counters: Map.put(state.counters, name, n),
              ledger: Map.put(state.ledger, path, window)
          }

          {:ok, path, spawn_node(state, window, prompt)}
        end

      _ ->
        available =
          state.definitions |> Agents.primaries() |> Enum.map_join(", ", &("/" <> &1.name))

        {:error, "unknown command /#{name}; available: #{available}"}
    end
  end

  defp normalize_args(args) when is_binary(args), do: {args, %{}}
  defp normalize_args(%{} = args), do: {Map.get(args, :prompt, ""), Map.drop(args, [:prompt])}
  defp normalize_args(_), do: {"", %{}}

  defp spawn_node(state, window, initial_input) do
    def = Map.fetch!(state.definitions, window.name)

    spec = %Spec{
      session_id: state.session_id,
      agent_path: window.agent_path,
      branch_id: window.branch_id,
      definition_name: window.name,
      definitions: state.definitions,
      config: state.config,
      provider: state.provider,
      workspace: state.workspace,
      isolation: window.isolation,
      depth: 0,
      parent: nil,
      initial_input: initial_input,
      budget: Budget.from_definition(def, Map.get(window, :budget) || %{}),
      source: window.source
    }

    case Branches.start_branch(state.session_id, spec) do
      {:ok, pid} ->
        monitor(state, pid, window.agent_path)

      {:error, {:already_started, pid}} ->
        monitor(state, pid, window.agent_path)

      {:error, reason} ->
        Log.append(state.session_id, window.agent_path, :branch_failed, %{message: inspect(reason)})
        state
    end
  end

  defp monitor(state, pid, path) do
    if Enum.any?(state.monitors, fn {_ref, p} -> p == path end) do
      state
    else
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, ref, path)}
    end
  end

  defp stop_node(state, path) do
    case Session.whereis(state.session_id, {:node, path}) do
      nil ->
        state

      pid ->
        {refs, monitors} = Enum.split_with(state.monitors, fn {_ref, p} -> p == path end)
        for {ref, _} <- refs, do: Process.demonitor(ref, [:flush])
        Branches.stop_branch(state.session_id, path)
        _ = pid
        %{state | monitors: Map.new(monitors)}
    end
  end

  defp latest_branch_state_seq(sid, path) do
    sid
    |> Log.events(path)
    |> Enum.filter(&(&1.type == :branch_state))
    |> List.last()
    |> case do
      nil -> nil
      e -> e.seq
    end
  end

  defp worktree_window(state, path) do
    case Map.get(state.ledger, path) do
      nil -> {:error, "no window #{path}"}
      %{isolation: :shared} -> {:error, "#{path} is not a worktree branch"}
      %{state: s} when s not in @resting -> {:error, "#{path} is still #{s}"}
      window -> {:ok, window}
    end
  end

  ## Fold

  defp root(path), do: path |> String.split("/") |> hd()

  defp fold(state, %{type: :branch_spawned, agent_path: path, seq: seq, data: d}) do
    window = %{
      agent_path: path,
      name: d.name,
      branch_id: d.branch_id,
      state: :running,
      isolation: d.isolation,
      prompt: d.prompt,
      reason: nil,
      summary: nil,
      message: nil,
      created_seq: seq,
      source: d.source,
      worktree: nil,
      diff_stat: nil,
      budget: Map.get(d, :budget) || %{}
    }

    n = path |> String.split("-") |> List.last() |> String.to_integer()
    counters = Map.update(state.counters, d.name, n, &max(&1, n))
    %{state | counters: counters, ledger: Map.put_new(state.ledger, path, window)}
  end

  defp fold(state, %{type: :branch_state, agent_path: path, data: %{state: s} = d}) do
    root_path = root(path)
    nested? = root_path != path

    update_window(state, root_path, fn w ->
      cond do
        w.state == :dismissed -> w
        nested? and s == :done_unread -> w
        s == :done_unread -> %{w | state: s, reason: d[:reason], summary: d[:summary]}
        true -> %{w | state: s}
      end
    end)
  end

  defp fold(state, %{type: :branch_failed, agent_path: path, data: d}) do
    update_window(state, root(path), fn w -> %{w | state: :failed_unread, message: d[:message]} end)
  end

  defp fold(state, %{type: :window_dismissed, agent_path: path}) do
    update_window(state, path, fn w -> %{w | state: :dismissed} end)
  end

  defp fold(state, %{type: :worktree_created, agent_path: path, data: d}) do
    update_window(state, root(path), fn w ->
      %{w | worktree: %{path: d.path, git_branch: d.git_branch, merged: false, discarded: false}}
    end)
  end

  defp fold(state, %{type: :worktree_merged, agent_path: path, data: d}) do
    update_window(state, path, fn w ->
      %{w | worktree: w.worktree && Map.put(w.worktree, :merged, not d.conflicts)}
    end)
  end

  defp fold(state, %{type: :worktree_discarded, agent_path: path}) do
    update_window(state, path, fn w ->
      %{w | worktree: w.worktree && Map.put(w.worktree, :discarded, true)}
    end)
  end

  defp fold(state, %{type: :finished, agent_path: path, data: d}) do
    if root(path) == path,
      do: update_window(state, path, fn w -> %{w | diff_stat: d[:diff_stat]} end),
      else: state
  end

  defp fold(state, _event), do: state

  defp update_window(state, path, fun) do
    case Map.get(state.ledger, path) do
      nil -> state
      w -> %{state | ledger: Map.put(state.ledger, path, fun.(w))}
    end
  end

  ## Reconcile after (re)start

  defp reconcile(state) do
    Enum.reduce(Map.values(state.ledger), state, fn window, acc ->
      live = Session.whereis(acc.session_id, {:node, window.agent_path})

      cond do
        window.state in @active and live == nil -> spawn_node(acc, window, nil)
        window.state in @active -> monitor(acc, live, window.agent_path)
        live != nil -> stop_node(acc, window.agent_path)
        true -> acc
      end
    end)
  end
end
