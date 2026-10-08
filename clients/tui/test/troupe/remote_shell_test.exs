defmodule Troupe.RemoteShellTest do
  @moduledoc """
  `!cmd` on a session on a plane (issue #486, Decision 152): the command goes to the
  pod that holds the session, as `shell.run` on the session's own connection, and the
  block it comes back as says which profile's pod ran it and is otherwise a local one's.
  The worker's own `shell.run` is the gateway's, whose tests are in the harness; the pod
  here is `FakeRemote`'s.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers, only: [eventually: 1]
  import Troupe.TUIHelpers

  alias Troupe.FakeRemote

  @moduletag :remote

  test "!cmd runs on the session's pod, and its block says where" do
    {remote, url} =
      start_remote!(sessions: [FakeRemote.session(id: "s-pod", profile: "code", events: [])])

    origin = connect!(remote, url)
    sid = attach!(origin, "s-pod")
    {pid, session} = start_tui(sid)

    type(pid, "!git status")
    press(pid, "enter")

    eventually(fn -> calls(remote, "shell.run") != [] end)

    assert [%{"command" => "git status", "agent" => true, "session_id" => "s-pod"}] =
             calls(remote, "shell.run")

    entry =
      eventually(fn ->
        Enum.find_value(Map.values(user_state(pid).model.windows), fn w ->
          Enum.find_value(Map.values(w.agents), fn a ->
            Enum.find_value(a.transcript, fn
              {:shell, %{status: :exited} = s} -> s
              _ -> nil
            end)
          end)
        end)
      end)

    assert entry.where == "code"
    assert entry.output =~ "ran on the pod"
    assert screen_text(pid, session) =~ "! git status · on code · exit 0"
    assert calls(remote, "input.send") == []
  end

  defp calls(remote, method),
    do: for({^method, params} <- FakeRemote.calls(remote), do: params)
end
