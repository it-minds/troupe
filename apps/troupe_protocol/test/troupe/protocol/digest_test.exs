defmodule Troupe.Protocol.DigestTest do
  @moduledoc """
  A SHA-256 is written as the same 64 lowercase hex characters by every app.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Digest

  @empty "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  test "sha256/1 is lowercase hex" do
    assert Digest.sha256("") == @empty
    assert Digest.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    assert Digest.sha256(["a", "bc"]) == Digest.sha256("abc")
  end

  test "tagged/1 names the algorithm before it" do
    assert Digest.tagged("") == "sha256:" <> @empty
  end
end
