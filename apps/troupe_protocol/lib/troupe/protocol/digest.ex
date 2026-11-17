defmodule Troupe.Protocol.Digest do
  @moduledoc """
  A SHA-256 digest written as lowercase hex: a stored file's hash, a blob's name, a
  secret's fingerprint. Written once so that every app writes the same characters for
  the same bytes.
  """

  @doc "The SHA-256 of `data` as 64 lowercase hex characters."
  @spec sha256(iodata()) :: String.t()
  def sha256(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)

  @doc "The SHA-256 of `data` named as the log and the wire name one: `sha256:<hex>`."
  @spec tagged(iodata()) :: String.t()
  def tagged(data), do: "sha256:" <> sha256(data)
end
