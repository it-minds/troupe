defmodule SampleRepo do
  @moduledoc "A tiny project with one failing test, used for the manual acceptance run."

  @doc "Returns the sum of a list of integers."
  def sum(list), do: Enum.reduce(list, 0, fn x, acc -> acc - x end)
end
