defmodule Troupe.Gateway.SharedSettingsTest do
  @moduledoc """
  The settings the desktop app and the terminal UI share (#57), served by the daemon:
  `config.get` with every key and where its value came from, `config.set` of one key into
  the file a client names, and `config.changed` to every client attached once a file the
  daemon writes has changed. Two clients on one daemon, as the two programs are.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Error}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_AUTH_TOKEN TROUPE_PROVIDER TROUPE_MODEL TROUPE_SMALL_MODEL TROUPE_EXPENSIVE_MODEL)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-shared-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    %{
      base: base,
      user_file: Path.join([base, "config", "config.yaml"]),
      desktop: connect_as(:desktop, endpoint),
      terminal: connect_as(:terminal, endpoint)
    }
  end

  describe "a change one client makes" do
    test "the desktop app's model reaches the terminal, announced", ctx do
      assert {:ok, _} =
               Client.call(ctx.desktop, "config.set", %{
                 "command_id" => "c-1",
                 "provider" => "anthropic",
                 "models" => %{"default" => "claude-opus-5"}
               })

      assert_receive {:terminal, {:troupe_notification, "config.changed", changed}}, 2_000
      assert changed["scope"] == "user"
      assert changed["path"] == ctx.user_file
      assert "models.default" in changed["keys"]

      assert {:ok, answer} = Client.call(ctx.terminal, "config.get", %{})

      assert %{"value" => "claude-opus-5", "layer" => "user", "source" => source} =
               key(answer, "models.default")

      assert source == ctx.user_file
    end

    test "the terminal's model reaches the desktop app, set by name in the scope named", ctx do
      File.write!(ctx.user_file, "# mine\nmax_turns: 12   # raised\n")

      assert {:ok, %{"written" => written} = answer} =
               Client.call(ctx.terminal, "config.set", %{
                 "command_id" => "c-2",
                 "key" => "models.default",
                 "value" => "gateway/glm-5.2",
                 "scope" => "user"
               })

      assert written == %{"key" => "models.default", "scope" => "user", "path" => ctx.user_file}
      assert key(answer, "models.default")["value"] == "gateway/glm-5.2"

      assert_receive {:desktop,
                      {:troupe_notification, "config.changed", %{"keys" => ["models.default"]}}},
                     2_000

      # What the desktop app's model panel reads: the file's own fields, as before.
      assert {:ok, %{"models" => %{"default" => "gateway/glm-5.2"}}} =
               Client.call(ctx.desktop, "config.get", %{})

      # One line added; the comment and the other key stay.
      assert File.read!(ctx.user_file) ==
               "# mine\nmax_turns: 12   # raised\nmodels:\n  default: gateway/glm-5.2\n"
    end

    test "a write that changes nothing announces nothing", ctx do
      params = %{"key" => "max_turns", "value" => 9, "scope" => "user"}

      assert {:ok, _} =
               Client.call(ctx.desktop, "config.set", Map.put(params, "command_id", "c-3"))

      assert_receive {:terminal,
                      {:troupe_notification, "config.changed", %{"keys" => ["max_turns"]}}},
                     2_000

      assert {:ok, _} =
               Client.call(ctx.desktop, "config.set", Map.put(params, "command_id", "c-4"))

      refute_receive {:terminal, {:troupe_notification, "config.changed", _}}, 300
    end
  end

  describe "config.get" do
    test "answers every key with its value, the layer and file that set it, and no secret", ctx do
      File.write!(
        ctx.user_file,
        "api_key: sk-never-sent-back\nmax_turns: 7\nui:\n  theme: signal\n"
      )

      assert {:ok, answer} = Client.call(ctx.desktop, "config.get", %{})
      refute inspect(answer) =~ "sk-never"

      assert %{"value" => 7, "layer" => "user", "source" => source, "scopes" => ["user"]} =
               key(answer, "max_turns")

      assert source == ctx.user_file

      assert %{"value" => "claude-sonnet-5", "layer" => "default", "source" => nil} =
               key(answer, "models.default")

      assert %{"value" => "****", "secret" => true, "layer" => "user"} = key(answer, "api_key")
      assert %{"value" => "signal", "label" => "theme"} = key(answer, "ui.theme")
      assert key(answer, "max_turns")["doc"] =~ "Model calls"

      # The fields a settings screen read before are still there.
      assert %{"api_key_set" => true, "exists" => true} = answer
      assert [%{"scope" => "user", "path" => ^source, "exists" => true}] = answer["files"]
    end

    test "with a workspace, says which files may set each key there", ctx do
      ws = Path.join(ctx.base, "repo")
      File.mkdir_p!(Path.join(ws, ".troupe"))
      File.write!(Path.join(ws, ".troupe/config.yaml"), "max_turns: 5\n")

      assert {:ok, answer} = Client.call(ctx.desktop, "config.get", %{"workspace" => ws})
      assert answer["trusted"] == false
      assert %{"value" => 5, "layer" => "project"} = key(answer, "max_turns")
      assert key(answer, "max_turns")["scopes"] == ["user", "project", "local"]
      assert key(answer, "auto_approve")["scopes"] == ["user"]
      assert key(answer, "trusted_workspaces")["scopes"] == ["user"]
      assert Enum.map(answer["files"], & &1["scope"]) == ["user", "project", "local"]
    end
  end

  describe "config.set of one key" do
    test "refuses what the scope may not set, what the schema does not know, and a wrong type",
         ctx do
      ws = Path.join(ctx.base, "repo")
      File.mkdir_p!(ws)

      refusals = [
        {%{
           "key" => "trusted_workspaces",
           "value" => ["/"],
           "scope" => "project",
           "workspace" => ws
         }, "read only from the user's config.yaml"},
        {%{"key" => "auto_approve", "value" => true, "scope" => "project", "workspace" => ws},
         "trusted workspace"},
        {%{"key" => "max_turns", "value" => 3, "scope" => "project"}, "needs a workspace"},
        {%{"key" => "max_turns", "value" => 3, "scope" => "team"}, "scope must be"},
        {%{"key" => "max_tunrs", "value" => 3}, "did you mean max_turns"},
        {%{"key" => "max_turns", "value" => "lots"}, "max_turns must be a whole number"},
        {%{"key" => "version", "value" => 1}, "not a setting a client sets"}
      ]

      for {{params, reason}, n} <- Enum.with_index(refusals) do
        params = Map.put(params, "command_id", "r-#{n}")

        assert {:error, %Error{message: "invalid_params", data: data}} =
                 Client.call(ctx.desktop, "config.set", params)

        assert data["reason"] =~ reason, inspect({params, data})
      end

      refute File.exists?(ctx.user_file)
      refute File.exists?(Path.join(ws, ".troupe/config.yaml"))
      refute_receive {:terminal, {:troupe_notification, "config.changed", _}}, 200
    end

    test "writes a project's file, and null takes a key out of it", ctx do
      ws = Path.join(ctx.base, "repo")
      File.mkdir_p!(Path.join(ws, ".troupe"))
      project = Path.join(ws, ".troupe/config.yaml")
      File.write!(project, "# the team's\nmax_turns: 40\n")

      set = fn n, key, value ->
        Client.call(ctx.terminal, "config.set", %{
          "command_id" => "p-#{n}",
          "key" => key,
          "value" => value,
          "scope" => "project",
          "workspace" => ws
        })
      end

      assert {:ok, answer} = set.(1, "max_turns", 60)
      assert %{"value" => 60, "layer" => "project"} = key(answer, "max_turns")

      assert_receive {:desktop, {:troupe_notification, "config.changed", changed}}, 2_000

      assert changed == %{
               "scope" => "project",
               "path" => project,
               "workspace" => ws,
               "keys" => ["max_turns"]
             }

      assert {:ok, answer} = set.(2, "max_turns", nil)
      assert %{"value" => 40, "layer" => "default"} = key(answer, "max_turns")
      assert File.read!(project) == "# the team's\n"
    end
  end

  defp key(answer, name), do: Enum.find(answer["keys"], &(&1["key"] == name))

  # Each client is owned by a process that hands the test what it hears, named, so the
  # test can tell which of the two heard it.
  defp connect_as(name, endpoint) do
    test = self()
    owner = spawn_link(fn -> forward(test, name) end)
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false, owner: owner)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  defp forward(test, name) do
    receive do
      message ->
        send(test, {name, message})
        forward(test, name)
    end
  end
end
