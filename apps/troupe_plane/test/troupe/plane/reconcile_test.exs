defmodule Troupe.Plane.ReconcileTest do
  @moduledoc """
  The ledger and the gateway, compared.

  Two systems keep a record of the same spend for different reasons, and the nightly job
  says whether they agree. The done item asks for two things: that a gateway request id
  is accepted exactly once, and that injected drift is reported — so every test here
  injects a specific kind of disagreement and checks it is named rather than summed away.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Ledger, Reconcile, Sessions}

  @moduletag timeout: 60_000

  setup do
    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    user = person("ada@example.test", ["engineering"])

    {:ok, session} =
      Sessions.create(%{
        id: "s-#{System.unique_integer([:positive])}",
        owner_id: user.id,
        owner_subject: user.subject,
        team_id: team.id,
        profile: "dev",
        state: "active",
        epoch: 1
      })

    to = DateTime.utc_now() |> DateTime.add(1, :hour)
    from = DateTime.add(to, -2, :hour)

    %{team: team, user: user, session: session, from: from, to: to}
  end

  describe "the ledger itself" do
    test "accepts each gateway request id exactly once", context do
      attrs = usage(context, "req-1", 500)

      assert {:ok, first} = Ledger.record(attrs)

      # A repeat is a success, not an error: a worker replaying a queued report after a
      # reconnect has done nothing wrong and must not be told it has.
      assert {:duplicate, second} = Ledger.record(attrs)
      assert first.id == second.id
      assert Ledger.spent_micros(context.team.id) == 500

      # And a second report with different numbers does not overwrite the first. What
      # the gateway billed is what the first report said.
      assert {:duplicate, standing} = Ledger.record(usage(context, "req-1", 9_999))
      assert standing.cost_micros == 500
      assert Ledger.spent_micros(context.team.id) == 500
    end

    test "two different calls are two records", context do
      {:ok, _} = Ledger.record(usage(context, "req-1", 500))
      {:ok, _} = Ledger.record(usage(context, "req-2", 250))

      assert Ledger.spent_micros(context.team.id) == 750
      assert MapSet.size(Ledger.request_ids(context.from, context.to)) == 2
    end
  end

  describe "reconciling" do
    test "agreement is reported as agreement", context do
      {:ok, _} = Ledger.record(usage(context, "req-1", 500))
      {:ok, _} = Ledger.record(usage(context, "req-2", 250))

      result =
        Reconcile.compare(
          [gateway("req-1", 500), gateway("req-2", 250)],
          context.from,
          context.to
        )

      assert result.clean?
      assert result.drift_micros == 0
      assert result.missing == []
      assert result.extra == []
      assert result.mismatched == []
      assert result.gateway_records == 2
      assert result.ledger_records == 2
    end

    test "a call the gateway billed and the ledger never saw is named", context do
      {:ok, _} = Ledger.record(usage(context, "req-1", 500))

      result =
        Reconcile.compare(
          [gateway("req-1", 500), gateway("req-lost", 300)],
          context.from,
          context.to
        )

      refute result.clean?
      assert [%{request_id: "req-lost", cost_micros: 300}] = result.missing
      assert result.extra == []
      assert result.drift_micros == 300
    end

    test "a call the ledger has and the gateway does not is named separately", context do
      {:ok, _} = Ledger.record(usage(context, "req-1", 500))
      {:ok, _} = Ledger.record(usage(context, "req-phantom", 700))

      result = Reconcile.compare([gateway("req-1", 500)], context.from, context.to)

      refute result.clean?
      assert result.missing == []
      assert [%{request_id: "req-phantom", cost_micros: 700}] = result.extra
      assert result.drift_micros == 700
    end

    test "a cost both have and disagree about is named with both numbers", context do
      {:ok, _} = Ledger.record(usage(context, "req-1", 500))

      result = Reconcile.compare([gateway("req-1", 650)], context.from, context.to)

      refute result.clean?
      assert [mismatch] = result.mismatched
      assert mismatch.request_id == "req-1"
      assert mismatch.gateway_micros == 650
      assert mismatch.ledger_micros == 500
      assert mismatch.session_id == context.session.id
      assert result.drift_micros == 150
    end

    test "drift over the threshold is distinguished from drift under it", context do
      {:ok, _} = Ledger.record(usage(context, "req-1", 500))

      small =
        Reconcile.compare([gateway("req-1", 500), gateway("req-lost", 10)], context.from, context.to,
          threshold_micros: 1_000
        )

      refute small.clean?
      refute small.over_threshold?

      large =
        Reconcile.compare([gateway("req-1", 500), gateway("req-lost", 50_000)], context.from, context.to,
          threshold_micros: 1_000
        )

      assert large.over_threshold?
    end

    test "only the window is compared", context do
      {:ok, _} = Ledger.record(usage(context, "req-now", 500))

      long_ago = DateTime.add(context.from, -30, :day)
      {:ok, _} = Ledger.record(usage(context, "req-then", 900, occurred_at: long_ago))

      result = Reconcile.compare([gateway("req-now", 500)], context.from, context.to)

      assert result.clean?
      assert result.ledger_records == 1
    end

    test "a gateway's own shapes are read, whatever it calls things", context do
      {:ok, _} = Ledger.record(usage(context, "req-1", 1_500_000))

      # LiteLLM reports whole currency units as a float, under `data`, keyed `id`.
      body = %{"data" => [%{"id" => "req-1", "spend" => 1.5, "model" => "m"}]}

      fetched = fn _from, _to -> {:ok, normalise(body)} end
      assert {:ok, records} = Reconcile.fetch(context.from, context.to, fetcher: fetched)

      result = Reconcile.compare(records, context.from, context.to)
      assert result.clean?, "1.5 units should read as 1,500,000 micros"
    end

    test "with no gateway configured it says so rather than reporting a clean ledger", context do
      assert {:error, :no_gateway_configured} = Reconcile.fetch(context.from, context.to)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp usage(context, request_id, cost_micros, opts \\ []) do
    %{
      session_id: context.session.id,
      team_id: context.team.id,
      owner_subject: context.user.subject,
      model: "fake-model",
      input_tokens: 10,
      output_tokens: 2,
      cost_micros: cost_micros,
      gateway_request_id: request_id,
      occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now())
    }
  end

  defp gateway(request_id, cost_micros) do
    %{"request_id" => request_id, "cost_micros" => cost_micros, "model" => "fake-model"}
  end

  # The normalisation `Reconcile.fetch/3` does for an HTTP gateway, applied by hand so
  # the test can exercise it without an HTTP server.
  defp normalise(%{"data" => records}) do
    Enum.map(records, fn record ->
      %{
        "request_id" => record["id"],
        "cost_micros" => round(record["spend"] * 1_000_000),
        "model" => record["model"]
      }
    end)
  end
end
