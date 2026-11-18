defmodule Troupe.Eventually do
  @moduledoc """
  Waiting in a test for something another process does.

  The one polling helper of the umbrella's suites. It is compiled with the protocol's test
  support, which every other app's test run compiles too, so a case template imports it
  and a plain `ExUnit.Case` test imports it itself.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @doc """
  Call `fun` every `interval` milliseconds until it answers something other than `nil` or
  `false`, and answer that. After `timeout` milliseconds the test fails, naming the last
  answer.
  """
  @spec eventually((-> any()), non_neg_integer(), pos_integer()) :: any()
  def eventually(fun, timeout \\ 5_000, interval \\ 20) do
    poll(fun, System.monotonic_time(:millisecond) + timeout, timeout, interval)
  end

  defp poll(fun, deadline, timeout, interval) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition never held within #{timeout} ms; last answer: #{inspect(falsy)}")
        else
          Process.sleep(interval)
          poll(fun, deadline, timeout, interval)
        end

      truthy ->
        truthy
    end
  end
end
