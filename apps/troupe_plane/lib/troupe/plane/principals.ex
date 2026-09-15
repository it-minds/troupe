defmodule Troupe.Plane.Principals do
  @moduledoc """
  Service principals: the caller a trigger is.

  A principal is a credential a team owns. It is created by a team admin, may use a
  subset of the team's grants, and can create and steer sessions and nothing else —
  `Admin.actor_for/1` gives it no role. Everything downstream sees it as a `%User{}` of
  `kind: "service"` whose only team is its own, so grants, budgets, visibility and
  retention apply to it exactly as to a person, with no second code path to drift.

  The secret is minted here, shown once, and kept only as a salted hash. Exchanging it
  at `/auth/exchange` produces the same plane token a person gets, with `kind`, `team`
  and `profiles` claims added; a disabled principal is `unauthenticated` from its next
  exchange, and from its next `/rpc` call within one token lifetime, because the router
  resolves the subject on every request.
  """

  import Ecto.Query

  alias Troupe.Plane.{Identity, OIDC, Repo, Tokens}
  alias Troupe.Plane.Identity.{ServicePrincipal, Team, User}
  alias Troupe.Protocol.Token

  # -- lifecycle --------------------------------------------------------------

  @doc """
  Create a principal for a team, returning it with the secret that is shown once.

  Profiles are checked against the team's grants: a principal may use a subset of what
  its team may, never more, and a name outside the grants is refused here rather than
  discovered at the first `session.create`.

  A sponsor is required, and is checked the same way: a person the identity provider
  still knows, who is a member of this team. Somebody answerable for what the principal
  does has to be somebody who could have done it themselves.
  """
  @spec create(Team.t(), map(), String.t()) ::
          {:ok, ServicePrincipal.t(), String.t()} | {:error, Ecto.Changeset.t() | term()}
  def create(%Team{} = team, attrs, by) do
    name = attrs[:name] || attrs["name"]
    profiles = List.wrap(attrs[:profiles] || attrs["profiles"])

    with :ok <- check_profiles(team, profiles),
         {:ok, sponsor} <- check_sponsor(team, attrs[:sponsor] || attrs["sponsor"]) do
      {secret, hash, salt} = mint_secret()

      %ServicePrincipal{}
      |> ServicePrincipal.changeset(%{
        subject: ServicePrincipal.subject(team.name, to_string(name)),
        team_id: team.id,
        name: name,
        description: attrs[:description] || attrs["description"],
        profiles: profiles,
        secret_hash: hash,
        secret_salt: salt,
        created_by: by,
        sponsor_subject: sponsor
      })
      |> Repo.insert()
      |> case do
        {:ok, principal} -> {:ok, principal, secret}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc "Replace the secret. The old one stops working the moment this returns."
  @spec rotate(ServicePrincipal.t()) :: {:ok, ServicePrincipal.t(), String.t()} | {:error, term()}
  def rotate(%ServicePrincipal{} = principal) do
    {secret, hash, salt} = mint_secret()

    principal
    |> ServicePrincipal.changeset(%{secret_hash: hash, secret_salt: salt})
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated, secret}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Disable a principal.

  Not deleted: the sessions it created still name it as their owner, and a subject that
  could be re-created under the same name would inherit them.
  """
  @spec disable(ServicePrincipal.t()) :: {:ok, ServicePrincipal.t()} | {:error, term()}
  def disable(%ServicePrincipal{} = principal) do
    principal
    |> ServicePrincipal.changeset(%{disabled_at: principal.disabled_at || DateTime.utc_now()})
    |> Repo.update()
  end

  @doc "A team's principals, disabled ones included."
  @spec list(Team.t()) :: [ServicePrincipal.t()]
  def list(%Team{} = team) do
    Repo.all(from(p in ServicePrincipal, where: p.team_id == ^team.id, order_by: p.name))
  end

  @doc "A principal by subject, or `nil`."
  @spec get(String.t()) :: ServicePrincipal.t() | nil
  def get(subject) when is_binary(subject), do: Repo.get_by(ServicePrincipal, subject: subject)
  def get(_subject), do: nil

  @doc "A principal by id, or `nil`."
  @spec fetch(Ecto.UUID.t()) :: ServicePrincipal.t() | nil
  def fetch(id), do: Repo.get(ServicePrincipal, id)

  # -- authenticating ---------------------------------------------------------

  @doc """
  Check a secret against a subject's hash, in constant time.

  A principal that does not exist and one whose secret is wrong get the same answer, and
  a disabled one too: which of the three it was is not something the caller should learn.
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, ServicePrincipal.t()} | {:error, :unauthenticated}
  def authenticate(subject, secret) when is_binary(subject) and is_binary(secret) do
    with %ServicePrincipal{} = principal <- get(subject),
         true <- ServicePrincipal.enabled?(principal),
         true <- secret_matches?(principal, secret) do
      {:ok, principal}
    else
      _ -> {:error, :unauthenticated}
    end
  end

  def authenticate(_subject, _secret), do: {:error, :unauthenticated}

  @doc """
  Exchange a client id and secret for a plane token.

  The same token shape a person gets from `OIDC.exchange/2`, with `kind: "service"`, the
  principal's `team` and its `profiles` as claims, so nothing downstream has to ask which
  path minted it.
  """
  @spec exchange(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange(client_id, client_secret, opts \\ []) do
    with {:ok, principal} <- authenticate(client_id, client_secret),
         %User{} = user <- user_for(principal) do
      touch(principal)
      team = Identity.fetch_team(principal.team_id)

      claims = %{
        "sub" => user.subject,
        "name" => user.display_name,
        "kind" => "service",
        "team" => team && team.name,
        "teams" => List.wrap(team && team.name),
        "profiles" => principal.profiles,
        "role" => "service",
        "scopes" => Enum.map(Token.scopes_for("owner"), &Atom.to_string/1)
      }

      audience = Keyword.get(opts, :audience, OIDC.audience())

      case Tokens.mint(claims, audience: audience, lifetime: Keyword.get(opts, :lifetime, 900)) do
        {:ok, jwt, payload} ->
          {:ok,
           %{
             "token" => jwt,
             "expires_at" => payload["exp"],
             "subject" => user.subject,
             "display_name" => user.display_name,
             "kind" => "service",
             "teams" => claims["teams"],
             "profiles" => principal.profiles
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :unauthenticated}
      error -> error
    end
  end

  # -- as a user --------------------------------------------------------------

  @doc """
  The `%User{}` a principal is handled as, or `nil` for one that is disabled or missing.

  No row behind it: `id` is nil, and `principal` carries the record so that the places
  that need the team can find it without a second lookup.
  """
  @spec user_for(ServicePrincipal.t() | String.t()) :: User.t() | nil
  def user_for(%ServicePrincipal{} = principal) do
    if ServicePrincipal.enabled?(principal) do
      %User{
        id: nil,
        subject: principal.subject,
        display_name: principal.subject,
        email: nil,
        active: true,
        kind: "service",
        principal: principal
      }
    end
  end

  def user_for(subject) when is_binary(subject) do
    case get(subject) do
      nil -> nil
      principal -> user_for(principal)
    end
  end

  @doc "The profiles a principal may use, shaped as `Identity.profiles_for/1` shapes them."
  @spec profiles_for(ServicePrincipal.t()) ::
          [%{profile: String.t(), team: Team.t(), volume_mode: String.t()}]
  def profiles_for(%ServicePrincipal{} = principal) do
    case Identity.fetch_team(principal.team_id) do
      nil ->
        []

      team ->
        team
        |> Identity.grants_for_team()
        |> Enum.filter(&(&1.profile in principal.profiles))
        |> Enum.map(&%{profile: &1.profile, team: team, volume_mode: &1.volume_mode})
    end
  end

  # -- secrets ----------------------------------------------------------------

  # 256 bits of randomness, URL-safe so it survives a shell and a YAML file. The salt is
  # per principal so two principals with the same secret — which will not happen, but a
  # hash scheme should not depend on that — do not share a hash.
  defp mint_secret do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    salt = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    {secret, hash(salt, secret), salt}
  end

  defp hash(salt, secret),
    do: :crypto.hash(:sha256, salt <> secret) |> Base.encode16(case: :lower)

  defp secret_matches?(principal, secret) do
    presented = hash(principal.secret_salt, secret)

    byte_size(presented) == byte_size(principal.secret_hash) and
      :crypto.hash_equals(presented, principal.secret_hash)
  end

  # A sponsor the provider still knows, in this team. Not merely a string: a principal
  # whose sponsor is a typo has nobody answerable for it and nothing would ever notice,
  # because the field is only read when somebody leaves.
  defp check_sponsor(_team, nil), do: {:error, :no_sponsor}
  defp check_sponsor(_team, ""), do: {:error, :no_sponsor}

  defp check_sponsor(team, subject) when is_binary(subject) do
    case Identity.get_user(subject) do
      %User{active: false} -> {:error, {:sponsor_inactive, subject}}
      %User{} = user -> in_team(team, user, subject)
      nil -> {:error, {:no_such_sponsor, subject}}
    end
  end

  defp check_sponsor(_team, other), do: {:error, {:no_such_sponsor, other}}

  defp in_team(team, user, subject) do
    if team.id in Enum.map(Identity.teams_for(user), & &1.id) do
      {:ok, subject}
    else
      {:error, {:sponsor_not_in_team, subject, team.name}}
    end
  end

  @doc """
  Stop every principal a departing person sponsors, and say why.

  Called from the SCIM path when a user is deactivated. The principals are disabled
  rather than deleted — their sessions name them as owner — and the reason is recorded,
  so a console can say *needs a sponsor* instead of *disabled*, which is the difference
  between a field to fill in and a fault to investigate.
  """
  @spec sponsor_left(String.t()) :: {:ok, [ServicePrincipal.t()]}
  def sponsor_left(subject) when is_binary(subject) do
    now = DateTime.utc_now()

    {_count, stopped} =
      Repo.update_all(
        from(p in ServicePrincipal,
          where: p.sponsor_subject == ^subject and is_nil(p.disabled_at),
          select: p
        ),
        set: [
          disabled_at: now,
          disabled_reason: ServicePrincipal.sponsor_left(),
          updated_at: now
        ]
      )

    {:ok, stopped}
  end

  defp check_profiles(_team, []), do: {:error, :no_profiles}

  defp check_profiles(team, profiles) do
    granted = team |> Identity.grants_for_team() |> Enum.map(& &1.profile)

    case Enum.reject(profiles, &(&1 in granted)) do
      [] -> :ok
      outside -> {:error, {:not_granted, outside}}
    end
  end

  # Best effort and never on the request path's critical section: what a principal last
  # did is diagnostics, and a write that failed should not refuse a login.
  defp touch(principal) do
    Repo.update_all(
      from(p in ServicePrincipal, where: p.id == ^principal.id),
      set: [last_used_at: DateTime.utc_now()]
    )

    :ok
  end
end
