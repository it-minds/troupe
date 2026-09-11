defmodule Troupe.LLM.SSE do
  @moduledoc """
  Incremental parsing of `text/event-stream` bodies.

  A pure accumulator: bytes in, complete events out, remainder kept. Both HTTP
  adapters share it, so the framing is written and tested once rather than twice, and
  a chunk boundary landing mid-event is handled the same way in both.
  """

  @enforce_keys []
  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: String.t()}
  @type event :: %{event: String.t() | nil, data: String.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed a chunk in, get every complete event back plus the updated accumulator.

  Events are separated by a blank line. A trailing partial event stays in the buffer
  until the rest of it arrives.
  """
  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{buffer: buffer}, chunk) do
    # Normalise CRLF: the spec allows it, and a provider behind a proxy may send it.
    combined = String.replace(buffer <> chunk, "\r\n", "\n")

    case String.split(combined, "\n\n") do
      [remainder] ->
        {[], %__MODULE__{buffer: remainder}}

      parts ->
        {complete, [remainder]} = Enum.split(parts, -1)
        {Enum.flat_map(complete, &parse_block/1), %__MODULE__{buffer: remainder}}
    end
  end

  defp parse_block(block) do
    lines = String.split(block, "\n")

    {event, data} =
      Enum.reduce(lines, {nil, []}, fn line, {event, data} ->
        case line do
          "event:" <> value -> {String.trim(value), data}
          "data:" <> value -> {event, [String.trim_leading(value) | data]}
          ":" <> _comment -> {event, data}
          _ -> {event, data}
        end
      end)

    case data do
      [] -> []
      values -> [%{event: event, data: values |> Enum.reverse() |> Enum.join("\n")}]
    end
  end

  @doc "Decode an event's data as JSON, skipping the `[DONE]` sentinel."
  @spec decode(event()) :: {:ok, map()} | :done | :error
  def decode(%{data: "[DONE]"}), do: :done

  def decode(%{data: data}) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> :error
    end
  end
end
