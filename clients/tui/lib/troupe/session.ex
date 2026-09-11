defmodule Troupe.Session do
  @moduledoc """
  One session: a `rest_for_one` supervisor. `Session.Branches` starts before
  `Session.Dispatcher` on purpose (see ARCHITECTURE.md §1).
  """

  use Supervisor

  alias Troupe.Session.{Approvals, Branches, Dispatcher, Locks, Log, Watcher}

  @type opts :: %{
          session_id: String.t(),
          workspace: String.t(),
          config: Troupe.Config.t(),
          definitions: Troupe.Agents.snapshot(),
          provider: {module(), term()},
          resume?: boolean()
        }

  def start_link(%{session_id: sid} = opts) do
    Supervisor.start_link(__MODULE__, opts, name: via(sid, :session))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts.session_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    children = [
      {Log, opts},
      {Approvals, opts},
      {Locks, opts},
      {Branches, opts},
      {Dispatcher, opts},
      {Watcher, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 10)
  end

  @doc "Registry via-tuple for a session actor."
  @spec via(String.t(), term()) :: {:via, Registry, {Troupe.Registry, {String.t(), term()}}}
  def via(session_id, key), do: {:via, Registry, {Troupe.Registry, {session_id, key}}}

  @spec whereis(String.t(), term()) :: pid() | nil
  def whereis(session_id, key) do
    case Registry.lookup(Troupe.Registry, {session_id, key}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
