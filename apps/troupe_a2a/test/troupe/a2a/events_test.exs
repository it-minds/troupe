defmodule Troupe.A2A.EventsTest do
  @moduledoc """
  The fold, as pure functions over events: the parts of the mapping the end-to-end
  tests reach only one path through.
  """

  use ExUnit.Case, async: true

  alias Troupe.A2A.{Auth, Events}
  alias Troupe.Protocol.Event

  defp fold(events) do
    Enum.reduce(events, {Events.new("t-1"), []}, fn json, {acc, updates} ->
      {acc, new} = Events.step(acc, Event.from_json(json))
      {acc, updates ++ new}
    end)
  end

  defp durable(seq, type, data, agent \\ ["root"]) do
    %{"seq" => seq, "type" => type, "data" => data, "agent" => agent}
  end

  defp assistant(text, stop_reason) do
    %{
      "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]},
      "stop_reason" => stop_reason
    }
  end

  test "agent_done with a summary completes with it; the summary beats the last text" do
    {acc, updates} =
      fold([
        durable(1, "user_input", %{"text" => "go"}),
        durable(2, "llm_response", assistant("working on it", "tool_use")),
        durable(3, "agent_done", %{"reason" => "finished", "summary" => "All done."})
      ])

    assert acc.state == "completed"
    assert [%{"text" => "All done."}] = acc.message["parts"]
    assert %{"final" => true, "status" => %{"state" => "completed"}} = List.last(updates)
    assert acc.last_seq == 3
  end

  test "a turn that ends without a tool call is completed with its text" do
    {acc, _updates} = fold([durable(1, "llm_response", assistant("Here.", "end_turn"))])

    assert acc.state == "completed"
    assert [%{"text" => "Here."}] = acc.message["parts"]
  end

  test "a sub-agent's response is not the answer" do
    {acc, _updates} =
      fold([durable(1, "llm_response", assistant("child", "end_turn"), ["root", "explore#1"])])

    assert acc.state == "submitted"
    assert acc.history == []
  end

  test "budget and errors fail; a second ending changes nothing" do
    {acc, updates} =
      fold([
        durable(1, "agent_done", %{"reason" => "budget_exhausted", "limit" => "cost"}),
        durable(2, "budget_exhausted", %{"limit" => "cost"})
      ])

    assert acc.state == "failed"
    assert length(updates) == 1

    {acc, _updates} = fold([durable(1, "llm_error", %{"reason" => "overloaded"})])
    assert acc.state == "failed"
    assert [%{"text" => text}] = acc.message["parts"]
    assert text =~ "overloaded"

    {acc, _updates} = fold([durable(1, "cancelled", %{})])
    assert acc.state == "canceled"
  end

  test "an approval is input-required until it is decided" do
    requested = %{"call_id" => "c1", "tool" => "shell", "args" => %{"command" => "ls"}}
    {acc, updates} = fold([durable(1, "approval_requested", requested)])

    assert acc.state == "input-required"
    assert [%{"final" => true, "status" => %{"message" => message}}] = updates
    assert [_text, %{"data" => data}] = message["parts"]
    assert data == Map.put(requested, "decisions", ~w(allow deny allow_session))

    {acc, _updates} =
      fold([
        durable(1, "approval_requested", requested),
        durable(2, "approval_decided", %{"call_id" => "c1", "decision" => "allow"})
      ])

    assert acc.state == "working"
    assert acc.pending == %{}
  end

  test "a published file is an artifact named by its hash" do
    Application.put_env(:troupe_a2a, :public_url, "https://a2a.example.test")
    on_exit(fn -> Application.delete_env(:troupe_a2a, :public_url) end)

    hex = String.duplicate("ab", 32)

    published = %{
      "destination" => "team:acme/out.json",
      "hash" => "sha256:" <> hex,
      "bytes" => 12
    }

    {acc, [update]} = fold([durable(1, "published", published)])

    assert %{"kind" => "artifact-update", "artifact" => artifact} = update
    assert %{"artifactId" => ^hex, "name" => "team:acme/out.json"} = artifact
    assert [%{"artifactId" => ^hex, "parts" => [part]}] = Events.task(acc)["artifacts"]
    assert part["file"]["uri"] == "https://a2a.example.test/a2a/tasks/t-1/artifacts/#{hex}"
    assert part["file"]["mimeType"] == "application/json"
  end

  test "row statuses map onto states" do
    for {row, expected} <- [
          {%{"status" => "thinking"}, "working"},
          {%{"status" => "acting"}, "working"},
          {%{"status" => "waiting"}, "input-required"},
          {%{"status" => "done", "done_reason" => "finished"}, "completed"},
          {%{"status" => "done", "done_reason" => "cancelled"}, "canceled"},
          {%{"status" => "done", "done_reason" => "budget_exhausted"}, "failed"},
          {%{"status" => "interrupted"}, "failed"},
          {%{"status" => "idle", "last_seq" => 1}, "submitted"},
          {%{"status" => "idle", "last_seq" => 12}, "completed"}
        ] do
      assert Events.state_of_row(row) == expected, inspect(row)
    end
  end

  test "history is the last N messages, and none when not asked" do
    {acc, _updates} =
      fold([
        durable(1, "user_input", %{"text" => "one"}),
        durable(2, "llm_response", assistant("two", "end_turn")),
        durable(3, "user_input", %{"text" => "three"})
      ])

    refute Map.has_key?(Events.task(acc), "history")

    assert [%{"role" => "agent"}, %{"role" => "user", "parts" => [%{"text" => "three"}]}] =
             Events.task(acc, history_length: 2)["history"]

    assert [%{"messageId" => "t-1-1"} | _rest] = Events.task(acc, history_length: 3)["history"]
  end

  test "a credential is read from either header form" do
    assert {:ok, {:service, "svc:acme/litellm", "s3:cr:et"}} =
             Auth.parse("Bearer svc:acme/litellm:s3:cr:et")

    assert {:ok, {:service, "svc:acme/litellm", "x"}} =
             Auth.parse("Basic " <> Base.encode64("svc:acme/litellm:x"))

    assert {:ok, {:id_token, "eyJ.eyJ.sig"}} = Auth.parse("bearer eyJ.eyJ.sig")
    assert :error = Auth.parse("Bearer ")
    assert :error = Auth.parse("Bearer svc:acme/litellm")
    assert :error = Auth.parse("Digest abc")
  end
end
