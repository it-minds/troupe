defmodule Troupe.SharedSettingsTest do
  @moduledoc """
  Issue #57's done-when, from the terminal's side: the default model changed in the
  desktop app changes it in a running terminal UI, and the other way round. The desktop
  app is a second protocol client on the daemon this VM embeds, sending what its model
  panel sends; the terminal UI is the real one on a headless screen.

  Not async: both write the machine's own `config.yaml`, which every test here reads, and
  each puts it back as it was.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client.Daemon.Link
  alias Troupe.Protocol.Client, as: Protocol

  setup do
    path = Troupe.Config.user_path()
    before = File.read!(path)

    on_exit(fn ->
      File.write!(path, before)
      File.rm(path <> ".previous")
    end)

    # A workspace whose own file names no default model, so the machine's is the one in
    # effect, as on a person's laptop.
    {sid, _fake, ws} = start_session!(config: %{"models" => %{}})
    %{sid: sid, ws: ws, desktop: desktop()}
  end

  test "a default model the desktop app saves shows on the terminal's open settings page", ctx do
    {pid, session} = start_tui(ctx.sid)
    type(pid, "/settings")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "settings —" end)
    refute screen_text(pid, session) =~ "desktop-pick"

    # What the desktop app's model panel sends when a person picks a model and saves.
    assert {:ok, %{"models" => %{"default" => "desktop-pick"}}} =
             Protocol.call(ctx.desktop, "config.set", %{
               "command_id" => "gui-#{System.unique_integer([:positive])}",
               "provider" => "fake",
               "models" => %{"default" => "desktop-pick"}
             })

    # The page that is open says so, with nothing pressed.
    eventually(fn -> model_row(pid, session) =~ "desktop-pick" end)
  end

  test "a default model picked on the terminal's settings page reaches the desktop app", ctx do
    {pid, session} = start_tui(ctx.sid)
    type(pid, "/settings")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "settings —" end)
    to_setting(pid, "models.default")
    press(pid, "enter")

    # The menu of detected models, when there is one, ends in "type one instead".
    case user_state(pid).settings.picker do
      nil ->
        :ok

      picker ->
        for _ <- 1..length(picker.choices)//1, do: press(pid, "down")
        press(pid, "enter")
    end

    editing = user_state(pid).settings.editing
    for _ <- 1..String.length(editing)//1, do: press(pid, "backspace")
    type(pid, "terminal-pick")
    press(pid, "enter")

    assert_receive {:troupe_notification, "config.changed", %{"keys" => keys}}, 5_000
    assert "models.default" in keys

    # What the desktop app's model panel reads.
    assert {:ok, %{"models" => %{"default" => "terminal-pick"}}} =
             Protocol.call(ctx.desktop, "config.get", %{})
  end

  # #228: the theme is the one the desktop app's appearance screen sets, `ui.theme`.
  test "a theme the desktop app picks is the one the running terminal draws in, with nothing pressed",
       ctx do
    {pid, _session} = start_tui(ctx.sid)
    desktop_set(ctx.desktop, "ui.theme", "footlight")
    eventually(fn -> theme_of(pid) == :footlight end)
  end

  test "a theme picked on the terminal's settings page is drawn at once and reaches the desktop app",
       ctx do
    {pid, session} = start_tui(ctx.sid)
    type(pid, "/settings")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "settings —" end)
    to_setting(pid, "ui.theme")
    press(pid, "enter")

    # A menu of the four, and no "type one instead": a theme is one of them or none.
    assert %{choices: choices, cursor: cursor, typed?: false} = user_state(pid).settings.picker
    assert Enum.map(choices, & &1.value) == ~w(afterglow signal footlight limelight)
    assert screen_text(pid, session) =~ "4 themes"
    refute screen_text(pid, session) =~ "type one instead"

    target = Enum.find_index(choices, &(&1.value == "limelight"))
    for _ <- 1..(target - cursor)//1, do: press(pid, "down")
    press(pid, "enter")

    assert theme_of(pid) == :limelight
    assert_receive {:troupe_notification, "config.changed", %{"keys" => keys}}, 5_000
    assert "ui.theme" in keys

    # What the desktop app's appearance screen reads.
    assert {:ok, %{"keys" => served}} = Protocol.call(ctx.desktop, "config.get", %{})
    assert %{"value" => "limelight"} = Enum.find(served, &(&1["key"] == "ui.theme"))
  end

  test "a theme the terminal does not know is drawn as Afterglow and said so once", ctx do
    {pid, _session} = start_tui(ctx.sid)
    set = fn key, value -> desktop_set(ctx.desktop, key, value) end

    set.("ui.theme", "signal")
    eventually(fn -> theme_of(pid) == :signal end)

    set.("ui.theme", "neon-noir")
    eventually(fn -> theme_of(pid) == :afterglow end)

    # Another `ui` key read again with the same unknown theme: nothing said twice.
    set.("ui.blink", false)
    eventually(fn -> user_state(pid).theme.blink == false end)

    said = Enum.filter(user_state(pid).model.notices, &(&1 =~ "neon-noir"))
    assert [notice] = said
    assert notice =~ "afterglow"
  end

  defp desktop_set(desktop, key, value) do
    assert {:ok, _} =
             Protocol.call(desktop, "config.set", %{
               "command_id" => "gui-#{System.unique_integer([:positive])}",
               "key" => key,
               "value" => value,
               "scope" => "user"
             })
  end

  defp theme_of(pid), do: pid |> user_state() |> Map.get(:theme, %{}) |> Map.get(:name)

  # The desktop app: a client of its own on the same daemon, which hears what it is sent.
  defp desktop do
    {:ok, endpoint} = Link.ensure()

    {:ok, client} =
      Troupe.Protocol.Daemon.connect(
        endpoint: endpoint,
        spawn: false,
        client_info: %{"name" => "troupe-gui", "version" => "1"}
      )

    on_exit(fn -> if Process.alive?(client), do: Protocol.close(client) end)
    client
  end

  defp model_row(pid, session) do
    pid
    |> screen(session)
    |> Enum.find("", &(&1 =~ ~r/^\W*model\s/))
  end
end
