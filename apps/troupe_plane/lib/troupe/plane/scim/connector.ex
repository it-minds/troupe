defmodule Troupe.Plane.SCIM.Connector do
  @moduledoc """
  The one connector an identity provider pushes through, and the credential it presents.

  SCIM had a credential and no object: `TROUPE_SCIM_TOKEN`, compared in the router, set
  in a Kubernetes secret and changed with a rollout. Nothing said when the provider last
  pushed, nothing could rotate the token without a deploy, and a group the provider
  created sat as a group until an administrator noticed it. This is the object: one row,
  because a plane has one directory, holding a salted hash of the token the way a service
  principal's secret is held, when it was rotated and by whom, when the provider was last
  heard from, and whether a group it pushes becomes a team on arrival.

  ## The environment stays the floor

  `authorised?/1` answers for the stored token only. The router asks it *and* the deployed
  `TROUPE_SCIM_TOKEN`, so a plane provisioned before this row existed keeps working with
  no row at all, and a deployment that wants the credential in a secret still can. A
  token deleted here closes the stored door and leaves the deployed one where it was;
  the card says which of the two is open.

  ## Last seen, at most once a minute

  Entra's full sync is a request per user and per group. Writing a timestamp on each
  would be a write per person for a fact — "the provider is talking to us" — that does
  not change between two requests a second apart, so `seen/1` moves the mark only when
  it is older than a minute. The operation is kept with it because "last sync: a `GET`
  on `Users` with a filter" is the provider's connection test, and "a `PATCH` on a user"
  is a real change, and the difference is what somebody debugging wants to know.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Troupe.Plane.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "scim_connector" do
    field(:token_hash, :string)
    field(:token_salt, :string)
    field(:rotated_at, :utc_datetime_usec)
    field(:rotated_by, :string)
    field(:last_seen_at, :utc_datetime_usec)
    field(:last_seen_op, :string)
    field(:teams_from_groups, :boolean, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @seen_every_seconds 60

  @doc "The connector row, or `nil` when nothing has been rotated, pushed or switched yet."
  @spec current() :: t() | nil
  def current, do: Repo.one(from(c in __MODULE__, limit: 1))

  @doc """
  What the card shows and `admin.scim.get` returns: everything but the token.

  `token_set` is the only thing said about the token, which is the only thing anybody
  debugging can act on and the only thing that is not a leak.
  """
  @spec describe() :: map()
  def describe do
    connector = current() || %__MODULE__{}

    %{
      token_set: is_binary(connector.token_hash),
      rotated_at: connector.rotated_at,
      rotated_by: connector.rotated_by,
      last_seen_at: connector.last_seen_at,
      last_seen_op: connector.last_seen_op,
      teams_from_groups: connector.teams_from_groups
    }
  end

  @doc """
  Mint a token, keep its hash, and return the token — the one time it is ever seen.

  The previous token stops working the moment this returns: a provider mid-sync with the
  old one gets 401 on its next request and retries with the new one once somebody has
  pasted it in, which is the same thing that happens when a principal is rotated.
  """
  @spec rotate(String.t()) :: {t(), String.t()}
  def rotate(by) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    salt = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    connector =
      (current() || %__MODULE__{})
      |> change(%{
        token_hash: hash(salt, token),
        token_salt: salt,
        rotated_at: DateTime.utc_now(),
        rotated_by: by
      })
      |> Repo.insert_or_update!()

    {connector, token}
  end

  @doc """
  Forget the stored token. Every push presenting it answers 401 from now on.

  The row stays, with the switch and the last-seen mark: deleting a credential is not a
  reason to forget when the provider was last heard from, and the next rotate should not
  have to be told again whether groups become teams.
  """
  @spec delete() :: :ok
  def delete do
    case current() do
      nil ->
        :ok

      connector ->
        connector
        |> change(%{token_hash: nil, token_salt: nil, rotated_at: nil, rotated_by: nil})
        |> Repo.update!()

        :ok
    end
  end

  @doc "Change the switch. The only attribute a connector has that is not about its token."
  @spec update(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(attrs) do
    (current() || %__MODULE__{})
    |> cast(attrs, [:teams_from_groups])
    |> Repo.insert_or_update()
  end

  @doc "Whether a group the provider pushes becomes a team on arrival."
  @spec teams_from_groups?() :: boolean()
  def teams_from_groups?, do: match?(%{teams_from_groups: true}, current())

  @doc """
  Whether a presented bearer is the stored token, in constant time.

  `false` when there is no stored token, which is not the same as "SCIM is off": the
  router also asks the deployed `TROUPE_SCIM_TOKEN`.
  """
  @spec authorised?(term()) :: boolean()
  def authorised?(presented) when is_binary(presented) do
    case current() do
      %__MODULE__{token_hash: expected, token_salt: salt} when is_binary(expected) ->
        offered = hash(salt, presented)
        byte_size(offered) == byte_size(expected) and :crypto.hash_equals(offered, expected)

      _none ->
        false
    end
  end

  def authorised?(_presented), do: false

  @doc """
  Record that the provider was heard from, if the last mark is older than a minute.

  Called by the router after an authorised request and never before one: a refused push
  is somebody with the wrong token, and "last sync" must not move for them. A plane on
  the deployed token with no row yet gets one here, so the card can say the provider is
  talking even where nobody has rotated anything.
  """
  @spec seen(String.t()) :: :ok
  def seen(operation) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@seen_every_seconds, :second)

    case current() do
      nil ->
        %__MODULE__{}
        |> change(%{last_seen_at: now, last_seen_op: operation})
        |> Repo.insert!()

      %__MODULE__{id: id} ->
        Repo.update_all(
          from(c in __MODULE__,
            where: c.id == ^id and (is_nil(c.last_seen_at) or c.last_seen_at < ^cutoff)
          ),
          set: [last_seen_at: now, last_seen_op: operation]
        )
    end

    :ok
  end

  defp hash(salt, token),
    do: :crypto.hash(:sha256, salt <> token) |> Base.encode16(case: :lower)
end
