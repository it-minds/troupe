defmodule Troupe.Worker.LifespanChangedTest do
  @moduledoc """
  How long a pod session lasts (#1209): the plane's activation names it, and a new
  session's `session_created` records it; its owner changes it at the plane, which says
  `lifespan.changed`, and the log gains `session_lifespan_changed` with what it was, what it
  is and who said so. Never input. A session not up here records nothing; the plane's row
  is the record.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Worker.Plane.Commands

  @moduletag timeout: 60_000

  setup context do
    context = requires_tier(context)

    on_exit(fn ->
      Application.delete_env(:troupe_worker, :session_defaults)
      quieten(context.session_id)
    end)

    context
  end

  defp told(context, from, to),
    do: %{"session_id" => context.session_id, "from" => from, "to" => to, "actor" => "ada@example.test"}

  test "a new session's first event says how long it lasts, and a change is a line, no turn",
       context do
    Application.put_env(:troupe_worker, :session_defaults, activation(context))

    assert {:ok, %{"activated" => true}} =
             Commands.handle("session.activate", activation_push(context, "throwaway"))

    assert {:ok, %{"recorded" => true}} =
             Commands.handle("lifespan.changed", told(context, "throwaway", "normal"))

    events = Troupe.events(context.session_id)
    assert %{data: %{"lifespan" => "throwaway"}} = Enum.find(events, &(&1.type == "session_created"))
    assert [changed] = Enum.filter(events, &(&1.type == "session_lifespan_changed"))
    assert changed.data == %{"from" => "throwaway", "to" => "normal", "actor" => "ada@example.test"}
    refute Enum.any?(events, &(&1.type in ["user_input", "llm_request"]))
  end

  test "records nothing for a session not up here, and refuses another word", context do
    assert {:ok, %{"recorded" => false}} =
             Commands.handle("lifespan.changed", told(context, "normal", "persistent"))

    assert {:error, %{message: "invalid_params"}} =
             Commands.handle("lifespan.changed", told(context, "normal", "forever"))
  end

  defp activation_push(context, lifespan),
    do: %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "profile" => "fixing",
      "channel" => "stable",
      "lifespan" => lifespan
    }

  defp quieten(session_id) do
    Troupe.cancel(session_id)
    Troupe.stop_session(session_id)
  catch
    :exit, _ -> :ok
  end
end
