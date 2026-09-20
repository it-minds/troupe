defmodule Troupe.Phase3ClientTest do
  @moduledoc """
  The tail of phase 3 as this client sees it (Decision 107): the `/mcp` page from the
  daemon, a budget warning arriving once, and the settings the brief and full send
  brought.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers

  alias Troupe.Client

  # The same stdio stub the core tests with, kept here because the dependency is only `lib`.
  @stub Path.expand("../support/mcp_stub.exs", __DIR__)

  test "the /mcp page lists the workspace's own servers from the daemon" do
    elixir = System.find_executable("elixir") || "elixir"

    {sid, _, _ws} =
      start_session!(
        script: [],
        config: %{
          "mcp" => %{
            "stub" => %{"command" => elixir, "args" => [@stub]},
            "broken" => %{"command" => "no-such-mcp-server-anywhere"}
          }
        }
      )

    servers =
      eventually(
        fn ->
          case Client.mcp_status(sid) do
            [_, _] = servers -> if Enum.any?(servers, &(&1.state == :ready)), do: servers
            _ -> nil
          end
        end,
        20_000,
        250
      )

    assert %{name: "stub", state: :ready, tools: 1, error: nil} =
             Enum.find(servers, &(&1.name == "stub"))

    assert %{name: "broken", state: :error} = Enum.find(servers, &(&1.name == "broken"))
  end

  test "a limit that is near is a warning, once, and full_send silences it" do
    steps = for _ <- 1..4, do: {:text_and_tools, "again", [{"todo_read", %{}}]}
    script = steps ++ [{:text, "done"}, {:finish, "ok"}]

    {sid, _, _} = start_session!(script: script, config: %{"max_turns" => 6})
    say!(sid, "go")

    warning = await_event("root", :budget_warning, 15_000)
    assert warning.data.dimension == :turns
    assert warning.data.detail =~ "turns 5/6"
    await_done(15_000)
    refute_receive {:troupe_event, %{type: :budget_warning, agent_path: "root"}}, 200

    {quiet, _, _} = start_session!(script: script, config: %{"max_turns" => 6, "full_send" => true})
    say!(quiet, "go")
    await_done(15_000)
    refute_received {:troupe_event, %{session_id: ^quiet, type: :budget_warning}}
  end

  test "the settings page knows full send and the brief" do
    for key <- ["full_send", "memory", "memory_auto_refresh"] do
      assert {:ok, %{type: :bool, effect: :next_run}} = Troupe.Settings.fetch(key)
    end

    ws = tmp_workspace()
    assert {:ok, path} = Troupe.Settings.persist(ws, "full_send", true)
    assert File.read!(path) =~ "full_send: true"
    assert Troupe.Config.load(ws).full_send == true
  end
end
