defmodule Troupe.Gateway.PinAndRecentTest do
  @moduledoc """
  Two of a daemon's answers about its sessions (D125): `session.pin` marks a session
  pinned whether it is running or dormant, and the mark is kept beside its log, so it
  outlives the session going dormant; and `workspace.recent` answers at most `limit`
  workspaces.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Dispatch

  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-pin-#{System.unique_integer([:positive])}")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(base) end)

    fake = start_supervised!({Troupe.LLM.Fake, steps: [], default: {:text, "done"}})
    %{base: base, state_dir: state_dir, fake: fake}
  end

  test "a pin is kept beside the log: it outlives going dormant, and is set on a dormant session",
       context do
    session = start!(context, "one")

    assert {:ok, %{"pinned" => true}} =
             Dispatch.call("session.pin", %{"session_id" => session.id}, context(:admin))

    assert pinned?(session.id)

    # Dormant, it is read from its log, and the pin with it.
    :ok = Troupe.stop_session(session.id)
    assert pinned?(session.id)

    assert {:ok, %{"pinned" => false}} =
             Dispatch.call("session.unpin", %{"session_id" => session.id}, context(:admin))

    refute pinned?(session.id)

    assert {:ok, %{"pinned" => true}} =
             Dispatch.call("session.pin", %{"session_id" => session.id}, context(:admin))

    assert pinned?(session.id)
    assert Enum.find(listed(), &(&1["id"] == session.id))["pinned"] == true
  end

  test "a session that is nowhere cannot be pinned", _context do
    assert {:error, %{message: "not_found"}} =
             Dispatch.call(
               "session.pin",
               %{"session_id" => "20200101T000000-Nowher"},
               context(:admin)
             )
  end

  test "workspace.recent answers at most limit workspaces", context do
    start!(context, "one")
    start!(context, "two")

    assert {:ok, %{"workspaces" => all}} =
             Dispatch.call("workspace.recent", %{}, context(:observe))

    assert length(all) >= 2

    assert {:ok, %{"workspaces" => [_one]}} =
             Dispatch.call("workspace.recent", %{"limit" => 1}, context(:observe))
  end

  defp start!(context, name) do
    workspace = Path.join(context.base, name)
    File.mkdir_p!(workspace)

    {:ok, session} =
      Troupe.start_session(
        workspace: workspace,
        fake: context.fake,
        config_overrides: [
          provider: "fake",
          model: "fake-model",
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  defp pinned?(session_id) do
    assert {:ok, %{"pinned" => pinned}} =
             Dispatch.call("session.get", %{"session_id" => session_id}, context(:observe))

    pinned
  end

  defp listed do
    {:ok, %{"sessions" => sessions}} = Dispatch.call("session.list", %{}, context(:observe))
    sessions
  end

  defp context(scope) do
    scopes =
      case scope do
        :observe -> [:observe]
        :admin -> [:observe, :control, :admin]
      end

    %Dispatch.Context{
      principal: %{
        "subject" => "someone@example.test",
        "display_name" => "Someone",
        "kind" => "user"
      },
      scopes: scopes,
      connection: self(),
      next_subscription_id: "sub-1"
    }
  end
end
