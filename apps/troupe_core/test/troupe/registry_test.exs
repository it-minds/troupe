defmodule Troupe.RegistryTest do
  @moduledoc """
  `Troupe.Registry.whereis/1` never answers a process that has gone. The registry gives a
  name back when its partition hears of the exit, which can be after the exit itself; held
  back here, by suspending the partition, so the moment is not left to timing.

  Not async: the partition is the whole VM's, and every session's names wait while it is
  suspended.
  """

  use ExUnit.Case, async: false

  alias Elixir.Registry.Partition
  alias Troupe.Registry

  test "a process that has gone is not answered while its name is still registered" do
    key = {:session, "registry-test-#{System.unique_integer([:positive])}"}
    parent = self()

    pid =
      spawn(fn ->
        true = Registry.first?(key)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    assert Registry.whereis(key) == pid

    partition = Partition.pid_name(Troupe.Registry, 0)
    :sys.suspend(partition)

    try do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Still registered: the partition has not heard.
      assert [{^pid, _}] = Elixir.Registry.lookup(Troupe.Registry, key)
      assert Registry.whereis(key) == nil
    after
      :sys.resume(partition)
    end
  end
end
