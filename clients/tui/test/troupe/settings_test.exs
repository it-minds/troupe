defmodule Troupe.SettingsTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.{Config, Settings}
  alias Troupe.Session.Approvals

  # A project config file makes the settings page write there instead of the
  # (shared) global one, which keeps these tests independent of each other.
  defp workspace_with_config(yaml \\ "max_branches: 8\n") do
    ws = tmp_workspace(%{".troupe/config.yaml" => yaml})
    ws
  end

  describe "schema" do
    test "every field reads back out of a default config and formats" do
      cfg = %Config{}

      for field <- Settings.fields() do
        # `nil` is a real value for an override that means "inherit"; every other
        # field must have a default, and all of them must render.
        assert Settings.get(cfg, field.key) != nil or field.type == :effort, field.key
        assert is_binary(Settings.format(cfg, field.key)), field.key
      end
    end

    test "parse validates per type" do
      {:ok, bool} = Settings.fetch("auto_approve")
      {:ok, int} = Settings.fetch("max_branches")
      {:ok, float} = Settings.fetch("compaction.fraction")
      {:ok, string} = Settings.fetch("models.default")

      assert {:ok, true} = Settings.parse(bool, "on")
      assert {:ok, false} = Settings.parse(bool, "NO")
      assert {:error, "expected on or off"} = Settings.parse(bool, "maybe")

      assert {:ok, 12} = Settings.parse(int, " 12 ")
      assert {:error, msg} = Settings.parse(int, "0")
      assert msg =~ "positive"
      assert {:error, _} = Settings.parse(int, "eight")

      assert {:ok, 0.6} = Settings.parse(float, "0.6")
      assert {:error, _} = Settings.parse(float, "1.4")

      assert {:ok, "gw/gpt-5"} = Settings.parse(string, "gw/gpt-5")
      assert {:error, _} = Settings.parse(string, "   ")
    end

    test "put updates nested values and marks an explicit default model" do
      cfg = Settings.put(%Config{}, "compaction.fraction", 0.5)
      assert cfg.compaction.fraction == 0.5
      assert cfg.compaction.keep_last_turns == %Config{}.compaction.keep_last_turns

      cfg = Settings.put(cfg, "models.default", "gw/gpt-5")
      assert cfg.models.default == "gw/gpt-5"
      assert cfg.models_explicit?
    end

    test "unknown keys are reported, not raised" do
      assert :error = Settings.fetch("nope")
    end
  end

  describe "persistence" do
    test "writes to the project config and Config.load reads it back" do
      ws = workspace_with_config("max_branches: 8\nmodels:\n  cheap: tiny\n")

      assert {:ok, path} = Settings.persist(ws, "compaction.fraction", 0.5)
      assert path == Path.join([ws, ".troupe", "config.yaml"])
      assert {:ok, _} = Settings.persist(ws, "models.default", "gw/gpt-5")
      assert {:ok, _} = Settings.persist(ws, "auto_approve", true)

      cfg = Config.load(ws)
      assert cfg.compaction.fraction == 0.5
      assert cfg.models.default == "gw/gpt-5"
      assert cfg.auto_approve
      # untouched keys survive the rewrite
      assert cfg.max_branches == 8
      assert cfg.models.cheap == "tiny"
    end

    test "falls back to the global config file when the project has none" do
      ws = tmp_workspace()
      assert Settings.target_path(ws) == Path.join(Troupe.Paths.config_dir(), "config.yaml")
    end
  end

  describe "put_setting on a live session" do
    test "auto approve reaches the approvals gate and the config file" do
      ws = workspace_with_config()
      {sid, _fake, _ws} = start_session!(workspace: ws)

      refute Approvals.session_allowed?(sid, "write_file")

      assert {:ok, cfg, path} = Troupe.put_setting(sid, "auto_approve", true)
      assert cfg.auto_approve
      assert path == Path.join([ws, ".troupe", "config.yaml"])
      assert Approvals.session_allowed?(sid, "write_file")

      assert {:ok, _cfg, _path} = Troupe.put_setting(sid, "auto_approve", false)
      refute Approvals.session_allowed?(sid, "write_file")
    end

    test "watch mode toggles the watcher, and the dispatcher keeps the new config" do
      ws = workspace_with_config()
      {sid, _fake, _ws} = start_session!(workspace: ws)

      assert {:ok, _cfg, _path} = Troupe.put_setting(sid, "watch.enabled", true)
      assert %{enabled: true} = Troupe.Session.Watcher.status(sid)

      assert {:ok, cfg, _path} = Troupe.put_setting(sid, "max_branches", 2)
      assert cfg.max_branches == 2
      assert {^ws, %Config{max_branches: 2}} = Troupe.config(sid)

      assert {:ok, _cfg, _path} = Troupe.put_setting(sid, "watch.enabled", false)
      assert %{enabled: false} = Troupe.Session.Watcher.status(sid)
    end

    test "max branches applies to the next dispatch" do
      ws = workspace_with_config()

      {sid, _fake, _ws} =
        start_session!(
          workspace: ws,
          scripts: %{
            "code-1" => [{:delay, 60_000, {:finish, "never"}}],
            "code-2" => [{:delay, 60_000, {:finish, "never"}}]
          }
        )

      assert {:ok, _cfg, _path} = Troupe.put_setting(sid, "max_branches", 1)
      assert {:ok, "code-1"} = Troupe.dispatch(sid, "code", "one")
      assert {:error, msg} = Troupe.dispatch(sid, "code", "two")
      assert msg =~ "max_branches (1)"
    end

    test "an unknown key is refused" do
      {sid, _fake, _ws} = start_session!(workspace: workspace_with_config())
      assert {:error, "unknown setting nope"} = Troupe.put_setting(sid, "nope", 1)
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
      assert text =~ "max branches"
      assert text =~ "applies immediately"
      # curated help, not just the selected setting's own text
      assert text =~ "What Troupe is"
      assert text =~ "Dispatching work"
      assert text =~ "y / n / a"
      assert text =~ "Enter/Space toggles"

      press(pid, "esc")
      assert user_state(pid).focus == :command
      refute screen_text(pid, session) =~ "What Troupe is"
    end

    test "the help follows the cursor" do
      {sid, _fake, _ws} = start_session!(workspace: workspace_with_config())
      {pid, session} = start_tui(sid)

      type(pid, "help")
      press(pid, "enter")
      assert screen_text(pid, session) =~ "Run every tool call without asking"

      to_setting(pid, "max_branches")
      text = screen_text(pid, session)
      assert text =~ "max branches  (max_branches)"
      assert text =~ "How many branches may be running"
    end

    test "Enter toggles a boolean, applies it live and persists it" do
      ws = workspace_with_config()
      {sid, _fake, _ws} = start_session!(workspace: ws)
      {pid, session} = start_tui(sid)

      type(pid, "settings")
      press(pid, "enter")
      assert screen_text(pid, session) =~ "auto approve               off"

      press(pid, "enter")
      text = screen_text(pid, session)
      assert text =~ "auto approve               on"
      assert text =~ "auto_approve = on · saved to"
      assert Approvals.session_allowed?(sid, "shell")
      assert Config.load(ws).auto_approve
    end

    test "Enter edits a number, rejecting a bad value without changing anything" do
      ws = workspace_with_config()
      {sid, _fake, _ws} = start_session!(workspace: ws)
      {pid, session} = start_tui(sid)

      type(pid, "settings")
      press(pid, "enter")
      to_setting(pid, "max_branches")

      press(pid, "enter")
      assert screen_text(pid, session) =~ "max_branches = (Enter saves, Esc cancels)"

      # clear "8" and type a bad value
      press(pid, "backspace")
      type(pid, "lots")
      press(pid, "enter")
      text = screen_text(pid, session)
      assert text =~ "max_branches must be a whole number"
      assert {_ws, %Config{max_branches: 8}} = Troupe.config(sid)

      press(pid, "esc")
      press(pid, "enter")
      press(pid, "backspace")
      type(pid, "3")
      press(pid, "enter")

      assert screen_text(pid, session) =~ "max branches               3"
      assert {_ws, %Config{max_branches: 3}} = Troupe.config(sid)
      assert Config.load(ws).max_branches == 3
    end

    test "PgDn scrolls the help" do
      {sid, _fake, _ws} = start_session!(workspace: workspace_with_config())
      {pid, session} = start_tui(sid)

      type(pid, "settings")
      press(pid, "enter")
      before = screen_text(pid, session)

      press(pid, "page_down")
      assert screen_text(pid, session) != before
      assert user_state(pid).settings.scroll == 5
    end
  end
