defmodule Troupe.Plane.Audit do
  @moduledoc """
  Who changed what, and what it looked like before.

  Every administrative change writes one of these, with the actor and a diff. Not a log
  line — a row, queryable, because the question an audit answers is asked months later
  and by somebody who was not there: *when did this profile's image change, and who
  changed it*.

  The diff is `%{field => %{"from" => …, "to" => …}}` over the fields that actually
  moved. Recording the whole before and after would make every audit record a copy of a
  CR and bury the one field that changed in forty that did not.

  **Secret values never reach here.** What a profile holds is a secret *reference*, and a
  diff of references is a diff of names. `redact/1` is belt and braces for the case where
  somebody adds a field later without thinking about it.
  """

  import Ecto.Query

  alias Troupe.Plane.Audit.Event
  alias Troupe.Plane.Repo

  require Logger

  # Anything whose name suggests it holds a value rather than a reference to one. A
  # denylist is the wrong shape for a security boundary and this is not one — the boundary
  # is that the plane never holds a secret value at all. This is the second line.
  @suspicious ~w(password secret token key credential api_key apikey authorization)

  @doc """
  Record a change.

  `detail` is whatever a reader needs to understand it later: a diff for an update, the
  identity of the thing for a create or a delete, the reason for a refusal.
  """
  @spec record(String.t(), String.t(), String.t() | nil, map(), keyword()) ::
          {:ok, Event.t()} | {:error, term()}
  def record(actor, action, subject_id, detail \\ %{}, opts \\ []) do
    %Event{}
    |> Event.changeset(%{
      actor: actor,
      action: action,
      subject_kind: Keyword.get(opts, :kind, kind_of(action)),
      subject_id: subject_id,
      detail: redact(detail),
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  # `profile.put` is about a profile. Derived rather than passed, so an action and its
  # subject kind cannot drift apart.
  defp kind_of(action), do: action |> String.split(".") |> List.first()

  @doc """
  The diff between two maps, over the keys that moved.

  Both sides are compared as they would be stored, so a change from `nil` to `""` is not
  a change and a reordered list is.
  """
  @spec diff(map(), map()) :: map()
  def diff(before, now) do
    before = stringify(before)
    now = stringify(now)
    keys = MapSet.union(MapSet.new(Map.keys(before)), MapSet.new(Map.keys(now)))

    # Deliberately not a comprehension with `was = …` as a filter: an assignment used as
    # a filter drops the element when the value is `nil`, which would silently hide every
    # field being set from nothing or cleared to nothing — the two changes somebody
    # reading an audit trail most wants to see.
    keys
    |> Enum.flat_map(fn key ->
      was = Map.get(before, key)
      is = Map.get(now, key)

      if was == is, do: [], else: [{key, %{"from" => was, "to" => is}}]
    end)
    |> Map.new()
  end

  # Both sides keyed the same way, so a caller comparing a struct's atom keys with a
  # form's string ones gets a diff rather than a list of everything.
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  @doc """
  Replace anything that looks like a secret value with a marker.

  The plane does not hold secret values, so this should never fire. It firing is a bug
  report, and it says so in the log rather than quietly hiding the thing it caught.
  """
  @spec redact(term()) :: term()
  def redact(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} ->
      if suspicious?(key) and is_binary(value) and value != "" do
        Logger.error("troupe plane: an audit detail carried #{inspect(key)}, which was redacted")
        {key, "[redacted]"}
      else
        {key, redact(value)}
      end
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(value), do: value

  defp suspicious?(key) do
    name = key |> to_string() |> String.downcase()
    Enum.any?(@suspicious, &String.contains?(name, &1)) and not String.contains?(name, "_ref")
  end

  @doc "The audit trail, newest first, optionally narrowed."
  @spec list(keyword()) :: [Event.t()]
  def list(opts \\ []) do
    Event
    |> filter(opts)
    |> order_by([e], desc: e.occurred_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  defp filter(query, opts) do
    Enum.reduce(opts, query, fn
      {:actor, actor}, acc -> from e in acc, where: e.actor == ^actor
      {:kind, kind}, acc -> from e in acc, where: e.subject_kind == ^kind
      {:subject_id, id}, acc -> from e in acc, where: e.subject_id == ^id
      {:since, since}, acc -> from e in acc, where: e.occurred_at >= ^since
      _other, acc -> acc
    end)
  end
end
