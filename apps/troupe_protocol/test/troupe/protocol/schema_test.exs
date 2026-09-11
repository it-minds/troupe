defmodule Troupe.Protocol.SchemaTest do
  @moduledoc """
  The compatibility rule, checked in both directions.

  A protocol is a promise to people who are not in this repository. The rule that keeps
  it — add fields, never remove, rename, retype, or newly require one — is only worth
  anything if something fails when it is broken, so each of the four ways to break it
  gets its own case.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Troupe.Schema.Diff
  alias Troupe.Protocol.Schema

  describe "compatibility" do
    test "an added optional field passes" do
      committed = Schema.documents()
      current = add_field(committed, "events/user_input.json", "locale", %{"type" => "string"})

      assert Schema.incompatibilities(committed, current) == []
    end

    test "an added event type passes" do
      committed = Schema.documents()

      current =
        Map.put(committed, "events/something_new.json", %{
          "type" => "object",
          "properties" => %{"whatever" => %{"type" => "string"}},
          "required" => ["whatever"]
        })

      assert Schema.incompatibilities(committed, current) == []
    end

    test "a removed field fails" do
      committed = Schema.documents()
      current = drop_field(committed, "events/user_input.json", "source")

      assert [{:removed_field, "events/user_input.json", "source"}] =
               Schema.incompatibilities(committed, current)
    end

    test "a renamed field fails, because a rename is a removal" do
      committed = Schema.documents()

      current =
        committed
        |> drop_field("events/user_input.json", "text")
        |> add_field("events/user_input.json", "body", %{"type" => "string"})

      assert [{:removed_field, "events/user_input.json", "text"}] =
               Schema.incompatibilities(committed, current)
    end

    test "a changed type fails" do
      committed = Schema.documents()
      current = add_field(committed, "events/session_dormant.json", "last_seq", %{"type" => "string"})

      assert [{:retyped_field, "events/session_dormant.json", "last_seq", old, new}] =
               Schema.incompatibilities(committed, current)

      assert old == %{"type" => "integer"}
      assert new == %{"type" => "string"}
    end

    test "a newly required field fails" do
      committed = Schema.documents()
      current = require_field(committed, "events/agent_done.json", "summary")

      assert [{:newly_required, "events/agent_done.json", "summary"}] =
               Schema.incompatibilities(committed, current)
    end

    test "a removed event type fails" do
      committed = Schema.documents()
      current = Map.delete(committed, "events/cancelled.json")

      assert [{:removed_document, "events/cancelled.json"}] =
               Schema.incompatibilities(committed, current)
    end

    test "every breaking change reads as a sentence naming the field" do
      committed = Schema.documents()
      current = drop_field(committed, "events/user_input.json", "source")

      assert [change] = Schema.incompatibilities(committed, current)
      message = Schema.describe(change)

      assert message =~ "events/user_input.json"
      assert message =~ "source"
    end
  end

  describe "the committed schema" do
    test "is exactly what the current definitions generate" do
      root = Schema.Paths.root()
      committed = Diff.read_committed(root)

      assert committed != %{},
             "no committed schema in #{root} — run `mix troupe.schema.gen`"

      # Compared through JSON so the check is on what was written, not on how Elixir
      # happens to represent it.
      current = Map.new(Schema.documents(), fn {path, doc} -> {path, roundtrip(doc)} end)

      assert Schema.incompatibilities(committed, current) == []
      assert Map.keys(committed) |> Enum.sort() == Map.keys(current) |> Enum.sort()

      for {path, document} <- current do
        assert committed[path] == document,
               "#{path} is stale — run `mix troupe.schema.gen` and commit the result"
      end
    end
  end

  describe "validation" do
    test "accepts an event that matches its shape" do
      assert Schema.validate_event("user_input", %{"source" => "user", "text" => "hi"}) == :ok
    end

    test "names the field that is wrong" do
      assert {:error, problems} =
               Schema.validate_event("user_input", %{"source" => "user", "text" => 42})

      assert problems == ["text should be :string"]
    end

    test "names a missing required field" do
      assert {:error, ["missing required field text"]} =
               Schema.validate_event("user_input", %{"source" => "user"})
    end

    test "tolerates an unknown event type, the way a client must" do
      assert Schema.validate_event("from_the_future", %{"anything" => 1}) == :ok
    end

    test "tolerates extra fields, because adding one is allowed" do
      assert Schema.validate_event("user_input", %{
               "source" => "user",
               "text" => "hi",
               "locale" => "en"
             }) == :ok
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp add_field(documents, path, field, type) do
    update_in(documents, [path, "properties", field], fn _ -> type end)
  end

  defp drop_field(documents, path, field) do
    documents
    |> update_in([path, "properties"], &Map.delete(&1, field))
    |> update_in([path, "required"], &List.delete(&1, field))
  end

  defp require_field(documents, path, field) do
    update_in(documents, [path, "required"], &Enum.sort([field | &1]))
  end

  defp roundtrip(document), do: document |> Jason.encode!() |> Jason.decode!()
end
