defmodule Troupe.Operator.Status do
  @moduledoc """
  The conditions a `WorkerProfile` reports, and the rules they follow.

  Kubernetes conditions are how an operator says what it knows, and they are read by
  people and by `kubectl wait` alike. Two rules make them worth reading:
  `lastTransitionTime` only moves when the status actually changes, so "how long has
  this been broken" is answerable; and `observedGeneration` records which version of
  the spec the condition is about, so a stale `Ready: True` is recognisable as stale.
  """

  @type condition :: %{String.t() => term()}

  @doc "Set a condition, preserving `lastTransitionTime` when the status has not changed."
  @spec put(map(), String.t(), boolean(), String.t(), String.t(), integer() | nil) :: map()
  def put(status, type, holds?, reason, message, generation \\ nil) do
    conditions = Map.get(status, "conditions", [])
    existing = Enum.find(conditions, &(&1["type"] == type))
    value = if holds?, do: "True", else: "False"

    condition =
      %{
        "type" => type,
        "status" => value,
        "reason" => reason,
        "message" => message,
        "lastTransitionTime" => transition_time(existing, value)
      }
      |> put_unless_nil("observedGeneration", generation)

    Map.put(status, "conditions", replace(conditions, type, condition))
  end

  @doc "The value of one condition, or `nil` when it has never been set."
  @spec get(map(), String.t()) :: condition() | nil
  def get(status, type) do
    status |> Map.get("conditions", []) |> Enum.find(&(&1["type"] == type))
  end

  @doc "Whether a condition is currently true."
  @spec holds?(map(), String.t()) :: boolean()
  def holds?(status, type), do: match?(%{"status" => "True"}, get(status, type))

  defp transition_time(%{"status" => same, "lastTransitionTime" => at}, same) when is_binary(at),
    do: at

  defp transition_time(_existing, _value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp replace(conditions, type, condition) do
    conditions
    |> Enum.reject(&(&1["type"] == type))
    |> Kernel.++([condition])
    |> Enum.sort_by(& &1["type"])
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
