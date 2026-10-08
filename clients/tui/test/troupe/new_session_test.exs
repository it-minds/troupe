defmodule Troupe.NewSessionTest do
  @moduledoc """
  Issue #484, root Decision 812, TUI Decision 151: `/new` opens a fresh session in the
  workspace without leaving the TUI, and the session it left keeps running, stays in the
  picker, and `/back` returns to it.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.{Client, FakeRemote}
  alias Troupe.Client.Daemon.Link
  alias Troupe.Remote.RPC

  test "/new opens a fresh session here; the one it left stays in the picker, and /back returns" do
    {first, _, ws} = start_session!(script: [{:text_and_tools, "hello back", []}])
    {pid, session} = start_tui(first)

    type(pid, "hello")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "hello back" end, 10_000)

    type(pid, "/new")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != first end)
    fresh = user_state(pid).session_id
    on_exit(fn -> Client.stop_session(fresh) end)

    assert user_state(pid).focus == :command
    assert user_state(pid).model.workspace == ws
    refute screen_text(pid, session) =~ "hello back"
    assert Client.has_session?(first), "the session it left keeps running"

    type(pid, "/resume")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :sessions end)
    listed = Enum.map(user_state(pid).sessions.entries, & &1.id)
    assert first in listed and fresh in listed
    press(pid, "esc")

    type(pid, "/back")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id == first end)
    eventually(fn -> screen_text(pid, session) =~ "hello back" end)

    # Back again is the fresh one: /back goes to the session focused before.
    type(pid, "/back")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id == fresh end)
  end

  # `session.fork` on the daemon: the fork's log is the conversation so far, so its screen
  # shows it and its agent's next request carries it, while the first never hears the line
  # typed in the fork. A session of its own, not a branch of the first.
  test "/new --branch forks the session on screen and goes on from its conversation" do
    {first, _, ws} = start_session!(script: [{:text_and_tools, "hello back", []}])
    {pid, session} = start_tui(first)

    type(pid, "hello")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "hello back" end, 10_000)
    rested(first)

    type(pid, "/new --branch")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != first end)
    fork = user_state(pid).session_id
    on_exit(fn -> Client.stop_session(fork) end)

    eventually(fn -> screen_text(pid, session) =~ "hello back" end)
    assert user_state(pid).back == first

    assert [%Troupe.Protocol.Event{type: "session_forked", data: forked} | _] =
             Troupe.Session.Log.read_session(fork)

    assert forked["parent"]["session_id"] == first
    assert forked["reason"] == "branch"

    {:ok, rows} = Client.sessions({:local, ws})
    assert %{parent: nil} = Enum.find(rows, &(&1.id == fork))

    type(pid, "go on from here")
    press(pid, "enter")

    eventually(
      fn -> Troupe.LLM.Fake.requests(Troupe.Registry.fake(fork)) != [] end,
      10_000
    )

    [request | _] = Troupe.LLM.Fake.requests(Troupe.Registry.fake(fork))
    said = inspect(request.messages)
    assert said =~ "hello back"
    assert said =~ "go on from here"

    refute Enum.any?(
             Client.events(first),
             &match?(%{type: :input, data: %{content: "go on from here"}}, &1)
           )
  end

  test "/new --private opens a private session here" do
    {first, _, ws} = start_session!(script: [])
    {pid, _session} = start_tui(first)

    type(pid, "/new --private")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != first end)
    private = user_state(pid).session_id
    on_exit(fn -> Client.stop_session(private) end)

    {:ok, rows} = Client.sessions({:local, ws})
    assert %{kind: "private"} = Enum.find(rows, &(&1.id == private))
    assert user_state(pid).back == first
  end

  # Against `FakeRemote`, the plane stand-in the remote tests use: not tried on a plane.
  test "/new --remote PROFILE starts a session on the plane, --branch forks it there, and home is a step away" do
    {remote, url} = start_remote!()
    login!(remote, url)
    {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
    {pid, session} = start_tui(first)
    type(pid, "hello")
    press(pid, "enter")
    rested(first)

    type(pid, "/new --remote code")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != first end)
    pod = user_state(pid).session_id
    assert Client.remote?(pod)

    assert Enum.any?(
             FakeRemote.calls(remote),
             &match?({"session.create", %{"profile" => "code"}}, &1)
           )

    type(pid, "/new --branch")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != pod end)
    forked = user_state(pid).session_id
    assert Client.remote?(forked)

    assert {"session.fork", %{"session_id" => ^pod}} =
             List.keyfind(FakeRemote.calls(remote), "session.fork", 0)

    type(pid, "/back")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id == pod end)

    # With a plane's session on screen, this directory's sessions are still the ones the
    # window was opened in. (`/sessions`: the stand-in's command table lists no aliases.)
    type(pid, "/sessions #{first}")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id == first end)

    type(pid, "/new --bogus")
    press(pid, "enter")

    eventually(fn ->
      screen_text(pid, session) =~ "usage: /new [--private | --remote PROFILE | --branch]"
    end)
  end

  # Root Decision 812: one that cannot be carried on is refused, saying why and offering
  # /new, and the screen stays where it is.
  test "/back to an erased session, and /resume of one another device holds, are refused" do
    {first, _, _ws} = start_session!(script: [{:text_and_tools, "hi", []}])
    {pid, session} = start_tui(first)
    type(pid, "hello")
    press(pid, "enter")
    rested(first)

    type(pid, "/new")
    press(pid, "enter")
    eventually(fn -> user_state(pid).session_id != first end)
    fresh = user_state(pid).session_id
    on_exit(fn -> Client.stop_session(fresh) end)

    Client.stop_session(first)
    {:ok, _} = Link.call("session.erase", %{session_id: first, command_id: RPC.command_id()})

    type(pid, "/back")
    press(pid, "enter")

    eventually(fn ->
      screen_text(pid, session) =~ "#{first} is not a session here: it was erased"
    end)

    assert user_state(pid).session_id == fresh

    held = %{
      id: "s-held",
      origin: {:local, "/nowhere"},
      sync: "elsewhere",
      device: "ada-laptop",
      state: :dormant
    }

    assert Client.resume_refusal(held) =~ "s-held is held on ada-laptop"
  end

  # The root's turn has ended, as the log says it: a durable rest.
  defp rested(sid) do
    eventually(
      fn ->
        Enum.any?(
          Client.events(sid),
          &match?(
            %{agent_path: "root", type: :agent_state, seq: s, data: %{to: :idle}}
            when is_integer(s),
            &1
          )
        )
      end,
      10_000
    )
  end
end
