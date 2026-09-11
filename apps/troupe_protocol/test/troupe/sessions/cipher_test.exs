defmodule Troupe.Sessions.CipherTest do
  @moduledoc """
  What the object tier is encrypted with.

  Three properties, and all three are about failure: a tampered object must not decode,
  an object moved between sessions must not decode, and two encryptions of the same
  plaintext must not look alike.
  """

  use ExUnit.Case, async: true

  alias Troupe.Sessions.Cipher

  setup do
    %{key: :crypto.strong_rand_bytes(32), session: "s-#{System.unique_integer([:positive])}"}
  end

  test "what goes in comes out", %{key: key, session: session} do
    plaintext = :crypto.strong_rand_bytes(10_000)

    sealed = Cipher.seal(key, session, plaintext)
    assert {:ok, ^plaintext} = Cipher.open(key, session, sealed)
  end

  test "the ciphertext does not contain the plaintext", %{key: key, session: session} do
    marker = "CANARY-NEVER-IN-THE-OBJECT-STORE"
    sealed = Cipher.seal(key, session, "before " <> marker <> " after")

    refute sealed =~ marker
  end

  test "the same plaintext twice looks different", %{key: key, session: session} do
    # A fresh nonce per object. Reusing one under the same key leaks the XOR of two
    # plaintexts and breaks the authentication outright.
    first = Cipher.seal(key, session, "the same thing")
    second = Cipher.seal(key, session, "the same thing")

    refute first == second
    assert {:ok, "the same thing"} = Cipher.open(key, session, first)
    assert {:ok, "the same thing"} = Cipher.open(key, session, second)
  end

  test "a byte changed anywhere makes it fail rather than decode", %{key: key, session: session} do
    sealed = Cipher.seal(key, session, String.duplicate("session content ", 100))

    for position <- [5, 20, 40, byte_size(sealed) - 1] do
      <<before::binary-size(^position), byte, rest::binary>> = sealed
      tampered = <<before::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>

      assert {:error, :invalid} = Cipher.open(key, session, tampered),
             "a change at byte #{position} decoded anyway"
    end
  end

  test "an object from another session does not decode here", %{key: key} do
    sealed = Cipher.seal(key, "s-one", "one session's history")

    # The session id is authenticated, so a store that mixed up two sessions' objects
    # cannot hand one the other's history.
    assert {:error, :invalid} = Cipher.open(key, "s-two", sealed)
    assert {:ok, _} = Cipher.open(key, "s-one", sealed)
  end

  test "another key does not open it", %{key: key, session: session} do
    sealed = Cipher.seal(key, session, "content")

    assert {:error, :invalid} = Cipher.open(:crypto.strong_rand_bytes(32), session, sealed)
  end

  test "something that is not ours is refused as such", %{key: key, session: session} do
    assert {:error, :unknown_format} = Cipher.open(key, session, "just some bytes")
    refute Cipher.ours?("just some bytes")
    assert Cipher.ours?(Cipher.seal(key, session, "x"))
  end
end
