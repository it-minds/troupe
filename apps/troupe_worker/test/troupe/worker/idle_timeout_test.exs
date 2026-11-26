defmodule Troupe.Worker.IdleTimeoutTest do
  @moduledoc """
  A pod puts a session to sleep after the team's idle timeout, which the plane sends with
  every activation as `idle_timeout_seconds`: the number clients are told. A plane that
  sends none leaves the pod's own ten minutes; a number longer than a timer can wait is
  held at the longest it can, and one that is not a positive whole number is no timeout.

  Driven the way a pod is: `session.activate` from the plane, through the commands the
  control link runs.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Worker.Plane.Commands
  alias Troupe.Worker.Session.Manager

  @moduletag timeout: 60_000

  @fallback_ms 10 * 60 * 1000

  setup context do
    context = requires_tier(context)
    Application.put_env(:troupe_worker, :session_defaults, activation(context))
    on_exit(fn -> Application.delete_env(:troupe_worker, :session_defaults) end)
    context
  end

  test "a session sleeps after the idle timeout it was activated with, and not before",
       context do
    push = Map.put(push(context), "idle_timeout_seconds", 1)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)
    started = System.monotonic_time(:millisecond)

    assert dormant_after(context.session_id) == 1_000

    eventually(fn -> Sessions.whereis(context.session_id) == nil end, 10_000)
    assert System.monotonic_time(:millisecond) - started >= 900
  end

  test "a plane that sends none leaves the pod's own ten minutes", context do
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push(context))

    assert dormant_after(context.session_id) == @fallback_ms
    assert {:ok, _} = Sessions.dormant(context.session_id)
  end

  test "a timeout longer than a timer can wait is held at the longest it can", context do
    push = Map.put(push(context), "idle_timeout_seconds", 10_000_000_000)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    assert dormant_after(context.session_id) == 4_294_967_000
    assert {:ok, _} = Sessions.dormant(context.session_id)
  end

  test "a timeout that is not a positive whole number is none", context do
    for given <- [0, -60, "600", 1.5] do
      push = Map.put(push(context), "idle_timeout_seconds", given)
      assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

      assert dormant_after(context.session_id) == @fallback_ms
      assert {:ok, _} = Sessions.dormant(context.session_id)
    end
  end

  defp dormant_after(session_id) do
    session_id |> Sessions.whereis() |> Manager.status() |> Map.fetch!(:dormant_after_ms)
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
end
