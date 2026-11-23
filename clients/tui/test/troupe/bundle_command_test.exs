defmodule Troupe.BundleCommandTest do
  @moduledoc """
  `/bundle` and `/bundle update` (root #1177): a session on the platform says which bundle
  version it runs on and its channel's current one, and its owner raises it there, at the
  plane; the log's `config_upgraded` note says who raised it. A raise asked while the agent
  works is kept, and said so. A session on this computer has no bundle, and somebody who is
  not the owner is told whose it is to update.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Bundle
  alias Troupe.FakeRemote

  defp on_a_pod(fields) do
    events = [%{"type" => "llm_response", "data" => FakeRemote.said("first line")}]

    session =
      FakeRemote.session([id: "s-bundle", profile: "build", team: "eng", events: events] ++ fields)

    {remote, url} = start_remote!(sessions: [session])
    sid = attach!(connect!(remote, url), "s-bundle")
    {pid, screen} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {remote, sid, pid, screen}
  end

  defp notices(pid), do: user_state(pid).model.notices

  defp say(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  test "the owner hears both versions and raises it; the log's note says who" do
    {remote, sid, pid, _screen} = on_a_pod(bundle_version: 12, bundle_current: 14)

    say(pid, "/bundle")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "Configuration v12; v14 is current. /bundle update"))
    end)

    say(pid, "/bundle update")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "Configuration v14 now")) end)

    assert Enum.any?(
             FakeRemote.calls(remote),
             &match?({"session.bundle.raise", %{"session_id" => "s-bundle"}}, &1)
           )

    eventually(fn ->
      Enum.any?(
        Client.events(sid),
        &(&1.type == :remote_note and &1.data.text =~ "config upgraded from 12 to 14, raised by")
      )
    end)

    say(pid, "/bundle")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "Configuration v14, the current one.")) end)

    say(pid, "/bundle lower")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "/bundle or /bundle update: not lower")) end)
    refute Enum.any?(Client.events(sid), &(&1.type == :input))
  end

  test "a raise asked while the agent works is kept, and said so" do
    {_remote, _sid, pid, _screen} = on_a_pod(bundle_version: 12, bundle_current: 14, busy: true)

    say(pid, "/bundle update")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "it moves to v14 when the agent is done")) end)

    say(pid, "/bundle")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "Configuration v12; it moves to v14 when the agent is done."))
    end)
  end

  test "somebody who is not the owner is told whose it is to update" do
    {_remote, _sid, pid, _screen} =
      on_a_pod(owner: "bea", visibility: "team", bundle_version: 12, bundle_current: 14)

    say(pid, "/bundle")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "Configuration v12; v14 is current.")) end)
    refute Enum.any?(notices(pid), &(&1 =~ "/bundle update moves it"))

    say(pid, "/bundle update")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "only the session's owner updates its configuration"))
    end)
  end

  test "a session on this computer has no bundle" do
    {sid, _, _} = start_session!(script: [])
    assert {:error, refused} = Client.bundle(sid, :update)
    assert refused == Bundle.not_here()
  end

  test "a retired version's note says so" do
    {remote, sid, _pid, _screen} = on_a_pod([])

    FakeRemote.emit(remote, "s-bundle", "config_upgraded", %{
      "channel" => "stable",
      "from" => 3,
      "to" => 4,
      "hash" => "sha256:4",
      "reason" => "retired"
    })

    eventually(fn ->
      Enum.any?(
        Client.events(sid),
        &(&1.type == :remote_note and
            &1.data.text == "config upgraded from 3 to 4, its version retired")
      )
    end)
  end
end
