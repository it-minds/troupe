defmodule Troupe.Gateway.LocalSourcesTest do
  @moduledoc """
  `mcp.list`, `mcp.add`, `mcp.remove`, `mcp.check` and `skills.list`, `skills.add`,
  `skills.remove` through the daemon's own socket (Decision 700): a Claude Code
  `.mcp.json` and a `~/.claude/skills` directory imported in one step each, listed with
  their layer, a server tried before it is kept, a session's servers joined onto the
  listing, and — without the daemon — no such methods at all.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Dispatch}
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_AUTH_TOKEN TROUPE_PROVIDER TROUPE_MODEL)

  @stub Path.expand("../../../../troupe_core/test/support/mcp_stub.exs", __DIR__)
  @elixir System.find_executable("elixir") || "elixir"

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-sources-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))
    File.mkdir_p!(workspace)

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    # A session needs a model; the fake answers nothing here and nobody asks it.
    File.write!(
      Path.join([base, "config", "config.yaml"]),
      "version: 1\nprovider: fake\nmodels:\n  default: fake-model\n"
    )

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, user_file: Path.join([base, "config", "mcp.json"])}
  end

  describe "on the daemon" do
    setup %{base: base} do
      endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
      start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
      %{client: client}
    end

    test "a Claude Code .mcp.json imports in one step, is listed with its layer, and can be tried",
         context do
      from = Path.join(context.base, "claude/.mcp.json")
      File.mkdir_p!(Path.dirname(from))

      File.write!(
        from,
        Jason.encode!(%{
          "mcpServers" => %{
            "stub" => %{"command" => @elixir, "args" => [@stub]},
            "secret" => %{"command" => "x", "env" => %{"K" => "${input:token}"}}
          }
        })
      )

      assert {:ok, imported} =
               Client.call(context.client, "mcp.add", %{
                 "command_id" => "c-1",
                 "scope" => "user",
                 "from" => from
               })

      assert imported["added"] == ["stub"]
      assert [%{"name" => "secret"}] = imported["skipped"]
      assert imported["path"] == context.user_file
      refute imported["linked"]

      assert {:ok, %{"servers" => [stub], "warnings" => []}} =
               Client.call(context.client, "mcp.list", %{"workspace" => context.workspace})

      assert %{
               "name" => "stub",
               "layer" => "user",
               "transport" => "stdio",
               "state" => nil,
               "disabled" => false
             } = stub

      assert stub["source"] == context.user_file
      assert stub["command"] == @elixir

      assert {:ok, %{"server" => tried}} =
               Client.call(context.client, "mcp.check", %{
                 "workspace" => context.workspace,
                 "name" => "stub"
               })

      assert %{"name" => "stub", "state" => "ready", "tools" => ["greet"], "error" => nil} = tried

      # One given in the request, never written: the same probe.
      assert {:ok, %{"server" => %{"state" => "error", "error" => "could not start" <> _}}} =
               Client.call(context.client, "mcp.check", %{
                 "name" => "nope",
                 "server" => %{"command" => "no-such-mcp-server-anywhere"}
               })

      assert {:ok, %{"removed" => ["stub"]}} =
               Client.call(context.client, "mcp.remove", %{
                 "command_id" => "c-2",
                 "scope" => "user",
                 "name" => "stub"
               })

      assert {:ok, %{"servers" => []}} =
               Client.call(context.client, "mcp.list", %{"workspace" => context.workspace})
    end

    test "a server written by name, disabled by a partial add, and the env never read back",
         context do
      assert {:ok, %{"entry" => entry}} =
               Client.call(context.client, "mcp.add", %{
                 "command_id" => "c-3",
                 "name" => "fs",
                 "server" => %{
                   "command" => "npx",
                   "args" => ["-y", "fs"],
                   "env" => %{"TOKEN" => "secret-value"}
                 }
               })

      assert entry == %{"command" => "npx", "args" => ["-y", "fs"], "env" => ["TOKEN"]}
      refute inspect(entry) =~ "secret-value"

      assert {:ok, _} =
               Client.call(context.client, "mcp.add", %{
                 "command_id" => "c-4",
                 "name" => "fs",
                 "server" => %{"disabled" => true}
               })

      assert {:ok,
              %{"servers" => [%{"name" => "fs", "disabled" => true, "env" => ["TOKEN"]} = listed]}} =
               Client.call(context.client, "mcp.list", %{})

      refute inspect(listed) =~ "secret-value"

      assert {:error, %Error{message: "invalid_params", data: data}} =
               Client.call(context.client, "mcp.add", %{
                 "command_id" => "c-5",
                 "name" => "bad.name",
                 "server" => %{"command" => "x"}
               })

      assert data["reason"] =~ "not a server name"
    end

    # Decision 825, #508.
    test "a server's environment: imported as the variables that read it, and listed by name only",
         context do
      from = Path.join(context.base, "claude/.mcp.json")
      File.mkdir_p!(Path.dirname(from))

      File.write!(
        from,
        Jason.encode!(%{
          "mcpServers" => %{
            "github" => %{
              "command" => "npx",
              "args" => ["-y", "github-mcp"],
              "env" => %{"GITHUB_TOKEN" => "not-a-real-token", "HOME_DIR" => "${HOME}"}
            }
          }
        })
      )

      for {scope, written} <- [
            {"user", context.user_file},
            {"workspace", Path.join(context.workspace, ".troupe/mcp.json")}
          ] do
        assert {:ok, imported} =
                 Client.call(context.client, "mcp.add", %{
                   "command_id" => "c-e-#{scope}",
                   "scope" => scope,
                   "workspace" => context.workspace,
                   "from" => from
                 })

        assert imported["added"] == ["github"]

        assert Enum.any?(
                 imported["warnings"],
                 &(&1 =~ "set GITHUB_GITHUB_TOKEN to the value in the file it came from")
               )

        refute inspect(imported) =~ "not-a-real-token"
        assert File.read!(written) =~ "{env:GITHUB_GITHUB_TOKEN}"
        refute File.read!(written) =~ "not-a-real-token"
      end

      assert {:ok, %{"servers" => [server]}} =
               Client.call(context.client, "mcp.list", %{"workspace" => context.workspace})

      assert server["env"] == ["GITHUB_TOKEN", "HOME_DIR"]
      assert server["refused"] =~ "{env:GITHUB_GITHUB_TOKEN} is not set"
    end

    # Decision 820.
    test "a server's headers: imported as the variables that read them, and listed by name only",
         context do
      from = Path.join(context.base, "cursor/mcp.json")
      File.mkdir_p!(Path.dirname(from))

      File.write!(
        from,
        Jason.encode!(%{
          "mcpServers" => %{
            "api" => %{
              "url" => "https://api.example.com/mcp",
              "headers" => %{"Authorization" => "Bearer not-a-real-token", "X-Team" => "${TEAM}"}
            }
          }
        })
      )

      assert {:ok, imported} =
               Client.call(context.client, "mcp.add", %{"command_id" => "c-h1", "from" => from})

      assert imported["added"] == ["api"]
      assert Enum.any?(imported["warnings"], &(&1 =~ "set API_AUTHORIZATION to the credential"))
      refute inspect(imported) =~ "not-a-real-token"
      refute File.read!(context.user_file) =~ "not-a-real-token"

      assert {:ok, %{"entry" => entry}} =
               Client.call(context.client, "mcp.add", %{
                 "command_id" => "c-h2",
                 "name" => "keyed",
                 "server" => %{
                   "url" => "https://keyed.example.com/mcp",
                   "headers" => %{"X-Key" => "key-value"}
                 }
               })

      assert entry == %{"url" => "https://keyed.example.com/mcp", "headers" => ["X-Key"]}

      assert {:ok, %{"servers" => servers}} = Client.call(context.client, "mcp.list", %{})

      assert Enum.map(servers, &{&1["name"], &1["headers"]}) == [
               {"api", ["Authorization", "X-Team"]},
               {"keyed", ["X-Key"]}
             ]

      refute inspect(servers) =~ "key-value"
      # The variables are not set here, so neither server will start, and each says why.
      assert Enum.find(servers, &(&1["name"] == "api"))["refused"] =~
               "{env:API_AUTHORIZATION} is not set"
    end

    # Decision 830, #522.
    test "a workspace's server set to auto says it waits for the workspace to be trusted",
         context do
      File.mkdir_p!(Path.join(context.workspace, ".troupe"))

      File.write!(
        Path.join(context.workspace, ".troupe/mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "theirs" => %{"command" => "t", "permission" => "auto"},
            "plain" => %{"command" => "p"}
          }
        })
      )

      File.write!(
        context.user_file,
        Jason.encode!(%{"mcpServers" => %{"mine" => %{"command" => "m", "permission" => "auto"}}})
      )

      list = fn ->
        assert {:ok, %{"servers" => servers}} =
                 Client.call(context.client, "mcp.list", %{"workspace" => context.workspace})

        Map.new(servers, &{&1["name"], &1})
      end

      listed = list.()
      assert listed["theirs"]["permission"] == "auto"
      assert [%{"key" => "permission", "reason" => reason}] = listed["theirs"]["notes"]

      assert reason =~
               "theirs is set to permission: auto, which applies once this workspace is trusted"

      assert reason =~ "troupe config trust "
      assert reason =~ "until then its tools ask before each call"
      assert listed["plain"]["notes"] == []
      assert listed["mine"]["notes"] == []

      config = Path.join([context.base, "config", "config.yaml"])

      File.write!(
        config,
        File.read!(config) <> "trusted_workspaces:\n  - #{Jason.encode!(context.workspace)}\n"
      )

      assert Enum.all?(list.(), fn {_name, server} -> server["notes"] == [] end)
    end

    # Decision 830: a repository's file must not offer the person's own servers as its own.
    test "a workspace's include from outside the repository is listed, not read, until trusted",
         context do
      own = Path.join(context.base, "home/.claude.json")
      File.mkdir_p!(Path.dirname(own))

      File.write!(
        own,
        Jason.encode!(%{
          "mcpServers" => %{"mine" => %{"command" => "m", "env" => %{"TOKEN" => "x"}}}
        })
      )

      File.mkdir_p!(Path.join(context.workspace, ".troupe"))

      File.write!(
        Path.join(context.workspace, ".troupe/mcp.json"),
        Jason.encode!(%{"include" => [own]})
      )

      assert {:ok, %{"servers" => [], "warnings" => [held]}} =
               Client.call(context.client, "mcp.list", %{"workspace" => context.workspace})

      assert held =~ "includes #{own}, outside the repository: not read until"
      assert held =~ "(troupe config trust #{context.workspace})"

      assert {:error, %Error{message: "not_found"}} =
               Client.call(context.client, "mcp.check", %{
                 "workspace" => context.workspace,
                 "name" => "mine"
               })

      config = Path.join([context.base, "config", "config.yaml"])

      File.write!(
        config,
        File.read!(config) <> "trusted_workspaces:\n  - #{Jason.encode!(context.workspace)}\n"
      )

      assert {:ok,
              %{"servers" => [%{"name" => "mine", "layer" => "workspace"}], "warnings" => []}} =
               Client.call(context.client, "mcp.list", %{"workspace" => context.workspace})
    end

    test "a session's servers are joined onto the listing, and mcp.check brings one back",
         context do
      File.write!(
        context.user_file,
        Jason.encode!(%{"mcpServers" => %{"stub" => %{"command" => @elixir, "args" => [@stub]}}})
      )

      assert {:ok, %{"session_id" => session_id}} =
               Client.call(context.client, "session.create", %{
                 "command_id" => "c-6",
                 "workspace" => context.workspace,
                 "worktree" => "never"
               })

      on_exit(fn -> Troupe.stop_session(session_id) end)

      # The stub takes a moment to answer `initialize`; the listing shows it arriving.
      assert %{"name" => "stub", "state" => "ready", "tools" => ["greet"], "layer" => "user"} =
               wait_for_ready(context.client, session_id)

      assert {:ok, %{"server" => %{"state" => "ready", "tools" => ["greet"], "layer" => "user"}}} =
               Client.call(context.client, "mcp.check", %{
                 "session_id" => session_id,
                 "name" => "stub"
               })

      assert {:ok,
              %{
                "servers" => [
                  %{"name" => "stub", "state" => "ready", "layer" => "user", "source" => source}
                ]
              }} =
               Client.call(context.client, "mcp.status", %{"session_id" => session_id})

      assert source == context.user_file

      assert {:error, %Error{message: "not_found"}} =
               Client.call(context.client, "mcp.check", %{
                 "session_id" => session_id,
                 "name" => "nope"
               })
    end

    test "a ~/.claude/skills directory imports in one step, linked or copied, and is listed with its layer",
         context do
      claude = Path.join(context.base, ".claude/skills")
      File.mkdir_p!(Path.join(claude, "review"))

      File.write!(
        Path.join(claude, "review/SKILL.md"),
        "---\ndescription: How I review\n---\nCheck the tests."
      )

      assert {:ok, %{"added" => ["review"], "linked" => true}} =
               Client.call(context.client, "skills.add", %{
                 "command_id" => "c-7",
                 "scope" => "workspace",
                 "workspace" => context.workspace,
                 "from" => claude,
                 "link" => true
               })

      assert {:ok, %{"skills" => [linked]}} =
               Client.call(context.client, "skills.list", %{"workspace" => context.workspace})

      assert %{
               "name" => "review",
               "description" => "How I review",
               "layer" => "workspace",
               "linked" => true
             } = linked

      assert linked["source"] == claude

      assert {:ok, %{"added" => ["review"], "linked" => false}} =
               Client.call(context.client, "skills.add", %{
                 "command_id" => "c-8",
                 "from" => claude
               })

      assert {:ok, %{"skills" => [%{"layer" => "workspace"}]}} =
               Client.call(context.client, "skills.list", %{"workspace" => context.workspace})

      assert {:ok, %{"skills" => [%{"layer" => "user", "linked" => false}]}} =
               Client.call(context.client, "skills.list", %{})

      assert {:ok, %{"removed" => ["review"]}} =
               Client.call(context.client, "skills.remove", %{
                 "command_id" => "c-9",
                 "scope" => "workspace",
                 "workspace" => context.workspace,
                 "include" => claude
               })

      assert {:ok, %{"removed" => ["review"]}} =
               Client.call(context.client, "skills.remove", %{
                 "command_id" => "c-10",
                 "name" => "review"
               })

      assert {:ok, %{"skills" => []}} =
               Client.call(context.client, "skills.list", %{"workspace" => context.workspace})

      assert {:error, %Error{message: "invalid_params", data: data}} =
               Client.call(context.client, "skills.add", %{
                 "command_id" => "c-11",
                 "from" => Path.join(context.base, "nowhere")
               })

      assert data["reason"] =~ "not a directory"
    end

    # Decision 822: the repository's `.agents/skills` is a layer below Troupe's own, read in
    # place; a name `.troupe/skills` has too is listed as skipped, saying which is used.
    test "an .agents/skills skill is listed with its layer, and one .troupe/skills beats is " <>
           "listed as skipped, with why",
         context do
      ws = Path.expand(context.workspace)

      skill = fn dir, description ->
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "SKILL.md"), "---\ndescription: #{description}\n---\nDo it.")
      end

      skill.(Path.join(ws, ".agents/skills/deploy"), "From .agents")
      skill.(Path.join(ws, ".agents/skills/review"), "Hidden by .troupe")
      skill.(Path.join(ws, ".troupe/skills/review"), "From .troupe")

      assert {:ok, %{"skills" => [deploy, review], "skipped" => [skipped]}} =
               Client.call(context.client, "skills.list", %{"workspace" => ws})

      assert %{"name" => "deploy", "layer" => "agents", "description" => "From .agents"} = deploy
      assert deploy["source"] == Path.join(ws, ".agents/skills")

      assert %{"name" => "review", "layer" => "workspace", "description" => "From .troupe"} =
               review

      assert %{"name" => "review", "layer" => "agents", "status" => "skipped"} = skipped
      assert skipped["dir"] == Path.join(ws, ".agents/skills/review")
      assert skipped["reason"] == "skipped: #{Path.join(ws, ".troupe/skills/review")} is used"
      refute Map.has_key?(skipped, "description")
    end
  end

  defp wait_for_ready(client, session_id, waited \\ 0) do
    {:ok, %{"servers" => servers}} =
      Client.call(client, "mcp.list", %{"session_id" => session_id})

    case Enum.find(servers, &(&1["name"] == "stub")) do
      %{"state" => "connecting"} when waited < 20_000 ->
        Process.sleep(200)
        wait_for_ready(client, session_id, waited + 200)

      server ->
        server
    end
  end

  # A pod runs the same dispatcher without the daemon: its servers are its bundle's.
  test "without the daemon, the methods do not exist" do
    context = %Dispatch.Context{
      principal: %{"subject" => "someone"},
      scopes: [:observe, :control, :admin],
      connection: self()
    }

    refute Process.whereis(Daemon)

    for method <-
          ~w(mcp.list mcp.add mcp.remove mcp.check mcp.sign_in mcp.sign_out skills.list skills.add skills.remove) do
      assert {:error, %Error{message: "method_not_found"}} = Dispatch.call(method, %{}, context)
    end
  end
end
