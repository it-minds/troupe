defmodule Inventory do
  @moduledoc """
  A tiny stock ledger, used as the acceptance fixture for Troupe.

  One of its functions is wrong on purpose; `mix test` in this directory fails until
  it is fixed.
  """

  @type item :: %{sku: String.t(), quantity: integer()}

  @doc "Total quantity across every item."
  @spec total([item()]) :: integer()
  def total(items) do
    Enum.reduce(items, 0, fn item, acc -> acc + item.quantity end)
  end

  @doc """
  Items whose quantity has fallen to or below the reorder threshold.
  """
  @spec below_threshold([item()], integer()) :: [item()]
  def below_threshold(items, threshold) do
    Enum.filter(items, fn item -> item.quantity < threshold end)
  end
end
