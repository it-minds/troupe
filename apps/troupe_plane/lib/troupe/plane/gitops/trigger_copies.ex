defmodule Troupe.Plane.Gitops.TriggerCopies do
  @moduledoc """
  A direct plane's view of the `Trigger` resources in its namespace, and the copies an
  administrator makes of them.

  A deployment may keep its triggers in a repository and have an applier put them in the
  cluster while the plane stays in direct mode, where the rows are the truth and the
  profiles are not locked. A gitops pass would make the rows follow the resources; a direct
  plane never acts on a resource by itself. It lists them, reads each with the gitops
  pass's own checks (`Troupe.Plane.Gitops.Triggers.read/2`), and says whether each would
  pass today and, if not, why. An administrator copies one into a row
  (`admin.trigger.copy`), which records the resource and its generation, and copies it
  again when it moves.

  ## The checks, and one more

  What a gitops pass asks of a resource, and whether its principal may use its profile:
  the team granted it, and the principal lists it. A pass does not ask that, because a
  trigger whose principal may not use its profile is refused at the firing and reported on
  its run; a person about to press Copy is better told now.

  ## A copied row's state

  Taken by comparing the row's fields with what the resource would make of them, so drift
  shows in both directions and nothing is stored but the generation:

  | state | when |
  | --- | --- |
  | `copied` | the row says what the resource says |
  | `changed` | the resource's generation moved past the copied one, and they differ |
  | `differs` | they differ at the copied generation: the row was edited in the console |
  | `gone` | the cluster has no resource of its name; the row goes on running |
  | `not_copied` | a row of the resource's name nobody copied, which a copy would take over |

  The diff is `Troupe.Plane.Audit.diff/2`'s, field by field, from what the row says to what
  the resource says, which is what a copy would change. A resource that fails the checks
  has no diff: there is no row it would make.
  """

  alias Troupe.Plane.{Audit, Gitops, Identity, Principals}
  alias Troupe.Plane.Gitops.Triggers, as: GitopsTriggers
  alias Troupe.Plane.Triggers.Trigger

  @typedoc "One resource as the cluster listed it, read and checked."
  @type entry :: %{
          name: String.t() | nil,
          team: String.t() | nil,
          trigger: String.t() | nil,
          generation: integer() | nil,
          spec: map(),
          checked: {:ok, map()} | {:error, [String.t()]}
        }

  @doc "Every `Trigger` resource in the namespace, each read and checked, or why the cluster did not answer."
  @spec resources() :: {:ok, [entry()]} | {:error, term()}
  def resources do
    with {:ok, items} <- Gitops.list(GitopsTriggers) do
      context = GitopsTriggers.context()
      {:ok, Enum.map(items, &entry(&1, context))}
    end
  end

  @doc "One resource by name, read and checked, or `:not_found`."
  @spec resource(String.t()) :: {:ok, entry()} | {:error, :not_found | term()}
  def resource(name) do
    with {:ok, entries} <- resources() do
      case Enum.find(entries, &(&1.name == name)) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry}
      end
    end
  end

  defp entry(resource, context) do
    name = get_in(resource, ["metadata", "name"])

    {team, trigger} =
      case GitopsTriggers.split(name) do
        {:ok, team, trigger} -> {team, trigger}
        :error -> {nil, nil}
      end

    %{
      name: name,
      team: team,
      trigger: trigger,
      generation: get_in(resource, ["metadata", "generation"]),
      spec: resource["spec"] || %{},
      checked: check(resource, context)
    }
  end

  @doc """
  A resource with the plane's checks: the row's attributes, or every reason it would not
  pass, as sentences. Nothing is written.
  """
  @spec check(map(), term()) :: {:ok, map()} | {:error, [String.t()]}
  def check(resource, context) do
    with {:ok, attrs} <- GitopsTriggers.read(resource, context) do
      case ungranted(attrs) do
        [] -> {:ok, attrs}
        reasons -> {:error, reasons}
      end
    end
  rescue
    exception -> {:error, ["the plane failed reading it: #{Exception.message(exception)}"]}
  end

  defp ungranted(%{team: team, principal_id: id, profile: profile}) do
    principal = Principals.fetch(id)
    granted = MapSet.new(Identity.grants_for_team(team), & &1.profile)

    cond do
      not MapSet.member?(granted, profile) ->
        [
          "the team #{team.name} is not granted the profile #{profile}: grant it first " <>
            "(admin.team.grant)"
        ]

      profile not in principal.profiles ->
        [
          "#{principal.subject} is not granted the profile #{profile}: its profiles are " <>
            "#{if principal.profiles == [], do: "none", else: Enum.join(principal.profiles, ", ")}"
        ]

      not is_nil(principal.disabled_at) ->
        ["#{principal.subject} is disabled, and a trigger runs as it"]

      true ->
        []
    end
  end

  # -- a row against its resource ---------------------------------------------------------

  @doc "Where a row stands against its resource, `nil` where the cluster has none of its name."
  @spec state(Trigger.t(), entry() | nil) :: map()
  def state(%Trigger{} = row, nil) do
    %{
      "state" => if(row.copied_from, do: "gone", else: "not_copied"),
      "trigger_id" => row.id,
      "copied_generation" => row.copied_generation,
      "diff" => nil
    }
  end

  def state(%Trigger{} = row, entry) do
    diff =
      case entry.checked do
        {:ok, attrs} -> diff(row, attrs)
        {:error, _reasons} -> nil
      end

    state =
      cond do
        is_nil(row.copied_from) -> "not_copied"
        diff == %{} -> "copied"
        newer?(entry.generation, row.copied_generation) -> "changed"
        # Failing at the generation it was copied at: what it said then is what the row
        # was made from, and nothing here can say the row moved since.
        is_nil(diff) -> "copied"
        true -> "differs"
      end

    %{
      "state" => state,
      "trigger_id" => row.id,
      "copied_generation" => row.copied_generation,
      "diff" => diff
    }
  end

  defp newer?(generation, copied) when is_integer(generation) and is_integer(copied),
    do: generation > copied

  defp newer?(_generation, _copied), do: false

  @doc """
  What a copy would change of a row, field by field: from what the row says to what the
  resource says. The principal by subject, as a person reads it.
  """
  @spec diff(Trigger.t() | nil, map()) :: map()
  def diff(row, attrs), do: Audit.diff(shown(row), shown(attrs))

  defp shown(nil), do: %{}

  defp shown(fields) do
    {id, rest} = fields |> GitopsTriggers.comparable() |> Map.pop(:principal_id)
    Map.put(rest, :principal, id && subject(id))
  end

  defp subject(id) do
    case Principals.fetch(id) do
      nil -> id
      principal -> principal.subject
    end
  end

  # -- answers ----------------------------------------------------------------------------

  @doc """
  A resource as `admin.triggers.repository` answers it. `placed` is whether its team is
  one this plane has; where it is not, `team` is null and `name` the resource's.
  """
  @spec json(entry(), Trigger.t() | nil, boolean()) :: map()
  def json(entry, row, placed) do
    {passes, reasons} =
      case entry.checked do
        {:ok, _attrs} -> {true, []}
        {:error, reasons} -> {false, reasons}
      end

    %{
      "resource" => entry.name,
      "team" => if(placed, do: entry.team),
      "name" => if(placed, do: entry.trigger, else: entry.name),
      "generation" => entry.generation,
      "principal" => entry.spec["principal"],
      "profile" => entry.spec["profile"],
      "source" => entry.spec["source"],
      "passes" => passes,
      "reasons" => reasons,
      "copy" => row && state(row, entry)
    }
  end

  @doc "A copied row whose resource the cluster no longer has."
  @spec gone_json(Trigger.t(), String.t()) :: map()
  def gone_json(%Trigger{} = row, team) do
    Map.merge(state(row, nil), %{
      "resource" => row.copied_from,
      "team" => team,
      "name" => row.name
    })
  end
end
