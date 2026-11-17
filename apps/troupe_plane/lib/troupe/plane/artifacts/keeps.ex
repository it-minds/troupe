defmodule Troupe.Plane.Artifacts.Keeps do
  @moduledoc """
  The artifacts a person keeps at the top of their own gallery (#978).

  It is the person's view of their gallery, not anything of the artifact's: it follows them
  from one device and app to another, nobody else reads it, the owner is not told, and it is
  not audited, as reading a gallery is not. `artifact.list` and `artifact.get` say `kept` on
  each row, and the list never leaves a kept one out for being old.

  A row goes with its person and with its artifact. One for an artifact the person may no
  longer open stays where it is, never read: the list answers only what they may open, so it
  shows again only if they may open it again.
  """

  import Ecto.Query

  alias Troupe.Plane.Artifacts.Keep
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Repo

  @doc "Keep `artifact_id` at the top of `user`'s gallery (`true`), or let it go (`false`)."
  @spec set(String.t(), User.t(), boolean()) :: :ok
  def set(artifact_id, %User{id: user_id}, true) when is_binary(user_id) do
    Repo.insert_all(Keep, [%{user_id: user_id, artifact_id: artifact_id, inserted_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: [:user_id, :artifact_id]
    )

    :ok
  end

  def set(artifact_id, %User{id: user_id}, false) when is_binary(user_id) do
    Repo.delete_all(from(k in Keep, where: k.user_id == ^user_id and k.artifact_id == ^artifact_id))
    :ok
  end

  @doc "The ids of every artifact `user` keeps at the top: none for a principal, which has no gallery."
  @spec ids(User.t()) :: [String.t()]
  def ids(%User{id: user_id}) when is_binary(user_id),
    do: Repo.all(from(k in Keep, where: k.user_id == ^user_id, select: k.artifact_id))

  def ids(_user), do: []

  @doc "Which of `ids` `user` keeps at the top."
  @spec among([String.t()], User.t()) :: MapSet.t(String.t())
  def among([], _user), do: MapSet.new()

  def among(ids, %User{id: user_id}) when is_binary(user_id) do
    from(k in Keep, where: k.user_id == ^user_id and k.artifact_id in ^ids, select: k.artifact_id)
    |> Repo.all()
    |> MapSet.new()
  end

  def among(_ids, _user), do: MapSet.new()
end
