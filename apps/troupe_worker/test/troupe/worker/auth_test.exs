defmodule Troupe.Worker.AuthTest do
  @moduledoc """
  What the guard lets a token ask of a pod, method by method.

  A token for one session is for the methods about that session. Everything else a pod
  serves is about the pod — creating a session in any workspace, a path's brief, the
  workspaces it has seen, the machine's settings and identity — and a token for one session
  is refused it before anything runs. So are the five about the session that are the
  plane's to do: archiving, pinning, erasing and forking it. The walk is over the protocol's own
  method table, so a method added to it is one somebody has to put on one side of that
  line.

  The guard alone, asked directly: nothing here needs OpenBao, MinIO or a session, so
  nothing skips. `harness_auth_test.exs` asks the same over a real connection.
  """

  use ExUnit.Case, async: true

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Schema
  alias Troupe.Worker.Auth

  @mine "20260923T101112-q3Vx_A"

  # Answered by the connection before the guard is asked: a second `initialize` is
  # `invalid_request`, and `auth.refresh` is not in the table at all.
  @connection_own ["initialize"]

  # What a session's own client needs besides the commands that name the session: its
  # topics, and the two listings, which are narrowed to it.
  @connection_level ["subscribe", "unsubscribe", "session.list", "fleet.get"]

  # What the daemon serves about itself, its paths and its machine.
  @daemon_level [
    "session.create",
    "session.claim",
    # A private session's invitations, from the machine that holds its key (#765): a pod
    # session is invited at the plane.
    "session.invite",
    "session.uninvite",
    "session.invites",
    "session.read_sealed",
    "config.get",
    "config.models",
    "config.set",
    "identity.get",
    "identity.link",
    "identity.unlink",
    "watch.set",
    "memory.get",
    "memory.forget",
    "memory.decline",
    # A session's start asks them on the person's own machine (root Decision 835): the plan
    # and a yes take `admin` there, a no `control`; a worker has none of them, whatever the
    # token.
    "onboard.plan",
    "onboard.apply",
    "onboard.decline",
    "agents.list",
    "workflows.list",
    "workspace.recent",
    "workspace.search",
    "worktree.list",
    "worktree.remove",
    "worktree.merge",
    "worktree.discard",
    # A laptop's session offered to the plane for steering from another device (#58): a
    # pod's sessions are reached through the plane already.
    "remote.offer",
    "remote.withdraw"
  ]

  # About the session, and done through the plane, which holds a pod session's row, key
  # and retention. The plane's own erasure reaches the pod over the control channel, not
  # through this guard (`erasure_test.exs`). A fork is a new row (root Decision 812).
  @plane_level [
    "session.archive",
    "session.pin",
    "session.unpin",
    "session.erase",
    "session.fork"
  ]

  # Every method the clients send a worker today, read from their sources: the TUI's
  # `clients/tui/lib/troupe/remote/worker.ex`, the GUI's
  # `clients/gui/packages/client/src/session.ts` and `connection.ts`, and the A2A facade's
  # `apps/troupe_a2a/lib/troupe/a2a/worker.ex`. `initialize` and `auth.refresh` besides,
  # which the connection answers itself.
  @clients_send [
    "subscribe",
    "unsubscribe",
    "session.get",
    "commands.list",
    "commands.run",
    "input.send",
    "turn.cancel",
    "approval.respond",
    "question.answer",
    "todo.edit",
    "profile.switch",
    "session.goal.get",
    "session.goal.set",
    "session.goal.clear",
    "session.loop.get",
    "session.loop.start",
    "session.loop.stop",
    "fs.list",
    "fs.read",
    "fs.upload",
    # The scratchpad's documents, the GUI's (root Decision 870).
    "scratch.list",
    "blob.get",
    "context.get",
    "presence.set",
    # The person's own command (`!cmd`, the TUI's; Decision 813).
    "shell.run",
    "shell.cancel"
  ]

  setup do
    auth = start_supervised!({Auth, name: nil, worker_id: "worker-dev-0"})
    %{auth: auth, guard: Auth.guard(auth)}
  end

  describe "a token for one session" do
    test "has every method about its session but the plane's, and is refused every other",
         %{guard: guard} do
      wrong =
        for method <- methods(),
            answer = guard.(session_token(), method, params_for(method)),
            its_own?(method) != (answer == :ok),
            do: {method, answer}

      assert wrong == []
    end

    for method <- @daemon_level do
      test "is refused #{method}, naming it", %{guard: guard} do
        method = unquote(method)

        assert {:error, error} = guard.(session_token(), method, params_for(method))
        assert error.message == "forbidden"
        assert error.data.method == method
      end
    end

    for method <- @plane_level do
      test "is refused #{method} on its own session, which is the plane's", %{guard: guard} do
        method = unquote(method)

        assert {:error, error} = guard.(session_token(), method, params_for(method))
        assert error.message == "forbidden"
        assert error.data.method == method
        assert error.data.reason == "done through the plane"
      end
    end

    test "has everything the clients send a worker", %{guard: guard} do
      refused =
        for method <- @clients_send,
            answer = guard.(session_token(), method, params_for(method)),
            answer != :ok,
            do: {method, answer}

      assert refused == []
    end

    # The pickers of both clients list a pod session's agents with its own token (#594):
    # named by the session and no path, the agents are its own, its bundle's. Named by a
    # path they are the pod's, and another session's are another session's.
    test "reads its own session's agents, and no path's", %{guard: guard} do
      for method <- ~w(agents.list agents.get agents.validate) do
        own = %{"session_id" => @mine, "name" => "build", "source" => "x"}
        assert guard.(session_token(), method, own) == :ok, method

        assert {:error, %{message: "forbidden"}} =
                 guard.(session_token(), method, Map.put(own, "workspace", "/elsewhere"))

        assert {:error, %{message: "forbidden"}} =
                 guard.(session_token(), method, Map.delete(own, "session_id"))

        assert {:error, %{message: "forbidden"}} =
                 guard.(session_token(), method, %{own | "session_id" => "20260923T101112-other0"})
      end
    end

    # Its own configuration, what is in force in it; the pod's settings stay the pod's.
    test "has config.get naming its session, and no other's", %{guard: guard} do
      assert guard.(session_token(), "config.get", %{"session_id" => @mine}) == :ok

      assert {:error, %{message: "forbidden", data: %{field: "session_id"}}} =
               guard.(session_token(), "config.get", %{"session_id" => "20260923T101112-zz9_Bq"})

      assert {:error, %{message: "forbidden", data: %{method: "config.get"}}} =
               guard.(session_token(), "config.get", %{})
    end

    # The dispatcher answers `method_not_found` to everybody for a method the server does
    # not have, and nothing runs; saying `forbidden` instead would tell a client that a
    # method exists which does not.
    test "leaves a method the server does not have to the dispatcher", %{guard: guard} do
      assert guard.(session_token(), "no.such.method", %{}) == :ok
    end
  end

  describe "a token with no session in it" do
    test "keeps every method", %{guard: guard} do
      refused =
        for method <- methods(),
            answer = guard.(unscoped_token(), method, params_for(method)),
            answer != :ok,
            do: {method, answer}

      assert refused == []
    end
  end

  # The role the plane pushed since the token was minted (issue #494).
  describe "a role the plane narrows" do
    test "holds the next command to that role's scopes", %{auth: auth, guard: guard} do
      params = %{"session_id" => @mine}

      :ok = Auth.put_acl(auth, @mine, "owner@example.test", "collaborator")
      assert guard.(session_token(), "shell.run", params) == {:ok, [:observe, :control]}

      :ok = Auth.put_acl(auth, @mine, "owner@example.test", "viewer")
      assert guard.(session_token(), "input.send", params) == {:ok, [:observe]}

      :ok = Auth.put_acl(auth, @mine, "owner@example.test", nil)
      assert {:error, %{message: "forbidden"}} = guard.(session_token(), "input.send", params)
    end

    test "to the fewest scopes of the sessions a token with none in it names",
         %{auth: auth, guard: guard} do
      other = "20260923T101112-zz9_Bq"
      :ok = Auth.put_acl(auth, @mine, "owner@example.test", "collaborator")
      :ok = Auth.put_acl(auth, other, "owner@example.test", "viewer")

      params = %{"session_id" => @mine, "topic" => "session:" <> other}
      assert guard.(unscoped_token(), "subscribe", params) == {:ok, [:observe]}

      assert guard.(unscoped_token(), "input.send", %{"session_id" => @mine}) ==
               {:ok, [:observe, :control]}
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp session_token, do: Map.put(unscoped_token(), "session_id", @mine)

  defp unscoped_token, do: %{"sub" => "owner@example.test", "role" => "owner"}

  # Every method the protocol describes and every one the dispatcher serves, so that a
  # method added to only one of the two is still held to the table.
  defp methods do
    (Map.keys(Schema.commands()) ++ Map.keys(Dispatch.methods()))
    |> Enum.uniq()
    |> Enum.sort()
    |> Kernel.--(@connection_own)
  end

  # `session.claim` names a session, but a private session lives on a daemon: a pod has none
  # to take over (Decision 785).
  defp its_own?(method),
    do: about_the_session?(method) and method not in @plane_level and method not in @daemon_level

  defp about_the_session?(method) do
    method in @connection_level or
      match?(%{"session_id" => %{required: true}}, Map.get(Schema.commands(), method))
  end

  # What each method is asked with: its own session wherever it names one, and a path
  # outside any session wherever it takes one. The guard reads only the first.
  defp params_for(method) do
    for {field, %{required: true}} <- Map.get(Schema.commands(), method, %{}),
        into: %{},
        do: {field, value_for(field)}
  end

  defp value_for("session_id"), do: @mine
  defp value_for("topic"), do: "session:" <> @mine
  defp value_for("workspace"), do: "/"
  defp value_for("path"), do: "/etc"
  defp value_for(_field), do: "c-1"
end
