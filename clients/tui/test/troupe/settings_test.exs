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
    # One key table (#57): the page's keys are the schema's, with its help. Of the `ui`
    # keys, the two the terminal acts on (#228).
    test "the page shows the schema's settings, by their labels and with their docs, but not the desktop app's" do
      expected =
        for {path, spec} <- Schema.settings(),
            hd(path) != "ui" or path in [~w(ui theme), ~w(ui blink)],
            do: {Enum.join(path, "."), spec.label, spec.doc}

      assert Enum.map(Settings.fields(), &{&1.key, &1.label, &1.help}) == expected
      refute Enum.any?(Settings.fields(), &(&1.key in ["ui.mode", "ui.notifications"]))
      assert {:ok, %{type: :model}} = Settings.fetch("models.default")
      assert {:ok, %{type: :bool, effect: :now}} = Settings.fetch("watch")
      assert {:ok, %{type: :theme, effect: :now}} = Settings.fetch("ui.theme")
      assert {:ok, %{type: :bool, effect: :now}} = Settings.fetch("ui.blink")
    end

    test "the theme is a menu of every theme the tokens define, in the desktop app's order" do
      {:ok, field} = Settings.fetch("ui.theme")
      choices = Settings.choices(field, %Config{}, "footlight")

      assert Enum.map(choices, & &1.value) == ~w(afterglow signal footlight limelight)
      assert Enum.map(choices, & &1.label) == ~w(Afterglow Signal Footlight Limelight)
      assert Enum.all?(choices, &(length(&1.notes) == 3))
    end

    # Issue #658: the provider is offered where a person picks one, here too, from the one
    # list of the types, each saying what else it needs. On the chunk's tip the page had no
    # provider at all.
    test "the provider is a menu of every type a person may pick, each saying what it needs" do
      assert {:ok, %{type: :provider} = field} = Settings.fetch("provider")
      choices = Settings.choices(field, %Config{}, "anthropic")

      assert Enum.map(choices, & &1.value) == Troupe.Protocol.ProviderTypes.named()

      assert Enum.map(choices, & &1.label) ==
               ~w(Anthropic OpenAI Ollama OpenRouter) ++ ["Azure OpenAI", "Gemini"]

      assert Enum.all?(choices, &(length(&1.notes) == 3))

      notes = Map.new(choices, &{&1.value, Enum.at(&1.notes, 1)})
      assert notes["ollama"] == "No key; http://localhost:11434 unless base_url says."
      assert notes["azure_openai"] =~ "Needs base_url, such as https://<resource>.openai.azure.com"
      assert notes["gemini"] == "A key, or GEMINI_API_KEY."

      # The fake is offered only where it is the provider already.
      refute "fake" in Enum.map(choices, & &1.value)
      assert "fake" in Enum.map(Settings.choices(field, %Config{}, "fake"), & &1.value)

      assert Settings.parse(field, " ollama ") == {:ok, "ollama"}
      assert {:error, "provider is one of anthropic, openai" <> _} = Settings.parse(field, "x")
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

      type(pid, "/settings")
      press(pid, "enter")

      text = screen_text(pid, session)
      assert text =~ "settings — a change goes to"
      assert text =~ "▸ provider"
      assert text =~ "model"
      assert text =~ "auto approve"
      assert text =~ ~r/max turns\s+40  · project/
      assert text =~ "set by: project (#{Path.join(ws, ".troupe/config.yaml")})"

      press(pid, "esc")
      assert user_state(pid).focus == :command
    end

    # Picking one writes it as any menu's pick does; a provider is a trusted key, which in
    # this suite's untrusted workspace goes to the user's file every test reads, so this
    # stops at the menu.
    test "Enter on the provider opens the provider types, starting on the one in use" do
      {sid, _fake, _ws} = start_session!(config: @own)
      {pid, session} = start_tui(sid)

      type(pid, "/settings")
      press(pid, "enter")
      to_setting(pid, "provider")
      assert screen_text(pid, session) =~ "Enter opens the provider types"
      press(pid, "enter")

      text = screen_text(pid, session)
      assert text =~ "7 provider types — Enter picks"
      assert text =~ "choose a provider type"
      assert text =~ "▸ The fake provider"

      for label <- ["Anthropic", "OpenAI", "Ollama", "OpenRouter", "Azure OpenAI", "Gemini"],
          do: assert(text =~ label, label)

      for _ <- 1..4, do: press(pid, "up")
      assert screen_text(pid, session) =~ "▸ Ollama"
      press(pid, "esc")
      refute user_state(pid).settings.picker
    end

    test "Enter toggles a boolean and persists it to the file it came from" do
      {sid, _fake, ws} = start_session!(auto_approve: false, config: @own)
      {pid, session} = start_tui(sid)

      type(pid, "/settings")
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

      type(pid, "/settings")
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

      type(pid, "/settings")
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
