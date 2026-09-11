defmodule Troupe.Protocol do
  @moduledoc """
  The wire contract, and the only thing a Troupe client is allowed to depend on.

  `PROTOCOL.md` at the repository root is the normative description and is written to
  stand alone — a client author should never need to read this code. These modules
  are that document expressed as data, so the two cannot drift: the JSON Schemas
  shipped in `protocol/schema/v1/` are generated from the same definitions the server
  validates against.

  Nothing here starts a process or touches a session. It is types, codecs, a command
  table, and a client.
  """

  @version "1"

  @doc "The protocol major version this build speaks."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Every major version this build can speak, newest first."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: [@version]

  @spec supports?(String.t()) :: boolean()
  def supports?(version), do: version in supported_versions()
end
