defmodule Troupe.Bench.Prefix do
  @moduledoc """
  How often a session's prompt changed in front of what it had already sent, and what that
  did to the thinking it handed back: issue #465's input, counted from a session's log
  (Decision 815).

  A kept thinking block on Anthropic's newest models, and the cached prefix on any
  provider that caches, are bound to the system prompt, the tools and the conversation
  before them. Per model call the log says whether the system prompt and the tools
  changed since the agent's call before (`llm_request`'s `system_changed` and
  `tools_changed`), and what became of the thinking the call handed back: refused as bound
  to another conversation and sent again without it (`llm_response`'s `thinking_resent`,
  Decision 805), or dropped by Anthropic's thinking-binding beta (`thinking_dropped`, the
  number of blocks). `count/1` adds them up; the live bench puts them on each run, and
  `mix troupe.prefix` over a directory of session logs.

  A log written before those fields has `prompt_bytes` (Decision 769): a call whose system
  prompt or tools differ in size from its agent's call before changed them, so they are
  counted from that, and `inferred` says how many calls were. That misses an edit that
  keeps the size, so it is a floor. Nothing in such a log says a call was sent again.
  """

  alias Troupe.Protocol.Event

  @doc """
  What `events` say, as a map: `model_calls`; `system_changes` and `tools_changes`, the
  calls whose system prompt or tools differed from their agent's call before; `inferred`,
  how many of the calls compared were judged by size; `thinking_resent`, the calls sent
  again without their thinking; `thinking_dropped`, the blocks the beta dropped, in
  `calls_dropping` calls; and `turn_contexts`, the calls that sent a stable system
  prompt's turn context.
  """
  @spec count([Event.t()]) :: map()
  def count(events) do
    requests = Enum.filter(events, &(&1.type == "llm_request" and not &1.ephemeral?))
    responses = Enum.filter(events, &(&1.type == "llm_response" and not &1.ephemeral?))
    compared = compared(requests)
    dropped = Enum.map(responses, &(&1.data["thinking_dropped"] || 0))

    %{
      "model_calls" => length(requests),
      "system_changes" => Enum.count(compared, & &1.system),
      "tools_changes" => Enum.count(compared, & &1.tools),
      "inferred" => Enum.count(compared, & &1.inferred),
      "thinking_resent" => Enum.count(responses, &(&1.data["thinking_resent"] == true)),
      "thinking_dropped" => Enum.sum(dropped),
      "calls_dropping" => Enum.count(dropped, &(&1 > 0)),
      "turn_contexts" => Enum.count(requests, &is_list(&1.data["turn_context"]))
    }
  end

  @doc "Two counts added together, measure by measure."
  @spec add(map(), map()) :: map()
  def add(a, b), do: Map.merge(a, b, fn _key, x, y -> x + y end)

  @doc "A count of nothing: what `add/2` starts from."
  @spec zero() :: map()
  def zero, do: count([])

  # Each call beside its agent's call before it, in the order they were made.
  defp compared(requests) do
    requests
    |> Enum.group_by(& &1.agent)
    |> Enum.flat_map(fn {_agent, calls} ->
      calls
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [before, call] -> change(before.data, call.data) end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp change(_before, %{"system_changed" => system, "tools_changed" => tools}),
    do: %{system: system == true, tools: tools == true, inferred: false}

  defp change(%{"prompt_bytes" => %{} = before}, %{"prompt_bytes" => %{} = bytes}) do
    %{
      system: before["system"] != bytes["system"],
      tools: before["tools"] != bytes["tools"],
      inferred: true
    }
  end

  defp change(_before, _call), do: nil
end
