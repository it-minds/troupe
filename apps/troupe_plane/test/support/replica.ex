defmodule Troupe.Plane.Replica do
  @moduledoc """
  A second plane replica, as a real OTP node.

  A test that faked the second replica would not exercise `:global` at all, and
  `:global` is the whole mechanism by which two replicas agree there is one placement
  actor per profile. So this starts a real node with `:peer`, gives it the same database
  configuration, and starts the whole application on it — the *application*, not the
  pieces, because a supervisor started through `:erpc` is linked to the call's own
  process and dies with it, and what these tests need is a replica that keeps running.

  Extracted from `Troupe.Plane.ClusterTest` so the worker's failover test can have one
  too: a worker reconnecting to a surviving replica is a property neither app can test
  alone.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.Repo

  @doc """
  Start a replica, or say why not.

  `:env` is merged over this node's `:troupe_plane` configuration, which is how a caller
  gives the replica its own control port — two listeners in one test cannot share one.
  """
  @spec start(keyword()) :: {:ok, pid(), node()} | {:error, term()}
  def start(opts \\ []) do
    with :ok <- ensure_epmd(),
         {:ok, _pid} <- ensure_distributed(),
         {:ok, peer, node} <- start_peer() do
      :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
      :ok = :erpc.call(node, Application, :put_all_env, [[troupe_plane: env(opts)]])
      {:ok, _started} = :erpc.call(node, Application, :ensure_all_started, [:troupe_plane], 30_000)

      {:ok, peer, node}
    end
  end

  defp start_peer do
    :peer.start_link(%{
      name: :"troupe_plane_peer_#{System.unique_integer([:positive])}",
      host: ~c"127.0.0.1",
      longnames: true,
      args: [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())]
    })
  end

  # A peer node starts with no application environment of its own. It needs the same
  # database configuration this node has, because a second replica is a second
  # connection pool against one database, not a second database.
  defp env(opts) do
    :troupe_plane
    |> Application.get_all_env()
    |> Keyword.put(:autostart, true)
    |> Keyword.update(Repo, [pool_size: 5], fn repo_config ->
      repo_config |> Keyword.put(:pool_size, 5) |> Keyword.delete(:pool)
    end)
    |> Keyword.merge(Keyword.get(opts, :env, []))
  end

  @doc """
  Stop a replica, tolerating one that has already gone.

  The peer is linked to the process that started it, which ExUnit takes down before
  running `on_exit`, so by then it is usually already gone. Stopping it anyway is the
  belt to that braces, and its absence is not a failure.
  """
  @spec stop(pid()) :: :ok
  def stop(peer) do
    :peer.stop(peer)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Kill a replica the way a node failure kills one: no shutdown, no goodbye.

  `:peer.stop/1` is an orderly stop, which is the *other* case — a pod being drained
  rather than a pod being lost. What a failover test needs is the abrupt one.
  """
  @spec kill(pid(), node()) :: :ok
  def kill(peer, node) do
    :erpc.cast(node, :erlang, :halt, [1])
    stop(peer)
    :ok
  end

  @doc "Let the peer share this node's database, which a sandbox otherwise prevents."
  @spec share_database() :: :ok
  def share_database do
    Sandbox.mode(Repo, :auto)
    :ok
  end

  @doc "Put the sandbox back, for the tests that come after."
  @spec unshare_database() :: :ok
  def unshare_database do
    Sandbox.mode(Repo, :manual)
    :ok
  end

  # Erlang distribution needs EPMD, and a machine that has never run a distributed node
  # has none. Starting it is a one-liner; skipping the only test of the mechanism
  # because of it would not be.
  defp ensure_epmd do
    case System.cmd("epmd", ["-daemon"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:epmd, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:epmd, error}}
  end

  defp ensure_distributed do
    case :net_kernel.start([:"troupe_plane_test@127.0.0.1", :longnames]) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end
end
