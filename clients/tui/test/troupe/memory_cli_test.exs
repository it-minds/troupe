defmodule Troupe.MemoryCLITest do
  @moduledoc """
  `troupe memory` (root issue #55's user level): the person's own memory on the plane,
  through the daemon's `me.memory` and `me.memory.put`. Shown alone; `--edit` saves what the
  person left in their editor over the version they started from; `--clear` empties it; a
  daemon that is not signed in says so. `async: false`, as the editor is the application
  environment's.
  """

  use ExUnit.Case, async: false

  alias Troupe.CLI
  alias Troupe.CLI.Memory

  @own %{
    "version" => 3,
    "text" => "I write British English.",
    "bytes" => 24,
    "limit" => 8192,
    "changed_by" => "ada@example.test",
    "changed_at" => "2026-10-25T09:00:00Z",
    "plane_url" => "https://plane.example.test"
  }

  setup do
    on_exit(fn -> Application.delete_env(:troupe, :edit_file) end)
    :ok
  end

  test "the command line is troupe memory, with --edit or --clear" do
    assert {:ok, %{mode: :memory, edit: false, clear: false}} = CLI.parse(["memory"])
    assert {:ok, %{mode: :memory, edit: true}} = CLI.parse(["memory", "--edit"])
    assert {:ok, %{mode: :memory, clear: true}} = CLI.parse(["memory", "--clear"])

    assert {:error, "troupe memory takes --edit or --clear, not both"} =
             CLI.parse(["memory", "--edit", "--clear"])
  end

  test "alone it prints the document, its version and who saved it" do
    {status, said} = run(%{}, fn "me.memory", _ -> {:ok, @own} end)

    assert status == 0
    assert said =~ "your memory on https://plane.example.test, version 3, 24 of 8192 bytes"
    assert said =~ "I write British English."
  end

  test "--edit saves what the editor left, over the version it started from" do
    Application.put_env(:troupe, :edit_file, fn path ->
      File.write!(path, File.read!(path) <> "Tabs, not spaces.\r\n")
      :ok
    end)

    test = self()

    call = fn
      "me.memory", _ ->
        {:ok, @own}

      "me.memory.put", params ->
        send(test, {:put, params})
        {:ok, %{"changed" => true, "user" => %{@own | "version" => 4, "bytes" => 42}}}
    end

    {status, said} = run(%{edit: true}, call)

    assert status == 0

    assert_received {:put,
                     %{
                       "text" => "I write British English.\nTabs, not spaces.",
                       "version" => 3,
                       "command_id" => _
                     }}

    assert said =~ "is saved, version 4"
    assert said =~ "read it from their next turn"
  end

  test "--edit that changes nothing saves nothing, and a save made elsewhere is said" do
    Application.put_env(:troupe, :edit_file, fn _path -> :ok end)
    {0, said} = run(%{edit: true}, fn "me.memory", _ -> {:ok, @own} end)
    assert said =~ "nothing was saved"

    Application.put_env(:troupe, :edit_file, fn path -> File.write!(path, "Mine.\n") end)

    call = fn
      "me.memory", _ ->
        {:ok, @own}

      "me.memory.put", _ ->
        {:error,
         %{
           data: %{
             "reason" => "your memory was saved somewhere else since; version 4 is in force now"
           }
         }}
    end

    {1, said} = run(%{edit: true}, call)
    assert said =~ "version 4 is in force now"

    # An editor that cannot be started as a program is said, and nothing is saved.
    Application.put_env(:troupe, :edit_file, fn _path -> raise ErlangError, original: :enoent end)
    {1, said} = run(%{edit: true}, fn "me.memory", _ -> {:ok, @own} end)
    assert said =~ "your memory was not edited: the editor could not be started"
  end

  test "--clear empties it, and a daemon not signed in says so" do
    test = self()

    call = fn
      "me.memory", _ ->
        {:ok, @own}

      "me.memory.put", params ->
        send(test, {:put, params}) &&
          {:ok,
           %{"changed" => true, "user" => %{@own | "version" => 4, "bytes" => 0, "text" => ""}}}
    end

    {0, said} = run(%{clear: true}, call)
    assert_received {:put, %{"text" => "", "version" => 3}}
    assert said =~ "is cleared, version 4"

    reason =
      "this computer's daemon is not signed in to a Troupe plane, so there is no memory of yours to read or change"

    {1, said} = run(%{}, fn "me.memory", _ -> {:error, %{data: %{"reason" => reason}}} end)
    assert said =~ "not signed in to a Troupe plane"
  end

  # --status: which versions this machine holds, whether they are current, and what each
  # session here read at its last turn.
  test "--status says which versions this machine holds and what each session here read" do
    assert {:ok, %{mode: :memory, status: true}} = CLI.parse(["memory", "--status"])
    assert {:error, message} = CLI.parse(["memory", "--status", "--edit"])
    assert message =~ "changes nothing"

    org = %{
      "scope" => "organisation",
      "name" => nil,
      "version" => 2,
      "hash" => "sha256:0123456789abcdef"
    }

    team = %{
      "scope" => "team",
      "name" => "design",
      "version" => 5,
      "hash" => "sha256:fedcba9876543210"
    }

    status = %{
      "plane_url" => "https://plane.example.test",
      "fetched_at" => "2026-10-25T09:00:00Z",
      "path" => "~/.local/state/troupe/memory.json",
      "documents" => [org, team],
      "problem" => nil,
      "in_force" => [%{org | "version" => 3}, team],
      "current" => false,
      "reason" => nil,
      "sessions" => [
        %{
          "session_id" => "s-1",
          "turn_at" => "2026-10-25T08:59:00Z",
          "documents" => [org, team],
          "current" => false
        }
      ]
    }

    {0, said} = run(%{status: true}, fn "me.memory.status", _ -> {:ok, status} end)

    assert said =~
             "this machine holds the memory of https://plane.example.test, fetched 2026-10-25T09:00:00Z"

    assert said =~ "  the organisation's memory, version 2 (sha256:0123456789ab)"
    assert said =~ "  the team design's memory, version 5"
    assert said =~ "behind: the plane has the organisation's memory, version 3"

    assert said =~
             "session s-1, last turn 2026-10-25T08:59:00Z: organisation v2, team v5 (behind until its next turn)"

    signed_out = %{
      status
      | "current" => nil,
        "in_force" => nil,
        "reason" => "signed out: the plane was not asked",
        "sessions" => []
    }

    {0, said} = run(%{status: true}, fn "me.memory.status", _ -> {:ok, signed_out} end)
    assert said =~ "not checked against the plane: signed out"
  end

  defp run(args, call) do
    test = self()
    status = Memory.run(args, &send(test, {:said, &1}), call)
    {status, said()}
  end

  defp said(acc \\ []) do
    receive do
      {:said, line} -> said([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
