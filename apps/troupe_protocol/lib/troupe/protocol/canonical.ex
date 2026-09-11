defmodule Troupe.Protocol.Canonical do
  @moduledoc """
  Canonical JSON, as `PROTOCOL.md` §4 defines it: UTF-8, object keys sorted by
  Unicode code point, no insignificant whitespace, numbers in shortest round-trip
  form.

  This exists so the event hash chain can be verified by anyone, in any language,
  from the stored log alone. Two implementations must produce byte-identical output
  for the same value or the chain is worthless, so the rules here are deliberately
  narrow and boring — no float formatting cleverness, no locale, no ordering by
  anything but code point.
  """

  @doc """
  Encode a term to canonical JSON.

      iex> Troupe.Protocol.Canonical.encode(%{"b" => 1, "a" => [true, nil]})
      ~s({"a":[true,null],"b":1})

      iex> Troupe.Protocol.Canonical.encode(%{"z" => %{"y" => 2, "x" => 1}})
      ~s({"z":{"x":1,"y":2}})
  """
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> build() |> IO.iodata_to_binary()

  defp build(value) when is_map(value) and not is_struct(value) do
    inner =
      value
      |> Enum.map(fn {key, val} -> {to_key(key), val} end)
      # Sorting by the UTF-8 binary is sorting by code point, because UTF-8 preserves
      # code point order — which is why this needs no collation table.
      |> Enum.sort_by(&elem(&1, 0), :asc)
      |> Enum.map(fn {key, val} -> [Jason.encode!(key), ?:, build(val)] end)
      |> Enum.intersperse(?,)

    [?{, inner, ?}]
  end

  defp build(value) when is_list(value) do
    [?[, value |> Enum.map(&build/1) |> Enum.intersperse(?,), ?]]
  end

  defp build(%Date{} = value), do: Jason.encode!(value)
  defp build(%DateTime{} = value), do: Jason.encode!(value)
  defp build(%NaiveDateTime{} = value), do: Jason.encode!(value)

  defp build(value) when is_struct(value) do
    value |> Map.from_struct() |> stringify() |> build()
  end

  defp build(value), do: Jason.encode!(value)

  defp stringify(map), do: Map.new(map, fn {key, val} -> {to_key(key), val} end)

  defp to_key(key) when is_binary(key), do: key
  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(key) when is_integer(key), do: Integer.to_string(key)

  @doc "The `sha256:` digest of a term's canonical form."
  @spec hash(term()) :: String.t()
  def hash(term) do
    "sha256:" <> (:sha256 |> :crypto.hash(encode(term)) |> Base.encode16(case: :lower))
  end
end
