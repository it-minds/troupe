defmodule Troupe.RemoteHelpers do
  @moduledoc """
  Starting a `FakeRemote`, logging in to it, and attaching — the three steps
  every remote test begins with.

  The device flow is approved up front and the poll's sleep is replaced, so a
  login costs no wall-clock time; everything else is the real client path.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Troupe.Client
  alias Troupe.FakeRemote
  alias Troupe.Remote.Tokens

  @doc "Starts a FakeRemote for this test and forgets every credential afterwards."
  @spec start_remote!(keyword()) :: {pid(), String.t()}
  def start_remote!(opts \\ []) do
    {:ok, remote} = FakeRemote.start_link(opts)
    url = FakeRemote.url(remote)

    # Connections and journals outlive a test unless they are told not to: the
    # next test reuses the same session ids against a different port, and an
    # attachment left behind would quietly point at yesterday's server.
    on_exit(fn ->
      detach_all()
      _ = Tokens.logout(:all)
      if Process.alive?(remote), do: GenServer.stop(remote, :normal)
    end)

    {remote, url}
  end

  @doc "Runs the device flow against a FakeRemote, as `troupe login` does."
  @spec login!(pid(), String.t()) :: [String.t()]
  def login!(remote, url) do
    :ok = FakeRemote.approve_device(remote)
    me = self()

    code =
      Troupe.CLI.Remote.login(url,
        sleep: fn _ms -> :ok end,
        say: fn line -> send(me, {:said, line}) end
      )

    assert code == 0, "login failed"
    said()
  end

  @doc "Stops every remote connection and journal this VM holds."
  @spec detach_all() :: :ok
  def detach_all do
    for supervisor <- [Troupe.Remote.Sessions, Troupe.Remote.Connections],
        {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(supervisor, pid)
    end

    :ok
  end

  @doc "Everything `login/2` (or another command) printed, in order."
  @spec said() :: [String.t()]
  def said(acc \\ []) do
    receive do
      {:said, line} -> said([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "Logs in and connects the plane, returning the origin."
  @spec connect!(pid(), String.t()) :: Client.origin()
  def connect!(remote, url) do
    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    origin
  end

  @doc "Opens a session in read mode and waits until its worker connection is up."
  @spec attach!(Client.origin(), String.t()) :: String.t()
  def attach!(origin, session_id) do
    {:ok, sid} = Client.open_session(origin, session_id, :read)
    await_up(sid)
    sid
  end

  @doc "Blocks until the session's worker connection has finished its handshake."
  @spec await_up(String.t()) :: :ok
  def await_up(sid) do
    up? =
      try do
        Troupe.TestHelpers.eventually(fn -> Client.capability(sid).up? end)
      rescue
        _ -> false
      end

    unless up?, do: flunk("worker never came up: #{inspect(Troupe.Remote.Worker.status(sid))}")
    :ok
  end

  @doc "The events the client has for a session, by type."
  @spec types(String.t()) :: [atom()]
  def types(sid), do: sid |> Client.events() |> Enum.map(& &1.type)
end
