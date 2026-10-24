defmodule Troupe.Plane.ClientsSeen do
  @moduledoc """
  Which version each person's clients last ran (#657): what an administrator reads before
  and after changing a version policy (`ClientVersions`), to see whom it holds back.

  One row per person and component, written at `initialize` from the `client_info` the
  client gave, and moved on by the next one: the version, the platform where the client
  named one, when that version was first seen here (`since`) and when the client was last
  seen (`seen_at`). Never a history, since "who is behind" is a question about now.

  Written only for a client the plane served. One it refused is not recorded, nor one it
  cannot place (no component it knows), nor a service principal, which has no row of its
  own. A person's rows go with their row.

  A connected daemon asks `initialize` again every thirty seconds, so an unchanged row is
  rewritten only once its `seen_at` is a few minutes old: one statement either way, and no
  write at all for most of them. A database that cannot be written is logged and the client
  served all the same, as a plane that cannot read its policy serves every version.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Troupe.Plane.{ClientVersions, Repo}
  alias Troupe.Plane.Identity.User
  alias Troupe.Protocol.ClientUpdate

  require Logger

  @primary_key false
  @foreign_key_type :binary_id

  schema "clients_seen" do
    belongs_to(:user, User, primary_key: true)
    field(:component, :string, primary_key: true)
    field(:version, :string)
    field(:platform, :string)
    field(:since, :utc_datetime_usec)
    field(:seen_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  # How stale an unchanged row may grow before an `initialize` writes it again.
  @refresh_seconds 300

  # A version or a platform is a label a client gives; this is as long as one gets.
  @max_label 64

  @standings ~w(current behind refused)

  @doc """
  Record what one served client said of itself at `initialize`: its component, its
  version and, where `client_info` names one, its `platform`. Nothing for a client the plane
  cannot place or a caller with no row.
  """
  @spec record(User.t(), String.t() | nil, map()) :: :ok
  def record(%User{id: user_id}, component, info)
      when is_binary(user_id) and is_binary(component) and is_map(info) do
    case label(info["version"]) do
      nil -> :ok
      version -> upsert(user_id, component, version, label(info["platform"]))
    end
  end

  def record(_user, _component, _info), do: :ok

  defp upsert(user_id, component, version, platform) do
    now = DateTime.utc_now()

    row = %__MODULE__{
      user_id: user_id,
      component: component,
      version: version,
      platform: platform,
      since: now,
      seen_at: now
    }

    # `since` moves only with the version; the write is skipped for a row that says the
    # same and was seen a moment ago.
    moved =
      from(s in __MODULE__,
        update: [
          set: [
            version: fragment("EXCLUDED.version"),
            platform: fragment("EXCLUDED.platform"),
            seen_at: fragment("EXCLUDED.seen_at"),
            since:
              fragment(
                "CASE WHEN ? IS DISTINCT FROM EXCLUDED.version THEN EXCLUDED.since ELSE ? END",
                s.version,
                s.since
              )
          ]
        ],
        where:
          fragment(
            "? IS DISTINCT FROM EXCLUDED.version OR ? IS DISTINCT FROM EXCLUDED.platform OR ? < EXCLUDED.seen_at - make_interval(secs => ?)",
            s.version,
            s.platform,
            s.seen_at,
            ^@refresh_seconds
          )
      )

    Repo.insert(row, on_conflict: moved, conflict_target: [:user_id, :component])
    :ok
  rescue
    error ->
      Logger.warning("troupe plane: could not record a client's version: #{inspect(error)}")
      :ok
  end

  defp label(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, @max_label) do
      "" -> nil
      text -> if String.printable?(text), do: text
    end
  end

  defp label(_value), do: nil

  @doc """
  Every row, with the person's subject and name: `%{subject, display_name, component,
  version, platform, since, seen_at}`. For a platform admin's whole fleet, or `user_ids` for
  the people a team admin may see.
  """
  @spec list(:all | [String.t()]) :: [map()]
  def list(user_ids \\ :all) do
    from(s in __MODULE__,
      join: u in User,
      on: u.id == s.user_id,
      order_by: [s.component, u.subject],
      select: %{
        subject: u.subject,
        display_name: u.display_name,
        component: s.component,
        version: s.version,
        platform: s.platform,
        since: s.since,
        seen_at: s.seen_at
      }
    )
    |> only(user_ids)
    |> Repo.all()
  end

  defp only(query, :all), do: query
  defp only(query, ids), do: where(query, [s], s.user_id in ^ids)

  @doc """
  Each component's clients held to its policy as it stands: how many are on the
  recommended version or past it (`current`), how many below it (`behind`), how many it
  would refuse at their next `initialize` (`refused`: below the minimum or blocked), and
  the people, each with their `standing`.
  """
  @spec fleet(:all | [String.t()]) :: %{String.t() => map()}
  def fleet(user_ids \\ :all) do
    rows = Enum.group_by(list(user_ids), & &1.component)

    Map.new(ClientVersions.components(), fn component ->
      policy = ClientVersions.policy(component)
      people = Enum.map(Map.get(rows, component, []), &person(&1, policy))
      {component, Map.put(count(people), "people", people)}
    end)
  end

  @doc """
  How many of a component's clients a policy finds current, behind and refusing: what an
  administrator's change of it holds, as its audit row says.
  """
  @spec affected(String.t(), map()) :: %{String.t() => non_neg_integer()}
  def affected(component, policy) do
    :all
    |> list()
    |> Enum.filter(&(&1.component == component))
    |> Enum.map(&person(&1, policy))
    |> count()
  end

  defp count(people) do
    counted = Enum.frequencies_by(people, & &1["standing"])
    Map.new(@standings, &{&1, Map.get(counted, &1, 0)})
  end

  defp person(row, policy) do
    %{
      "subject" => row.subject,
      "display_name" => row.display_name,
      "version" => row.version,
      "platform" => row.platform,
      "since" => row.since,
      "seen_at" => row.seen_at,
      "standing" => standing(policy, row.version)
    }
  end

  defp standing(policy, version) do
    case ClientUpdate.judge(policy, version) do
      {:refuse, _why} -> "refused"
      {:ok, "suggest"} -> "behind"
      {:ok, _none} -> "current"
    end
  end
end