end

defmodule Troupe.ModelMenuTest do
  @moduledoc "Decision 51: every configured model is detected and pickable."

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.{Config, Settings}

  @opencode """
  {
    "model": "portal/glm-5.2",
    "provider": {
      "portal": {
        "options": { "baseURL": "https://llm-gw.example/v1" },
        "models": {
          "glm-5.2": { "limit": { "context": 100000 } },
          "qwen": { "limit": { "context": 50000 } }
        }
      },
      "keyless": { "options": { "baseURL": "https://nope.example/v1" } }
    }
  }
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "troupe-models-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    config = Path.join(dir, "opencode.jsonc")
    auth = Path.join(dir, "auth.json")
    File.write!(config, @opencode)
    File.write!(auth, Jason.encode!(%{"portal" => %{"type" => "api", "key" => "portal-key"}}))
    System.put_env("TROUPE_OPENCODE_CONFIG", config)
    System.put_env("TROUPE_OPENCODE_AUTH", auth)

    on_exit(fn ->
      System.delete_env("TROUPE_OPENCODE_CONFIG")
      System.delete_env("TROUPE_OPENCODE_AUTH")
      File.rm_rf(dir)
    end)

    :ok
  end

  test "models are detected from opencode and from config.yaml providers, with context and key status" do
    ws =
      tmp_workspace(%{
        ".troupe/config.yaml" => """
        providers:
          local:
            type: openai
            base_url: http://localhost:11434/v1
            models:
              qwen3-coder:
                context: 32000
        """
      })

    cfg = Config.load(ws)
    ids = Enum.map(Config.models(cfg), & &1.id)

    assert "portal/glm-5.2" in ids
    assert "portal/qwen" in ids
    assert "local/qwen3-coder" in ids
    assert "keyless/" in ids, "a provider that lists no models is still offered by name"
    assert cfg.models.default in ids, "the model in use is always in the list"

    portal = Enum.find(Config.models(cfg), &(&1.id == "portal/glm-5.2"))
    assert portal.context == 100_000
    assert portal.source == :opencode
    assert portal.key?
    assert Config.describe_model(portal) == "100k ctx · opencode"

    keyless = Enum.find(Config.models(cfg), &(&1.id == "keyless/"))
    refute keyless.key?
    assert Config.describe_model(keyless) =~ "no key"

    local = Enum.find(Config.models(cfg), &(&1.id == "local/qwen3-coder"))
    assert local.source == :yaml
    assert Config.describe_model(local) =~ "32k ctx"

    # `troupe config` prints them, marking the one in use
    described = Config.describe(cfg)
    assert described =~ "models Troupe can address"
    assert described =~ "portal/qwen"
    assert described =~ "<- default"
  end

  test "/models opens a menu of the detected models and picking one saves it" do
    ws = tmp_workspace(%{".troupe/config.yaml" => "max_branches: 8\n"})
    {sid, _, _} = start_session!(workspace: ws)
    {pid, session} = start_tui(sid)

    type(pid, "models")
    press(pid, "enter")

    assert user_state(pid).focus == :settings
    s = user_state(pid).settings
    assert s.picker, "the menu is open"
    assert Enum.at(Settings.fields(), s.cursor).key == "models.default"

    text = screen_text(pid, session)
    assert text =~ "models detected"
    assert text =~ "portal/glm-5.2"
    assert text =~ "100k ctx · opencode"
    assert text =~ "keyless/"
    assert text =~ "no key"
    assert text =~ "type one instead"
    assert text =~ "Enter picks"

    # the model in use is offered first, so picking straight away changes nothing
    assert hd(s.picker.choices).value == s.config.models.default

    # a narrow terminal shortens each note rather than clipping it mid-word
    {narrow, narrow_session} = start_tui(sid, width: 80, height: 24)
    type(narrow, "models")
    press(narrow, "enter")
    narrow_text = screen_text(narrow, narrow_session)
    assert narrow_text =~ "portal/qwen"
    assert narrow_text =~ "no key"
    refute narrow_text =~ "no ke\n", "a note is never cut in half"

    cursor = Enum.find_index(s.picker.choices, &(&1.value == "portal/qwen"))
    for _ <- 1..cursor, do: press(pid, "down")
    press(pid, "enter")

    assert user_state(pid).settings.picker == nil
    assert Settings.get(user_state(pid).settings.config, "models.default") == "portal/qwen"
    assert screen_text(pid, session) =~ "models.default = portal/qwen"
    assert File.read!(Path.join([ws, ".troupe", "config.yaml"])) =~ ~s(default: "portal/qwen")

    # and the session uses it for branches dispatched from now on
    {_ws, cfg} = Troupe.config(sid)
    assert cfg.models.default == "portal/qwen"
  end

  test "the entry past the last model types one instead, and Esc leaves the menu" do
    ws = tmp_workspace(%{".troupe/config.yaml" => "max_branches: 8\n"})
    {sid, _, _} = start_session!(workspace: ws)
    {pid, session} = start_tui(sid)

    type(pid, "models")
    press(pid, "enter")
    press(pid, "esc")
    assert user_state(pid).settings.picker == nil
    assert user_state(pid).focus == :settings, "Esc closes the menu, not the page"

    press(pid, "enter")
    n = length(user_state(pid).settings.picker.choices)
    for _ <- 1..(n + 2), do: press(pid, "down")
    press(pid, "enter")

    assert user_state(pid).settings.picker == nil
    assert is_binary(user_state(pid).settings.editing), "it fell back to typing"

    for _ <- 1..40, do: press(pid, "backspace")
    type(pid, "gw/gpt-5")
    press(pid, "enter")
    assert Settings.get(user_state(pid).settings.config, "models.default") == "gw/gpt-5"
    assert screen_text(pid, session) =~ "gw/gpt-5"

    # a typed model is in the menu next time it opens
    press(pid, "enter")
    assert hd(user_state(pid).settings.picker.choices).value == "gw/gpt-5"
  end

  test "the cheap model has the same menu, and the wheel moves it" do
    ws = tmp_workspace(%{".troupe/config.yaml" => "max_branches: 8\n"})
    {sid, _, _} = start_session!(workspace: ws)
    {pid, _session} = start_tui(sid)

    type(pid, "settings")
    press(pid, "enter")
    cheap = Enum.find_index(Settings.fields(), &(&1.key == "models.cheap"))
    for _ <- 1..cheap, do: press(pid, "down")
    press(pid, "enter")

    assert user_state(pid).settings.picker
    wheel(pid, :down)
    assert user_state(pid).settings.picker.cursor == 1
    wheel(pid, :up)
    assert user_state(pid).settings.picker.cursor == 0

    press(pid, "down")
    choice = Enum.at(user_state(pid).settings.picker.choices, 1)
    press(pid, "enter")
    assert Settings.get(user_state(pid).settings.config, "models.cheap") == choice.value
  end
end
