defmodule Troupe.Worker.ActivateTwiceTest do
  @moduledoc """
  Two activations of one session that arrive together, as the A2A facade's open after a
  create sends them: both are answered with the one running session.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Worker.Plane.Commands

  @moduletag timeout: 60_000

  setup context do
    context = requires_tier(context)

    on_exit(fn ->
      Application.delete_env(:troupe_worker, :session_defaults)

      try do
        Troupe.stop_session(context.session_id)
      catch
        :exit, _ -> :ok
      end
    end)

    context
  end

  test "both are answered, and one tree runs", context do
    Application.put_env(:troupe_worker, :session_defaults, activation(context))

    push = %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "profile" => "dev",
      "channel" => "stable"
    }

    for _round <- 1..3 do
      answers =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> Commands.handle("session.activate", push) end) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert Enum.all?(answers, &match?({:ok, %{"activated" => true}}, &1)), inspect(answers)
      assert {:ok, _} = Sessions.dormant(context.session_id)
    end
  end

  # A tree that outlived the manager that started it, as one does when that manager went
  # before it was answered: the next activation finds the session's name taken and answers
  # the tree that runs, rather than failing with `already_started`.
  test "a tree that is already running is the answer, not an error", context do
    Application.put_env(:troupe_worker, :session_defaults, activation(context))

    push = %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "profile" => "dev",
      "channel" => "stable"
    }

    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)
    tree = Troupe.Registry.whereis({:session, context.session_id})
    manager = Sessions.whereis(context.session_id)
    ref = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^ref, :process, ^manager, :killed}, 5_000
    assert Process.alive?(tree)

    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)
    assert Troupe.Registry.whereis({:session, context.session_id}) == tree
  end
end
