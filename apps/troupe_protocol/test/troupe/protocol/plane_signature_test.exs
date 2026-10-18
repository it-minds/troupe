defmodule Troupe.Protocol.PlaneSignatureTest do
  @moduledoc """
  The plane's signed answers (#657): the document, the envelope, and every way a client
  refuses one. The vector at the bottom is the one the desktop app's verifier is held to
  (`clients/gui/packages/client/test/plane-signature.test.ts`).
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.PlaneSignature

  @seed :binary.copy(<<7>>, 32)
  @now ~U[2026-10-18 12:00:00Z]

  defp keypair(seed \\ @seed) do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {%{public_key: public, fingerprint: PlaneSignature.fingerprint(public)}, secret}
  end

  defp sign(kind, body, secret, public, opts \\ []) do
    document =
      PlaneSignature.document(
        kind,
        body,
        Keyword.merge([now: @now, plane: "https://plane.example.test"], opts)
      )

    signature = :crypto.sign(:eddsa, :none, document, [secret, :ed25519])
    PlaneSignature.envelope(document, signature, PlaneSignature.fingerprint(public))
  end

  test "a signed answer is the body it was signed over, from the key pinned" do
    {key, secret} = keypair()

    body = %{
      "versions" => %{"tui" => %{"minimum" => "0.21.0-beta"}},
      "release" => %{"url" => nil}
    }

    signed = sign("client_versions", body, secret, key.public_key)

    assert {:ok,
            %{body: ^body, signed_at: "2026-10-18T12:00:00Z", expires_at: "2026-10-25T12:00:00Z"}} =
             PlaneSignature.verify(signed, key, "client_versions", now: @now)
  end

  test "the document is canonical JSON with the kind, the plane and the window" do
    text =
      PlaneSignature.document("client_defaults", %{"b" => 1, "a" => 2},
        now: @now,
        plane: "https://p.example.test"
      )

    assert text ==
             ~s({"body":{"a":2,"b":1},"expires_at":"2026-10-25T12:00:00Z","kind":"client_defaults","plane":"https://p.example.test","signed_at":"2026-10-18T12:00:00Z"})
  end

  test "an answer changed after it was signed is refused as forged" do
    {key, secret} = keypair()

    signed =
      sign("client_defaults", %{"enforced" => %{"max_turns" => 10}}, secret, key.public_key)

    edited =
      Map.update!(
        signed,
        "document",
        &String.replace(&1, ~s("max_turns":10), ~s("max_turns":900))
      )

    assert {:error, :forged} = PlaneSignature.verify(edited, key, "client_defaults", now: @now)

    assert PlaneSignature.refusal(:forged, "https://plane.example.test",
             what: "the organisation's document"
           ) ==
             "the organisation's document from https://plane.example.test does not match its signature: " <>
               "it was changed after the plane signed it, and is not taken"
  end

  test "an answer signed by another key names that key" do
    {pinned, _secret} = keypair()
    {other, other_secret} = keypair(:binary.copy(<<9>>, 32))
    signed = sign("client_versions", %{"versions" => %{}}, other_secret, other.public_key)

    assert {:error, {:other_key, fingerprint}} =
             PlaneSignature.verify(signed, pinned, "client_versions", now: @now)

    assert fingerprint == other.fingerprint

    sentence =
      PlaneSignature.refusal({:other_key, fingerprint}, "https://plane.example.test",
        what: "the version policy",
        pinned: pinned.fingerprint
      )

    assert sentence =~ "is signed by the key #{other.fingerprint}, not by #{pinned.fingerprint}"
    assert sentence =~ "not taken until you accept the new key"
  end

  test "an expired answer, one signed as the other kind, an unsigned one and nonsense are refused" do
    {key, secret} = keypair()
    signed = sign("client_versions", %{"versions" => %{}}, secret, key.public_key)

    assert {:error, {:expired, "2026-10-25T12:00:00Z"}} =
             PlaneSignature.verify(signed, key, "client_versions", now: ~U[2026-10-25 12:00:00Z])

    assert {:error, {:wrong_kind, "client_versions"}} =
             PlaneSignature.verify(signed, key, "client_defaults", now: @now)

    assert {:error, :unsigned} = PlaneSignature.verify(nil, key, "client_versions")

    assert {:error, :malformed} =
             PlaneSignature.verify(%{"algorithm" => "rsa"}, key, "client_versions")

    assert {:error, :malformed} =
             PlaneSignature.verify(
               %{signed | "signature" => "not base64!"},
               key,
               "client_versions", now: @now)
  end

  test "a key is read from what the plane serves, its fingerprint worked out again" do
    {key, _secret} = keypair()
    served = PlaneSignature.key_json(key.public_key) |> Map.put("fingerprint", "SHA256:lies")

    assert {:ok, %{public_key: raw, fingerprint: fingerprint}} = PlaneSignature.read_key(served)
    assert raw == key.public_key
    assert fingerprint == key.fingerprint
    assert String.starts_with?(fingerprint, "SHA256:")

    assert {:error, :malformed} =
             PlaneSignature.read_key(%{"algorithm" => "ed25519", "public_key" => "AAAA"})
  end

  # The vector the desktop app's TypeScript verifier checks the same way: a fixed seed, a
  # fixed time, one answer.
  test "the shared vector" do
    {key, secret} = keypair()

    signed =
      sign(
        "client_versions",
        %{"versions" => %{"desktop" => %{"recommended" => "0.22.0-beta"}}},
        secret,
        key.public_key
      )

    assert Base.encode64(key.public_key) == "6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw="
    assert key.fingerprint == "SHA256:/oEsEvOrTOasXbaaw1L5BssbEe9D+zPiUu9/9VImOIk"

    assert signed["signature"] ==
             "vvRwPMQ83kuULmIjIoq/wVj2eB4eOnmrmU9kuHHSg1t2waFkqnOuJhEL2QIV9Gnt+SahvTn37Y7NLLprK+RtDA=="
  end
end
