defmodule Troupe.Plane.UsageTest do
  @moduledoc """
  What a pod's batch does to the ledger, and what it is told back.

  The reply is the contract. A pod deletes what it is holding up to the watermark this
  returns and folds its log forward from the same number next time, so a watermark that
  moved too far loses a charge and one that did not move at all makes a pod send the same
  records forever. Both are tested here.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Ledger
  alias Troupe.Plane.Ledger.Cache
  alias Troupe.Plane.Ledger.UsageRecord
  alias Troupe.Plane.Sessions
  alias Troupe.Plane.TeamBudget

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!(Cache)

    verify = fn
      "dev-token" ->
        {:ok,
         %{
           profile: "dev",
           namespace: "troupe-w-dev",
           pod_name: nil,
           service_account: "troupe-worker"
         }}

      _other ->
        {:error, :unauthenticated}
    end

    start_supervised!({Listener, port: 0, verify: verify})

    team = team_with_grant("eng", "dev", budget_micros: 10_000_000)

    {:ok, _session} =
      Sessions.create(%{
        id: "s-1",
        owner_subject: "idp|alice",
        profile: "dev",
        team_id: team.id
      })

    %{port: Listener.port(), team: team}
  end

  # Dated now unless a test says otherwise. A fixed date in September was fine while a
  # team's spend was all time, and read as nothing from October once a `monthly` team
  # counted only the month it is read in.
  defp usage(seq, cost, opts \\ []) do
    %{
      "seq" => seq,
      "gateway_request_id" => Keyword.get(opts, :id, "gw_#{seq}"),
      "model" => "anthropic/claude-opus-5",
      "input_tokens" => 100,
      "output_tokens" => 20,
      "cost_micros" => cost,
      "occurred_at" =>
        Keyword.get_lazy(opts, :at, fn -> DateTime.to_iso8601(DateTime.utc_now()) end)
    }
  end

  describe "usage.batch" do
    test "records every row and answers with the watermark", %{port: port, team: team} do
      worker = enrolled(port)

      assert {:ok, result} =
               call(worker, "usage.batch", %{
                 "session_id" => "s-1",
                 "records" => [usage(4, 1_000), usage(6, 2_500)]
               })

      assert result == %{"recorded" => 2, "duplicates" => 0, "usage_seq" => 6}
      assert Sessions.get("s-1").usage_seq == 6
      assert Ledger.spent_micros(team.id) == 3_500
      assert Ledger.session_cost_micros("s-1") == 3_500
    end

    test "the same batch twice is one charge and the same watermark", %{port: port, team: team} do
      worker = enrolled(port)
      batch = %{"session_id" => "s-1", "records" => [usage(4, 1_000)]}

      assert {:ok, %{"recorded" => 1, "usage_seq" => 4}} = call(worker, "usage.batch", batch)
      assert {:ok, second} = call(worker, "usage.batch", batch)

      assert second == %{"recorded" => 0, "duplicates" => 1, "usage_seq" => 4}
      assert Ledger.spent_micros(team.id) == 1_000
      assert TeamBudget.inspect_state(team).spent_micros == 1_000
    end

    test "a late batch cannot walk the watermark backwards", %{port: port} do
      worker = enrolled(port)

      {:ok, _} = call(worker, "usage.batch", %{"session_id" => "s-1", "records" => [usage(9, 1)]})

      # A retry of an older batch arrives after the newer one. It is still recorded —
      # a charge is a charge — but the pod is told where the ledger actually is.
      assert {:ok, %{"recorded" => 1, "usage_seq" => 9}} =
               call(worker, "usage.batch", %{"session_id" => "s-1", "records" => [usage(3, 1)]})

      assert Sessions.get("s-1").usage_seq == 9
    end

    test "the owner on the row is the plane's, not the pod's", %{port: port} do
      worker = enrolled(port)

      {:ok, _} =
        call(worker, "usage.batch", %{
          "session_id" => "s-1",
          "records" => [Map.put(usage(1, 5), "owner_subject", "idp|mallory")]
        })

      assert [record] = Repo.all(UsageRecord)
      assert record.owner_subject == "idp|alice"
    end

    test "a record with no gateway id is refused, because that is what joins the two ledgers",
         %{port: port} do
      worker = enrolled(port)

      assert {:error, error} =
               call(worker, "usage.batch", %{
                 "session_id" => "s-1",
                 "records" => [Map.delete(usage(1, 5), "gateway_request_id")]
               })

      assert error["data"]["reason"] =~ "gateway_request_id"
      assert Repo.all(UsageRecord) == []
    end

    test "a session the plane does not know is not an error, and the pod is told to stop",
         %{port: port} do
      worker = enrolled(port)

      assert {:ok, result} =
               call(worker, "usage.batch", %{
                 "session_id" => "s-gone",
                 "records" => [usage(7, 5)]
               })

      assert result == %{"recorded" => 0, "duplicates" => 0, "usage_seq" => 7}
    end

    test "a charge dated in the future is dated now, so a report can still see it", %{
      port: port,
      team: team
    } do
      worker = enrolled(port)
      ahead = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      {:ok, _} =
        call(worker, "usage.batch", %{
          "session_id" => "s-1",
          "records" => [usage(1, 500, at: ahead)]
        })

      assert [record] = Repo.all(UsageRecord)
      assert DateTime.compare(record.occurred_at, DateTime.utc_now()) != :gt
      assert [%{cost_micros: 500}] = Ledger.breakdown(team.id, :model)
    end

    test "an empty batch is accepted and changes nothing", %{port: port} do
      worker = enrolled(port)

      assert {:ok, %{"recorded" => 0, "usage_seq" => 0}} =
               call(worker, "usage.batch", %{"session_id" => "s-1", "records" => []})

      assert Sessions.get("s-1").usage_seq == 0
    end
  end

  describe "the ledger's reads" do
    test "a breakdown groups by model and by who owned the session", %{port: port, team: team} do
      worker = enrolled(port)

      {:ok, _} =
        call(worker, "usage.batch", %{
          "session_id" => "s-1",
          "records" => [
            usage(1, 1_000),
            Map.put(usage(2, 4_000), "model", "anthropic/claude-haiku-4-5")
          ]
        })

      assert [top, second] = Ledger.breakdown(team.id, :model)
      assert top.key == "anthropic/claude-haiku-4-5"
      assert top.cost_micros == 4_000
      assert second.cost_micros == 1_000

      assert [%{key: "idp|alice", calls: 2, cost_micros: 5_000, input_tokens: 200}] =
               Ledger.breakdown(team.id, :owner_subject)
    end

    test "the cache answers the same numbers, and a write throws it away", %{
      port: port,
      team: team
    } do
      worker = enrolled(port)
      assert Ledger.spent_micros(team.id) == 0

      {:ok, _} =
        call(worker, "usage.batch", %{"session_id" => "s-1", "records" => [usage(1, 700)]})

      # Had the write not invalidated it, this would still be the remembered zero.
      assert Ledger.spent_micros(team.id) == 700
    end

    test "a breakdown up to now is remembered, rather than asked again", %{
      port: port,
      team: team
    } do
      worker = enrolled(port)

      {:ok, _} =
        call(worker, "usage.batch", %{"session_id" => "s-1", "records" => [usage(1, 700)]})

      assert [%{cost_micros: 700}] = Ledger.breakdown(team.id, :model)

      # Written past the team's actor, so nothing throws the remembered answer away. A
      # breakdown with no `:to` was remembered under the instant it was asked, so the next
      # read was always a new key and a new aggregate, and saw this.
      {:ok, _} =
        Ledger.record(%{
          session_id: "s-1",
          team_id: team.id,
          owner_subject: "idp|alice",
          model: "anthropic/claude-opus-5",
          cost_micros: 300,
          gateway_request_id: "behind-the-cache"
        })

      assert [%{cost_micros: 700}] = Ledger.breakdown(team.id, :model)
    end

    test "clearing the cache changes no answer", %{port: port, team: team} do
      worker = enrolled(port)

      {:ok, _} =
        call(worker, "usage.batch", %{"session_id" => "s-1", "records" => [usage(1, 42)]})

      before = {Ledger.spent_micros(team.id), Ledger.breakdown(team.id, :model)}
      :ok = Cache.clear()
      assert {Ledger.spent_micros(team.id), Ledger.breakdown(team.id, :model)} == before
    end
  end

  # -- the wire ---------------------------------------------------------------

  defp enrolled(port) do
    worker = connect(port)

    {:ok, _} =
      call(worker, "enrol", %{
        "token" => "dev-token",
        "pod_name" => "troupe-w-dev-0",
        "capacity" => 4,
        "disk_total_bytes" => 1000
      })

    worker
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    %{socket: socket, id: :counters.new(1, [])}
  end

  defp call(worker, method, params) do
    :counters.add(worker.id, 1, 1)
    id = :counters.get(worker.id, 1)

    :ok =
      :gen_tcp.send(worker.socket, [
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}),
        "\n"
      ])

    case answer(worker, id) do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
      other -> {:error, other}
    end
  end

  # The plane pushes down this channel too, so a reply is the message carrying this id.
  defp answer(worker, id) do
    case read(worker) do
      %{"id" => ^id} = message -> message
      %{"method" => _method} -> answer(worker, id)
      other -> other
    end
  end

  defp read(worker, timeout \\ 5_000) do
    {:ok, line} = :gen_tcp.recv(worker.socket, 0, timeout)
    line |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
  end
end
