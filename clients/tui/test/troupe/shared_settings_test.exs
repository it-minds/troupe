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
    type(pid, "settings")
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
    type(pid, "settings")
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
