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
  alias Troupe.Client.Daemon.Link
  alias Troupe.Remote.RPC

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

  # The command line's form for one server, as the desktop app's Add server writes it:
  # `/mcp try` runs it once and keeps nothing, `/mcp add` writes it and starts it in this
  # session, and a second `add` with flags alone edits what is there.
  test "a server written with /mcp add joins the session, and /mcp try keeps nothing", context do
    elixir = System.find_executable("elixir") || "elixir"
    file = Path.join(context.config_home, "mcp.json")

    {sid, _, _ws} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    type(pid, "/mcp try stub #{elixir} #{@stub}")
    press(pid, "enter")

    eventually(
      fn -> screen_text(pid, session) =~ "stub: ready, 1 tools (tried, not kept)" end,
      20_000,
      250
    )

    refute File.exists?(file)

    press(pid, "esc")
    type(pid, "/mcp add stub --env STUB_TOKEN={env:STUB_TOKEN_FROM} #{elixir} #{@stub} --quiet")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "wrote stub into" end, 20_000, 250)

    assert %{"mcpServers" => %{"stub" => entry}} = file |> File.read!() |> Jason.decode!()
    assert entry["command"] == elixir
    assert entry["args"] == [@stub, "--quiet"]
    assert entry["env"] == %{"STUB_TOKEN" => "{env:STUB_TOKEN_FROM}"}

    # Flags alone edit the entry: `K=` takes a variable out, the command stays.
    press(pid, "esc")
    type(pid, "/mcp add stub --env STUB_TOKEN= --auto")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "wrote stub into" end, 20_000, 250)
    assert %{"mcpServers" => %{"stub" => edited}} = file |> File.read!() |> Jason.decode!()
    assert edited["command"] == elixir
    assert edited["permission"] == "auto"
    refute Map.has_key?(edited, "env")

    eventually(
      fn -> match?([%{name: "stub", state: :ready}], Client.mcp_status(sid)) end,
      20_000,
      250
    )
  end

  # A value a server needs, kept in the keychain (the suite's is in this VM): the line says
  # which key it wants, `p` asks for it as dots, and the entry gets the reference alone.
  test "p keeps a missing secret in the keychain, typed as dots, and the server starts", context do
    elixir = System.find_executable("elixir") || "elixir"
    stub = Path.expand("../../../../apps/troupe_core/test/support/mcp_stub.exs", __DIR__)
    file = Path.join(context.config_home, "mcp.json")

    File.write!(
      file,
      Jason.encode!(%{
        "mcpServers" => %{
          "stub" => %{
            "command" => elixir,
            "args" => [stub],
            "env" => %{"STUB_TOKEN" => "{secret:stub/STUB_TOKEN}"}
          }
        }
      })
    )

    on_exit(fn -> Troupe.MCP.Secrets.delete("stub/STUB_TOKEN") end)

    {sid, _, _ws} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    type(pid, "/mcp")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "stub  [user]  needs STUB_TOKEN — p sets it" end)

    press(pid, "p")
    eventually(fn -> screen_text(pid, session) =~ "Enter keeps it in your keychain" end)
    type(pid, "hunter2")
    eventually(fn -> screen_text(pid, session) =~ "•••••••" end)
    refute screen_text(pid, session) =~ "hunter2"

    press(pid, "enter")

    eventually(
      fn -> screen_text(pid, session) =~ "kept STUB_TOKEN in your keychain" end,
      20_000,
      250
    )

    assert Troupe.MCP.Secrets.get("stub/STUB_TOKEN") == {:ok, "hunter2"}
    refute File.read!(file) =~ "hunter2"

    # Started in the session, and its tool shown as the server describes it.
    eventually(fn -> screen_text(pid, session) =~ "✓ stub  [user]  1 tools" end, 20_000, 250)
    eventually(fn -> screen_text(pid, session) =~ "Greet someone (greet) · reads only" end)
  end

  test "the words of /mcp add: flags first, then a URL or a command and its arguments" do
    alias Troupe.UI.TUI.Server

    assert {:ok, "wiki",
            %{"url" => "https://mcp.example.test/mcp", "oauth" => %{"scopes" => ["a", "b"]}}} =
             Server.parse_server("wiki --oauth --scope a --scope b https://mcp.example.test/mcp")

    assert {:ok, "t", %{"headers" => %{"Authorization" => "Bearer {env:T}"}, "command" => nil}} =
             Server.parse_server(
               ~s(t --header "Authorization=Bearer {env:T}" https://t.example.test)
             )

    assert {:ok, "fs",
            %{"command" => "npx", "args" => ["-y", "fs", "--root", "/tmp"], "url" => nil}} =
             Server.parse_server("fs npx -y fs --root /tmp")

    assert {:error, "usage: /mcp add" <> _} = Server.parse_server("fs --nope npx")
    assert {:error, "env takes K=V" <> _} = Server.parse_server("fs --env NOPE npx")
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

    # troupe-remote Decision 872: a tool that wants more than the sign-in granted. The
    # page says what it wants, and `s` signs in for it, saying what it asks for.
    {:ok, %{"content" => content}} =
      Link.call("mcp.call", %{
        name: "notes",
        tool: "write",
        arguments: %{"topic" => "x"},
        command_id: RPC.command_id()
      })

    assert content =~ "notes.write"

    eventually(
      fn ->
        press(pid, "r")
        screen_text(pid, session) =~ "wants notes.write — s"
      end,
      10_000,
      250
    )

    press(pid, "s")
    assert_receive {:opened, wider}, 10_000
    assert URI.decode_query(URI.parse(wider).query)["scope"] =~ "notes.write"
    eventually(fn -> screen_text(pid, session) =~ "asking for notes.read" end)
    assert {200, _page} = Troupe.Test.FakeOAuth.browse(wider)

    eventually(
      fn ->
        press(pid, "r")
        screen_text(pid, session) =~ "✓ notes  [user]  1 tools · ada@example.test"
      end,
      10_000,
      250
    )

    press(pid, "o")
    eventually(fn -> screen_text(pid, session) =~ "notes: signed out on this machine" end)
    assert screen_text(pid, session) =~ "the provider revoked"
    eventually(fn -> screen_text(pid, session) =~ "sign in — s" end)
  end

  # troupe-remote Decision 872: signing out of Troupe as a whole signs the daemon out of
  # the person's own servers too, and their provider revokes the sign-in.
  test "troupe logout signs out of the person's own servers, and their provider is told",
       context do
    fake = Troupe.Test.FakeOAuth.start(self())
    on_exit(fn -> Troupe.Test.FakeOAuth.stop(fake) end)

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

    {:ok, %{"url" => url}} =
      Link.call("mcp.sign_in", %{name: "notes", command_id: RPC.command_id()})

    assert {200, _page} = Troupe.Test.FakeOAuth.browse(url)
    assert Troupe.Test.FakeOAuth.refresh_token?(fake, "rt-1")
    me = self()

    # A daemon that is not running is not started to be told, and the sign-in is said to
    # be kept, and why.
    for {_id, daemon, _type, _modules} <- DynamicSupervisor.which_children(Troupe.Client.Daemons),
        is_pid(daemon),
        do: DynamicSupervisor.terminate_child(Troupe.Client.Daemons, daemon)

    eventually(fn -> not Troupe.Protocol.Daemon.running?() end)
    # And the link has heard its connection to that daemon close: a call made before it
    # had went out on the closed connection and was answered `unavailable`, where one made
    # after it starts a daemon.
    eventually(fn -> not Link.up?() end)

    assert 0 == Troupe.CLI.Remote.logout(nil, say: &send(me, {:said, &1}))
    assert Enum.any?(said(), &(&1 =~ "your sign-ins to 1 MCP server(s) are kept"))
    refute Troupe.Protocol.Daemon.running?()
    assert Troupe.Test.FakeOAuth.refresh_token?(fake, "rt-1")

    # With it running, it signs out of the server and tells the provider.
    {:ok, _identity} = Link.call("identity.get", %{})
    assert 0 == Troupe.CLI.Remote.logout(nil, say: &send(me, {:said, &1}))

    assert Enum.any?(
             said(),
             &(&1 == "signed out of the MCP server notes; the provider revoked the sign-in")
           )

    refute Troupe.Test.FakeOAuth.refresh_token?(fake, "rt-1")
    {:ok, %{"servers" => servers}} = Link.call("mcp.list", %{})
    assert %{"auth" => %{"state" => "signed_out"}} = Enum.find(servers, &(&1["name"] == "notes"))
  end

  defp said do
    receive do
      {:said, line} -> [line | said()]
    after
      0 -> []
    end
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
