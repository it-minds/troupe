defmodule Troupe.Release.MinisignTest do
  @moduledoc """
  The one verifier of a release's signature (#66, Decision 865): minisign's formats, a
  rotation's two signatures, and every refusal a sentence. Each key is a throwaway made
  here; the shared vectors are `vectors_test.exs`'s.
  """

  use ExUnit.Case, async: true

  alias Troupe.Release.{Keys, Minisign}

  setup do
    {current, current_secret} = Minisign.generate_keypair()
    {previous, previous_secret} = Minisign.generate_keypair()

    %{
      current: current,
      current_secret: current_secret,
      previous: previous,
      previous_secret: previous_secret
    }
  end

  test "a public key reads back from its file and from its line", %{current: key} do
    assert {:ok, ^key} = Minisign.parse_public_key(Minisign.public_key_file(key))
    assert {:ok, ^key} = Minisign.parse_public_key(Minisign.encode_public_key(key))
    assert "RW" <> _ = Minisign.encode_public_key(key)
    assert String.length(Minisign.key_id(key)) == 16

    assert {:error, "is empty" <> _} = Minisign.parse_public_key("untrusted comment: nothing\n")
    assert {:error, _} = Minisign.parse_public_key("RWQ not base64 !")

    assert {:error, "is not a minisign public key" <> _} =
             Minisign.parse_public_key(Base.encode64("Ed short"))
  end

  test "a signature by a trusted key holds, and says by which", %{
    current: key,
    current_secret: secret
  } do
    signature = Minisign.sign("the manifest", secret, trusted_comment: "file:manifest.json")
    # minisign's own shape: four lines, the signature's base64 starting "RU" for "ED".
    assert [_comment, "RU" <> _, "trusted comment: file:manifest.json", _global] =
             String.split(signature, "\n", trim: true)

    assert {:ok, %{key_ids: [id], trusted_comment: "file:manifest.json"}} =
             Minisign.verify("the manifest", signature, [key])

    assert id == Minisign.key_id(key)
    # Windows line endings in the file change nothing.
    assert {:ok, _} =
             Minisign.verify("the manifest", String.replace(signature, "\n", "\r\n"), [key])
  end

  test "each refusal is a sentence", %{
    current: key,
    current_secret: secret,
    previous: other,
    previous_secret: other_secret
  } do
    signature = Minisign.sign("the manifest", secret)

    assert {:error, "does not match its signature by key " <> rest} =
             Minisign.verify("the manifest!", signature, [key])

    assert rest =~ "changed after it was signed"

    assert {:error, "is signed by key " <> rest} =
             Minisign.verify("the manifest", Minisign.sign("the manifest", other_secret), [key])

    assert rest =~ "which this build does not trust (it trusts #{Minisign.key_id(key)})"
    refute rest =~ Minisign.key_id(other) <> ")"

    assert {:error, "has no signature" <> _} = Minisign.verify("the manifest", "", [key])

    assert {:error, "has a signature file that is not a minisign signature" <> _} =
             Minisign.verify("the manifest", "garbage\n", [key])

    assert {:error, "cannot be checked: this build trusts no release key" <> _} =
             Minisign.verify("the manifest", signature, [])

    [comment, line, _trusted, global] = String.split(signature, "\n", trim: true)
    edited = Enum.join([comment, line, "trusted comment: something else", global], "\n")

    assert {:error, "has a signature by key " <> rest} =
             Minisign.verify("the manifest", edited, [key])

    assert rest =~ "trusted comment was changed"
  end

  test "a rotation's two signatures: each key alone, or both, accepts it", context do
    message = "the manifest of a rotation"

    both =
      Minisign.sign(message, context.current_secret) <>
        Minisign.sign(message, context.previous_secret)

    assert {:ok, %{key_ids: [_]}} = Minisign.verify(message, both, [context.current])
    assert {:ok, %{key_ids: [_]}} = Minisign.verify(message, both, [context.previous])

    assert {:ok, %{key_ids: [_, _]}} =
             Minisign.verify(message, both, [context.current, context.previous])

    # A trusted block that does not hold is a refusal, whatever the other block says.
    [first | _] = String.split(both, "\n", trim: true) |> Enum.chunk_every(4)
    bad = Minisign.sign("another message", context.previous_secret)
    mixed = Enum.join(first, "\n") <> "\n" <> bad
    assert {:error, _} = Minisign.verify(message, mixed, [context.current, context.previous])
  end

  test "the unhashed signature minisign once wrote is read too", %{
    current: key,
    current_secret: secret
  } do
    signature = Minisign.sign("old", secret, legacy: true)
    assert [_, "RW" <> _, _, _] = String.split(signature, "\n", trim: true)
    assert {:ok, _} = Minisign.verify("old", signature, [key])
  end

  test "an unencrypted secret key reads back; an encrypted or cut one is refused", %{
    current: key,
    current_secret: secret
  } do
    text = Minisign.encode_secret_key(secret)
    assert {:ok, ^secret} = Minisign.parse_secret_key(text)
    assert Minisign.public_key(secret) == key

    {:ok, bytes} = text |> String.split("\n", trim: true) |> List.last() |> Base.decode64()
    <<"Ed", 0, 0, rest::binary>> = bytes

    assert {:error, "is encrypted" <> _} =
             Minisign.parse_secret_key(Base.encode64("EdSc" <> rest))

    # The seed, after the algorithm, the salt, the limits and the key id, no longer gives
    # the public key beside it.
    <<head::binary-size(62), seed_byte, tail::binary>> = bytes
    changed = Base.encode64(head <> <<Bitwise.bxor(seed_byte, 1)>> <> tail)

    assert {:error, "is not a whole minisign secret key" <> _} =
             Minisign.parse_secret_key(changed)

    assert {:error, _} = Minisign.parse_secret_key("")
  end

  test "this build's keys come from priv/release-keys.txt, the current one first" do
    {:ok, keys} = Minisign.parse_key_list(File.read!(Keys.path()))
    assert Keys.trusted() == keys

    {a, _} = Minisign.generate_keypair()
    {b, _} = Minisign.generate_keypair()

    list =
      "# a comment\n\n#{Minisign.encode_public_key(a)}\n  #{Minisign.encode_public_key(b)}  \n"

    assert {:ok, [^a, ^b]} = Minisign.parse_key_list(list)
    assert {:error, _} = Minisign.parse_key_list("RWnot-a-key\n")
  end
end
