defmodule Troupe.Worker.SensitiveTest do
  @moduledoc """
  A sensitive session on a pod (#1239). The plane sends the profile's `spec.sensitive` in
  effect as `sensitive_rules` at every activation, and the session's mark as `sensitive`
  once its row has one; the pod marks the session at the gate, refuses what `deny` names,
  a person's `!` command included, and marks a live session a person marked at the plane
  (`sensitive.changed`).

  Driven the way a pod is: `session.activate` from the plane, then the agent's turn, and a
  person's command through the dispatcher the pod's socket uses.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Error
  alias Troupe.Session.Sensitive
  alias Troupe.Worker.Plane.Commands

  @moduletag timeout: 60_000

  @ada "ada@example.test"

  @rules %{
    "markedBy" => ["read_file(records/**)"],
    "deny" => ["shell(curl)", "web_fetch"],
    "profile" => "records"
  }

  setup context do
    context = requires_tier(context)

    on_exit(fn ->
      Application.delete_env(:troupe_worker, :session_defaults)
      quieten(context.session_id)
    end)

    context
  end

  test "a call the profile names marks the session, and what it denies is refused after",
       context do
    File.mkdir_p!(Path.join(context.workspace, "records"))
    File.write!(Path.join(context.workspace, "records/ann.txt"), "Ann")

    test = self()

    defaults =
      activation(context,
        report: fn report -> send(test, {:report, report}) end,
        steps: [
          {:tools, [{"read_file", %{"path" => "records/ann.txt"}}]},
          {:tools, [{"web_fetch", %{"url" => "https://example.test/"}}]},
          {:text, "done"}
        ]
      )

    Application.put_env(:troupe_worker, :session_defaults, defaults)

    push = Map.put(push(context), "sensitive_rules", @rules)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "go")
    assert eventually(fn -> length(completed(context.session_id)) == 2 end, 20_000)

    [read, fetch] = completed(context.session_id)
    assert read.data["ok"]
    assert fetch.data["refused"] == "sensitive"
    assert fetch.data["content"] =~ "by the profile records (deny web_fetch)"
    assert %{"how" => "call", "by" => "read_file"} = Sensitive.mark_of(context.session_id)

    # The plane hears it in the session's status, which its row is written from.
    assert eventually(fn -> sensitive_status_reported?() end, 10_000)

    # A person's own command is refused by the sensitive deny as the agent's call is.
    assert {:error, %Error{message: "forbidden", data: data}} =
             shell(context.session_id, "curl https://example.test/")

    assert data.setting == "sensitive"
    assert data.reason =~ "this session is sensitive since read_file read from it"
    assert {:ok, %{"run_id" => _}} = shell(context.session_id, "echo fine")
  end

  test "a person's mark at the plane marks a live session, and a dormant one learns at its wake",
       context do
    Application.put_env(:troupe_worker, :session_defaults, activation(context))
    push = Map.put(push(context), "sensitive_rules", @rules)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    told = %{
      "session_id" => context.session_id,
      "by" => @ada,
      "by_name" => "Ada",
      "at" => "2026-11-28T10:14:00Z"
    }

    assert {:ok, %{"recorded" => true}} = Commands.handle("sensitive.changed", told)

    assert %{"how" => "person", "by" => @ada, "display_name" => "Ada"} =
             Sensitive.mark_of(context.session_id)

    assert {:error, %Error{data: %{setting: "sensitive"}}} = shell(context.session_id, "curl x")

    # Asleep: nothing to mark here, and the plane's activation carries the mark instead.
    assert {:ok, _} = Sessions.dormant(context.session_id)

    assert {:ok, %{"recorded" => false, "reason" => "dormant"}} =
             Commands.handle("sensitive.changed", told)

    mark = %{"at" => "2026-11-28T10:14:00Z", "by" => @ada, "how" => "person"}

    assert {:ok, %{"activated" => true}} =
             Commands.handle("session.activate", Map.put(push, "sensitive", mark))

    assert Sensitive.mark_of(context.session_id)["by"] == @ada

    marks =
      Enum.filter(Troupe.events(context.session_id), &(&1.type == "session_marked_sensitive"))

    assert length(marks) == 1

    assert {:error, %Error{message: "invalid_params"}} =
             Commands.handle("sensitive.changed", Map.delete(told, "at"))
  end

  test "a wake that carries the mark holds the gate before the log is read", context do
    Application.put_env(
      :troupe_worker,
      :session_defaults,
      activation(context,
        steps: [
          {:tools, [{"web_fetch", %{"url" => "https://example.test/"}}]},
          {:text, "done"}
        ]
      )
    )

    mark = %{"at" => "2026-11-28T10:14:00Z", "by" => @ada, "how" => "person"}

    push =
      push(context)
      |> Map.put("sensitive_rules", @rules)
      |> Map.put("sensitive", mark)

    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "fetch")
    assert eventually(fn -> completed(context.session_id) != [] end, 20_000)
    [fetch] = completed(context.session_id)
    assert fetch.data["refused"] == "sensitive"
    assert fetch.data["content"] =~ "since #{@ada} marked it"
    assert fetch.data["content"] =~ "10:14 UTC"
  end

  defp sensitive_status_reported? do
    receive do
      {:report,
       %{
         "type" => "session.status",
         "sensitive_by" => "read_file",
         "sensitive_rule" => "read_file(records/**)"
       }} ->
        true

      {:report, _other} ->
        sensitive_status_reported?()
    after
      0 -> false
    end
  end

  defp completed(session_id),
    do: Enum.filter(Troupe.events(session_id), &(&1.type == "tool_call_completed"))

  defp push(context) do
    %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "profile" => "records",
      "channel" => "stable"
    }
  end

  defp shell(session_id, command) do
    connection =
      %Dispatch.Context{
        principal: %{"subject" => @ada},
        scopes: [:observe, :control, :admin],
        connection: self()
      }

    Dispatch.call(
      "shell.run",
      %{
        "command_id" => "c-#{System.unique_integer([:positive])}",
        "session_id" => session_id,
        "command" => command,
        "agent" => false
      },
      connection
    )
  end

  defp quieten(session_id) do
    Troupe.cancel(session_id)
    Troupe.stop_session(session_id)
  catch
    :exit, _ -> :ok
  end
end
