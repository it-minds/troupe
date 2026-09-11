defmodule Troupe.Protocol.CanonicalTest do
  @moduledoc """
  Canonical JSON and the event hash chain.

  These matter more than their size suggests: the audit guarantee is that anyone can
  re-derive the chain from stored bytes, in any language. That only holds if the
  encoding is byte-stable, so the tests here are about bytes, not about parsing back
  to the same term.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.{Canonical, Event}

  doctest Troupe.Protocol.Canonical

  describe "canonical encoding" do
    test "sorts object keys by code point, at every depth" do
      assert Canonical.encode(%{"b" => 1, "a" => 2}) == ~s({"a":2,"b":1})
      assert Canonical.encode(%{"z" => %{"b" => 1, "a" => 2}}) == ~s({"z":{"a":2,"b":1}})
      assert Canonical.encode(%{"B" => 1, "a" => 2}) == ~s({"B":1,"a":2})
    end

    test "is insensitive to the order keys were inserted in" do
      one = Canonical.encode(%{"a" => 1, "b" => 2, "c" => 3})
      other = Canonical.encode(%{"c" => 3, "b" => 2, "a" => 1})
      assert one == other
    end

    test "treats atom and string keys as the same key" do
      assert Canonical.encode(%{a: 1, b: 2}) == Canonical.encode(%{"a" => 1, "b" => 2})
    end

    test "preserves array order, which is data rather than presentation" do
      assert Canonical.encode(["c", "a", "b"]) == ~s(["c","a","b"])
    end

    test "emits no insignificant whitespace" do
      refute Canonical.encode(%{"a" => [1, 2], "b" => %{"c" => 3}}) =~ ~r/\s/
    end

    test "handles the scalar types an event can carry" do
      assert Canonical.encode(nil) == "null"
      assert Canonical.encode(true) == "true"
      assert Canonical.encode(42) == "42"
      assert Canonical.encode("hi") == ~s("hi")
      assert Canonical.encode(%{}) == "{}"
      assert Canonical.encode([]) == "[]"
    end

    test "escapes exactly as JSON requires, so the bytes survive a round trip" do
      encoded = Canonical.encode(%{"k" => "a\"b\\c\nd\tünïcode 🎩"})
      assert {:ok, %{"k" => back}} = Jason.decode(encoded)
      assert back == "a\"b\\c\nd\tünïcode 🎩"
    end

    test "hashes are stable across equal-but-differently-built terms" do
      assert Canonical.hash(%{"a" => 1, "b" => 2}) == Canonical.hash(%{"b" => 2, "a" => 1})
      refute Canonical.hash(%{"a" => 1}) == Canonical.hash(%{"a" => 2})
      assert Canonical.hash(%{}) =~ ~r/^sha256:[0-9a-f]{64}$/
    end
  end

  describe "the event chain" do
    test "seals events into a chain that verifies" do
      chain = build_chain(["session_created", "user_input", "llm_response"])

      assert Event.verify(chain) == :ok
      assert [first | _] = chain
      assert first.prev_hash == nil
      assert Enum.map(chain, & &1.seq) == [1, 2, 3]
    end

    test "each link is the digest of the previous event" do
      [first, second, _third] = build_chain(["a", "b", "c"])
      assert second.prev_hash == Event.hash(first)
    end

    test "flipping one byte of any event is caught at that seq" do
      chain = build_chain(["a", "b", "c", "d"])

      tampered =
        List.update_at(chain, 2, fn event -> %{event | data: %{"n" => "tampered"}} end)

      # The altered event still has the right prev_hash, so it verifies; the *next*
      # one is where the chain breaks, which is what a verifier reports.
      assert {:error, 4, :prev_hash_mismatch} = Event.verify(tampered)
    end

    test "a removed event is caught as a gap" do
      chain = build_chain(["a", "b", "c"])
      assert {:error, 3, _} = Event.verify(List.delete_at(chain, 1))
    end

    test "the hash ignores prev_hash itself, so a verifier can recompute it" do
      [first | _] = build_chain(["a", "b"])
      assert Event.hash(first) == Event.hash(%{first | prev_hash: "sha256:nonsense"})
    end

    test "an event survives a JSON round trip unchanged" do
      [_, event | _] = build_chain(["a", "b"])
      restored = event |> Event.to_json() |> Jason.encode!() |> Jason.decode!() |> Event.from_json()

      assert restored.seq == event.seq
      assert restored.prev_hash == event.prev_hash
      assert restored.type == event.type
      assert Event.hash(restored) == Event.hash(event)
    end

    test "ephemeral events carry no seq and never join the chain" do
      event = Event.ephemeral("llm_delta", ["root"], %{"text" => "hi"})

      assert event.ephemeral?
      assert event.seq == nil
      assert %{"ephemeral" => true} = Event.to_json(event)
      refute Map.has_key?(Event.to_json(event), "seq")
    end
  end

  defp build_chain(types) do
    types
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {type, seq}, acc ->
      event = %Event{type: type, data: %{"n" => seq}, agent: ["root"]}
      acc ++ [Event.seal(event, seq, List.last(acc), "2026-09-11T00:00:0#{seq}.000Z")]
    end)
  end
end
