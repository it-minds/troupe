defmodule Troupe.SettingsTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.{Config, Settings}
  alias Troupe.Config.Schema

  # The workspace's own file sets what these tests change, so the page writes there and
  # not into the user's file every other test of the run reads (`shared_settings_test.exs`
  # is the one about that file).
  @own %{"max_turns" => 40, "context_window" => 200_000}

  describe "schema" do
    # One key table (#57): the page's keys are the schema's, with its help.
    test "the page shows the schema's settings, by their labels and with their docs, but not the desktop app's" do
      expected =
        for {path, spec} <- Schema.settings(),
            hd(path) != "ui",
            do: {Enum.join(path, "."), spec.label, spec.doc}

      assert Enum.map(Settings.fields(), &{&1.key, &1.label, &1.help}) == expected
      refute Enum.any?(Settings.fields(), &String.starts_with?(&1.key, "ui."))
      assert {:ok, %{type: :model}} = Settings.fetch("models.default")
      assert {:ok, %{type: :bool, effect: :now}} = Settings.fetch("watch")
    end

    test "every field reads back out of a default config and formats" do
      cfg = %Config{}
      view = Settings.view(%{})

      for field <- Settings.fields() do
        # `nil` is a real value for the cheap and expensive models: it means the default.
        inherits? = field.key in ["models.cheap", "models.expensive"]
        assert Settings.value(view, cfg, field.key) != nil or inherits?, field.key
        assert is_binary(Settings.format(view, cfg, field.key)), field.key
      end

      assert Settings.mouse?(cfg)
      assert Settings.format(view, cfg, "mouse") == "on"
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

    # A change goes where the person said; else to the file its value came from, so that
    # it takes effect; else to the user's.
    test "where a change goes" do
      view =
        Settings.view(%{
          "keys" => [
            %{
              "key" => "max_turns",
              "value" => 9,
              "layer" => "project",
              "scopes" => ~w(user project local)
            },
            %{
              "key" => "max_depth",
              "value" => 3,
              "layer" => "default",
              "scopes" => ~w(user project local)
            },
            %{"key" => "auto_approve", "value" => true, "layer" => "env", "scopes" => ["user"]}
          ],
          "files" => [%{"scope" => "user", "path" => "/home/me/.config/troupe/config.yaml"}]
        })

      assert Settings.value(view, %Config{}, "max_turns") == 9
      assert Settings.target(view, "max_turns", nil) == "project"
      assert Settings.target(view, "max_depth", nil) == "user"
      assert Settings.target(view, "auto_approve", nil) == "user"
      assert Settings.target(view, "max_turns", "local") == "local"
      assert Settings.target(view, "auto_approve", "project") == "user"

      assert Settings.next_scope(view, "max_turns", nil) == "local"
      assert Settings.next_scope(view, "max_turns", "local") == "user"
      assert Settings.next_scope(view, "auto_approve", nil) == "user"
    end

    # The help beside the settings named commands in prose that could drift from the
    # table the palette is drawn from (defects D32); its commands are the table's now.
    test "the help's commands are the setup section of the command table" do
      table = Troupe.Commands.list()
      lines = Settings.help_lines(table)

      for %{"section" => "setup", "name" => name, "summary" => summary} <- table do
        assert Enum.any?(lines, &(&1 =~ "/#{name} " and String.ends_with?(&1, summary))), name
      end

      assert "Setup commands" in lines
      refute "Setup commands" in Settings.help_lines([])
      assert "Keys" in Settings.help_lines([])
    end

    test "unknown keys are reported, not raised" do
      assert :error = Settings.fetch("nope")
    end
  end

  describe "the settings page" do
    test "/settings shows values, where they came from, and the curated help, and Esc goes back" do
      {sid, _fake, ws} = start_session!(config: @own)
      {pid, session} = start_tui(sid)

      type(pid, "settings")
      press(pid, "enter")

      text = screen_text(pid, session)
      assert text =~ "settings — a change goes to"
      assert text =~ "▸ model"
      assert text =~ "auto approve"
      assert text =~ ~r/max turns\s+40  · project/
      assert text =~ "set by: project (#{Path.join(ws, ".troupe/config.yaml")})"

      press(pid, "esc")
      assert user_state(pid).focus == :command
    end

    test "Enter toggles a boolean and persists it to the file it came from" do
      {sid, _fake, ws} = start_session!(auto_approve: false, config: @own)
      {pid, session} = start_tui(sid)

      type(pid, "settings")
      press(pid, "enter")
      to_setting(pid, "auto_approve")
      assert screen_text(pid, session) =~ "auto approve"

      press(pid, "enter")
      eventually(fn -> screen_text(pid, session) =~ "auto_approve = on · saved to" end)
      assert Config.load(ws).auto_approve
      assert File.read!(Path.join(ws, ".troupe/config.yaml")) =~ "auto_approve: true"
    end

    test "Enter edits a number, rejecting a bad value without changing anything" do
      {sid, _fake, ws} = start_session!(config: @own)
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

    test "s moves where a change goes, and the change goes there" do
      {sid, _fake, ws} = start_session!(config: @own)
      {pid, session} = start_tui(sid)

      type(pid, "settings")
      press(pid, "enter")
      to_setting(pid, "context_window")
      assert screen_text(pid, session) =~ "a change goes to project:"

      # project, then local, the git-ignored file beside it.
      press(pid, "s")
      local = Path.join(ws, ".troupe/config.local.yaml")
      assert screen_text(pid, session) =~ "a change goes to local (#{local})"

      press(pid, "enter")
      for _ <- 1..6, do: press(pid, "backspace")
      type(pid, "100000")
      press(pid, "enter")

      eventually(fn -> File.exists?(local) and File.read!(local) =~ "context_window: 100000" end)
      assert Config.load(ws).context_window == 100_000
      refute File.read!(Path.join(ws, ".troupe/config.yaml")) =~ "100000"
      eventually(fn -> screen_text(pid, session) =~ ~r/context window\s+100000  · local/ end)
    end
  end
end
