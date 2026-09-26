defmodule Troupe.Session.LocalPricingTest do
  @moduledoc """
  What a call cost when the gateway does not say.

  A streamed response cannot carry a cost header: the headers are written before a token
  is generated, so LiteLLM's `x-litellm-response-cost` is absent and its breakdown
  headers all read `0.0`. Streaming is how the harness talks to a model, so on such a
  gateway every session's cost was zero while the tokens were counted correctly.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
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

  # The index has carried `tokens` and `cost` from the start, and only `pin_session/2`
  # ever wrote to the entry: every listing said 0 tokens and $0.00 however long a session
  # had been working.
  test "reaches the listing, so a session says what it has spent", context do
    %{session: session} =
      start_session(context,
        steps: [{:text, "done"}],
        cost_micros: nil,
        config_overrides: [
          catalog: %{"fake-model" => %Catalog{id: "fake-model", input: 1.0e-6, output: 2.0e-6}}
        ]
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "say something")
    await_event(session.id, :llm_response)

    # The totals are added by a cast from the agent, so they land just after the event
    # the test waited for.
    assert %{tokens: tokens, cost: cost} = eventually_listed(session.id)
    assert tokens > 0
    assert cost > 0.0
  end

  defp eventually_listed(session_id, tries \\ 50) do
    listed = Enum.find(Troupe.list_live_sessions(%{}), &(&1.id == session_id))

    cond do
      listed && listed.tokens > 0 -> listed
      tries == 0 -> listed
      true -> Process.sleep(20) && eventually_listed(session_id, tries - 1)
    end
  end

  test "is nothing, rather than a guess, for a model with no price", context do
    response = priced(context, %{"fake-model" => %Catalog{id: "fake-model", context: 200_000}})

    assert response.data["gateway"] in [nil, %{}] or
             not Map.has_key?(response.data["gateway"], "cost_micros")
  end

  # #160. A pod has no catalog — nothing fetched one — and a gateway model the catalog
  # does not list, such as `qwen3-235b` behind LiteLLM, has no price in it anyway. So
  # every such call was free as far as the plane's ledger could tell, and no money budget
  # ever applied to it.
  describe "a price in models.prices" do
    test "prices a call the catalog cannot, marked as this machine's arithmetic", context do
      write_file(context, ".troupe/config.yaml", """
      models:
        prices:
          fake-model: {input: 1.0, output: 2.0}
      """)

      response = priced(context, %{})

      # The fake's answer is 100 input tokens and one output token: $1 and $2 a million.
      assert %{"cost_micros" => 102, "priced_locally" => true} = response.data["gateway"]
    end

    test "loses to the gateway's own figure", context do
      write_file(context, ".troupe/config.yaml", """
      models:
        prices:
          fake-model: {input: 1.0, output: 2.0}
      """)

      %{session: session} = start_session(context, steps: [{:text, "done"}], cost_micros: 777)

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "say something")
      await_event(session.id, :llm_response)

      response = session.id |> Log.replay() |> Enum.find(&(&1.type == "llm_response"))
      assert response.data["gateway"]["cost_micros"] == 777
      refute Map.has_key?(response.data["gateway"], "priced_locally")
    end

    test "loses to the provider's own price in the catalog", context do
      write_file(context, ".troupe/config.yaml", """
      models:
        prices:
          fake-model: {input: 1.0, output: 2.0}
      """)

      response =
        priced(context, %{
          "fake-model" => %Catalog{id: "fake-model", input: 3.0e-6, output: 4.0e-6}
        })

      assert %{"cost_micros" => 304, "priced_locally" => true} = response.data["gateway"]
    end
  end

  test "a model with no price anywhere is said once a session, not counted as free in silence",
       context do
    test = self()
    handler = "unpriced-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:troupe, :llm, :unpriced],
      fn _event, _measurements, meta, _config -> send(test, {:unpriced, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{session: session} =
      start_session(context,
        steps: [{:tools, [{"list_files", %{}}]}, {:text, "done"}],
        cost_micros: nil
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "look around")
    await_event(session.id, :turn_ended)

    session_id = session.id
    assert 2 == session_id |> Log.replay() |> Enum.count(&(&1.type == "llm_response"))
    assert_receive {:unpriced, %{session_id: ^session_id, model: "fake-model"}}
    refute_receive {:unpriced, %{session_id: ^session_id}}, 100
  end

  # The claim is the session's rather than the claiming agent's: a subagent that called the
  # model first has stopped by the time the next one calls it (#171), and the claim stays.
  test "a model only subagents call is said once a session, not once a delegation", context do
    test = self()
    handler = "unpriced-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:troupe, :llm, :unpriced],
      fn _event, _measurements, meta, _config -> send(test, {:unpriced, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, pricey} =
      Definition.parse(
        "pricey",
        "---\nmode: subagent\nmodel: unpriced-model\n---\npricey",
        :project
      )

    definitions =
      Definitions.from_list(Definitions.all(Definitions.load(System.tmp_dir!())) ++ [pricey])

    %{session: session} =
      start_session(context,
        routes: %{
          "root" => [
            {:tools, [{"delegate", %{"agent" => "pricey", "task" => "one"}}]},
            {:tools, [{"delegate", %{"agent" => "pricey", "task" => "two"}}]},
            {:text, "done"}
          ],
          "pricey" => [
            {:tools, [{"finish", %{"summary" => "one"}}]},
            {:tools, [{"finish", %{"summary" => "two"}}]}
          ]
        },
        cost_micros: nil,
        definitions: definitions
      )

    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "delegate twice")
    await_event(session.id, :turn_ended, 10_000)

    session_id = session.id

    assert [_one, _two] =
             session_id |> Log.replay() |> Enum.filter(&(&1.type == "delegation_started"))

    assert_receive {:unpriced, %{session_id: ^session_id, model: "unpriced-model"}}
    refute_receive {:unpriced, %{session_id: ^session_id, model: "unpriced-model"}}, 100
  end
end
