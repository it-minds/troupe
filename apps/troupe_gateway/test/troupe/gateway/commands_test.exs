defmodule Troupe.Gateway.CommandsTest do
  use ExUnit.Case, async: false

  alias Troupe.Gateway.Commands

  # The ledger is a named process the daemon and every worker start; a test suite that
  # already has one running reuses it, and one that does not starts its own.
  setup do
    case Process.whereis(Commands) do
      nil -> start_supervised!(Commands)
      _pid -> :ok
    end

    :ok
  end

  test "the same key twice runs the function once and returns the first answer" do
    key = {"ada@example.test", unique_id()}
    counter = :counters.new(1, [])

    first = Commands.once(key, fn -> :counters.add(counter, 1, 1) && {:ok, :first} end)
    second = Commands.once(key, fn -> :counters.add(counter, 1, 1) && {:ok, :second} end)

    assert first == {:ok, :first}
    assert second == {:ok, :first}
    assert :counters.get(counter, 1) == 1
  end

  # Two clients each counting from `c-1` are the protocol's stated normal case, not a
  # collision. Keyed by the command id alone, the second client's `session.create` would
  # be answered with the first client's session — somebody else's session id, handed to
  # a principal who never created it.
  test "the same command_id from two principals is two commands" do
    command_id = unique_id()

    ada = Commands.once({"ada@example.test", command_id}, fn -> {:ok, "ada's session"} end)
    grace = Commands.once({"grace@example.test", command_id}, fn -> {:ok, "grace's session"} end)

    assert ada == {:ok, "ada's session"}
    assert grace == {:ok, "grace's session"}
  end

  defp unique_id, do: "c-" <> Integer.to_string(System.unique_integer([:positive]))
end
