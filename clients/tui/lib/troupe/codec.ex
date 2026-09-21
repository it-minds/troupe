defmodule Troupe.Codec do
  @moduledoc """
  JSON encoding and decoding of persisted events.

  Encoding is plain `Jason`. Decoding restores the shape the live system uses:
  map keys become atoms except inside opaque model-supplied maps (tool
  `input`, watch `markers`), and a fixed set of enum fields become atoms.
  """

  alias Troupe.Event

  @opaque_keys ~w(input markers)
  @enum_keys ~w(state source reason decision stop_reason role type status isolation kind provider)

  @spec encode_event(Event.t()) :: iodata()
  def encode_event(%Event{} = e) do
    Jason.encode_to_iodata!(%{
      seq: e.seq,
      ts: e.ts,
      agent_path: e.agent_path,
      type: e.type,
      data: e.data
    })
  end

  @spec decode_event(String.t(), binary()) :: {:ok, Event.t()} | {:error, term()}
  def decode_event(session_id, line) do
    case Jason.decode(line) do
      {:ok, %{"seq" => seq, "ts" => ts, "agent_path" => path, "type" => type, "data" => data}} ->
        {:ok,
         %Event{
           session_id: session_id,
           seq: seq,
           ts: ts,
           agent_path: path,
           type: String.to_atom(type),
           data: decode_data(data)
         }}

      {:ok, other} ->
        {:error, {:malformed_event, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Restores atom keys and enum values in decoded JSON event data."
  @spec decode_data(term()) :: term()
  def decode_data(data) when is_map(data) do
    Map.new(data, fn {k, v} -> decode_pair(k, v) end)
  end

  def decode_data(list) when is_list(list), do: Enum.map(list, &decode_data/1)
  def decode_data(other), do: other

  defp decode_pair(k, v) when is_binary(k) do
    cond do
      k in @opaque_keys -> {String.to_atom(k), v}
      k in @enum_keys and is_binary(v) -> {String.to_atom(k), String.to_atom(v)}
      true -> {String.to_atom(k), decode_data(v)}
    end
  end

  defp decode_pair(k, v), do: {k, decode_data(v)}
end
