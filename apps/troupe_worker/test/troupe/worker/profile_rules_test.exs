defmodule Troupe.Worker.ProfileRulesTest do
  @moduledoc """
  A worker profile's per-tool rules are an enforced layer for every session on its pods
  (#724). The plane reads them at every activation, the profile's and every profile's it
  extends, and sends them as `permission_rules`, each with the profile that wrote it; the
  pod adds them to the session's rules as the `profile` scope. Of every rule that matches a
  call the strictest holds, so the session's own files cannot loosen them, and a refusal
  names the profile. A `deny` for `shell` refuses a command the person types with `!` too.

  Driven the way a pod is: `session.activate` from the plane, then the agent's turn, and a
  person's command through the dispatcher the pod's socket uses.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Error
  alias Troupe.Worker.Plane.Commands

  @moduletag timeout: 60_000

  @ada "ada@example.test"

  @rules [
    %{"action" => "deny", "rule" => "shell(touch)", "profile" => "standard"},
    %{"action" => "allow", "rule" => "shell(touch)", "profile" => "fixing"}
  ]

  setup context do
    context = requires_tier(context)

    on_exit(fn ->
      Application.delete_env(:troupe_worker, :session_defaults)
      quieten(context.session_id)
    end)

    context
  end

  test "the agent's call a profile's rule denies is refused, naming the profile, whatever else allows it",
       context do
    defaults =
      activation(context,
        steps: [{:tools, [{"shell", %{"command" => "touch ran.txt"}}]}, {:text, "done"}]
      )

    Application.put_env(:troupe_worker, :session_defaults, defaults)

    push = Map.put(push(context), "permission_rules", @rules)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "go")

    completed = await_completed(context.session_id)
    refute completed.data["ok"]

    # The parent's deny holds over the child's allow: two scopes, and the strictest wins.
    assert completed.data["content"] =~
             "refused by the rule deny shell(touch), from the worker profile standard"

    refute File.exists?(Path.join(defaults[:workspace], "ran.txt"))
  end

  test "a command the person types is refused by the profile's deny, and runs without it",
       context do
    Application.put_env(:troupe_worker, :session_defaults, activation(context))

    push = Map.put(push(context), "permission_rules", @rules)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    assert {:error, %Error{message: "forbidden", data: data}} =
             shell(context.session_id, "touch ran.txt")

    assert data.setting == "permissions"
    assert data.reason =~ "deny shell(touch), from the worker profile standard"

    # Asleep, and woken with the rule gone from the profile: the next activation is where
    # the profile's word arrives.
    assert {:ok, _} = Sessions.dormant(context.session_id)

    assert {:ok, %{"activated" => true}} =
             Commands.handle("session.activate", Map.put(push(context), "permission_rules", []))

    assert {:ok, %{"run_id" => _}} = shell(context.session_id, "echo fine")
  end

  defp push(context) do
    %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "profile" => "fixing",
      "channel" => "stable"
    }
  end

  defp shell(session_id, command) do
    connection =
      %Dispatch.Context{
        principal: %{"subject" => @ada},
        # The owner, who alone may run commands on a session.
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

  defp await_completed(session_id) do
    receive do
      {:troupe_event, ^session_id, %{type: "tool_call_completed"} = event} -> event
      {:troupe_event, ^session_id, _other} -> await_completed(session_id)
    after
      20_000 -> flunk("no tool_call_completed")
    end
  end

  defp quieten(session_id) do
    Troupe.cancel(session_id)
    Troupe.stop_session(session_id)
  catch
    :exit, _ -> :ok
  end
end
