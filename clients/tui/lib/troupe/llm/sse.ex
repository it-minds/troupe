defmodule Troupe.LLM.SSE do
  @moduledoc "Incremental Server-Sent Events parser: feed chunks, get `{event, data}` pairs."

  @type t :: String.t()

  @spec new() :: t()
  def new, do: ""

  @spec feed(t(), binary()) :: {[{String.t() | nil, String.t()}], t()}
  def feed(buffer, chunk) do
    buffer = buffer <> chunk
    parts = String.split(buffer, ~r/\r?\n\r?\n/)
    {complete, [rest]} = Enum.split(parts, -1)
    events = complete |> Enum.map(&parse_block/1) |> Enum.reject(&is_nil/1)
    {events, rest}
  end

  defp parse_block(block) do
    lines = String.split(block, ~r/\r?\n/)

    event =
      lines
      |> Enum.find_value(fn
        "event:" <> e -> String.trim(e)
        _ -> nil
      end)

    data =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &String.trim(String.replace_prefix(&1, "data:", "")))

    if data == "", do: nil, else: {event, data}
  end
end
