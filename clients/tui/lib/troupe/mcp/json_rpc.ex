defmodule Troupe.MCP.JSONRPC do
  @moduledoc "JSON-RPC 2.0 encode/decode helpers for MCP."

  @spec request(pos_integer(), String.t(), map()) :: String.t()
  def request(id, method, params) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})
  end

  @spec notification(String.t(), map()) :: String.t()
  def notification(method, params) do
    Jason.encode!(%{jsonrpc: "2.0", method: method, params: params})
  end

  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(binary) do
    Jason.decode(binary)
  end

  @spec result?(map()) :: boolean()
  def result?(%{} = map), do: Map.has_key?(map, "result")

  @spec error?(map()) :: boolean()
  def error?(%{} = map), do: Map.has_key?(map, "error")
end
