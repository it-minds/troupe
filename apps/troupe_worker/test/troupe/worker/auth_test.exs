defmodule Troupe.Worker.AuthTest do
  @moduledoc """
  What the guard lets a token ask of a pod, method by method.

  A token for one session is for the methods about that session. Everything else a pod
  serves is about the pod — creating a session in any workspace, a path's brief, the
  workspaces it has seen, the machine's settings and identity — and a token for one session
  is refused it before anything runs. The walk is over the protocol's own method table, so
  a method added to it is one somebody has to put on one side of that line.

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
    "config.get",
    "config.models",
    "config.set",
    "identity.get",
    "identity.link",
    "identity.unlink",
    "watch.set",
    "memory.get",
    "memory.forget",
    "agents.list",
    "workflows.list",
    "workspace.recent",
    "workspace.search",
    "worktree.list",
    "worktree.remove",
    "worktree.merge",
    "worktree.discard"
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
    "blob.get",
    "presence.set"
  ]

  setup do
    auth = start_supervised!({Auth, name: nil, worker_id: "worker-dev-0"})
    %{guard: Auth.guard(auth)}
  end

  describe "a token for one session" do
    test "has every method about its session and is refused every other", %{guard: guard} do
      wrong =
        for method <- methods(),
            answer = guard.(session_token(), method, params_for(method)),
            about_the_session?(method) != (answer == :ok),
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

    test "has everything the clients send a worker", %{guard: guard} do
      refused =
        for method <- @clients_send,
            answer = guard.(session_token(), method, params_for(method)),
            answer != :ok,
            do: {method, answer}

      assert refused == []
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

  # -- helpers ----------------------------------------------------------------

  defp session_token, do: Map.put(unscoped_token(), "session_id", @mine)

  defp unscoped_token, do: %{"sub" => "owner@example.test", "role" => "owner"}

  # Every method the protocol describes and every one the dispatcher serves: a few are in
  # only one of the two.
  defp methods do
    (Map.keys(Schema.commands()) ++ Map.keys(Dispatch.methods()))
    |> Enum.uniq()
    |> Enum.sort()
    |> Kernel.--(@connection_own)
  end

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
