defmodule Troupe.Worker.PlaneMemoryTest do
  @moduledoc """
  The organisation's memory on a pod (#55). The plane reads the organisation's, the
  session's team's and its worker profile's memory documents at every activation and sends
  them as `memory`; the session reads them as instructions from the organisation before
  every file, in that order, and `config --explain` names each with its version. A save
  reaches a session at its next activation.

  Driven the way a pod is: `session.activate` from the plane, then the agent's turn.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Config.Explain
  alias Troupe.LLM.Fake
  alias Troupe.Worker.Plane.Commands

  @moduletag timeout: 60_000

  @memory [
    %{"scope" => "profile", "name" => "fixing", "version" => 1, "hash" => "sha256:p", "text" => "Profile: fix one issue at a time."},
    %{"scope" => "organisation", "name" => nil, "version" => 7, "hash" => "sha256:o", "text" => "Org: deploy on Tuesdays."},
    %{"scope" => "team", "name" => "design", "version" => 3, "hash" => "sha256:t", "text" => "Team: use the design tokens."}
  ]

  setup context do
    context = requires_tier(context)

    on_exit(fn ->
      Application.delete_env(:troupe_worker, :session_defaults)
      quieten(context.session_id)
    end)

    context
  end

  test "the activation's memory is the first of the session's instructions, in order, and explained",
       context do
    File.write!(Path.join(context.workspace, "AGENTS.md"), "Repository: run mix check.\n")

    fake =
      start_supervised!(
        Supervisor.child_spec({Fake, steps: [{:text, "one"}], default: {:text, "done"}},
          id: {Fake, System.unique_integer([:positive])}
        )
      )

    defaults = activation(context, fake: fake, config_overrides: [system_prompt: "per_turn"])
    Application.put_env(:troupe_worker, :session_defaults, defaults)

    push = Map.put(push(context), "memory", @memory)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "go")
    await_turn(context.session_id)

    [request] = Fake.requests(fake)

    at = fn text ->
      {at, _} = :binary.match(request.system, text)
      at
    end

    assert at.("The organisation's memory (version 7):\nOrg: deploy on Tuesdays.") <
             at.("The team design's memory (version 3):\nTeam: use the design tokens.")

    assert at.("Team: use the design tokens.") <
             at.("The worker profile fixing's memory (version 1):\nProfile: fix one issue at a time.")

    assert at.("Profile: fix one issue at a time.") < at.("Repository: run mix check.")

    {text, 0} = Explain.explain_session(context.session_id)

    assert text =~
             "  memory   the organisation's memory, version 7 (the plane, with the session's activation)"

    assert text =~ "  memory   the team design's memory, version 3"
    assert text =~ "  memory   the worker profile fixing's memory, version 1"
  end

  # A save on the plane while the session runs here: the plane says `session.memory`, and
  # the session's next turn reads the new documents and says what changed.
  test "a save told to the pod reaches the running session at its next turn", context do
    fake =
      start_supervised!(
        Supervisor.child_spec({Fake, steps: [{:text, "one"}, {:text, "two"}], default: {:text, "done"}},
          id: {Fake, System.unique_integer([:positive])}
        )
      )

    defaults = activation(context, fake: fake, config_overrides: [system_prompt: "per_turn"])
    Application.put_env(:troupe_worker, :session_defaults, defaults)

    push = Map.put(push(context), "memory", @memory)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    Troupe.subscribe(context.session_id)
    Troupe.send_input(context.session_id, "go")
    await_turn(context.session_id)

    saved = [%{"scope" => "organisation", "name" => nil, "version" => 8, "hash" => "sha256:o8", "text" => "Org: deploy on Thursdays."}]
    told = %{"session_id" => context.session_id, "epoch" => 1, "memory" => saved}

    # A pod the session moved on from takes nothing for it.
    assert {:error, %{data: %{reason: "stale epoch"}}} = Commands.handle("session.memory", %{told | "epoch" => 2})
    assert {:ok, %{"memory" => 1}} = Commands.handle("session.memory", told)

    Troupe.send_input(context.session_id, "again")
    await_turn(context.session_id)

    [_first, second] = Fake.requests(fake)
    assert second.system =~ "Org: deploy on Thursdays."
    refute second.system =~ "Tuesdays"
    refute second.system =~ "Team: use the design tokens."

    events = Troupe.events(context.session_id)
    assert [changed] = Enum.filter(events, &(&1.type == "memory_changed"))

    assert changed.data["changes"] == [
             %{"scope" => "organisation", "name" => nil, "from" => 7, "to" => 8},
             %{"scope" => "team", "name" => "design", "from" => 3, "to" => nil},
             %{"scope" => "profile", "name" => "fixing", "from" => 1, "to" => nil}
           ]

    {text, 0} = Explain.explain_session(context.session_id)
    assert text =~ "the organisation's memory, version 8"
    refute text =~ "the team design's memory"
  end

  test "a session not up on the pod is said to be so", context do
    told = %{"session_id" => context.session_id, "epoch" => 1, "memory" => []}
    assert {:error, %{data: %{reason: "the session is not up on this pod"}}} = Commands.handle("session.memory", told)
  end

  test "an activation with none gives the session none", context do
    defaults = activation(context, config_overrides: [system_prompt: "per_turn"])
    Application.put_env(:troupe_worker, :session_defaults, defaults)

    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push(context))
    assert %{layers: layers} = Troupe.Session.resolved(context.session_id)
    assert layers.memory.documents == []
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

  defp await_turn(session_id) do
    receive do
      {:troupe_event, ^session_id, %{type: "turn_ended"}} -> :ok
      {:troupe_event, ^session_id, _other} -> await_turn(session_id)
    after
      20_000 -> flunk("no turn_ended")
    end
  end

  defp quieten(session_id) do
    Troupe.cancel(session_id)
    Troupe.stop_session(session_id)
  catch
    :exit, _ -> :ok
  end
end
