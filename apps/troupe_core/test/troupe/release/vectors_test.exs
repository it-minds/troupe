defmodule Troupe.Release.VectorsTest do
  @moduledoc """
  The shared test vectors in `test/fixtures/release/` (Decision 865): every case
  `vectors.json` lists, as any verifier of a release has to answer it. The desktop app's,
  when it comes, runs the same file. `scripts/release-vectors.exs` writes them.
  """

  use ExUnit.Case, async: true

  alias Troupe.Release.{Manifest, Minisign}

  @dir Path.expand("../../../../../test/fixtures/release", __DIR__)

  setup_all do
    %{vectors: @dir |> Path.join("vectors.json") |> File.read!() |> JSON.decode!()}
  end

  test "every signature case is answered as the vectors say", %{vectors: vectors} do
    assert length(vectors["signatures"]) >= 10

    for %{
          "name" => name,
          "manifest" => manifest,
          "signature" => signature,
          "trusted" => trusted,
          "expect" => expect
        } <-
          vectors["signatures"] do
      keys =
        for file <- trusted do
          {:ok, key} = Minisign.parse_public_key(read(file))
          key
        end

      got =
        case Minisign.verify(read(manifest), read(signature), keys) do
          {:ok, _} -> "ok"
          {:error, why} when is_binary(why) -> "refused"
        end

      assert got == expect, "#{name}: #{got}, not #{expect}"
    end
  end

  test "every artifact case is answered as the vectors say", %{vectors: vectors} do
    for %{
          "name" => name,
          "manifest" => manifest,
          "artifact" => artifact,
          "file" => file,
          "expect" => expect
        } <-
          vectors["artifacts"] do
      {:ok, decoded} = Manifest.decode(read(manifest))
      entry = Enum.find(decoded.artifacts, &(&1.file == artifact))

      got =
        case Manifest.check_file(entry, Path.join(@dir, file)) do
          :ok -> "ok"
          {:error, why} when is_binary(why) -> "refused"
        end

      assert got == expect, "#{name}: #{got}, not #{expect}"
    end
  end

  # The bytes signed are the bytes in the checkout: a line ending changed by git would fail
  # every case above, and say only that the signature does not hold.
  test "the vectors are byte for byte what was signed" do
    refute read("manifest.json") =~ "\r"

    assert read("manifest.json") ==
             Manifest.encode(elem(Manifest.decode(read("manifest.json")), 1))
  end

  defp read(file), do: File.read!(Path.join(@dir, file))
end
