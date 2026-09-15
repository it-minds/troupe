defmodule Troupe.Plane.Identity.Entitlement do
  @moduledoc """
  One row narrowing what a grant gives: an agent, a skill or an MCP server, allowed or
  denied.

  The bundle is untouched by any of this. It stays one content-addressed document with
  one hash; there are no derived bundles, no per-team hashes and nothing new to
  invalidate. What narrows is the *session*, which records the set it resolved to.

  ## The rules, in one place

  `resolve/2` is the whole of the semantics, and every caller goes through it:

  * **No rows for a kind means everything of that kind.** Absence means everything, which
    is the rule this repository applies from the entitlement table up through the policy
    ladder, and it is what makes the migration that introduced this table a no-op.
  * **An `allow` row makes that kind an allowlist.** Once anything of a kind is allowed,
    only the allowed names are offered.
  * **A `deny` row subtracts.** A kind with only `deny` rows is everything except those.
  * **Deny wins.** Two ways of writing one intent must not disagree, and the safe reading
    is the one that grants less.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(agent skill mcp_server)
  @modes ~w(allow deny)

  schema "grant_entitlements" do
    belongs_to(:grant, Troupe.Plane.Identity.Grant)
    field(:kind, :string)
    field(:name, :string)
    field(:mode, :string, default: "allow")

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The three lists a bundle has."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The two ways a row can read."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:grant_id, :kind, :name, :mode])
    |> validate_required([:grant_id, :kind, :name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:mode, @modes)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint([:grant_id, :kind, :name])
  end

  @doc """
  Narrow a list of names of one kind by the rows that apply to it.

      iex> alias Troupe.Plane.Identity.Entitlement
      iex> Entitlement.resolve(["a", "b"], [])
      ["a", "b"]
      iex> Entitlement.resolve(["a", "b"], [%{kind: "skill", name: "a", mode: "allow"}])
      ["a"]
      iex> Entitlement.resolve(["a", "b"], [%{kind: "skill", name: "a", mode: "deny"}])
      ["b"]
      iex> rows = [%{kind: "skill", name: "a", mode: "allow"},
      ...>         %{kind: "skill", name: "a", mode: "deny"}]
      iex> Entitlement.resolve(["a", "b"], rows)
      []

  The last one is deny winning: `a` is denied, and `b` is outside an allowlist that now
  exists. Both halves of the rule, in one answer.
  """
  @spec resolve([String.t()], [t() | map()]) :: [String.t()]
  def resolve(names, rows) do
    denied = MapSet.new(for %{mode: "deny", name: name} <- rows, do: name)
    allowed = MapSet.new(for %{mode: "allow", name: name} <- rows, do: name)

    names
    |> Enum.reject(&MapSet.member?(denied, &1))
    |> then(fn kept ->
      if MapSet.size(allowed) == 0,
        do: kept,
        else: Enum.filter(kept, &MapSet.member?(allowed, &1))
    end)
  end

  @doc """
  The rows of one kind, from a mixed list.

  Kinds do not interact: an allowlist of skills says nothing about agents, which is what
  lets an admin narrow one list without having to enumerate the other two.
  """
  @spec of_kind([t() | map()], String.t()) :: [t() | map()]
  def of_kind(rows, kind), do: Enum.filter(rows, &(&1.kind == kind))

  @doc "A row as the wire and the audit diff carry it."
  @spec json(t() | map()) :: map()
  def json(%{kind: kind, name: name, mode: mode}) do
    %{"kind" => kind, "name" => name, "mode" => mode}
  end
end
