defmodule Troupe.Log.FoldTest do
  @moduledoc """
  Logs from every released version still mean what they meant.

  A session written a year ago and activated today is replayed by today's code, so the
  thing that has to hold is not that the code is unchanged but that its *reading* of an
  old log is. Each released version has fixtures under `test/fixtures/logs/<version>/`
  and a recorded fold hash; every build replays all of them and compares.

  A hash that moves is not a test to update. It is the build saying an old session would
  now come back as something different, which is either a bug or a change that needs a
  new schema version and an upcaster.
  """

  use ExUnit.Case, async: true

  alias Troupe.Log.{Fold, Upcast}
  alias Troupe.Protocol.Event

  @fixtures Path.join([File.cwd!(), "..", "..", "test", "fixtures", "logs"]) |> Path.expand()

  describe "recorded fixtures" do
    test "every version's logs replay to their recorded fold hash" do
      versions = versions()
      assert versions != [], "no fixtures recorded; run `mix troupe.fixtures.record`"

      for version <- versions do
        %{"folds" => folds} = hashes(version)
        assert folds != %{}

        for {name, expected} <- folds do
          path = Path.join([@fixtures, version, name <> ".jsonl"])
          assert File.exists?(path), "#{version}/#{name}.jsonl is recorded but missing"

          assert {:ok, _state, actual} = Fold.file(path)

          assert actual == expected, """
          #{version}/#{name} folds differently in this build.

          recorded: #{expected}
          now:      #{actual}

          An old log now means something different. If that is deliberate, it needs a new
          schema version and an upcaster, not a new number here.
          """
        end
      end
    end

    test "the fixtures are distinct, so each one is actually covering something" do
      for version <- versions() do
        %{"folds" => folds} = hashes(version)

        assert map_size(folds) == folds |> Map.values() |> Enum.uniq() |> length(),
               "#{version} has two fixtures with the same fold; one of them tests nothing"
      end
    end

    test "every fixture's hash chain verifies, as a log from that version would" do
      for version <- versions(), {name, _hash} <- hashes(version)["folds"] do
        events = read([@fixtures, version, name <> ".jsonl"])
        assert :ok = Event.verify(events), "#{version}/#{name} has a broken chain"
      end
    end
  end

  describe "the witness" do
    test "covers every durable event type the agent's replay acts on" do
      # Read from the source rather than listed here, so adding a clause to the agent's
      # replay without adding one to the fold is caught by CI rather than by nobody.
      replayed = agent_replay_types()
      witnessed = MapSet.new(Fold.witnessed_types())
      missing = MapSet.difference(replayed, witnessed)

      assert MapSet.size(replayed) > 0, "found no replay clauses; the reader needs updating"

      assert MapSet.size(missing) == 0, """
      Troupe.Agent.Server replays #{inspect(MapSet.to_list(missing))}, which
      Troupe.Log.Fold does not witness. A change to how those events are read would not
      move any fixture hash, which is a blind spot rather than a passing test.
      """
    end

    test "a change in what an event means moves the hash" do
      base = [
        event(1, :user_input, %{"source" => "user", "text" => "hello"}),
        event(2, :llm_response, %{
          "message" => %{"role" => "assistant", "content" => []},
          "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
        })
      ]

      # The same events with one field different: a fold that ignored `usage` would give
      # these two the same hash, which is exactly the blind spot to avoid.
      different = [
        Enum.at(base, 0),
        event(2, :llm_response, %{
          "message" => %{"role" => "assistant", "content" => []},
          "usage" => %{"input_tokens" => 99, "output_tokens" => 2}
        })
      ]

      assert Fold.hash(base) != Fold.hash(different)
    end

    test "compaction is folded, because it is the one thing that shrinks a conversation" do
      grown =
        for seq <- 1..6, do: event(seq, :user_input, %{"source" => "user", "text" => "m#{seq}"})

      compacted =
        grown ++
          [
            event(7, :compacted, %{
              "summary" => "the gist",
              "conversation" => [%{"role" => "user", "content" => []}]
            })
          ]

      assert Fold.state(grown)["agents"]["root"]["messages"] == 6
      assert Fold.state(compacted)["agents"]["root"]["messages"] == 1
      assert Fold.state(compacted)["agents"]["root"]["compactions"] == 1
    end

    test "a failed request's note is a message, and an error from before notes is not" do
      asked = event(1, :user_input, %{"source" => "user", "text" => "hello"})
      old = [asked, event(2, :llm_error, %{"reason" => "the gateway is down"})]

      noted = [
        asked,
        event(2, :llm_error, %{
          "reason" => "the gateway is down",
          "note" =>
            "The previous model request failed: the gateway is down. Try a different approach."
        })
      ]

      assert Fold.state(old)["agents"]["root"]["messages"] == 1
      assert Fold.state(noted)["agents"]["root"]["messages"] == 2
      assert Fold.hash(old) != Fold.hash(noted)
    end

    test "the hash does not depend on key order" do
      one = [event(1, :user_input, %{"source" => "user", "text" => "a"})]
      two = [event(1, :user_input, %{"text" => "a", "source" => "user"})]

      assert Fold.hash(one) == Fold.hash(two)
    end
  end

  describe "upcasting" do
    test "an event at the current version is untouched" do
      original = event(1, :user_input, %{"source" => "user", "text" => "a"})
      assert Upcast.event(original) == original
    end

    test "an event from a newer version is read rather than rejected" do
      from_the_future = %{event(1, :user_input, %{"source" => "user", "text" => "a"}) | v: 99}

      assert Upcast.event(from_the_future) == from_the_future
      assert Upcast.from_the_future([from_the_future]) == [99]
      assert Fold.state([from_the_future])["events"] == 1
    end

    test "a log of the current version reports nothing from the future" do
      events = read([@fixtures, List.first(versions()), "simple_turn.jsonl"])
      assert Upcast.from_the_future(events) == []
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp versions do
    case File.ls(@fixtures) do
      {:ok, entries} -> entries |> Enum.filter(&File.dir?(Path.join(@fixtures, &1))) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  defp hashes(version) do
    [@fixtures, version, "hashes.json"] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  defp read(parts) do
    parts
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> Jason.decode!() |> Event.from_json()))
  end

  # The event types `Agent.Server.fold_event/2` has a clause for, read out of the source
  # so the two cannot drift apart quietly.
  defp agent_replay_types do
    # Line endings normalised because this reads source rather than data, and a
    # checkout that stores CRLF would otherwise make every anchor below miss — which
    # reads like `fold_event/2` having no clauses at all.
    source =
      [File.cwd!(), "lib", "troupe", "agent", "server.ex"]
      |> Path.join()
      |> File.read!()
      |> String.replace("\r\n", "\n")

    [_before, body] =
      String.split(source, "defp fold_event(%Event{type: type, data: data}, state) do", parts: 2)

    [clauses, _rest] = String.split(body, "\n  end\n", parts: 2)

    # A type can also have a head of its own, ahead of the case (the goal's two do).
    heads = Regex.scan(~r/^  defp fold_event\(%Event\{type: "([a-z_]+)"/m, source)

    ~r/^      "([a-z_]+)" ->$/m
    |> Regex.scan(clauses)
    |> Enum.concat(heads)
    |> Enum.map(fn [_line, type] -> type end)
    |> MapSet.new()
  end

  defp event(seq, type, data) do
    %Event{
      seq: seq,
      type: to_string(type),
      agent: ["root"],
      data: data,
      actor: Event.Actor.system(),
      ts: "2026-01-01T00:00:00.000000Z"
    }
  end
end
