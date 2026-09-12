defmodule Troupe.A2A.StreamTest do
  @moduledoc """
  `message/stream` and `tasks/resubscribe` over server-sent events, end to end: a real
  facade, a real socket to the fake worker, and the events a client would parse.
  """

  use Troupe.A2A.Case, async: false

  defp send_params(text, opts \\ []) do
    message = %{"role" => "user", "parts" => [%{"kind" => "text", "text" => text}]}

    case Keyword.get(opts, :task_id) do
      nil -> %{"message" => message}
      task_id -> %{"message" => Map.put(message, "taskId", task_id)}
    end
  end

  defp status_updates(events) do
    for %{"result" => %{"kind" => "status-update"} = update} <- events, do: update
  end

  test "a new task streams from submitted to completed and ends", context do
    FakeWorker.script(
      context.worker,
      :default,
      opening("Review PR 812.") ++
        [
          ephemeral("llm_delta", %{"kind" => "text", "text" => "Looks "}),
          response(4, "Looks fine.")
        ]
    )

    assert {200, events} = stream(context, send_params("Review PR 812."))

    assert [%{"result" => %{"kind" => "task", "status" => %{"state" => "submitted"}}} | _] =
             events

    states = for update <- status_updates(events), do: update["status"]["state"]
    assert "working" in states

    assert %{"result" => %{"final" => true, "status" => status}} = List.last(events)
    assert status["state"] == "completed"
    assert [%{"text" => "Looks fine."}] = status["message"]["parts"]
  end

  test "an approval request ends the stream as input-required", context do
    FakeWorker.script(
      context.worker,
      :default,
      opening("Run the tests.") ++
        [
          event(4, "approval_requested", %{
            "call_id" => "call_1",
            "tool" => "shell",
            "args" => %{"command" => "mix test"},
            "agent_path" => ["root"]
          })
        ]
    )

    assert {200, events} = stream(context, send_params("Run the tests."))

    assert %{"result" => %{"final" => true, "status" => status}} = List.last(events)
    assert status["state"] == "input-required"
    assert [_text, %{"kind" => "data", "data" => data}] = status["message"]["parts"]
    assert %{"call_id" => "call_1", "tool" => "shell"} = data
  end

  test "a message on a task is sent after the subscription, and its effects stream",
       context do
    StubPlane.put_row(context.plane, "s-1", %{"status" => "idle", "last_seq" => 4})
    FakeWorker.script(context.worker, "s-1", opening("First.") ++ [response(4, "Done once.")])

    FakeWorker.on_command(context.worker, "s-1", "input.send", [
      event(5, "user_input", %{"source" => "user", "text" => "Again."}),
      response(6, "Done twice.")
    ])

    assert {200, events} = stream(context, send_params("Again.", task_id: "s-1"))
    assert_receive {:worker_command, "input.send", %{"text" => "Again."}}

    assert %{"result" => %{"final" => true, "status" => status}} = List.last(events)
    assert status["state"] == "completed"
    assert [%{"text" => "Done twice."}] = status["message"]["parts"]
  end

  test "resubscribing from the last seq replays the past without ending on it", context do
    StubPlane.put_row(context.plane, "s-2", %{
      "status" => "done",
      "done_reason" => "finished",
      "last_seq" => 7
    })

    FakeWorker.script(
      context.worker,
      "s-2",
      opening("Go.") ++
        [
          event(4, "approval_requested", %{"call_id" => "c1", "tool" => "shell", "args" => %{}}),
          event(5, "approval_decided", %{"call_id" => "c1", "decision" => "allow"}),
          event(6, "tool_call_completed", %{"call_id" => "c1", "name" => "shell", "ok" => true}),
          response(7, "All green.")
        ]
    )

    params = %{"id" => "s-2", "metadata" => %{"lastSeq" => 3}}
    assert {200, events} = stream(context, params, method: "tasks/resubscribe")

    states =
      for update <- status_updates(events), do: {update["status"]["state"], update["final"]}

    # The approval that was answered long ago is reported, but it does not end the
    # stream; the turn's end does.
    assert {"input-required", false} in states
    assert List.last(states) == {"completed", true}
    assert Enum.all?(Enum.drop(states, -1), fn {_state, final?} -> final? == false end)

    # Reattaching reads; it never wakes a session.
    refute Enum.any?(StubPlane.calls(context.plane), fn
             {_who, "session.open", %{"mode" => "activate"}} -> true
             _call -> false
           end)
  end

  test "a task at rest with nothing to replay is one final update", context do
    StubPlane.put_row(context.plane, "s-3", %{
      "status" => "done",
      "done_reason" => "finished",
      "last_seq" => 9
    })

    assert {200, [%{"result" => %{"final" => true, "status" => %{"state" => "completed"}}}]} =
             stream(context, %{"id" => "s-3"}, method: "tasks/resubscribe")

    refute_receive {:worker_command, _method, _params}
  end

  test "an expiring token is refreshed on the open socket", context do
    FakeWorker.script(context.worker, :default, opening("Go.") ++ [response(4, "Done.")])
    FakeWorker.expire_soon(context.worker)

    assert {200, _events} = stream(context, send_params("Go."))

    assert_receive {:worker_command, "auth.refresh", %{"auth" => %{"token" => token}}}
    assert token =~ "pod-token-"
    assert Enum.any?(StubPlane.calls(context.plane), &(elem(&1, 1) == "token.mint"))
  end

  test "beyond the replica's limit a stream is a 429", context do
    Application.put_env(:troupe_a2a, :max_streams, 0)

    # A refused stream is an ordinary JSON answer, which the SSE parser would not see.
    {:ok, response} =
      Req.post("#{context.url}/a2a/reviewer",
        json: %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "message/stream",
          "params" => send_params("Go.")
        },
        headers: [{"authorization", auth(:litellm)}],
        retry: false
      )

    assert response.status == 429
    assert %{"error" => %{"message" => "too many streams"}} = response.body
  end
end
