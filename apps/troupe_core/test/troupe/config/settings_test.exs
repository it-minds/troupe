defmodule Troupe.Config.SettingsTest do
  @moduledoc """
  `Troupe.Config.Settings`, what the daemon's `config.get` and `config.set` stand on
  (#57): every key with where its value came from and which files may set it, one key
  written into the scope a client names and refused where that scope may not set it,
  and the keys a write changed.

  Not async: the user's file is found through `TROUPE_CONFIG_HOME`.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.Config.Settings

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY TROUPE_AUTH_TOKEN
           TROUPE_PROVIDER TROUPE_MODEL TROUPE_SMALL_MODEL TROUPE_EXPENSIVE_MODEL SETTINGS_TEST_KEY)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    ws = Path.join(base, "repo")
    File.mkdir_p!(Path.join(ws, ".troupe"))
    %{user: Config.user_path(), ws: ws, project: Config.project_path(ws), base: base}
  end

  defp key(answer, name), do: Enum.find(answer["keys"], &(&1["key"] == name))

  describe "describe/1" do
    test "every key, with its value, layer, file and scopes, and no secret", ctx do
      File.write!(
        ctx.user,
        "api_key: sk-a-long-secret-key\nbase_url: \"{env:SETTINGS_TEST_KEY}\"\nmax_turns: 7\n" <>
          "mcp:\n  notes:\n    command: notes-server\n    args: [\"{env:SETTINGS_TEST_KEY}\"]\n"
      )

      File.write!(ctx.project, "max_depth: 2\n")

      answer = Settings.describe(ctx.ws)
      refute inspect(answer) =~ "sk-a-long"

      assert %{"value" => 7, "layer" => "user", "source" => user, "default" => 40} =
               key(answer, "max_turns")

      assert user == ctx.user
      assert %{"value" => 2, "layer" => "project", "source" => project} = key(answer, "max_depth")
      assert project == ctx.project
      assert %{"value" => "****", "secret" => true} = key(answer, "api_key")
      # A reference to a variable that is not set is shown as written: it is not the key.
      # In a list too, and the answer is JSON all the same.
      assert key(answer, "base_url")["value"] == "{env:SETTINGS_TEST_KEY}"
      assert key(answer, "mcp.notes.args")["value"] == ["{env:SETTINGS_TEST_KEY}"]
      assert {:ok, _json} = Jason.encode(answer)

      # Untrusted: a key marked trusted is the user's to set alone, here.
      refute answer["trusted"]
      assert key(answer, "max_turns")["scopes"] == ["user", "project", "local"]
      assert key(answer, "auto_approve")["scopes"] == ["user"]
      assert key(answer, "version")["scopes"] == []

      assert %{"label" => "model", "doc" => doc} = key(answer, "models.default")
      assert doc =~ "every agent uses"

      assert %{"value" => "afterglow", "layer" => "default", "label" => "theme"} =
               key(answer, "ui.theme")
    end

    test "a file that is refused answers why, and no keys", ctx do
      File.write!(ctx.user, "max_turns: lots\n")

      assert %{"keys" => [], "errors" => [error]} = Settings.describe(nil)
      assert error =~ "max_turns must be a whole number"
    end
  end

  describe "set/4" do
    test "writes the key's own line in the user's file, by its new name", ctx do
      File.write!(ctx.user, "# mine\nmodel: old   # the old spelling\nmax_turns: 9\n")

      assert {:ok, %{"key" => "models.default", "scope" => "user", "path" => path}} =
               Settings.set("models.default", "gateway/opus", "user", nil)

      assert path == ctx.user
      assert File.read!(ctx.user) == "# mine\nmax_turns: 9\nmodels:\n  default: gateway/opus\n"
      assert Config.load(nil).model == "gateway/opus"

      # An old spelling is the same setting.
      assert {:ok, %{"key" => "models.cheap"}} =
               Settings.set("small_model", "gateway/haiku", nil, nil)

      assert Config.load(nil).small_model == "gateway/haiku"
    end

    test "null takes a key out, and the block it emptied with it", ctx do
      File.write!(ctx.user, "max_turns: 9\nui:\n  theme: signal\n")

      assert {:ok, _} = Settings.set("ui.theme", nil, "user", nil)
      assert File.read!(ctx.user) == "max_turns: 9\n"

      # Taking out what is not there changes nothing, and writes nothing.
      File.rm!(ctx.user <> ".previous")
      assert {:ok, _} = Settings.set("ui.mode", nil, "user", nil)
      refute File.exists?(ctx.user <> ".previous")
    end

    test "a name under a map is a path, dots and all" do
      assert {:ok, %{"key" => "models.prices.gpt-4.1"}} =
               Settings.set(
                 ["models", "prices", "gpt-4.1"],
                 %{"input" => 2, "output" => 8},
                 "user",
                 nil
               )

      assert Config.load(nil).prices["gpt-4.1"] == %{"input" => 2, "output" => 8}
    end

    test "a project's file, and a key marked trusted once the workspace is", ctx do
      assert {:ok, %{"path" => project}} = Settings.set("max_turns", 60, "project", ctx.ws)
      assert project == ctx.project
      assert Config.load(ctx.ws).max_turns == 60

      assert {:error, reason} = Settings.set("auto_approve", true, "project", ctx.ws)
      assert reason =~ "only in a trusted workspace"
      assert reason =~ "troupe config trust"

      File.write!(ctx.user, "trusted_workspaces:\n  - #{ctx.ws}\n")
      assert {:ok, _} = Settings.set("auto_approve", true, "local", ctx.ws)
      assert Config.load(ctx.ws).auto_approve
      assert File.read!(Config.local_path(ctx.ws)) =~ "auto_approve: true"
    end

    test "refuses, and writes nothing", ctx do
      refusals = [
        {{"trusted_workspaces", ["/"], "local", ctx.ws}, "read only from the user's config.yaml"},
        {{"max_turns", 3, "project", nil}, "the project scope needs a workspace"},
        {{"max_turns", 3, "machine", nil}, "scope must be user, project or local"},
        {{"modles.default", "x", "user", nil},
         "is not a setting Troupe knows; did you mean models.default?"},
        {{"models.defualt", "x", "user", nil}, "did you mean models.default?"},
        {{"max_turns", 0, "user", nil}, "max_turns must be a whole number, at least 1"},
        {{"ui.mode", "bright", "user", nil}, "ui.mode must be one of system, light, dark"},
        {{"auto_approve", "yes", "user", nil}, "write true"},
        {{"providers.gw", %{"tpye" => "openai"}, "user", nil},
         "providers.gw.tpye is not a setting"},
        {{"$schema", "x", "user", nil}, "not a setting a client sets"},
        {{"", 1, "user", nil}, "key must be a setting's name"}
      ]

      for {{key, value, scope, ws}, reason} <- refusals do
        assert {:error, said} = Settings.set(key, value, scope, ws)
        assert said =~ reason, inspect({key, said})
      end

      refute File.exists?(ctx.user)
      refute File.exists?(Config.local_path(ctx.ws))
    end

    test "leaves a file that does not parse alone", ctx do
      File.write!(ctx.user, "max_turns: [\n")
      assert {:error, reason} = Settings.set("max_turns", 3, "user", nil)
      assert reason =~ "fix it or move it aside"
      assert File.read!(ctx.user) == "max_turns: [\n"
    end
  end

  test "changed/2 names each key that differs, a block by its keys, and not the writer's own" do
    before = %{"max_turns" => 9, "models" => %{"default" => "a", "cheap" => "b"}}

    now = %{
      "version" => 1,
      "max_turns" => 9,
      "models" => %{"default" => "c", "cheap" => "b"},
      "ui" => %{"theme" => "x"}
    }

    assert Settings.changed(before, now) == ["models.default", "ui.theme"]
    assert Settings.changed(now, now) == []
    assert Settings.changed(%{"ui" => %{}}, %{}) == ["ui"]
  end
end
