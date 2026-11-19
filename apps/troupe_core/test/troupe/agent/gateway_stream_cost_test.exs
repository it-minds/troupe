defmodule Troupe.Agent.GatewayStreamCostTest do
  @moduledoc """
  A call behind a LiteLLM gateway costs what the gateway's stream says it cost (#1133).

  The gateway sends its headers before the first token, so a streamed call's cost is not in
  them; asked to, it writes `usage.cost` into the stream's last chunk. A model the catalog
  does not price, addressed by the gateway's alias as a pod addresses it, was charged
  nothing: the call carried no cost and the turn counted it unpriced.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Test.ErrorStandIn

  test "the stream's cost lands on the call and on the turn's spend", context do
    stand_in =
      ErrorStandIn.start(
        script: fn _n, _body -> {:priced, {:text, "done"}, 0.000123450000000001} end
      )

    on_exit(fn -> ErrorStandIn.stop(stand_in) end)

    %{session: session} =
      start_session(context,
        config_overrides: [
          provider: "openai",
          model: "team-alias-not-in-any-catalog",
          base_url: stand_in.base_url <> "/v1",
          api_key: "sk-stand-in-0123456789abcdef"
        ]
      )

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "go")
    ended = await_event(sid, :turn_ended, 15_000)

    assert [%{data: %{"gateway" => gateway}}] = events_of_type(sid, :llm_response)
    assert gateway["cost_micros"] == 123
    refute Map.has_key?(gateway, "priced_locally")

    assert %{"calls" => 1, "cost_micros" => 123, "unpriced" => 0} = ended.data["turn"]
  end
end
