defmodule Troupe.Plane.Fleet.Hosts do
  @moduledoc """
  Registering machines that run workers, and checking what they present.

  The plane's side of *a host that answers*. Somebody registers a machine against a
  profile, is handed a secret once, and installs the worker themselves. Nothing here
  creates or reaches a machine.

  Every decision about whether a host may enrol is made here, which is the point: the
  refusal a host gets has to be the one a pod from the wrong namespace gets, and that is
  only true if there is one place that decides it.
  """

  import Ecto.Query

  alias Troupe.Plane.Fleet.Host
  alias Troupe.Plane.Repo

  @doc """
  Register a machine, and hand back its secret once.

  Once, because what is kept is a salted digest. Somebody who loses it rotates and
  reinstalls, which is the behaviour to want anyway — a secret that could be read back is
  a secret a compromised console hands out.
  """
  @spec register(String.t(), map()) :: {:ok, Host.t(), String.t()} | {:error, term()}
  def register(profile, attrs) do
    {id, secret, hash, salt} = mint()

    %Host{}
    |> Host.changeset(
      attrs
      |> stringify()
      |> Map.merge(%{
        "id" => id,
        "profile" => profile,
        "ordinal" => next_ordinal(profile),
        "secret_hash" => hash,
        "secret_salt" => salt
      })
    )
    |> Repo.insert()
    |> case do
      {:ok, host} -> {:ok, host, secret}
      error -> error
    end
  end

  @doc """
  Issue a new secret and invalidate the old one.

  The same call whether somebody is rotating on a schedule or because a laptop was stolen,
  and it takes effect at the host's next enrolment attempt rather than at its next restart:
  the old secret stops matching the moment this returns. A worker already connected keeps
  its connection, which is the same thing a rotated trigger key does and is the honest
  behaviour — revoking a credential is not the same operation as ending a session, and
  conflating them would make rotation something people avoid doing.
  """
  @spec rotate(Host.t(), String.t()) :: {:ok, Host.t(), String.t()}
  def rotate(%Host{} = host, by) do
    # Bound to the id this host already has. A secret carries the id of the row it opens, so
    # minting a fresh pair here would hand somebody a secret naming a row that does not
    # exist — it would be refused, which looks exactly like a rotation that did not take.
    {secret, hash, salt} = mint_for(host.id)

    {:ok, host} =
      host
      |> Host.rotate_changeset(%{
        secret_hash: hash,
        secret_salt: salt,
        secret_rotated_at: DateTime.utc_now(),
        secret_rotated_by: by
      })
      |> Repo.update()

    {:ok, host, secret}
  end

  @doc """
  Take a host out of service, or put it back. Not a delete: the listing keeps it.

  Written by id rather than through the struct the caller is holding. A changeset built
  from a stale struct whose `enabled` already reads the new value is an empty changeset, and
  `Repo.update/1` obliges by writing nothing and returning `{:ok, host}` — a call that says
  it worked and did not. Turning a host back on is exactly when a caller is holding a stale
  copy, so this is the one place that shape would bite.
  """
  @spec set_enabled(Host.t() | String.t(), boolean()) :: {:ok, Host.t()} | {:error, :not_found}
  def set_enabled(%Host{id: id}, enabled?), do: set_enabled(id, enabled?)

  def set_enabled(id, enabled?) when is_binary(id) do
    now = DateTime.utc_now()

    case Repo.update_all(
           from(h in Host, where: h.id == ^id),
           set: [enabled: enabled?, updated_at: now]
         ) do
      {1, _updated} -> {:ok, Repo.get(Host, id)}
      {0, _none} -> {:error, :not_found}
    end
  end

  @doc "Every host registered to a profile, by name."
  @spec for_profile(String.t()) :: [Host.t()]
  def for_profile(profile) do
    Repo.all(from(h in Host, where: h.profile == ^profile, order_by: h.name))
  end

  @doc "One host, by id."
  @spec get(String.t()) :: Host.t() | nil
  def get(id) when is_binary(id), do: Repo.get(Host, id)
  def get(_other), do: nil

  @doc "One host of a profile, by the name an operator gave it."
  @spec by_name(String.t(), String.t()) :: Host.t() | nil
  def by_name(profile, name), do: Repo.get_by(Host, profile: profile, name: name)

  @doc """
  The host a presented secret belongs to, if it may enrol.

  `{:error, :unauthenticated}` for every way this can fail — an unknown secret, a secret
  for a host somebody disabled, a name that does not match the secret's host. One answer,
  because which check failed is exactly what an attacker would like to be told, and because
  it is the same answer `Troupe.Plane.Enrolment` gives a pod from the wrong namespace.
  """
  @spec authenticate(String.t(), String.t() | nil) ::
          {:ok, Host.t()} | {:error, :unauthenticated}
  def authenticate(secret, claimed_name \\ nil)

  def authenticate(secret, claimed_name) when is_binary(secret) do
    with {:ok, host} <- by_secret(secret),
         true <- Host.enrollable?(host),
         true <- claimed_name in [nil, host.name] do
      {:ok, host}
    else
      _refused -> {:error, :unauthenticated}
    end
  end

  def authenticate(_secret, _claimed_name), do: {:error, :unauthenticated}

  @doc "Note that a host got in, so a listing can say 'registered and never seen'."
  @spec enrolled(Host.t()) :: :ok
  def enrolled(%Host{} = host) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(h in Host, where: h.id == ^host.id),
      set: [last_enrolled_at: now, updated_at: now]
    )

    :ok
  end

  # One past the highest, never reused. A number that came back into circulation would
  # make a drain order that changed under somebody, and the numbers are cheap.
  defp next_ordinal(profile) do
    Repo.one(from(h in Host, where: h.profile == ^profile, select: max(h.ordinal))) |> next()
  end

  defp next(nil), do: 0
  defp next(highest), do: highest + 1

  # The secret names its own host, so this is one indexed lookup rather than a scan, with
  # the random half compared against a salted digest in constant time. The id is not a
  # secret — it is in every listing — and on its own it opens nothing.
  defp by_secret(secret) do
    with ["twh_" <> id, _presented] <- String.split(secret, ".", parts: 2),
         %Host{} = host <- Repo.get(Host, "wh_" <> id),
         true <- matches?(host, secret) do
      {:ok, host}
    else
      _no -> {:error, :unauthenticated}
    end
  end

  # 256 bits after the id, URL-safe so it survives a shell, an environment file and a
  # configuration-management tool. Prefixed so a secret found in a log says what it is and
  # what to rotate. A dot separates the halves, because base64url uses `-` and `_`.
  defp mint do
    id = "wh_" <> (12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
    {secret, hash, salt} = mint_for(id)
    {id, secret, hash, salt}
  end

  defp mint_for("wh_" <> id) do
    random = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    salt = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    secret = "twh_" <> id <> "." <> random
    {secret, hash(salt, secret), salt}
  end

  defp hash(salt, secret),
    do: :sha256 |> :crypto.hash(salt <> secret) |> Base.encode16(case: :lower)

  defp matches?(%Host{secret_hash: stored, secret_salt: salt}, secret) do
    presented = hash(salt, secret)
    byte_size(presented) == byte_size(stored) and :crypto.hash_equals(presented, stored)
  end

  defp stringify(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
