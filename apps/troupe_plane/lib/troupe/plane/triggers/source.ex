defmodule Troupe.Plane.Triggers.Source do
  @moduledoc """
  A trigger's `source`: a map, with its time zone under `tz` however it arrived.

  `tz` is the name everywhere a trigger is written down — the `Trigger` resource, the admin
  API, the docs — and it is the one the changeset checks. The console saved the zone as
  `timezone`, which nothing read: a schedule given a zone fired in UTC under a form that
  said otherwise, and a zone the plane refuses was kept. So `timezone` is read as `tz`, in
  what a caller sends and in a row saved that way, and a blank zone is none. Nothing else
  in the map is touched; a webhook's keys are its executor's.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(%{} = source), do: {:ok, spelled(source)}
  def cast(_other), do: :error

  @impl Ecto.Type
  def load(%{} = source), do: {:ok, spelled(source)}
  def load(_other), do: :error

  @impl Ecto.Type
  def dump(%{} = source), do: {:ok, source}
  def dump(_other), do: :error

  @doc "The source with its zone under `tz`, and no blank one."
  @spec spelled(map()) :: map()
  def spelled(source) do
    {timezone, source} = Map.pop(source, "timezone")
    {tz, source} = Map.pop(source, "tz")

    case present(tz) || present(timezone) do
      nil -> source
      zone -> Map.put(source, "tz", zone)
    end
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value
end
