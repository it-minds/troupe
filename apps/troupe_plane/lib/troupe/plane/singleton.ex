defmodule Troupe.Plane.Singleton do
  @moduledoc """
  One process of a kind across the whole cluster, started wherever it is first needed.

  Two things in the plane must not be decided in two places at once: how many sessions
  fit on a profile's pods, and how much of a team's budget is left. Both are answered by
  reading, deciding, and writing — and two replicas doing that concurrently is exactly
  how you overbook.

  The usual answers are a lock or a transaction with the right isolation level. This is
  neither: the decision is made by *one process*, registered with `:global`, so the
  question is serialised by a mailbox rather than by contention. Callers on other
  replicas reach it by name.

  When the node holding one dies, `:global` forgets the name and the next caller starts
  it again on a survivor — where it reloads its state from PostgreSQL, because a
  decision that lived only in a process would be lost with it.
  """

  use DynamicSupervisor

  require Logger

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  The process for this key, starting it if nobody has.

  A race between two replicas is the ordinary case rather than an error: both try, one
  wins the `:global` name, and the loser is handed the winner.
  """
  @spec whereis(module(), term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def whereis(module, key, opts \\ []) do
    case :global.whereis_name({module, key}) do
      :undefined -> start(module, key, opts)
      pid -> {:ok, pid}
    end
  end

  defp start(module, key, opts) do
    spec = {module, Keyword.merge(opts, key: key, name: {:global, {module, key}})}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid}

      # Somebody else got there first, here or on another replica.
      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error("troupe plane: could not start #{inspect(module)} for #{inspect(key)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Call the singleton for a key, starting it if necessary.

  Retries once on `:noproc`, because the process can go away between being found and
  being called — a replica dying mid-call is the case this exists to survive, so
  failing it would be perverse.
  """
  @spec call(module(), term(), term(), timeout(), keyword()) :: term()
  def call(module, key, message, timeout \\ 15_000, opts \\ []) do
    with {:ok, pid} <- whereis(module, key, opts) do
      try do
        GenServer.call(pid, message, timeout)
      catch
        :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
          {:ok, pid} = whereis(module, key, opts)
          GenServer.call(pid, message, timeout)
      end
    end
  end

  @doc "Every singleton running on this node, for diagnostics."
  @spec local() :: [pid()]
  def local do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} -> if is_pid(pid), do: [pid], else: [] end)
  end
end
