defmodule Troupe.Gateway.MemoryFactsTest do
  @moduledoc """
  Memory's facts over the protocol (#248, Decision 839): `memory.get` answers them, each
  with its status as read now, and says the brief's text is their generated view;
  `memory.forget` with an `id` forgets one fact, and without one the whole brief as before.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Memory.Facts
  alias Troupe.Protocol.{Client, Endpoint, Error, Schema}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-facts-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)
    File.write!(Path.join(workspace, "mix.exs"), "defmodule R do\nend\n")

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    %{workspace: workspace, client: client}
  end

  test "memory.get answers the facts with their status, and the text as their view",
       %{workspace: ws, client: client} do
    assert {:ok, %{"facts" => [], "generated" => true}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    {:ok, command} =
      Facts.put(
        ws,
        %{kind: "command", claim: "`mix check` is the gate", anchors: ["mix.exs"], scope: nil},
        %{session: "s-1", seq: 12, by: "librarian", exit_status: 0}
      )

    {:ok, note} =
      Facts.put(
        ws,
        %{kind: "note", claim: "the ledger is a fold", anchors: [], scope: "lib/**"},
        %{session: "s-1", seq: 13, by: "agent:build"}
      )

    assert {:ok, %{"facts" => facts, "generated" => true}} =
             Client.call(client, "memory.get", %{"workspace" => ws})

    by_id = Map.new(facts, &{&1["id"], &1})

    assert %{
             "kind" => "command",
             "claim" => "`mix check` is the gate",
             "status" => "current",
             "anchors" => [%{"path" => "mix.exs", "hash" => hash}],
             "evidence" => %{
               "session" => "s-1",
               "seq" => 12,
               "by" => "librarian",
               "exit_status" => 0
             }
           } = by_id[command["id"]]

    assert hash =~ ~r/^[0-9a-f]{64}$/
    assert %{"kind" => "note", "status" => "unanchored", "scope" => "lib/**"} = by_id[note["id"]]

    for fact <- facts, key <- ~w(id created_at verified_at), do: assert(is_binary(fact[key]))

    # An edit to the anchor is read at once: the fact may no longer be true.
    File.write!(Path.join(ws, "mix.exs"), "defmodule R do\n  # moved\nend\n")

    assert {:ok, %{"facts" => facts}} = Client.call(client, "memory.get", %{"workspace" => ws})
    assert Enum.find(facts, &(&1["id"] == command["id"]))["status"] == "moved"

    File.rm!(Path.join(ws, "mix.exs"))
    assert {:ok, %{"facts" => facts}} = Client.call(client, "memory.get", %{"workspace" => ws})
    assert Enum.find(facts, &(&1["id"] == command["id"]))["status"] == "missing"
  end

  test "memory.forget with an id forgets that fact alone, and an unknown one is not found",
       %{workspace: ws, client: client} do
    {:ok, one} =
      Facts.put(ws, %{kind: "note", claim: "one", anchors: [], scope: nil}, %{by: "person"})

    {:ok, two} =
      Facts.put(ws, %{kind: "note", claim: "two", anchors: [], scope: nil}, %{by: "person"})

    params = %{"command_id" => Client.command_id(), "workspace" => ws, "id" => one["id"]}
    assert Schema.validate(Schema.commands()["memory.forget"], params) == :ok

    assert {:ok, %{"forgotten" => true, "id" => id}} =
             Client.call(client, "memory.forget", params)

    assert id == one["id"]
    assert {:ok, %{"facts" => [left]}} = Client.call(client, "memory.get", %{"workspace" => ws})
    assert left["id"] == two["id"]

    assert {:error, %Error{message: "not_found"}} =
             Client.call(client, "memory.forget", %{
               "command_id" => Client.command_id(),
               "workspace" => ws,
               "id" => "no-such-fact"
             })

    # Without an id it is the whole brief, as it was.
    assert {:ok, %{"forgotten" => true} = whole} =
             Client.call(client, "memory.forget", %{
               "command_id" => Client.command_id(),
               "workspace" => ws
             })

    refute Map.has_key?(whole, "id")
  end
end
