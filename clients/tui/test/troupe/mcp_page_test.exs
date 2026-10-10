# The core suite's fake authorization server and protected MCP server (Decision 741).
Code.require_file("../../../../apps/troupe_core/test/support/fake_oauth.exs", __DIR__)

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

  # troupe-remote Decision 741: a server that wants the person signed in, against the
  # core suite's fake authorization server and protected MCP server.
  test "a server that wants a sign-in: s opens the browser, and the page says whose it is",
       context do
    fake = Troupe.Test.FakeOAuth.start(self())
    test = self()

    Application.put_env(:troupe, :open_url, fn url ->
      send(test, {:opened, url})
      :ok
    end)

    on_exit(fn ->
      Application.delete_env(:troupe, :open_url)
      Troupe.Test.FakeOAuth.stop(fake)
    end)

    File.write!(
      Path.join(context.config_home, "mcp.json"),
      Jason.encode!(%{
        "mcpServers" => %{
          "notes" => %{
            "url" => fake.mcp_url,
            "oauth" => %{"client_id" => Troupe.Test.FakeOAuth.client_id()}
          }
        }
      })
    )

    {sid, _, _ws} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    type(pid, "/mcp")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "→ notes  [user]  sign in — s" end)
    assert screen_text(pid, session) =~ "not signed in — s signs in"

    press(pid, "s")
    assert_receive {:opened, url}, 10_000
    assert String.starts_with?(url, fake.issuer <> "/authorize?")
    eventually(fn -> screen_text(pid, session) =~ "finish signing in in your browser" end)
    eventually(fn -> screen_text(pid, session) =~ "waiting for the browser" end)

    assert {200, _page} = Troupe.Test.FakeOAuth.browse(url)

    # The session that waited asks for the tools by itself; `r` reads the page again.
    eventually(
      fn ->
        press(pid, "r")
        screen_text(pid, session) =~ "✓ notes  [user]  1 tools · ada@example.test"
      end,
      10_000,
      250
    )

    assert screen_text(pid, session) =~ "signed in as ada@example.test"
    assert [%{name: "notes", state: :ready, tools: 1}] = Client.mcp_status(sid)

    press(pid, "o")
    eventually(fn -> screen_text(pid, session) =~ "notes: signed out on this machine" end)
    eventually(fn -> screen_text(pid, session) =~ "sign in — s" end)
  end

  # Decision 822's layers: a skill in the repository's `.agents/skills` and one in
  # `~/.agents/skills` are named for their layers, the one a nearer layer hides is listed
  # with why, and `x` on one Troupe never writes says whose it is instead of asking the
  # daemon to remove it from the person's own files.
  test "the .agents layers are named, a hidden skill is listed with why, and x leaves the repository's alone" do
    home =
      tmp_workspace(%{"skills/notes/SKILL.md" => "---\ndescription: My notes\n---\nWrite it down."})

    Application.put_env(:troupe_core, :agents_home, home)
    on_exit(fn -> Application.delete_env(:troupe_core, :agents_home) end)

    ws =
      tmp_workspace(%{
        ".agents/skills/lint/SKILL.md" => "---\ndescription: The repository's lint\n---\nRun it.",
        ".agents/skills/review/SKILL.md" => "---\ndescription: The shared review\n---\nLook.",
        ".troupe/skills/review/SKILL.md" => "---\ndescription: Our review\n---\nCheck the tests."
      })

    {sid, _, _ws} = start_session!(workspace: ws, script: [])
    {pid, session} = start_tui(sid)

    type(pid, "/mcp")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "◆ lint  [agents]  The repository's lint" end)

    text = screen_text(pid, session)
    assert text =~ "◆ notes  [user_agents]  My notes"
    assert text =~ "◆ review  [workspace]  Our review"
    assert text =~ "◇ review  [agents]  skipped: "
    refute text =~ "[session]"

    assert {:ok, %{skipped: [%{name: "review", layer: :agents, status: :skipped} = hidden]}} =
             Client.sources(sid)

    assert hidden.reason =~ "is used"

    # The hidden one, selected, says why it is not offered.
    press(pid, "down")
    press(pid, "down")
    press(pid, "down")
    eventually(fn -> screen_text(pid, session) =~ "offered    no" end)

    # `x` on the repository's `.agents` skill: nothing is asked of the daemon, and the
    # notice says whose it is and why Troupe leaves it.
    press(pid, "up")
    press(pid, "up")
    press(pid, "up")
    press(pid, "x")
    eventually(fn -> screen_text(pid, session) =~ "lint is the repository's" end)
    assert File.regular?(Path.join(ws, ".agents/skills/lint/SKILL.md"))
  end

  test "a remote session's page says the servers are its profile's" do
    assert {:error, message} = Troupe.Client.Remote.sources("s-remote")
    assert message =~ "profile"
  end
end
