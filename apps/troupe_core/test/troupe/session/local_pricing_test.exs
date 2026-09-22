defmodule Troupe.Session.LocalPricingTest do
  @moduledoc """
  What a call cost when the gateway does not say.

  A streamed response cannot carry a cost header: the headers are written before a token
  is generated, so LiteLLM's `x-litellm-response-cost` is absent and its breakdown
  headers all read `0.0`. Streaming is how the harness talks to a model, so on such a
  gateway every session's cost was zero while the tokens were counted correctly.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.Catalog
  alias Troupe.Session.Log

  defp priced(context, catalog) do
    %{session: session} =
      start_session(context,
        steps: [{:text, "done"}],
        cost_micros: nil,
        config_overrides: [catalog: catalog]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "say something")
    await_event(session.id, :llm_response)

    session.id
    |> Log.replay()
    |> Enum.find(&(&1.type == "llm_response"))
  end

  test "is worked out from the catalog, and marked as this machine's arithmetic", context do
    # $1 per million in, $2 per million out, which is what a catalog entry holds.
    catalog = %{"fake-model" => %Catalog{id: "fake-model", input: 1.0e-6, output: 2.0e-6}}

    response = priced(context, catalog)

    assert %{"cost_micros" => cost, "priced_locally" => true} = response.data["gateway"]
    assert cost > 0
  end

  test "is nothing, rather than a guess, for a model with no price", context do
    response = priced(context, %{"fake-model" => %Catalog{id: "fake-model", context: 200_000}})

    assert response.data["gateway"] in [nil, %{}] or
             not Map.has_key?(response.data["gateway"], "cost_micros")
  end
end
