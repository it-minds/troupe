defmodule Troupe.Plane.SettingsWithoutDatabaseTest do
  @moduledoc """
  Reading a setting when the database cannot answer.

  The deployment is the floor under every setting, so a plane whose database is missing,
  refusing or disappearing mid-query still has a complete answer — and the requests that
  read a setting on their way through, `/.well-known/troupe` among them, have to get it.
  Two ways to lose the database, because they arrive differently: one raises and one
  exits, and only the first is a `rescue`.

  Its own module rather than a `DataCase`: these tests say what happens with no checked
  out connection, which is the opposite of what that case template arranges.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.{Repo, Settings}

  # Deployed as nothing here, so what comes back is the setting's own fallback.
  @deployed_default 365

  setup do
    Settings.invalidate()
    on_exit(&Settings.invalidate/0)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "a query that is refused falls back to the deployment" do
    # No connection was checked out for this process, so the sandbox refuses it — the
    # shape of a plane whose database is not reachable yet.
    assert read_in_a_fresh_process() == {:ok, @deployed_default}
  end

  test "a connection that dies under the query falls back too" do
    # An owner that exits while a reader is checking out: the reader is sent an exit, not
    # an exception. Repeated, because the window it lands in is the ownership manager
    # learning about the death, and once is not evidence.
    outcomes =
      for _ <- 1..40 do
        owner = shared_owner()
        Process.exit(owner, :kill)
        read_in_a_fresh_process()
      end

    assert Enum.uniq(outcomes) == [{:ok, @deployed_default}]
  end

  # An owner holding the repo in shared mode, so a process that checked out nothing finds
  # its connection — which is how a request on a live plane finds one.
  defp shared_owner do
    parent = self()

    owner =
      spawn(fn ->
        Sandbox.checkout(Repo)
        Sandbox.mode(Repo, {:shared, self()})
        send(parent, :ready)
        receive do: (:stop -> :ok)
      end)

    receive do
      :ready -> owner
    after
      2_000 -> flunk("the sandbox owner never took its connection")
    end
  end

  # In a process of its own and monitored, because the failure this guards against is not
  # a wrong answer but a caller that does not live to give one.
  defp read_in_a_fresh_process do
    parent = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        Settings.invalidate()
        send(parent, {:read, Settings.get("default_erase_after_days")})
      end)

    receive do
      {:DOWN, ^ref, :process, _pid, :normal} ->
        receive do
          {:read, value} -> {:ok, value}
        after
          0 -> :no_answer
        end

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:died, reason}
    after
      5_000 -> :timed_out
    end
  end
end
