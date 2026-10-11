defmodule Troupe.Release.Keys do
  @moduledoc """
  The release keys this build trusts, read from `priv/release-keys.txt` when it is compiled
  (#66, Decision 865).

  Compiled in, and nothing else: no setting, environment variable or file read at run time
  adds a key, so a client trusts exactly the keys of the commit it was built from. A test
  hands its own throwaway key to the function it calls instead.
  """

  alias Troupe.Release.Minisign

  @path Path.expand("../../../priv/release-keys.txt", __DIR__)
  @external_resource @path

  @keys (case Minisign.parse_key_list(File.read!(@path)) do
           {:ok, keys} -> keys
           {:error, why} -> raise "priv/release-keys.txt: #{why}"
         end)

  @doc "The keys, the current one first."
  @spec trusted() :: [Minisign.public_key()]
  def trusted, do: @keys

  @doc "Where the keys are written in the repository."
  @spec path() :: Path.t()
  def path, do: @path
end
