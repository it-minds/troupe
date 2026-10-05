defmodule Troupe.Worker.IdentifyTest do
  @moduledoc """
  A pod session's model calls name the worker as the client, whichever client is
  attached, and carry what the plane attributes the session with: its owner, its team
  and its worker profile (Decision 787). Read off the requests the scripted model was
  sent.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.LLM.Fake

  @moduletag timeout: 180_000

  test "a pod session's call names the worker, its owner, its team and its profile", context do
    context = requires_tier(context)
    fake = start_supervised!({Fake, steps: [{:text, "done"}], default: {:text, "done"}})

    assert {:ok, _} =
             activate(context,
               fake: fake,
               prompt: "hello",
               owner_subject: "ada@example.test",
               profile: "standard"
             )

    eventually(fn -> Fake.requests(fake) != [] end, 15_000)
    [request | _] = Fake.requests(fake)
    team = context.team

    assert %{client: "worker", identify: true} = request

    assert %{owner: "ada@example.test", team: ^team, profile: "standard", agent: "root"} =
             request.attribution
  end
end
