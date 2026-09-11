defmodule Troupe.WrapperTest do
  @moduledoc """
  The launcher watchdog.

  Burrito's launcher forks the BEAM rather than exec'ing it, so `kill -9` on the
  process a user can see would otherwise leave the VM — and every shell command it is
  holding open through reaper — running.
  """

  use ExUnit.Case, async: true

  alias Troupe.Wrapper

  test "reads a parent pid on this platform" do
    case :os.type() do
      {:win32, _} -> assert Wrapper.parent_pid() == nil
      _ -> assert is_integer(Wrapper.parent_pid())
    end
  end

  test "does not run outside a wrapped binary" do
    refute Wrapper.wrapped?()
    assert Wrapper.child_spec_if_wrapped() == nil
  end

  test "halts when the recorded launcher is gone" do
    test_pid = self()

    {:ok, pid} =
      GenServer.start_link(Wrapper,
        interval_ms: 5,
        halt: fn code -> send(test_pid, {:halt, code}) end
      )

    # A pid that cannot exist, so the very first check sees the launcher as gone.
    :sys.replace_state(pid, fn state -> %{state | parent: 999_999_999} end)
    send(pid, :check)

    assert_receive {:halt, 0}, 1_000
  end

  test "a live parent is not reported gone, and a missing one is" do
    refute Wrapper.parent_gone?(Wrapper.parent_pid())

    case :os.type() do
      {:win32, _} -> assert Wrapper.parent_gone?(999_999_999) == false
      _ -> assert Wrapper.parent_gone?(999_999_999)
    end
  end

  test "keeps running while its parent is unchanged" do
    test_pid = self()

    {:ok, pid} =
      GenServer.start_link(Wrapper,
        interval_ms: 5,
        halt: fn code -> send(test_pid, {:halt, code}) end
      )

    send(pid, :check)
    refute_receive {:halt, _}, 200
    assert Process.alive?(pid)
  end
end
