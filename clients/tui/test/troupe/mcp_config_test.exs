defmodule Troupe.MCPConfigTest do
  use ExUnit.Case, async: false

  import Troupe.TestHelpers

  alias Troupe.Config
  alias Troupe.Event
  alias Troupe.UI.TUI.Model

  # A project config.yaml with one stdio server and one SSE server.
  @yaml ~s"""
  mcp:
    filesystem:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      env:
        FOO: bar
    remote:
      url: http://localhost:3001/sse
  """

  @not_a_map_yaml ~s"""
  mcp: "not a map"
  """

  @bad_server_yaml ~s"""
  mcp:
    bad: "string"
    good:
      command: echo
  """

  describe "MCP config parsing" do
    # Point the global config dir at an empty temp dir so the assertions reflect
    # only the project config and the overrides under test, never the
    # developer's own ~/.config/troupe/config.yaml. async: false keeps the env
    # var change from racing any other module that reads config.
    setup do
      prev = System.get_env("TROUPE_CONFIG_DIR")

      tmp_cfg =
        Path.join(System.tmp_dir!(), "troupe-mcp-cfg-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_cfg)
      System.put_env("TROUPE_CONFIG_DIR", tmp_cfg)

      ws = Path.join(System.tmp_dir!(), "troupe-mcp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(ws, ".troupe"))
      File.write!(Path.join([ws, ".troupe", "config.yaml"]), @yaml)

      on_exit(fn ->
        case prev do
          nil -> System.delete_env("TROUPE_CONFIG_DIR")
          _ -> System.put_env("TROUPE_CONFIG_DIR", prev)
        end

        File.rm_rf!(tmp_cfg)
        File.rm_rf!(ws)
      end)

      %{config: Config.load(ws)}
    end

    test "YAML mcp config is parsed into the mcp field", %{config: cfg} do
      assert MapSet.new(Map.keys(cfg.mcp)) == MapSet.new(["filesystem", "remote"])

      fs = cfg.mcp["filesystem"]

      # stdio servers normalize to atom keys: command, args, env, cd, url
      assert MapSet.new(Map.keys(fs)) == MapSet.new([:command, :args, :env, :cd, :url])
      assert fs.command == "npx"
      assert fs.args == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      assert fs.env == %{"FOO" => "bar"}
      assert fs.cd == nil
      assert fs.url == nil

      remote = cfg.mcp["remote"]

      # SSE servers share the same atom-keyed shape; absent stdio fields default
      assert MapSet.new(Map.keys(remote)) == MapSet.new([:command, :args, :env, :cd, :url])
      assert remote.url == "http://localhost:3001/sse"
      assert remote.command == nil
      assert remote.args == []
    end

    test "config override merges mcp servers" do
      cfg = Config.load(tmp_workspace(%{}), %{mcp: %{"override_srv" => %{command: "echo"}}})
      assert cfg.mcp["override_srv"].command == "echo"
    end

    test "empty mcp config defaults to empty map" do
      assert Config.load(tmp_workspace(%{})).mcp == %{}
    end

    test "malformed mcp entry is skipped" do
      # a non-map mcp value yields an empty map
      cfg1 = Config.load(tmp_workspace(%{".troupe/config.yaml" => @not_a_map_yaml}))
      assert cfg1.mcp == %{}

      # a server whose value is not a map is dropped; the rest survive
      cfg2 = Config.load(tmp_workspace(%{".troupe/config.yaml" => @bad_server_yaml}))
      refute Map.has_key?(cfg2.mcp, "bad")
      assert cfg2.mcp["good"].command == "echo"
    end
  end

  describe "UI model fold" do
    test "model folds :mcp_status events" do
      model = Model.new("test-sid", ".")

      model = Model.apply(model, mcp_event("test", :connecting, [], nil))
      assert model.mcp["test"].state == :connecting
      assert model.mcp["test"].tools == 0
      assert model.mcp["test"].error == nil

      model = Model.apply(model, mcp_event("test", :ready, [%{name: "x"}], nil))
      assert model.mcp["test"].state == :ready
      assert model.mcp["test"].tools == 1
    end

    test "mcp_servers/1 returns sorted list" do
      model = Model.new("test-sid", ".")

      model =
        model
        |> Model.apply(mcp_event("beta", :ready, [%{name: "b"}], nil))
        |> Model.apply(mcp_event("alpha", :connecting, [], "retrying"))

      servers = Model.mcp_servers(model)
      assert Enum.map(servers, & &1.name) == ["alpha", "beta"]

      alpha = Enum.find(servers, &(&1.name == "alpha"))
      assert alpha.state == :connecting
      assert alpha.tools == 0
      assert alpha.error == "retrying"

      beta = Enum.find(servers, &(&1.name == "beta"))
      assert beta.state == :ready
      assert beta.tools == 1
      assert beta.error == nil
    end

    test "mcp_servers/1 returns [] for empty model" do
      model = Model.new("test-sid", ".")
      assert Model.mcp_servers(model) == []
    end
  end

  defp mcp_event(server, state, tools, error) do
    %Event{
      session_id: "test-sid",
      agent_path: "mcp",
      type: :mcp_status,
      data: %{server: server, state: state, tools: tools, error: error}
    }
  end
end
