defmodule Troupe.Tools.Output do
  @moduledoc """
  Capping tool output.

  Every tool that can produce unbounded text goes through here. Truncation is
  announced in the text itself, because a model that cannot tell it got a partial
  answer will confidently reason from it.
  """

  @doc "Trim text to `limit` bytes, keeping the head and saying what was dropped."
  @spec cap(String.t(), pos_integer()) :: String.t()
  def cap(text, limit) when byte_size(text) <= limit, do: text

  def cap(text, limit) do
    kept = binary_part(text, 0, limit)
    dropped = byte_size(text) - limit

    # Cut back to the last newline so the truncation never lands mid-line.
    kept =
      case :binary.matches(kept, "\n") do
        [] -> kept
        matches -> binary_part(kept, 0, matches |> List.last() |> elem(0))
      end

    kept <> "\n\n[truncated: #{dropped} more bytes. Narrow the request to see the rest.]"
  end

  @doc "Cap text taken from the *end* of a stream, such as shell output."
  @spec cap_tail(String.t(), pos_integer()) :: String.t()
  def cap_tail(text, limit) when byte_size(text) <= limit, do: text

  def cap_tail(text, limit) do
    dropped = byte_size(text) - limit
    kept = binary_part(text, dropped, limit)

    kept =
      case :binary.match(kept, "\n") do
        :nomatch -> kept
        {pos, len} -> binary_part(kept, pos + len, byte_size(kept) - pos - len)
      end

    "[truncated: #{dropped} earlier bytes omitted]\n\n" <> kept
  end
end
