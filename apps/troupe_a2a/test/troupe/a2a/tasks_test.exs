defmodule Troupe.A2A.TasksTest do
  @moduledoc """
  `message/send`, `tasks/get` and `tasks/cancel`, against a stub plane and a fake
  worker over real sockets.

  What matters is what the facade sends on: that a session is created with `origin.kind
  a2a` as the caller's principal, that a decision becomes `approval.respond` and text
  on a waiting task does not, and that another principal's task is not found — which
  the stub plane decides, exactly as the real one would.
  """

  use Troupe.A2A.Case, async: false

  defp calls(context, method) do
    context.plane |> StubPlane.calls() |> Enum.filter(&(elem(&1, 1) == method))
  end

  defp opened?(context, id, mode) do
    Enum.any?(StubPlane.calls(context.plane), fn
      {_who, "session.open", %{"session_id" => ^id, "mode" => ^mode}} -> true
      _call -> false
    end)
  end

  defp decision(task_id, data) do
    %{
      "message" => %{
        "role" => "user",
        "taskId" => task_id,
        "parts" => [%{"kind" => "data", "data" => data}]
      }
    }
  end

  describe "message/send" do
    test "creates a session as the caller, with origin a2a; the session id is the task",
         context do
      params = %{
        "message" => %{
          "role" => "user",
          "messageId" => "m-1",
          "parts" => [
            %{"kind" => "text", "text" => "Review PR 812."},
            %{"kind" => "text", "text" => "Focus on the migration."}
          ]
        }
      }

      assert {200, %{"result" => task}} = rpc(context, "message/send", params)
      assert task["kind"] == "task"
      assert task["status"]["state"] == "submitted"
      assert task["contextId"] == task["id"]

      assert [{"svc:acme/litellm", "session.create", create}] = calls(context, "session.create")
      assert create["profile"] == "reviewer"
      assert create["prompt"] == "Review PR 812.\n\nFocus on the migration."
      assert create["visibility"] == "private"
      assert create["session_id"] == task["id"]
      assert create["title"] == "Review PR 812."

      assert create["origin"] == %{
               "kind" => "a2a",
               "caller" => "svc:acme/litellm",
               "task" => task["id"]
             }

      # And the plane's row is what a later call finds it by.
      assert %{"origin" => %{"kind" => "a2a"}} = StubPlane.row(context.plane, task["id"])
    end

    test "a message with no text is refused", context do
      parts = [%{"kind" => "data", "data" => %{}}]
      params = %{"message" => %{"role" => "user", "parts" => parts}}

      assert {200, %{"error" => %{"code" => -32_602}}} =
               rpc(context, "message/send", params)

      assert [] = calls(context, "session.create")
    end

    test "on an existing task it is input.send on the pod", context do
      StubPlane.put_row(context.plane, "s-1", %{"status" => "idle", "last_seq" => 9})

      assert {200, %{"result" => %{"status" => %{"state" => "working"}}}} =
               send_text(context, "And the tests?", task_id: "s-1")

      assert_receive {:worker_command, "input.send", %{"session_id" => "s-1", "text" => text}}
      assert text == "And the tests?"

      # Steering opens the session for steering, not for reading.
      assert opened?(context, "s-1", "activate")
    end

    test "a decision part on a waiting task becomes approval.respond", context do
      StubPlane.put_row(context.plane, "s-2", %{
        "status" => "waiting",
        "pending_approvals" => ["call_3"],
        "last_seq" => 12
      })

      assert {200, %{"result" => %{"status" => %{"state" => "working"}}}} =
               rpc(context, "message/send", decision("s-2", %{"decision" => "allow"}))

      # The call id came from the row: the message named none and there was one to name.
      assert_receive {:worker_command, "approval.respond", respond}
      assert %{"session_id" => "s-2", "call_id" => "call_3", "decision" => "allow"} = respond
    end

    test "free text on a waiting task is refused with a hint, and nothing is logged",
         context do
      StubPlane.put_row(context.plane, "s-3", %{
        "status" => "waiting",
        "pending_approvals" => ["c1"]
      })

      assert {200, %{"error" => %{"code" => -32_602, "data" => %{"reason" => reason}}}} =
               send_text(context, "yes go ahead", task_id: "s-3")

      assert reason =~ "decision"
      refute_receive {:worker_command, "approval.respond", _params}
      refute_receive {:worker_command, "input.send", _params}
    end

    test "a decision on a task that is not waiting is refused", context do
      StubPlane.put_row(context.plane, "s-4", %{"status" => "thinking"})
      params = decision("s-4", %{"decision" => "deny", "call_id" => "c9"})

      assert {200, %{"error" => %{"code" => -32_602}}} = rpc(context, "message/send", params)
      refute_receive {:worker_command, "approval.respond", _params}
    end

    test "blocking waits for the turn to end and returns the answer", context do
      script = opening("Review PR 812.") ++ [response(4, "Looks fine.")]
      FakeWorker.script(context.worker, :default, script)

      configuration = %{"blocking" => true, "historyLength" => 10}

      assert {200, %{"result" => task}} =
               send_text(context, "Review PR 812.", configuration: configuration)

      assert task["status"]["state"] == "completed"
      assert [%{"kind" => "text", "text" => "Looks fine."}] = task["status"]["message"]["parts"]
      assert [%{"role" => "user"}, %{"role" => "agent"}] = task["history"]
    end
  end

  describe "tasks/get" do
    test "a task being worked on is answered from the row, without a reader", context do
      StubPlane.put_row(context.plane, "s-5", %{"status" => "acting", "last_seq" => 20})

      assert {200, %{"result" => task}} = rpc(context, "tasks/get", %{"id" => "s-5"})
      assert %{"status" => %{"state" => "working"}, "metadata" => %{"lastSeq" => 20}} = task
      refute_receive {:worker_command, _method, _params}
    end

    test "row statuses map onto A2A states", context do
      for {attrs, expected} <- [
            {%{"status" => "thinking"}, "working"},
            {%{"status" => "idle", "last_seq" => 2}, "submitted"},
            {%{"status" => "interrupted", "last_seq" => 9}, "failed"}
          ] do
        id = "s-#{expected}"
        StubPlane.put_row(context.plane, id, attrs)

        assert {200, %{"result" => %{"status" => %{"state" => ^expected}}}} =
                 rpc(context, "tasks/get", %{"id" => id})
      end
    end

    test "a finished task carries the final answer, rendered from the log", context do
      StubPlane.put_row(context.plane, "s-6", %{
        "status" => "done",
        "done_reason" => "finished",
        "last_seq" => 5
      })

      FakeWorker.script(
        context.worker,
        "s-6",
        opening("Review it.") ++
          [
            response(4, "Calling a tool.", "tool_use"),
            event(5, "agent_done", %{"reason" => "finished", "summary" => "Two findings."})
          ]
      )

      assert {200, %{"result" => task}} =
               rpc(context, "tasks/get", %{"id" => "s-6", "historyLength" => 1})

      assert task["status"]["state"] == "completed"
      assert [%{"text" => "Two findings."}] = task["status"]["message"]["parts"]
      assert [%{"role" => "agent", "parts" => [%{"text" => "Calling a tool."}]}] = task["history"]

      # A reader, never an activation.
      assert opened?(context, "s-6", "read")
      refute opened?(context, "s-6", "activate")
    end

    test "a failed task says why", context do
      StubPlane.put_row(context.plane, "s-7", %{
        "status" => "done",
        "done_reason" => "llm_error",
        "last_seq" => 4
      })

      script = opening("Go.") ++ [event(4, "llm_error", %{"reason" => "overloaded"})]
      FakeWorker.script(context.worker, "s-7", script)

      assert {200, %{"result" => %{"status" => status}}} =
               rpc(context, "tasks/get", %{"id" => "s-7"})

      assert status["state"] == "failed"
      assert [%{"text" => text}] = status["message"]["parts"]
      assert text =~ "overloaded"
    end

    test "a waiting task names the tool and its arguments", context do
      StubPlane.put_row(context.plane, "s-8", %{
        "status" => "waiting",
        "pending_approvals" => ["call_3"],
        "last_seq" => 4
      })

      FakeWorker.script(
        context.worker,
        "s-8",
        opening("Run it.") ++
          [
            event(4, "approval_requested", %{
              "call_id" => "call_3",
              "tool" => "shell",
              "args" => %{"command" => "mix test"},
              "agent_path" => ["root"]
            })
          ]
      )

      assert {200, %{"result" => %{"status" => status}}} =
               rpc(context, "tasks/get", %{"id" => "s-8"})

      assert status["state"] == "input-required"

      assert [%{"kind" => "text", "text" => text}, %{"kind" => "data", "data" => data}] =
               status["message"]["parts"]

      assert text =~ "shell"
      assert data["call_id"] == "call_3"
      assert data["args"] == %{"command" => "mix test"}
      assert "allow" in data["decisions"]
    end

    test "a second caller's task is not found", context do
      assert {200, %{"result" => %{"id" => id}}} = send_text(context, "Review PR 812.")

      assert {200, %{"error" => %{"code" => -32_001}}} =
               rpc(context, "tasks/get", %{"id" => id}, as: :other)

      assert {200, %{"error" => %{"code" => -32_001}}} =
               rpc(context, "tasks/get", %{"id" => id}, as: :person)

      assert {200, %{"result" => %{"id" => ^id}}} =
               rpc(context, "tasks/get", %{"id" => id}, as: :litellm)
    end

    test "a session no A2A call created is not a task", context do
      StubPlane.put_row(context.plane, "s-human", %{"origin" => %{"kind" => "cli"}})

      assert {200, %{"error" => %{"code" => -32_001}}} =
               rpc(context, "tasks/get", %{"id" => "s-human"})
    end
  end

  describe "tasks/cancel" do
    test "stops the turn and archives the session", context do
      StubPlane.put_row(context.plane, "s-9", %{"status" => "acting", "last_seq" => 8})

      assert {200, %{"result" => %{"status" => %{"state" => "canceled"}}}} =
               rpc(context, "tasks/cancel", %{"id" => "s-9"})

      assert_receive {:worker_command, "turn.cancel", %{"session_id" => "s-9"}}
      assert %{"state" => "dormant"} = StubPlane.row(context.plane, "s-9")
    end

    test "a finished task cannot be canceled", context do
      StubPlane.put_row(context.plane, "s-10", %{"status" => "done", "done_reason" => "finished"})

      assert {200, %{"error" => %{"code" => -32_002}}} =
               rpc(context, "tasks/cancel", %{"id" => "s-10"})

      refute_receive {:worker_command, "turn.cancel", _params}
    end
  end

  describe "who is calling" do
    defp bare_post(context, headers) do
      {:ok, response} =
        Req.post("#{context.url}/a2a/reviewer",
          json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "tasks/get", "params" => %{}},
          headers: headers,
          retry: false
        )

      response
    end

    test "no credential is a 401 with a challenge", context do
      response = bare_post(context, [])
      assert response.status == 401
      assert [challenge] = Req.Response.get_header(response, "www-authenticate")
      assert challenge =~ "Bearer"
    end

    test "a credential the plane refuses is a 401", context do
      response = bare_post(context, [{"authorization", "Bearer svc:acme/litellm:wrong"}])
      assert response.status == 401
    end

    test "push notifications are declined by name", context do
      assert {200, %{"error" => %{"code" => -32_003}}} =
               rpc(context, "tasks/pushNotificationConfig/set", %{"taskId" => "s-1"})
    end

    test "an unknown method is -32601", context do
      assert {200, %{"error" => %{"code" => -32_601}}} = rpc(context, "tasks/frobnicate", %{})
    end
  end
end
