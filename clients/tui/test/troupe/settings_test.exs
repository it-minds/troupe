defmodule Troupe.SettingsTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.{Config, Settings}

  # A project config file makes the settings page write there instead of the
  # (shared) global one, which keeps these tests independent of each other.
  defp workspace_with_config(yaml \\ "max_turns: 40\n") do
    tmp_workspace(%{".troupe/config.yaml" => yaml})
  end

  describe "schema" do
    test "every field reads back out of a default config and formats" do
      cfg = %Config{}

      for field <- Settings.fields() do
        # `nil` is a real value for the cheap and expensive models: it means the default.
        inherits? = field.key in ["models.cheap", "models.expensive"]
        assert Settings.get(cfg, field.key) != nil or inherits?, field.key
        assert is_binary(Settings.format(cfg, field.key)), field.key
      end

      assert Settings.mouse?(cfg)
      assert Settings.format(cfg, "mouse") == "on"
    end

    test "parse validates per type" do
      {:ok, bool} = Settings.fetch("auto_approve")
      assert Settings.parse(bool, "on") == {:ok, true}
      assert Settings.parse(bool, "No") == {:ok, false}
      assert {:error, _} = Settings.parse(bool, "maybe")

      {:ok, int} = Settings.fetch("max_turns")
      assert Settings.parse(int, " 12 ") == {:ok, 12}
      assert {:error, msg} = Settings.parse(int, "lots")
      assert msg =~ "whole number"
      assert {:error, _} = Settings.parse(int, "0")

      {:ok, float} = Settings.fetch("compact_at")
      assert Settings.parse(float, "0.5") == {:ok, 0.5}
      assert {:error, _} = Settings.parse(float, "2")

      {:ok, model} = Settings.fetch("models.default")
      assert Settings.parse(model, "gateway/opus") == {:ok, "gateway/opus"}
      assert {:error, _} = Settings.parse(model, "")

      {:ok, cheap} = Settings.fetch("models.cheap")
      assert Settings.parse(cheap, "default") == {:ok, nil}
    end

    test "put changes the field, marks an explicit default model, and sets mouse" do
      cfg = %Config{}
      assert %Config{max_turns: 3} = Settings.put(cfg, "max_turns", 3)
      assert %Config{model: "x", models_explicit?: true} = Settings.put(cfg, "models.default", "x")
      assert %Config{mouse: false} = off = Settings.put(cfg, "mouse", false)
      refute Settings.mouse?(off)
    end

    test "unknown keys are reported, not raised" do
      assert :error = Settings.fetch("nope")
      assert {:error, msg} = Settings.persist(tmp_workspace(), "nope", 1)
      assert msg =~ "unknown setting"
    end
  end

  describe "persistence" do
    test "writes to the project config and Config.load reads it back" do
      ws = workspace_with_config()
      {:ok, path} = Settings.persist(ws, "max_turns", 3)
      assert path == Path.join(ws, ".troupe/config.yaml")
      assert Config.load(ws).max_turns == 3

      {:ok, _} = Settings.persist(ws, "models.default", "gateway/opus")
      assert Config.load(ws).model == "gateway/opus"
      # the other keys in the file survive a write
      assert File.read!(path) =~ "max_turns: 3"
    end

    test "falls back to the global config file when the project has none" do
      ws = tmp_workspace()
      {:ok, path} = Settings.persist(ws, "auto_approve", true)
      assert path == Path.join(Troupe.Paths.config_dir(), "config.yaml")
      assert Config.load(ws).auto_approve
      {:ok, _} = Settings.persist(ws, "auto_approve", false)
    end

    test "mouse defaults to on and persists off" do
      ws = workspace_with_config()
      assert Settings.mouse?(Config.load(ws))
      {:ok, _} = Settings.persist(ws, "mouse", false)
      refute Settings.mouse?(Config.load(ws))
    end

    test "writes the new spelling only, replacing the old one, with version and the schema header" do
      ws =
        workspace_with_config(
          "# hand-written\nmodel: old-default\nsmall_model: old-cheap\nmax_turns: 5\n"
        )

      {:ok, path} = Settings.persist(ws, "models.default", "gateway/opus")

      {:ok, written} = YamlElixir.read_from_file(path)
      assert written["models"] == %{"default" => "gateway/opus", "cheap" => "old-cheap"}
      refute Map.has_key?(written, "model")
      refute Map.has_key?(written, "small_model")
      assert written["version"] == 1
      assert File.read!(path) =~ "# yaml-language-server: $schema="
      assert File.read!(path <> ".previous") =~ "# hand-written"

      config = Config.load(ws)

      assert {config.model, config.small_model, config.max_turns, config.warnings} ==
               {"gateway/opus", "old-cheap", 5, []}
    end

    test "writes auto_approve to the user's file while the workspace is not trusted" do
      # The suite trusts the temp directory; this workspace is outside it.
      ws = Path.join([File.cwd!(), "tmp", "untrusted-#{System.unique_integer([:positive])}"])
      File.mkdir_p!(Path.join(ws, ".troupe"))
      File.write!(Path.join(ws, ".troupe/config.yaml"), "max_turns: 5\n")
      on_exit(fn -> File.rm_rf(ws) end)

      refute Config.trusted?(ws)
      assert Settings.target_path(ws, "auto_approve") == Config.user_path()
      assert Settings.target_path(ws, "max_turns") == Path.join(ws, ".troupe/config.yaml")
    end
  end

  describe "the settings page" do
    test "/settings shows values and the curated help, and Esc goes back" do
      ws = workspace_with_config()
      {sid, _fake, _ws} = start_session!(workspace: ws)
      {pid, session} = start_tui(sid)

      type(pid, "settings")
      press(pid, "enter")

      text = screen_text(pid, session)
      assert text =~ "settings —"
      assert text =~ "▸ auto approve"
      assert text =~ "max turns"

      press(pid, "esc")
      assert user_state(pid).focus == :command
    end

    test "Enter toggles a boolean and persists it to the workspace's config" do
      ws = workspace_with_config()
      {sid, _fake, _ws} = start_session!(workspace: ws, auto_approve: false)
      {pid, session} = start_tui(sid)

      type(pid, "settings")
      press(pid, "enter")
      assert screen_text(pid, session) =~ "auto approve"

      press(pid, "enter")
      eventually(fn -> screen_text(pid, session) =~ "auto_approve = on · saved to" end)
      assert Config.load(ws).auto_approve
    end

    test "Enter edits a number, rejecting a bad value without changing anything" do
      ws = workspace_with_config()
      {sid, _fake, _ws} = start_session!(workspace: ws)
      {pid, session} = start_tui(sid)

      type(pid, "settings")
      press(pid, "enter")
      to_setting(pid, "max_turns")

      press(pid, "enter")
      assert screen_text(pid, session) =~ "max_turns = (Enter saves, Esc cancels)"

      for _ <- 1..2, do: press(pid, "backspace")
      type(pid, "lots")
      press(pid, "enter")
      assert screen_text(pid, session) =~ "max_turns must be a whole number"
      assert Config.load(ws).max_turns == 40

      press(pid, "esc")
      press(pid, "enter")
      for _ <- 1..2, do: press(pid, "backspace")
      type(pid, "3")
      press(pid, "enter")

      eventually(fn -> Config.load(ws).max_turns == 3 end)
    end
  end
end
