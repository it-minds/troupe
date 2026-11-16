defmodule Troupe.Plane.Artifacts.People do
  @moduledoc """
  An artifact shared with picked people (#62): its owner names a person, and that person
  holds a role on that one artifact until the owner takes it back.

  **The roles.** `view` opens it; `comment` opens it and writes in its thread; `edit` does
  both and publishes new versions of it, as an edit link does. Nothing an owner alone does
  (who it is for, links, pins, deleting it) is anybody's but an owner's.

  **Beside links, not instead of them.** A link (`Troupe.Plane.Artifacts.Shares`) gives its
  role to whoever the plane signs in through it; a grant here gives its role to one person
  named by the owner, who need open nothing first. Both are read together at every request
  (`role/2` in `Troupe.Plane.Artifacts`), the stronger winning, and a person either gave is
  under *Shared with you* in every gallery. Taking a person back (`artifact.unshare` with
  `person`) ends both: their grant and their use of every link.

  Granting, changing a role and taking it back are audited as `artifact.share` and
  `artifact.unshare`, with the person and the role.
  """

  import Ecto.Query

  alias Troupe.Plane.Artifacts.{Artifact, Person}
  alias Troupe.Plane.{Audit, Identity, Repo}
  alias Troupe.Plane.Identity.User
  alias Troupe.Protocol.Error

  @roles ~w(view comment edit)

  @doc "The roles a grant or a link gives, weakest first."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "The stronger of two roles (`nil` for none): `edit` above `comment` above `view`."
  @spec stronger(String.t() | nil, String.t() | nil) :: String.t() | nil
  def stronger(a, b), do: if(rank(a) >= rank(b), do: a, else: b)

  defp rank(nil), do: -1
  defp rank(role), do: Enum.find_index(@roles, &(&1 == role)) || -1

  @doc """
  Share `artifact` with the person `subject` at `role`, by its owner `owner`; naming them
  again changes their role. `not_found` for nobody of that subject, and `invalid_params` for
  the owner themselves or a role that is not one.
  """
  @spec grant(Artifact.t(), User.t(), String.t(), term()) :: {:ok, map()} | {:error, Error.t()}
  def grant(%Artifact{} = artifact, %User{} = owner, subject, role) when is_binary(subject) do
    with {:ok, role} <- role(role),
         {:ok, person} <- person(subject),
         :ok <- not_self(person, owner) do
      now = DateTime.utc_now()

      Repo.insert_all(
        Person,
        [
          %{
            artifact_id: artifact.id,
            user_id: person.id,
            role: role,
            granted_by: owner.subject,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: [set: [role: role, granted_by: owner.subject, updated_at: now]],
        conflict_target: [:artifact_id, :user_id]
      )

      {:ok, _event} =
        Audit.record(owner.subject, "artifact.share", artifact.id, %{
          "person" => person.subject,
          "role" => role
        })

      {:ok, %{"id" => artifact.id, "person" => json(person, role, owner.subject, now)}}
    end
  end

  def grant(_artifact, _owner, other, _role),
    do: {:error, invalid("person is a person's subject, not #{inspect(other)}")}

  defp role(role) when role in @roles, do: {:ok, role}

  defp role(other),
    do: {:error, invalid("a person's role is view, comment or edit, not #{inspect(other)}")}

  defp person(subject) do
    case Identity.get_user(subject) do
      %User{id: id, active: true} = user when is_binary(id) -> {:ok, user}
      _none -> {:error, Error.new(:not_found, %{person: subject, reason: "nobody of that name is a person of this plane"})}
    end
  end

  defp not_self(%User{id: id}, %User{id: id}),
    do: {:error, invalid("you own it already; share it with somebody else")}

  defp not_self(_person, _owner), do: :ok

  @doc "Take `subject`'s grant on `artifact` away: how many there were (0 or 1)."
  @spec revoke(Artifact.t(), String.t()) :: non_neg_integer()
  def revoke(%Artifact{id: id}, subject) when is_binary(subject) do
    users = from(u in User, where: u.subject == ^subject, select: u.id)
    {n, _} = Repo.delete_all(from(p in Person, where: p.artifact_id == ^id and p.user_id in subquery(users)))
    n
  end

  @doc "The ids of the artifacts `user` was given by name, as a query."
  @spec granted_to(User.t()) :: Ecto.Query.t()
  def granted_to(%User{id: id}) when is_binary(id),
    do: from(p in Person, where: p.user_id == ^id, select: p.artifact_id)

  def granted_to(_user), do: from(p in Person, where: false, select: p.artifact_id)

  @doc "The role a grant gives `user` on each of `ids`."
  @spec roles([String.t()], User.t()) :: %{String.t() => String.t()}
  def roles([], _user), do: %{}

  def roles(ids, %User{id: user_id}) when is_binary(user_id) do
    from(p in Person, where: p.user_id == ^user_id and p.artifact_id in ^ids, select: {p.artifact_id, p.role})
    |> Repo.all()
    |> Map.new()
  end

  def roles(_ids, _user), do: %{}

  @doc "Who `artifact` is shared with by name, by name, with their roles: for its owners."
  @spec list(Artifact.t()) :: [map()]
  def list(%Artifact{id: id}) do
    from(p in Person, where: p.artifact_id == ^id, preload: :user)
    |> Repo.all()
    |> Enum.map(&json(&1.user, &1.role, &1.granted_by, &1.updated_at))
    |> Enum.sort_by(&String.downcase(&1["display_name"] || &1["subject"]))
  end

  @doc "The subjects `artifact` is shared with at `role` or above, for whom its news is."
  @spec subjects_at_least(Artifact.t(), String.t()) :: [String.t()]
  def subjects_at_least(%Artifact{id: id}, role) do
    wanted = Enum.drop_while(@roles, &(&1 != role))

    from(p in Person,
      join: u in User,
      on: u.id == p.user_id,
      where: p.artifact_id == ^id and p.role in ^wanted,
      select: u.subject
    )
    |> Repo.all()
  end

  defp json(%User{} = user, role, by, at),
    do: %{
      "subject" => user.subject,
      "display_name" => user.display_name,
      "email" => user.email,
      "role" => role,
      "granted_by" => by,
      "granted_at" => at
    }

  defp invalid(reason), do: Error.new(:invalid_params, %{reason: reason})
end
