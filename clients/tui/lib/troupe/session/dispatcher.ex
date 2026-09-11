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
          diff_stat: String.t() | nil,
          cancelled: boolean()
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

  @doc """
  Cancels a branch and removes its window: stops the agent, discards the
  Troupe-managed worktree it was working in, and dismisses the window. A branch
  that is still running comes to rest first (the agent kills its tasks and
  children), and the window is removed when it does.
  """
  @spec cancel(String.t(), String.t()) :: :ok | {:error, String.t()}
  def cancel(sid, path),
    do: GenServer.call(Session.via(sid, :dispatcher), {:cancel, path}, 120_000)

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

  @doc "The session's config and workspace, as the Dispatcher currently holds them."
  @spec context(String.t()) :: {String.t(), Troupe.Config.t()}
  def context(sid), do: GenServer.call(Session.via(sid, :dispatcher), :context)

  @doc "Replaces the config used for branches dispatched from now on."
  @spec put_config(String.t(), Troupe.Config.t()) :: :ok
  def put_config(sid, config),
    do: GenServer.call(Session.via(sid, :dispatcher), {:put_config, config})

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

    send(self(), :maybe_refresh_memory)
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

  def handle_call(:context, _from, state), do: {:reply, {state.workspace, state.config}, state}

  def handle_call({:put_config, config}, _from, %__MODULE__{} = state),
    do: {:reply, :ok, %__MODULE__{state | config: config}}

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

  def handle_call(:finished?, _from, state) do
    windows = Map.values(state.ledger)
    {:reply, windows != [] and not Enum.any?(windows, &(&1.state in @active)), state}
  end

  def handle_call({:dismiss, path}, _from, state) do
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

  def handle_call({:cancel, path}, _from, state) do
    case Map.get(state.ledger, path) do
      nil ->
        {:reply, {:error, "no window #{path}"}, state}

      %{state: :dismissed} ->
        {:reply, {:error, "window #{path} was dismissed"}, state}

      %{state: s} when s in @active ->
        case Session.whereis(state.session_id, {:agent, path}) do
          # The agent stops itself, logs `cancelled` and comes to rest; the window
          # is removed then, when nothing is writing the worktree any more.
          pid when is_pid(pid) ->
            send(pid, :cancel)

          # An active window with no agent behind it (a Node that never came back)
          # has nobody to write those two events, so the Dispatcher writes them.
          nil ->
            Log.append(state.session_id, path, :cancelled, %{})

            Log.append(state.session_id, path, :branch_state, %{
              state: :done_unread,
              reason: :cancelled,
              summary: "Cancelled by user"
            })
        end

        {:reply, :ok, state}

      _resting ->
        {:reply, :ok, remove_window(state, path)}
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

    state = dismiss_when_internal(state, after_w)
    state = remove_when_cancelled(state, after_w)

    {:noreply, state}
  end

  def handle_info(:maybe_refresh_memory, state), do: {:noreply, maybe_refresh_memory(state)}

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

          with {:ok, prompt, branch_id, existing} <-
                 worktree_target(state, isolation, path, prompt) do
            spawn_window(state, name, path, n, %{
              isolation: isolation,
              prompt: prompt,
              branch_id: branch_id,
              existing: existing,
              source: source,
              budget: Map.get(opts, :budget, %{})
            })
          end
        end

      _ ->
        available =
          state.definitions |> Agents.primaries() |> Enum.map_join(", ", &("/" <> &1.name))

        {:error, "unknown command /#{name}; available: #{available}"}
    end
  end

  defp spawn_window(state, name, path, n, o) do
    window = %{
      agent_path: path,
      name: name,
      branch_id: o.branch_id,
      state: :running,
      isolation: o.isolation,
      prompt: o.prompt,
      reason: nil,
      summary: nil,
      message: nil,
      created_seq: 0,
      source: o.source,
      worktree: nil,
      diff_stat: nil,
      cancelled: false,
      budget: o.budget,
      existing_worktree: o.existing
    }

    event =
      Log.append(state.session_id, path, :branch_spawned, %{
        branch_id: o.branch_id,
        name: name,
        prompt: o.prompt,
        isolation: o.isolation,
        source: o.source,
        budget: o.budget,
        existing_worktree: o.existing
      })

    window = %{window | created_seq: event.seq}

    state = %{
      state
      | counters: Map.put(state.counters, name, n),
        ledger: Map.put(state.ledger, path, window)
    }

    {:ok, path, spawn_node(state, window, o.prompt)}
  end

  @worktree_name ~r{^[A-Za-z0-9][A-Za-z0-9._/-]*$}

  # Which worktree a `/worktree` command works in: `<name>: <prompt>` is a Troupe-managed
  # worktree of that name, created the first time and reused after (Decision 42);
  # `<existing> <prompt>` is a worktree the user checked out themselves (Decision 39);
  # anything else is all prompt and gets the automatic `<agent>-<n>` worktree.
  defp worktree_target(state, :worktree, default_id, prompt) do
    case named_worktree(prompt) do
      {:ok, wt_name, rest} ->
        named_target(state, wt_name, rest)

      {:error, msg} ->
        {:error, msg}

      :none ->
        {prompt, existing} = existing_worktree(state, prompt)
        {:ok, prompt, default_id, existing}
    end
  end

  defp worktree_target(_state, _isolation, default_id, prompt),
    do: {:ok, prompt, default_id, nil}

  defp named_target(state, wt_name, prompt) do
    in_use =
      state.ledger
      |> Map.values()
      |> Enum.find(&(&1.state in @active and &1.branch_id == wt_name))

    cond do
      not Regex.match?(@worktree_name, wt_name) or String.contains?(wt_name, "..") ->
        {:error, "#{wt_name} is not a usable worktree name"}

      in_use ->
        {:error, "worktree #{wt_name} is already in use by #{in_use.agent_path}"}

      true ->
        {:ok, prompt, wt_name, nil}
    end
  end

  # `<name>:` as the first word names a worktree; a bare colon or no prompt is a mistake.
  defp named_worktree(prompt) do
    case String.split(String.trim(prompt), ~r/\s+/, parts: 2) do
      [word, rest] ->
        if String.ends_with?(word, ":"),
          do: {:ok, String.trim_trailing(word, ":"), rest},
          else: :none

      [word] ->
        if String.ends_with?(word, ":"),
          do: {:error, "give a prompt after the worktree name: /worktree #{word} <prompt>"},
          else: :none

      _ ->
        :none
    end
  end

  # `/worktree <existing-worktree> <prompt>` runs in a worktree the user already checked out.
  defp existing_worktree(state, prompt) do
    case String.split(String.trim(prompt), ~r/\s+/, parts: 2) do
      [name, rest] ->
        case Worktree.find(state.workspace, name) do
          nil -> {prompt, nil}
          wt -> {rest, %{path: wt.path, git_branch: wt.branch}}
        end

      _ ->
        {prompt, nil}
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
      source: window.source,
      existing_worktree: Map.get(window, :existing_worktree)
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
      nil ->
        {:error, "no window #{path}"}

      %{isolation: :shared} ->
        {:error, "#{path} is not a worktree branch"}

      %{worktree: %{managed: false, path: wt}} ->
        {:error, "#{path} worked in your own worktree #{wt}; review and commit there yourself"}

      %{state: s} when s not in @resting ->
        {:error, "#{path} is still #{s}"}

      window ->
        {:ok, window}
    end
  end

  ## Project brief

  # The librarian is dispatched at most once per session: `counters` is folded
  # from `branch_spawned`, so the guard survives a Dispatcher restart and resume.
  defp maybe_refresh_memory(%__MODULE__{} = state) do
    memory = Map.get(state.config || %{}, :memory) || %{}

    with true <- Map.get(memory, :auto_refresh, true),
         true <- Map.has_key?(state.definitions, "librarian"),
         nil <- Map.get(state.counters, "librarian"),
         status when status in [:absent, :stale] <- Session.Memory.status(state.session_id) do
      refresh(state, status)
    else
      _not_now -> state
    end
  end

  defp refresh(state, status) do
    prompt =
      case status do
        :absent -> "Write the project brief for this repository."
        :stale -> "The project brief is out of date. Revise it against the repository as it is now."
      end

    case dispatch(state, "librarian", prompt, :memory) do
      {:ok, _path, state} ->
        state

      {:error, msg} ->
        Logger.debug("memory: skipping brief refresh: #{msg}")
        state
    end
  end

  # A window the harness raised for itself reports to nobody, so it clears itself
  # away rather than sitting unread in the strip.
  defp dismiss_when_internal(state, %{source: :memory, state: s, agent_path: path})
       when s in @resting do
    Log.append(state.session_id, path, :window_dismissed, %{})
    state
  end

  defp dismiss_when_internal(state, _window), do: state

  # `/cancel` removes the window it stops. A branch that was still running is
  # removed once it comes to rest, so nothing is writing the worktree that is
  # about to be discarded.
  defp remove_when_cancelled(state, %{cancelled: true, state: s, agent_path: path})
       when s in @resting,
       do: remove_window(state, path)

  defp remove_when_cancelled(state, _window), do: state

  # Stops the branch's Node, discards the worktree Troupe made for it, and
  # dismisses the window. A worktree the user checked out themselves is theirs
  # (Decision 39) and is left alone, as is one already merged or discarded.
  defp remove_window(state, path) do
    window = Map.get(state.ledger, path)
    state = stop_node(state, path)

    state =
      if unresolved_worktree?(window) do
        _ = Worktree.discard(state.workspace, window.branch_id)
        Log.append(state.session_id, path, :worktree_discarded, %{})
        update_window(state, path, &%{&1 | worktree: Map.put(&1.worktree, :discarded, true)})
      else
        state
      end

    Log.append(state.session_id, path, :window_dismissed, %{})
    # The events above fold back through `handle_info` and apply exactly this, but
    # not before the next event arrives: applying it here keeps the window from
    # being removed a second time on the way.
    update_window(state, path, &%{&1 | state: :dismissed})
  end

  ## Close

  # `reason` (set on done) and `message` (set on failure) both survive a later
  # dismissal, so the counts stay right after windows are dismissed.
  defp report(%__MODULE__{} = state) do
    windows = Map.values(state.ledger)

    report = %{
      session_id: state.session_id,
      branches: length(windows),
      done: Enum.count(windows, &(&1.reason != nil or &1.state == :done_unread)),
      failed: Enum.count(windows, &(&1.message != nil or &1.state == :failed_unread)),
      active: paths(windows, &(&1.state in @active)),
      worktrees: paths(windows, &unresolved_worktree?/1),
      text: ""
    }

    %{report | text: report_text(report)}
  end

  defp paths(windows, pred) do
    windows |> Enum.filter(pred) |> Enum.map(& &1.agent_path) |> Enum.sort()
  end

  # A worktree the user checked out themselves is theirs to resolve (Decision 39):
  # Troupe never commits there and refuses `/merge`, so it cannot block a close.
  defp unresolved_worktree?(%{worktree: %{managed: true, merged: false, discarded: false}}),
    do: true

  defp unresolved_worktree?(_window), do: false

  defp blockers(_report, true), do: []

  defp blockers(%{} = report, false) do
    [
      if(report.active != [],
        do: "#{length(report.active)} branch(es) still active: #{Enum.join(report.active, ", ")}"
      ),
      if(report.worktrees != [],
        do:
          "#{length(report.worktrees)} worktree(s) neither merged nor discarded: " <>
            Enum.join(report.worktrees, ", ")
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp report_text(%{branches: 0}), do: "no branches ran"

  defp report_text(%{} = r) do
    extra =
      [
        if(r.active != [], do: "#{length(r.active)} active"),
        if(r.worktrees != [], do: "#{length(r.worktrees)} worktree(s) unresolved")
      ]
      |> Enum.reject(&is_nil/1)

    base = "#{r.branches} branch(es): #{r.done} done, #{r.failed} failed"
    Enum.join([base | extra], ", ")
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
      cancelled: false,
      budget: Map.get(d, :budget) || %{},
      existing_worktree: Map.get(d, :existing_worktree)
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

  defp fold(state, %{type: :cancelled, agent_path: path}) do
    update_window(state, root(path), fn w -> %{w | cancelled: true} end)
  end

  defp fold(state, %{type: :window_dismissed, agent_path: path}) do
    update_window(state, path, fn w -> %{w | state: :dismissed} end)
  end

  defp fold(state, %{type: :worktree_created, agent_path: path, data: d}) do
    update_window(state, root(path), fn w ->
      %{
        w
        | worktree: %{
            path: d.path,
            git_branch: d.git_branch,
            merged: false,
            discarded: false,
            managed: Map.get(d, :managed, true)
          }
      }
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
