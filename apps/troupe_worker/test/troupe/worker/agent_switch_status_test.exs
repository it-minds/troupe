defmodule Troupe.Worker.AgentSwitchStatusTest do
  @moduledoc """
  The agent a pod session runs as, as the plane is told it.

  The plane's row names the agent a session was created as, and a listing offers to start
  another one like it. A switch happens on the pod, so the pod says so in its
  `session.status`: `agent` is the root's agent once it has been switched, and nil before,
  which the plane reads as "keep what the row has". Needs the session tier (OpenBao and
  MinIO), as every `SessionCase` suite does.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake

  @moduletag timeout: 120_000

  test "a switch of the root's agent is reported, and nothing is said of one before it",
       context do
    context = requires_tier(context)
    sid = context.session_id

    fake =
      start_supervised!(
        Supervisor.child_spec({Fake, steps: [], default: {:text, "done"}},
          id: {Fake, System.unique_integer([:positive])}
        )
      )

    assert {:ok, _} = activate(context, fake: fake, report: reporter_to(self()))
    assert %{"agent" => nil} = await_status()

    assert {:ok, _} = Troupe.switch_profile(sid, "plan")
    assert %{"agent" => "plan"} = await_status(&(&1["agent"] == "plan"))
  end

  defp await_status(predicate \\ fn _ -> true end, timeout \\ 15_000) do
    receive do
      {:sealed, %{"type" => "session.status"} = report} ->
        if predicate.(report), do: report, else: await_status(predicate, timeout)

      {:sealed, _other} ->
        await_status(predicate, timeout)
    after
      timeout -> flunk("no matching session.status within #{timeout}ms")
    end
  end
end
