defmodule Troupe.Worker.VisibilityChangedTest do
  @moduledoc """
  A pod session given to its team by its owner, or taken back (#1169): the plane says
  `visibility.changed`, and the session's log gains `session_visibility_changed` with the
  visibility and who changed it, which every client attached hears. Never input. A session
  not up here records nothing; the plane's row is the record.
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

  defp told(context, visibility),
    do: %{
      "session_id" => context.session_id,
      "visibility" => visibility,
      "by" => "ada@example.test",
      "by_name" => "Ada"
    }

  test "is a line in the running session's log, each way, and no turn", context do
    Application.put_env(:troupe_worker, :session_defaults, activation(context))
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", activation_push(context))

    assert {:ok, %{"recorded" => true}} = Commands.handle("visibility.changed", told(context, "team"))
    assert {:ok, %{"recorded" => true}} = Commands.handle("visibility.changed", told(context, "private"))

    events = Troupe.events(context.session_id)
    assert [given, taken] = Enum.filter(events, &(&1.type == "session_visibility_changed"))
    assert given.data == %{"visibility" => "team", "by" => "ada@example.test", "by_name" => "Ada"}
    assert taken.data["visibility"] == "private"
    refute Enum.any?(events, &(&1.type in ["user_input", "llm_request"]))
  end

  test "records nothing for a session not up here, and refuses another visibility", context do
    assert {:ok, %{"recorded" => false}} = Commands.handle("visibility.changed", told(context, "team"))

    assert {:error, %{message: "invalid_params"}} =
             Commands.handle("visibility.changed", told(context, "everyone"))
  end

  defp activation_push(context),
    do: %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "profile" => "fixing",
      "channel" => "stable"
    }

  defp quieten(session_id) do
    Troupe.cancel(session_id)
    Troupe.stop_session(session_id)
  catch
    :exit, _ -> :ok
  end
end
