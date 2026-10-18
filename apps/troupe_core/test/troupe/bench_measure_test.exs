defmodule Troupe.BenchMeasureTest do
  @moduledoc """
  What the offline bench says a request's system prompt weighs is all of it: the prompt
  and what follows it (`system_tail`, the task list among it), as the log counts a
  request's system bytes, and not the first part alone (D65).
  """

  use ExUnit.Case, async: true

  alias Troupe.Bench.Model
  alias Troupe.LLM.Request

  test "the system prompt is measured with its tail" do
    request = %Request{
      model: "m",
      system: "You build.",
      system_tail: "Tasks:\n- one",
      messages: [],
      tools: []
    }

    assert Model.measure(request, "/w").system == byte_size("You build.\n\nTasks:\n- one")
    assert Model.measure(%{request | system_tail: nil}, "/w").system == byte_size("You build.")
  end
end
