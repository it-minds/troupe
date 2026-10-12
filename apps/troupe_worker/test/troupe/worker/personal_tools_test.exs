defmodule Troupe.Worker.PersonalToolsTest do
  @moduledoc """
  A worker profile may forbid people offering their own signed-in tools to its pods
  (Decision 862, #595). The plane reads `spec.personalTools` from the profile at every
  activation and sends it as `personal_tools`; a session it activates with `forbid` refuses
  `tools.register` with a sentence naming the setting, says so in the pod's log, and
  registers nothing. Anything else, and a plane that says nothing, is the default: the
  person's tools are offered as #308 offers them.

  Driven the way a pod is: `session.activate` from the plane, then the registration a
  client sends over its connection, through the dispatcher the pod's socket uses.
  """

  use Troupe.Worker.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Error
  alias Troupe.Session.ClientTools
  alias Troupe.Worker.Plane.Commands

  @moduletag timeout: 60_000

  @ada "ada@example.test"

  @tool %{
    "name" => "wiki.search",
    "description" => "Search my wiki.",
    "schema" => %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
  }

  setup context do
    context = requires_tier(context)
    Application.put_env(:troupe_worker, :session_defaults, activation(context))
    on_exit(fn -> Application.delete_env(:troupe_worker, :session_defaults) end)
    on_exit(fn -> quieten(context.session_id) end)
    context
  end

  test "a profile that forbids them refuses the offer, says why, logs it and registers nothing",
       context do
    push = Map.put(push(context), "personal_tools", "forbid")
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    {result, log} = with_log(fn -> register(context.session_id) end)

    # Refused before any challenge, so nobody is asked to consent to what the pod will not
    # take, and in a sentence that names the profile and its setting.
    assert {:error, %Error{message: "forbidden", data: data}} = result
    assert data.setting == "personalTools"
    assert data.profile == "dev"
    assert data.reason =~ "worker profile dev"
    assert data.reason =~ "personalTools: forbid"

    assert log =~ "refused tools.register"
    assert log =~ context.session_id
    assert log =~ @ada
    assert log =~ "wiki.search"

    assert ClientTools.list(context.session_id) == []
    types = context.session_id |> Troupe.replay_from(0) |> Enum.map(& &1.type)
    refute "tools_registered" in types
    refute "session_tainted" in types
  end

  test "a profile that allows them, or says nothing, asks for the person's consent as before",
       context do
    for setting <- ["allow", nil] do
      push =
        if setting, do: Map.put(push(context), "personal_tools", setting), else: push(context)

      assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

      assert {:error, %Error{message: "consent_required", data: data}} =
               register(context.session_id)

      assert data["tools"] == ["wiki.search"]
      assert {:ok, _} = Sessions.dormant(context.session_id)
    end
  end

  # Asleep, and woken under a profile that has changed its mind: the activation is where
  # the profile's word arrives, so it holds from the next wake and restarts no pod.
  test "a profile that turns it off reaches a session at its next activation", context do
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push(context))
    assert {:error, %Error{message: "consent_required"}} = register(context.session_id)

    assert {:ok, _} = Sessions.dormant(context.session_id)
    forbid = Map.put(push(context), "personal_tools", "forbid")
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", forbid)

    assert {:error, %Error{message: "forbidden"}} = register(context.session_id)
  end

  defp push(context) do
    %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "profile" => "dev",
      "channel" => "stable"
    }
  end

  defp register(session_id) do
    connection =
      %Dispatch.Context{
        principal: %{"subject" => @ada},
        scopes: [:observe, :control],
        connection: self()
      }

    Dispatch.call(
      "tools.register",
      %{
        "command_id" => "c-#{System.unique_integer([:positive])}",
        "session_id" => session_id,
        "tools" => [@tool]
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
