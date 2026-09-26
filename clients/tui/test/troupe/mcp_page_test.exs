defmodule Troupe.MCPPageTest do
  @moduledoc """
  The `/mcp` page over the person's own servers and skills (troupe-remote Decision
  700): a Claude Code `.mcp.json` imported with one command shows up with its layer and
  its live state, a `~/.claude/skills` linked with one command shows up beside it, a
  check brings a server into a running session, and `x` takes them away again. The
  suite's one config directory is written here, which is why this runs alone.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client

  @stub Path.expand("../support/mcp_stub.exs", __DIR__)

  setup do
    config_home = System.fetch_env!("TROUPE_CONFIG_HOME")

    on_exit(fn ->
      File.rm_rf!(Path.join(config_home, "mcp.json"))
      File.rm_rf!(Path.join(config_home, "mcp.json.previous"))
      File.rm_rf!(Path.join(config_home, "skills.json"))
      File.rm_rf!(Path.join(config_home, "skills"))
    end)

    %{config_home: config_home}
  end

  test "importing a .mcp.json and linking a skills directory shows both, with their layers",
       context do
    elixir = System.find_executable("elixir") || "elixir"

    claude =
      tmp_workspace(%{
        ".mcp.json" =>
          Jason.encode!(%{"mcpServers" => %{"stub" => %{"command" => elixir, "args" => [@stub]}}}),
        "skills/review/SKILL.md" => "---\ndescription: How I review\n---\nCheck the tests."
      })

    {sid, _, _ws} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    type(pid, "/mcp import " <> Path.join(claude, ".mcp.json"))
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "imported servers stub into" end)
    eventually(fn -> screen_text(pid, session) =~ "stub  [user]" end)
    assert File.regular?(Path.join(context.config_home, "mcp.json"))

    # Written after the session started, so it is not running there yet; `c` starts it.
    assert screen_text(pid, session) =~ "not in this session yet"
    press(pid, "c")
    eventually(fn -> screen_text(pid, session) =~ "stub: ready, 1 tools" end, 20_000, 250)
    assert screen_text(pid, session) =~ "✓ stub  [user]  1 tools"
    assert [%{name: "stub", state: :ready, tools: 1}] = Client.mcp_status(sid)

    press(pid, "esc")
    type(pid, "/skills link " <> Path.join(claude, "skills"))
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "linked skills review into" end)
    eventually(fn -> screen_text(pid, session) =~ "◆ review  [user]  How I review" end)

    assert {:ok,
            %{servers: [%{name: "stub", layer: :user}], skills: [%{name: "review", linked?: true}]}} =
             Client.sources(sid)

    # `x` on the skill unlinks nothing: it comes from a linked directory, and the notice says so.
    press(pid, "down")
    press(pid, "x")
    eventually(fn -> screen_text(pid, session) =~ "comes from" end)

    press(pid, "up")
    press(pid, "x")
    eventually(fn -> screen_text(pid, session) =~ "removed stub from the user mcp" end)
    refute screen_text(pid, session) =~ "stub  [user]"
  end

  test "a remote session's page says the servers are its profile's" do
    assert {:error, message} = Troupe.Client.Remote.sources("s-remote")
    assert message =~ "profile"
  end
end
