defmodule Troupe.Protocol.JSONRPC do
  @moduledoc """
  JSON-RPC 2.0 framing: the three message shapes and how they map to and from JSON.

  Decoding is deliberately strict about the envelope and permissive about the
  payload. A malformed envelope is a protocol fault worth reporting; an unrecognised
  method or an extra field is not, because forward compatibility depends on both
  sides tolerating what they do not know.
  """

  alias Troupe.Protocol.Error

  @type id :: integer() | String.t()
  @type t ::
          {:request, id(), String.t(), map()}
          | {:notification, String.t(), map()}
          | {:result, id(), map()}
          | {:error, id() | nil, Error.t()}

  @doc "Encode a message to a JSON string. Never raises on protocol-shaped input."
  @spec encode(t()) :: String.t()
  def encode(message), do: message |> to_map() |> Jason.encode!()

  @doc "Encode to the map form, for transports that do their own serialisation."
  @spec to_map(t()) :: map()
  def to_map({:request, id, method, params}) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  def to_map({:notification, method, params}) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  def to_map({:result, id, result}) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  def to_map({:error, id, %Error{} = error}) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => Error.to_json(error)}
  end

  @doc """
  Decode one JSON string.

  Returns `{:error, %Error{}}` for anything that is not a well-formed JSON-RPC 2.0
  message, including batches, which this protocol does not use.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, json} -> from_map(json)
      {:error, _} -> {:error, Error.new(:parse_error)}
    end
  end

  @spec from_map(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(%{"jsonrpc" => "2.0"} = json) do
    case json do
      %{"id" => id, "method" => method} -> {:ok, {:request, id, method, params(json)}}
      %{"method" => method} -> {:ok, {:notification, method, params(json)}}
      %{"id" => id, "result" => result} -> {:ok, {:result, id, result}}
      %{"id" => id, "error" => error} -> {:ok, {:error, id, Error.from_json(error)}}
      _ -> {:error, Error.new(:invalid_request)}
    end
  end

  def from_map(list) when is_list(list) do
    # Batches are valid JSON-RPC but not part of this protocol: they complicate
    # ordering guarantees that subscriptions depend on, for no benefit here.
    {:error, Error.new(:invalid_request, %{reason: "batches are not supported"})}
  end

  def from_map(_json), do: {:error, Error.new(:invalid_request)}

  defp params(json) do
    case Map.get(json, "params") do
      params when is_map(params) -> params
      nil -> %{}
      # A positional params array has no meaning for any method here.
      _ -> %{}
    end
  end
end
