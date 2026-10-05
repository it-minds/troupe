defmodule Troupe.Agent.ThinkingFormTest do
  @moduledoc """
  A model's `reasoning_effort` reaches Anthropic in the form the model takes (Decision
  780): an agent's request to a named provider of `type: anthropic`, sent to a loopback
  stand-in that records the body, carries adaptive thinking and the effort for one of the
  newest models, and a budget where the provider's model list says the model takes one.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.Catalog
  alias Troupe.Test.PromptCacheStandIn

  test "one of the newest models is sent adaptive thinking at the configured effort", context do
    body = first_request(context, "claude-opus-5-5", "high", %{})

    assert body["model"] == "claude-opus-5-5"
    assert body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
    assert body["output_config"] == %{"effort" => "high"}
    refute Map.has_key?(body["thinking"], "budget_tokens")
  end

  test "a model the provider's list says takes a budget is sent one, whatever its name",
       context do
    catalog = %{"gw/house-model" => %Catalog{id: "gw/house-model", thinking: :budget}}
    body = first_request(context, "house-model", "medium", catalog)

    assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 8_192}
    refute Map.has_key?(body, "output_config")
  end

  defp first_request(context, model, effort, catalog) do
    stand_in = PromptCacheStandIn.start(script: fn _n, _body -> {:text, "done"} end)
    on_exit(fn -> PromptCacheStandIn.stop(stand_in) end)

    provider = %{
      type: :anthropic,
      base_url: stand_in.base_url,
      api_key: "test-key",
      auth: :api_key,
      source: :yaml,
      models: %{model => %{id: model, context: nil, max_output: nil, reasoning_effort: effort}}
    }

    %{session: session} =
      start_session(context,
        config_overrides: [
          providers: %{"gw" => provider},
          model: "gw/" <> model,
          catalog: catalog
        ]
      )

    sid = session.id
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "think about it")
    await_state(sid, [:idle], 30_000)

    [{1, "/v1/messages", body, _usage} | _] = PromptCacheStandIn.drain()
    body
  end
end
