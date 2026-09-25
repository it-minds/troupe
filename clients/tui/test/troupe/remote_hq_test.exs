defmodule Troupe.RemoteHQTest do
  @moduledoc """
  Done items 2, 7 and 8: what `troupe --remote` shows, what a viewer token is
  allowed to do, and what happens when the plane goes away.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.FakeRemote

  @moduletag :remote

  defp sessions do
    [
      FakeRemote.session(
        id: "s-alpha",
        title: "port the parser",
        team: "core",
        profile: "code",
        state: "active",
        status: "running",
        events: [%{"type" => "message.completed", "data" => %{"text" => "working on it"}}]
      ),
      FakeRemote.session(
        id: "s-beta",
        title: "audit the config",
        team: "core",
        profile: "plan",
        state: "dormant",
        status: "asleep"
      )
    ]
  end

  defp profiles do
    [
      %{
        "name" => "code",
        "description" => "writes code",
        "health" => "ok",
        "capacity" => %{"free" => 3, "total" => 4}
      },
      %{
        "name" => "plan",
        "description" => "plans work",
        "health" => "degraded",
        "capacity" => %{"free" => 0, "total" => 2}
      }
    ]
  end

  defp local_session! do
    ws = tmp_workspace()

    {sid, _fake, _ws} =
      start_session!(
        workspace: ws,
        script: [{:text, "did the local thing"}, {:finish, "did the local thing"}],
        auto_approve: true
      )

    say!(sid, "a local errand")
    await_done()
    {sid, ws}
  end

  describe "troupe --remote" do
    test "lists exactly what FakeRemote returns, with local sessions alongside and labelled" do
      {remote, url} =
        start_remote!(
          sessions: sessions(),
          profiles: profiles(),
          teams: [%{"id" => "core", "name" => "Core"}, %{"id" => "ops", "name" => "Ops"}]
        )

      login!(remote, url)
      {sid, ws} = local_session!()

      {pid, screen} = start_tui(sid, page: :hq, plane: url)
      text = screen_text(pid, screen)

      # teams, as the plane returns them
      assert text =~ "Core"
      assert text =~ "Ops"

      # profiles with health and capacity
      assert text =~ "code"
      assert text =~ "ok"
      assert text =~ "3/4 free"
      assert text =~ "plan"
      assert text =~ "degraded"
      assert text =~ "0/2 free"

      # remote sessions with their state
      assert text =~ "port the parser"
      assert text =~ "active"
      assert text =~ "audit the config"
      assert text =~ "dormant"

      # and this machine's own session, clearly labelled
      assert text =~ Path.basename(ws)
      assert text =~ "local"
      assert text =~ "remote"

      hq = user_state(pid).hq
      assert Enum.map(hq.sessions, & &1.id) == ["s-alpha", "s-beta", sid]

      assert Enum.map(hq.sessions, & &1.origin) == [
               {:remote, url},
               {:remote, url},
               local_origin(hq)
             ]

      assert match?({:local, _}, local_origin(hq))

      GenServer.stop(pid, :normal)
    end

    test "Enter on a remote row attaches it and the window takes the screen" do
      {remote, url} = start_remote!(sessions: sessions(), profiles: profiles())
      login!(remote, url)
      {sid, _ws} = local_session!()

      {pid, screen} = start_tui(sid, page: :hq, plane: url)
      assert user_state(pid).focus == :hq

      press(pid, "enter")

      eventually(fn -> user_state(pid).session_id == "s-alpha" end)
      state = user_state(pid)
      assert state.focus == :command
      assert state.hq == nil

      eventually(fn -> screen_text(pid, screen) =~ "working on it" end)
      GenServer.stop(pid, :normal)
    end

    test "the wizard creates a session with the chosen profile, source and prompt, then attaches" do
      {remote, url} = start_remote!(sessions: sessions(), profiles: profiles())
      login!(remote, url)
      {sid, _ws} = local_session!()

      {pid, _screen} = start_tui(sid, page: :hq, plane: url)

      press(pid, "n")
      assert user_state(pid).hq.create.step == :profile
      press(pid, "enter")

      assert user_state(pid).hq.create.profile == "code"
      assert user_state(pid).hq.create.step == :source
      press(pid, "enter")

      assert user_state(pid).hq.create.step == :visibility
      press(pid, "down")
      assert user_state(pid).hq.create.visibility == "team"
      press(pid, "enter")

      type(pid, "ship it")
      press(pid, "enter")

      eventually(fn -> user_state(pid).session_id != sid end)

      assert [params] = for({"session.create", p} <- FakeRemote.calls(remote), do: p)
      assert params["profile"] == "code"
      # chosen by id in HQ, sent by name, which is what the plane matches on
      assert params["team"] == "Core"
      assert params["visibility"] == "team"
      assert params["prompt"] == "ship it"
      assert params["source"] == %{"type" => "empty"}
      assert params["command_id"] != nil

      GenServer.stop(pid, :normal)
    end
  end

  describe "a viewer token" do
    test "disables input and approval, and an injected -32004 is handled gracefully" do
      {remote, url} = start_remote!(sessions: sessions(), scopes: ["observe"])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-alpha")

      capability = Client.capability(sid)
      refute capability.can_input?
      refute capability.can_approve?
      assert capability.reason =~ "observe"
      assert capability.scopes == ["observe"]

      FakeRemote.fail_next(remote, "input.send", -32_004, "control scope required")
      assert {:error, message} = Client.send_input(sid, "code-1", "let me in")
      assert message =~ "not allowed"
      assert message =~ "control scope required"

      # the connection survives a refusal
      assert Client.capability(sid).up?
    end

    test "the window says why input is off" do
      {remote, url} = start_remote!(sessions: sessions(), scopes: ["observe"])
      origin = connect!(remote, url)
      sid = attach!(origin, "s-alpha")
      eventually(fn -> Client.events(sid) != [] end)

      {pid, screen} = start_tui(sid)
      press(pid, "1")
      text = screen_text(pid, screen)

      assert text =~ "observe"
      refute user_state(pid).model.remote == nil
      GenServer.stop(pid, :normal)
    end
  end

  describe "degraded mode" do
    test "with the plane stopped an attached session keeps streaming and HQ says what is off" do
      {remote, url} = start_remote!(sessions: sessions(), profiles: profiles())
      origin = connect!(remote, url)
      sid = attach!(origin, "s-alpha")
      eventually(fn -> Client.capability(sid).up? end)

      {pid, screen} = start_tui(sid)
      FakeRemote.plane(remote, :down)
      eventually(fn -> Client.fleet_status(origin).up? == false end)

      # the attached session is untouched by the plane going away
      FakeRemote.emit(remote, "s-alpha", "message.completed", %{"text" => "still here"})
      eventually(fn -> screen_text(pid, screen) =~ "still here" end)
      assert Client.capability(sid).up?

      # and HQ says exactly what is unavailable
      type(pid, "hq")
      press(pid, "enter")
      eventually(fn -> user_state(pid).focus == :hq end)
      text = screen_text(pid, screen)

      assert text =~ "plane is unreachable"
      assert text =~ "creating and activating"

      # the sessions it already knew about are still listed
      assert text =~ "port the parser"
      GenServer.stop(pid, :normal)
    end
  end

  defp local_origin(hq), do: hq.sessions |> List.last() |> Map.fetch!(:origin)
end
