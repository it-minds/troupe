defmodule Troupe.MCP.LocalTest do
  @moduledoc """
  The two `mcp.json` layers (Decision 700): how the user's and the workspace's files
  stack over `config.yaml`'s `mcp:`, what a linked file adds, how an entry is merged,
  what import and remove write, and what the trust store remembers. Every file is
  under a scratch directory of the test's own, the user's by `user_path:`.
  """

  use ExUnit.Case, async: true

  alias Troupe.MCP.{Local, Trust}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-mcp-local-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      base: base,
      workspace: workspace,
      user_path: Path.join(base, "config/mcp.json"),
      state_dir: Path.join(base, "state")
    }
  end

  defp write_json!(path, map) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map))
  end

  describe "layering" do
    test "the workspace's file wins over the user's, and both over config.yaml, by name",
         context do
      write_json!(context.user_path, %{
        "mcpServers" => %{
          "shared" => %{"command" => "user-shared", "env" => %{"A" => "1"}},
          "mine" => %{"command" => "mine"}
        }
      })

      write_json!(Local.workspace_path(context.workspace), %{
        "mcpServers" => %{
          "shared" => %{"env" => %{"B" => "2"}, "args" => ["--x"]},
          "theirs" => %{"url" => "https://t.test/mcp"}
        }
      })

      base = %{
        "shared" => %{
          command: "yaml-shared",
          args: [],
          env: %{},
          cd: nil,
          url: nil,
          permission: :ask,
          timeout_ms: 30_000
        }
      }

      {servers, warnings} =
        Local.resolve(context.workspace, user_path: context.user_path, base: base)

      assert warnings == []

      assert Enum.map(servers, &{&1.name, &1.layer}) == [
               {"mine", :user},
               {"shared", :workspace},
               {"theirs", :workspace}
             ]

      # Merged key by key across the layers: the command from the user's file, the env
      # from both, the args from the workspace's.
      shared = Enum.find(servers, &(&1.name == "shared"))
      assert shared.config.command == "user-shared"
      assert shared.config.env == %{"A" => "1", "B" => "2"}
      assert shared.config.args == ["--x"]
      assert shared.source == Local.workspace_path(context.workspace)
      refute shared.disabled?

      theirs = Enum.find(servers, &(&1.name == "theirs"))
      assert theirs.config.url == "https://t.test/mcp"
      assert theirs.config.command == nil
    end

    test "config.yaml's servers stand underneath, with their own layer", context do
      base = %{
        "yaml" => %{
          command: "from-yaml",
          args: [],
          env: %{},
          cd: nil,
          url: nil,
          permission: :auto,
          timeout_ms: 30_000
        }
      }

      {[yaml], []} = Local.resolve(context.workspace, user_path: context.user_path, base: base)
      assert yaml.layer == :config
      assert yaml.source == "config.yaml"
      assert yaml.config.permission == :auto
    end

    test "a linked file is read in place, its entries under the layer's own", context do
      linked = Path.join(context.base, "elsewhere/.mcp.json")

      write_json!(linked, %{
        "mcpServers" => %{
          "fs" => %{"command" => "npx", "args" => ["fs"]},
          "own" => %{"command" => "linked"}
        }
      })

      write_json!(context.user_path, %{
        "include" => [linked],
        "mcpServers" => %{"own" => %{"command" => "mine"}}
      })

      {servers, []} = Local.resolve(nil, user_path: context.user_path)

      assert Enum.map(servers, &{&1.name, &1.source}) == [
               {"fs", linked},
               {"own", context.user_path}
             ]

      assert Enum.find(servers, &(&1.name == "own")).config.command == "mine"
    end

    test "a linked file that is missing, or malformed, warns and the rest still loads", context do
      missing = Path.join(context.base, "gone.json")
      bad = Path.join(context.base, "bad.json")
      File.write!(bad, "{nope")

      write_json!(context.user_path, %{
        "include" => [missing, bad],
        "mcpServers" => %{"ok" => %{"command" => "ok"}}
      })

      {servers, warnings} = Local.resolve(nil, user_path: context.user_path)
      assert Enum.map(servers, & &1.name) == ["ok"]
      assert Enum.any?(warnings, &(&1 =~ "gone.json"))
      assert Enum.any?(warnings, &(&1 =~ "bad.json is not JSON"))
    end

    test "disabled, {env:VAR} unset, and a relative cd", context do
      write_json!(context.user_path, %{
        "mcpServers" => %{
          "off" => %{"command" => "x", "disabled" => true},
          "keyed" => %{"command" => "x", "env" => %{"TOKEN" => "{env:TROUPE_TEST_NO_SUCH_VAR}"}},
          "here" => %{"command" => "x", "cd" => "sub"}
        }
      })

      {servers, []} = Local.resolve(context.workspace, user_path: context.user_path)
      by_name = Map.new(servers, &{&1.name, &1})

      assert by_name["off"].disabled?
      assert by_name["keyed"].config.refused =~ "{env:TROUPE_TEST_NO_SUCH_VAR} is not set"
      assert by_name["here"].config.cd == Path.join(context.workspace, "sub")
    end

    test "the fingerprint follows what would run, not the file's order", context do
      a = %{command: "x", args: ["1"], env: %{"A" => "1", "B" => "2"}, cd: nil, url: nil}

      b = %{
        command: "x",
        args: ["1"],
        env: %{"B" => "2", "A" => "1"},
        url: nil,
        cd: nil,
        permission: :auto
      }

      assert Local.fingerprint(a) == Local.fingerprint(b)
      refute Local.fingerprint(a) == Local.fingerprint(%{a | args: ["2"]})
      assert String.length(Local.fingerprint(a)) == 16
      _ = context
    end
  end

  describe "writing" do
    test "import copies another tool's servers into the layer, and a second import updates",
         context do
      from = Path.join(context.base, "claude/.mcp.json")

      write_json!(from, %{
        "mcpServers" => %{"fs" => %{"command" => "npx", "args" => ["fs"]}, "bad" => %{}}
      })

      assert {:ok, result} = Local.import(:user, nil, from, false, user_path: context.user_path)
      assert result.added == ["fs"]
      assert [%{name: "bad"}] = result.skipped
      refute result.linked
      assert result.path == context.user_path

      assert {:ok, file} = Local.read(context.user_path)
      assert file.servers == %{"fs" => %{"command" => "npx", "args" => ["fs"]}}
      assert file.include == []

      write_json!(from, %{"mcpServers" => %{"fs" => %{"command" => "node", "args" => ["fs.js"]}}})
      assert {:ok, _} = Local.import(:user, nil, from, false, user_path: context.user_path)
      assert {:ok, %{servers: %{"fs" => %{"command" => "node"}}}} = Local.read(context.user_path)
      assert File.regular?(context.user_path <> ".previous")
    end

    test "link records the file and reads it in place; unlinking takes its servers away",
         context do
      from = Path.join(context.base, "claude/.mcp.json")
      write_json!(from, %{"mcpServers" => %{"fs" => %{"command" => "npx"}}})

      assert {:ok, %{linked: true, added: ["fs"]}} =
               Local.import(:workspace, context.workspace, from, true, [])

      assert {:ok, %{include: [^from], servers: %{}}} =
               Local.read(Local.workspace_path(context.workspace))

      # Read in place: a change to the linked file is a change to the layer.
      write_json!(from, %{
        "mcpServers" => %{"fs" => %{"command" => "npx"}, "more" => %{"command" => "m"}}
      })

      {servers, []} = Local.resolve(context.workspace, user_path: context.user_path)
      assert Enum.map(servers, & &1.name) == ["fs", "more"]

      assert {:error, message} = Local.remove(:workspace, context.workspace, %{name: "fs"}, [])
      assert message =~ "comes from"
      assert message =~ "unlink it with include:"

      assert {:ok, %{removed: ["fs", "more"]}} =
               Local.remove(:workspace, context.workspace, %{include: from}, [])

      assert {[], []} = Local.resolve(context.workspace, user_path: context.user_path)
    end

    test "add writes one entry, merges onto it, and remove takes it out", context do
      assert {:ok, %{entry: entry}} =
               Local.add(:user, nil, "fs", %{command: "npx", args: ["a"], env: %{"K" => "v"}},
                 user_path: context.user_path
               )

      assert entry == %{"command" => "npx", "args" => ["a"], "env" => %{"K" => "v"}}

      # `disabled` alone: merged onto what is there, so the command need not be restated.
      assert {:ok, %{entry: %{"command" => "npx", "disabled" => true}}} =
               Local.add(:user, nil, "fs", %{"disabled" => true}, user_path: context.user_path)

      assert {:error, message} =
               Local.add(:user, nil, "with.dot", %{command: "x"}, user_path: context.user_path)

      assert message =~ "not a server name"

      # A partial entry is written as it is — it may complete a lower layer's — and one
      # that completes nothing is refused when the layers are resolved, not lost.
      assert {:ok, %{entry: %{"disabled" => true}}} =
               Local.add(:user, nil, "orphan", %{disabled: true}, user_path: context.user_path)

      {servers, []} = Local.resolve(nil, user_path: context.user_path)

      assert Enum.find(servers, &(&1.name == "orphan")).config.refused =~
               "orphan has neither a command nor a url"

      assert {:error, message} =
               Local.add(:user, nil, "both", %{command: "x", url: "y"},
                 user_path: context.user_path
               )

      assert message =~ "both a command and a url"

      assert {:ok, %{removed: ["fs"]}} =
               Local.remove(:user, nil, %{name: "fs"}, user_path: context.user_path)

      assert {:error, message} =
               Local.remove(:user, nil, %{name: "fs"}, user_path: context.user_path)

      assert message =~ "no server named fs"
    end

    test "the workspace scope needs a workspace, and a layer cannot import itself", context do
      assert {:error, "the workspace scope needs a workspace"} =
               Local.import(:workspace, nil, context.user_path, false, [])

      write_json!(context.user_path, %{"mcpServers" => %{}})

      assert {:error, message} =
               Local.import(:user, nil, context.user_path, true, user_path: context.user_path)

      assert message =~ "layer's own file"
    end
  end

  describe "the trust store" do
    test "remembers a server by workspace and fingerprint, and forgets on request", context do
      server = %{name: "fs", fingerprint: "abc"}
      refute Trust.approved?(context.state_dir, context.workspace, server)

      assert :ok =
               Trust.approve(context.state_dir, context.workspace, [
                 server,
                 %{name: "db", fingerprint: "def"}
               ])

      assert Trust.approved?(context.state_dir, context.workspace, server)

      assert Trust.approved(context.state_dir, context.workspace) == %{
               "fs" => "abc",
               "db" => "def"
             }

      # The same name with another command is another question.
      refute Trust.approved?(context.state_dir, context.workspace, %{
               server
               | fingerprint: "changed"
             })

      # Another workspace has answers of its own.
      other = Path.join(context.base, "other")
      File.mkdir_p!(other)
      refute Trust.approved?(context.state_dir, other, server)

      assert :ok = Trust.forget(context.state_dir, context.workspace)
      refute Trust.approved?(context.state_dir, context.workspace, server)
      assert File.regular?(Trust.path(context.state_dir))
    end
  end
end
