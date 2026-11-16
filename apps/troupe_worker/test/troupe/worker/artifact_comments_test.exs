defmodule Troupe.Worker.ArtifactCommentsTest do
  @moduledoc """
  A comment on an artifact a pod's session published (#62): the plane says
  `artifact.commented`, and the session's log gains an `artifact_commented` event with the
  artifact, who wrote the comment and what, which whoever steers the session reads. Never
  input: no turn starts and no agent is given it. A session not up here, or at another
  epoch, records nothing; the artifact's thread on the plane is the record.
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

  defp told(context, epoch \\ 1),
    do: %{
      "session_id" => context.session_id,
      "epoch" => epoch,
      "artifact" => %{"id" => "art-1", "title" => "Plan"},
      "comment" => %{
        "id" => "c-1",
        "author" => %{"subject" => "cy@example.test", "display_name" => "Cy"},
        "body" => "Can you add last quarter?",
        "created_at" => "2026-11-16T09:00:00Z"
      }
    }

  test "is a line in the running session's log, and no turn", context do
    Application.put_env(:troupe_worker, :session_defaults, activation(context))
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", activation_push(context))

    assert {:ok, %{"recorded" => true}} = Commands.handle("artifact.commented", told(context))

    events = Troupe.events(context.session_id)
    assert [event] = Enum.filter(events, &(&1.type == "artifact_commented"))
    assert event.data["artifact"] == %{"id" => "art-1", "title" => "Plan"}
    assert event.data["comment"]["body"] == "Can you add last quarter?"
    assert event.data["comment"]["author"]["display_name"] == "Cy"
    refute Enum.any?(events, &(&1.type in ["user_input", "llm_request"]))
  end

  test "records nothing for a session not up here or at another epoch, and refuses a shapeless one", context do
    assert {:ok, %{"recorded" => false}} = Commands.handle("artifact.commented", told(context))

    Application.put_env(:troupe_worker, :session_defaults, activation(context))
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", activation_push(context))
    assert {:ok, %{"recorded" => false}} = Commands.handle("artifact.commented", told(context, 2))

    assert {:error, %{message: "invalid_params"}} =
             Commands.handle("artifact.commented", Map.delete(told(context), "comment"))
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
