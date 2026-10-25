defmodule Troupe.Plane.Artifacts.Shares do
  @moduledoc """
  An artifact's links (#62): an address on the artifacts host, `/s/<token>`, that the owner
  hands to people.

  **A link honours the plane's sign-in.** Opening it signs nobody in: whoever the plane
  signs in through it (the console's `artifact.redeem`, or the artifacts host for a viewer
  its own cookie names) gets its role on that one artifact, `view` or `edit`, recorded per
  person on first use, so the owner sees who used it and revokes one person or the whole
  link. Somebody who does not hold it gains nothing by others holding it. Its role lasts as
  long as the link does: an expired or revoked link, or a revoked person, opens nothing.

  **A public link** needs no sign-in at all, which is why there is none unless an
  administrator turns `artifacts_public_links` on: then the owner may make one, `view` only
  and always with an expiry, and turn the artifact's own public links off at any time.

  The token is never kept, only its SHA-256, so the table opens nothing to whoever reads
  it. Making, using for the first time and revoking a link are audited, never the token.
  """

  import Ecto.Query

  alias Troupe.Plane.Artifacts.{Artifact, Share, ShareUse}
  alias Troupe.Plane.{Audit, Repo, Settings}
  alias Troupe.Plane.Identity.User
  alias Troupe.Protocol.Error

  @roles ~w(view edit)

  # A public link is a bearer anybody may forward; it does not outlive a quarter.
  @max_public_days 90

  @doc "Whether an administrator has public links on."
  @spec public_links?() :: boolean()
  def public_links?, do: Settings.get("artifacts_public_links") == true

  @doc """
  A new link to `artifact`, made by its owner: `role`, optional `expires` (ISO 8601, in the
  future), and `public`. The answer carries the token and the address once; nobody can
  read either back.
  """
  @spec share(Artifact.t(), User.t(), map(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def share(%Artifact{} = artifact, %User{} = owner, params, host) do
    public = params["public"] == true

    with {:ok, role} <- role(params["role"]),
         {:ok, expires} <- expires(params["expires"]),
         :ok <- public_allowed(public, role, expires) do
      token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      share =
        Repo.insert!(%Share{
          artifact_id: artifact.id,
          token_hash: hash(token),
          role: role,
          public: public,
          expires_at: expires,
          created_by: owner.subject
        })

      {:ok, _event} =
        Audit.record(owner.subject, "artifact.share", artifact.id, %{
          "share" => share.id,
          "role" => role,
          "public" => public,
          "expires_at" => expires && DateTime.to_iso8601(expires)
        })

      address = if public, do: "#{host}/s/#{token}/", else: "#{host}/s/#{token}"
      {:ok, %{"token" => token, "url" => address, "share" => json(Repo.preload(share, uses: :user))}}
    end
  end

  defp role(role) when role in @roles, do: {:ok, role}
  defp role(other), do: {:error, invalid("a link's role is view or edit, not #{inspect(other)}")}

  defp expires(nil), do: {:ok, nil}

  defp expires(at) when is_binary(at) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(at),
         :gt <- DateTime.compare(at, DateTime.utc_now()) do
      {:ok, at}
    else
      {:error, _} -> {:error, invalid("expires is a time in ISO 8601, not #{inspect(at)}")}
      _past -> {:error, invalid("a link cannot expire in the past (#{at})")}
    end
  end

  defp expires(other), do: {:error, invalid("expires is a time in ISO 8601, not #{inspect(other)}")}

  defp public_allowed(false, _role, _expires), do: :ok

  defp public_allowed(true, role, expires) do
    cond do
      not public_links?() ->
        {:error,
         Error.new(:forbidden, %{
           reason:
             "public links are switched off on this plane; an administrator turns them on with " <>
               "artifacts_public_links under Policy and settings. A link that honours sign-in works without it"
         })}

      role != "view" ->
        {:error, invalid("a public link is view only: anybody who has it opens it, signed in or not")}

      is_nil(expires) ->
        {:error, invalid("a public link needs an expiry (expires), at most #{@max_public_days} days away")}

      DateTime.diff(expires, DateTime.utc_now(), :day) > @max_public_days ->
        {:error, invalid("a public link expires within #{@max_public_days} days")}

      true ->
        :ok
    end
  end

  @doc """
  Revoke one link (`share`, its id), or one person (`person`, a subject) from every link to
  `artifact` they were signed in through. Audited as `artifact.unshare`.
  """
  @spec unshare(Artifact.t(), User.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def unshare(%Artifact{} = artifact, %User{} = owner, %{"share" => share_id}) when is_binary(share_id) do
    now = DateTime.utc_now()

    case Ecto.UUID.cast(share_id) do
      {:ok, uuid} ->
        query = from(s in Share, where: s.id == ^uuid and s.artifact_id == ^artifact.id and is_nil(s.revoked_at))

        case Repo.update_all(query, set: [revoked_at: now]) do
          {1, _} -> revoked(owner, artifact, %{"share" => uuid})
          {0, _} -> {:error, Error.new(:not_found, %{share: share_id})}
        end

      :error ->
        {:error, Error.new(:not_found, %{share: share_id})}
    end
  end

  def unshare(%Artifact{} = artifact, %User{} = owner, %{"person" => subject}) when is_binary(subject) do
    shares = from(s in Share, where: s.artifact_id == ^artifact.id, select: s.id)

    query =
      from(u in ShareUse,
        join: p in User,
        on: p.id == u.user_id,
        where: u.share_id in subquery(shares) and p.subject == ^subject and is_nil(u.revoked_at)
      )

    case Repo.update_all(query, set: [revoked_at: DateTime.utc_now()]) do
      {0, _} -> {:error, Error.new(:not_found, %{person: subject})}
      {_n, _} -> revoked(owner, artifact, %{"person" => subject})
    end
  end

  def unshare(_artifact, _owner, _params),
    do: {:error, invalid("artifact.unshare names a link (share) or a person (person)")}

  defp revoked(owner, artifact, detail) do
    {:ok, _event} = Audit.record(owner.subject, "artifact.unshare", artifact.id, detail)
    {:ok, Map.merge(%{"revoked" => true, "id" => artifact.id}, detail)}
  end

  @doc """
  Spend `token` for `user`: their use recorded (once, audited the first time), and the
  artifact's id and the role it gives them, or `not_found` for a link that is not there,
  expired, revoked, or that revoked them.
  """
  @spec use(term(), User.t()) :: {:ok, String.t(), String.t()} | {:error, Error.t()}
  def use(token, %User{id: user_id} = user) when is_binary(token) and is_binary(user_id) do
    now = DateTime.utc_now()

    with %Share{} = share <- live_share(token),
         false <- revoked_use?(share, user) do
      # A use already there keeps when it was first; one that took `now` is this one.
      {1, [row]} =
        Repo.insert_all(
          ShareUse,
          [%{share_id: share.id, user_id: user_id, first_used_at: now, last_used_at: now}],
          on_conflict: [set: [last_used_at: now]],
          conflict_target: [:share_id, :user_id],
          returning: [:first_used_at]
        )

      if DateTime.compare(row.first_used_at, now) == :eq,
        do:
          Audit.record(user.subject, "artifact.share.used", share.artifact_id, %{
            "share" => share.id,
            "role" => share.role
          })

      {:ok, share.artifact_id, share.role}
    else
      _no -> {:error, Error.new(:not_found, %{reason: "this link has expired, was revoked, or is not one"})}
    end
  end

  def use(_token, _user),
    do: {:error, Error.new(:not_found, %{reason: "this link has expired, was revoked, or is not one"})}

  defp revoked_use?(share, user) do
    Repo.exists?(
      from(u in ShareUse,
        where: u.share_id == ^share.id and u.user_id == ^user.id and not is_nil(u.revoked_at)
      )
    )
  end

  @doc "Whether `token` is a link that still opens something, and which kind."
  @spec live(String.t()) :: {:ok, :public | :signed_in} | :error
  def live(token) do
    case live_share(token) do
      %Share{public: true} -> if public_links?(), do: {:ok, :public}, else: :error
      %Share{} -> {:ok, :signed_in}
      nil -> :error
    end
  end

  @doc "The artifact a public link opens while it and the administrator's setting allow."
  @spec public_artifact(String.t()) :: {:ok, Artifact.t()} | :error
  def public_artifact(token) do
    with true <- public_links?(),
         %Share{public: true} = share <- live_share(token),
         %Artifact{} = artifact <- Repo.get(Artifact, share.artifact_id) do
      {:ok, artifact}
    else
      _no -> :error
    end
  end

  defp live_share(token) when is_binary(token) and byte_size(token) in 16..128 do
    now = DateTime.utc_now()

    Repo.one(
      from(s in Share,
        where:
          s.token_hash == ^hash(token) and is_nil(s.revoked_at) and
            (is_nil(s.expires_at) or s.expires_at > ^now)
      )
    )
  end

  defp live_share(_token), do: nil

  # A person's live uses: of a link not revoked or expired, and not revoked for them.
  defp live_uses(user_id) do
    now = DateTime.utc_now()

    from(u in ShareUse,
      join: s in Share,
      on: s.id == u.share_id,
      where:
        u.user_id == ^user_id and is_nil(u.revoked_at) and is_nil(s.revoked_at) and
          (is_nil(s.expires_at) or s.expires_at > ^now)
    )
  end

  @doc "The ids of the artifacts a link gives `user` a role on now, as a query."
  @spec shared_with(User.t()) :: Ecto.Query.t()
  def shared_with(%User{id: id}) when is_binary(id),
    do: from([u, s] in live_uses(id), select: s.artifact_id)

  @doc "The role a link gives `user` on `artifact` now: `edit`, `view` or `nil`."
  @spec role(Artifact.t(), User.t()) :: String.t() | nil
  def role(%Artifact{id: id}, user), do: Map.get(roles([id], user), id)

  @doc "The roles links give `user` on each of `ids`, `edit` above `view`."
  @spec roles([String.t()], User.t()) :: %{String.t() => String.t()}
  def roles([], _user), do: %{}

  def roles(ids, %User{id: user_id}) when is_binary(user_id) do
    from([u, s] in live_uses(user_id), where: s.artifact_id in ^ids, select: {s.artifact_id, s.role})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {id, role}, acc ->
      Map.update(acc, id, role, &if(&1 == "edit" or role == "edit", do: "edit", else: "view"))
    end)
  end

  def roles(_ids, _user), do: %{}

  @doc "Which of `ids` a public link opens now: the setting on, the owner's switch on, one live."
  @spec public_ids([String.t()]) :: MapSet.t(String.t())
  def public_ids([]), do: MapSet.new()

  def public_ids(ids) do
    if public_links?() do
      now = DateTime.utc_now()

      from(s in Share,
        join: a in Artifact,
        on: a.id == s.artifact_id,
        where:
          s.artifact_id in ^ids and s.public and is_nil(s.revoked_at) and
            (is_nil(s.expires_at) or s.expires_at > ^now) and a.public_links,
        distinct: true,
        select: s.artifact_id
      )
      |> Repo.all()
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  @doc "Every link to `artifact`, newest first, with who used each and when: for its owner."
  @spec list(Artifact.t()) :: [map()]
  def list(%Artifact{id: id}) do
    from(s in Share, where: s.artifact_id == ^id, order_by: [desc: s.inserted_at], preload: [uses: :user])
    |> Repo.all()
    |> Enum.map(&json/1)
  end

  defp json(%Share{} = share) do
    now = DateTime.utc_now()

    state =
      cond do
        share.revoked_at -> "revoked"
        share.expires_at && DateTime.compare(share.expires_at, now) != :gt -> "expired"
        share.public and not public_links?() -> "switched off"
        true -> "live"
      end

    %{
      "id" => share.id,
      "role" => share.role,
      "public" => share.public,
      "state" => state,
      "expires_at" => share.expires_at,
      "revoked_at" => share.revoked_at,
      "created_by" => share.created_by,
      "created_at" => share.inserted_at,
      "used_by" =>
        share.uses
        |> Enum.sort_by(& &1.first_used_at, DateTime)
        |> Enum.map(fn use ->
          %{
            "person" => %{"subject" => use.user.subject, "display_name" => use.user.display_name},
            "first_used_at" => use.first_used_at,
            "last_used_at" => use.last_used_at,
            "revoked_at" => use.revoked_at
          }
        end)
    }
  end

  defp hash(token), do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)

  defp invalid(reason), do: Error.new(:invalid_params, %{reason: reason})
end
