defmodule Troupe.Plane.Remote do
  @moduledoc """
  Laptop sessions offered to the plane for steering from another device (#58).

  A laptop's daemon dials `/v1/relay` with its person's plane token and offers sessions
  over it (`Troupe.Plane.Remote.Laptop`); a person it shared one with, or its owner on
  another device, asks `/rpc` for `remote.list` and `remote.open` and attaches at
  `/v1/relay/session` with the token that answers (`Troupe.Plane.Remote.Viewer`). The
  plane relays protocol messages between the two, checks each against
  `Troupe.Protocol.Relay` on the way, and keeps nothing of them: the row here is who
  offered what to whom and whether the laptop is there.

  **Online is a live connection.** Each session a laptop's connection offers is a
  `:global` name held by that connection's process, so any replica finds the laptop, and
  a connection that dies takes its names with it. A row with no name is offline, since
  `offline_since`; nobody is queued to it.

  **The laptop decides.** The plane holds a person to what the row says, and the laptop
  holds them again to its own record: a share the plane invented reaches nobody.
  """

  import Ecto.Query

  alias Troupe.Plane.Identity
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Remote.Offer
  alias Troupe.Plane.Repo
  alias Troupe.Protocol.{Error, Relay, SessionId}

  @audience "troupe-relay"

  @doc "The audience of a token for a relayed session, which no pod and no plane call takes."
  @spec audience() :: String.t()
  def audience, do: @audience

  @doc "The `:global` name the connection offering `session_id` holds."
  @spec name(String.t()) :: term()
  def name(session_id), do: {__MODULE__, :session, session_id}

  @doc "The process of the laptop connection offering the session now, or `nil`."
  @spec laptop(String.t()) :: pid() | nil
  def laptop(session_id) do
    case :global.whereis_name(name(session_id)) do
      :undefined -> nil
      pid -> pid
    end
  end

  # -- offering ---------------------------------------------------------------

  @doc """
  Record one offer from `user`'s laptop `device`: the session, its workspace's name and
  the share, each `%{"person" => subject or email, "role" => "observe" | "control"}`.
  Answers the share as resolved. A session another person offered is a `conflict`.
  """
  @spec offer(User.t(), String.t(), map()) :: {:ok, Offer.t()} | {:error, Error.t()}
  def offer(%User{} = user, device, params) do
    with {:ok, session_id} <- session_id(params["session_id"]),
         {:ok, people} <- resolve(params["share"], user),
         :ok <- not_anothers(session_id, user) do
      now = DateTime.utc_now()

      attrs = %{
        session_id: session_id,
        owner_subject: user.subject,
        device: device,
        workspace: label(params["workspace"]),
        shares: %{"people" => people},
        offered_at: now,
        offline_since: nil
      }

      existing = Repo.get(Offer, session_id) || %Offer{}

      case existing |> Offer.changeset(attrs) |> Repo.insert_or_update() do
        {:ok, offer} -> {:ok, offer}
        {:error, changeset} -> {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  @doc """
  The laptop's whole record, as it connects: each offer recorded, and every other row of
  this person's from this device dropped, since the laptop no longer offers it. Answers
  the offers kept and the refusals, by session.
  """
  @spec sync(User.t(), String.t(), list()) :: {[Offer.t()], [{String.t(), Error.t()}]}
  def sync(%User{} = user, device, offers) when is_list(offers) do
    results = Enum.map(offers, &{&1["session_id"], offer(user, device, &1)})
    kept = for {_id, {:ok, offer}} <- results, do: offer
    refused = for {id, {:error, error}} <- results, do: {id, error}
    kept_ids = Enum.map(kept, & &1.session_id)

    Repo.delete_all(
      from(o in Offer,
        where: o.owner_subject == ^user.subject and o.device == ^device and o.session_id not in ^kept_ids
      )
    )

    {kept, refused}
  end

  @doc "Withdraw one of the person's own offers."
  @spec withdraw(User.t(), String.t()) :: :ok
  def withdraw(%User{} = user, session_id) do
    Repo.delete_all(
      from(o in Offer, where: o.session_id == ^session_id and o.owner_subject == ^user.subject)
    )

    :ok
  end

  @doc "The laptop's connection went: what it offered is offline from now."
  @spec offline(String.t(), String.t(), [String.t()]) :: :ok
  def offline(subject, device, session_ids) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(o in Offer,
        where:
          o.owner_subject == ^subject and o.device == ^device and o.session_id in ^session_ids and
            is_nil(o.offline_since)
      ),
      set: [offline_since: now]
    )

    :ok
  end

  # -- seeing -----------------------------------------------------------------

  @doc "The offers `user` may see: their own and those shared with them."
  @spec visible(User.t()) :: [{Offer.t(), String.t()}]
  def visible(%User{} = user) do
    Offer
    |> order_by([o], desc: o.offered_at)
    |> Repo.all()
    |> Enum.flat_map(fn offer ->
      case role(offer, user) do
        nil -> []
        role -> [{offer, role}]
      end
    end)
  end

  @doc """
  The offer and the role `user` holds on it: `control` for its owner, the share's for
  somebody it names, `not_found` for anybody else, as for a session nobody showed them.
  """
  @spec access(String.t() | nil, User.t()) :: {:ok, Offer.t(), String.t()} | {:error, Error.t()}
  def access(session_id, %User{} = user) when is_binary(session_id) do
    with %Offer{} = offer <- Repo.get(Offer, session_id),
         role when is_binary(role) <- role(offer, user) do
      {:ok, offer, role}
    else
      _ -> {:error, Error.new(:not_found, %{kind: "session", id: session_id})}
    end
  end

  def access(_session_id, _user), do: {:error, Error.new(:invalid_params, %{field: "session_id"})}

  @doc "The role a person holds on an offer, or `nil`."
  @spec role(Offer.t(), User.t()) :: String.t() | nil
  def role(%Offer{owner_subject: subject}, %User{subject: subject}), do: "control"

  def role(%Offer{} = offer, %User{subject: subject}) do
    Enum.find_value(Offer.people(offer), &(&1["subject"] == subject && &1["role"]))
  end

  @doc "Whether the laptop is there now, and since when it is not."
  @spec presence(Offer.t()) :: {String.t(), DateTime.t() | nil}
  def presence(%Offer{} = offer) do
    if laptop(offer.session_id),
      do: {"online", nil},
      else: {"offline", offer.offline_since || offer.updated_at}
  end

  @doc "An offer as a listing row, for one person."
  @spec row(Offer.t(), String.t(), User.t()) :: map()
  def row(%Offer{} = offer, role, %User{} = user) do
    {state, since} = presence(offer)
    owner = Identity.get_user(offer.owner_subject)

    %{
      "id" => offer.session_id,
      "kind" => "remote",
      "owner" => offer.owner_subject,
      "owner_name" => owner && owner.display_name,
      "workspace" => offer.workspace,
      "state" => state,
      "offline_since" => since && DateTime.to_iso8601(since),
      "offered_at" => DateTime.to_iso8601(offer.offered_at),
      "your_role" => if(offer.owner_subject == user.subject, do: "owner", else: role),
      "shares" => if(offer.owner_subject == user.subject, do: Offer.people(offer))
    }
  end

  # -- the share --------------------------------------------------------------

  # Each person named by subject or email, at a role the relay carries. One the plane does
  # not know is refused by name rather than dropped: a share that silently reached fewer
  # people than were named is a share the laptop's person cannot trust.
  defp resolve(nil, _owner), do: {:ok, []}

  defp resolve(share, %User{} = owner) when is_list(share) do
    share
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case person(entry) do
        {:ok, %User{subject: subject}, _role} when subject == owner.subject ->
          {:cont, {:ok, acc}}

        {:ok, %User{} = person, role} ->
          resolved = %{
            "subject" => person.subject,
            "display_name" => person.display_name || person.subject,
            "email" => person.email,
            "role" => role
          }

          {:cont, {:ok, Enum.uniq_by(acc ++ [resolved], & &1["subject"])}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp resolve(_share, _owner), do: {:error, Error.new(:invalid_params, %{field: "share"})}

  defp person(%{"person" => person} = entry) when is_binary(person) and person != "" do
    role = entry["role"] || "observe"

    cond do
      role not in Relay.roles() ->
        {:error, Error.new(:invalid_params, %{field: "share", value: role})}

      user = find_person(String.trim(person)) ->
        {:ok, user, role}

      true ->
        {:error,
         Error.new(:not_found, %{
           kind: "person",
           person: person,
           reason: "#{person} has not signed in to this plane, so cannot be shared with yet"
         })}
    end
  end

  defp person(_entry), do: {:error, Error.new(:invalid_params, %{field: "share"})}

  defp find_person("svc:" <> _ = _service), do: nil

  defp find_person(person) do
    case Identity.get_user(person) do
      %User{active: true} = user ->
        user

      _ ->
        Repo.one(
          from(u in User,
            where: fragment("lower(?)", u.email) == ^String.downcase(person) and u.active == true,
            limit: 1
          )
        )
    end
  end

  defp not_anothers(session_id, %User{subject: subject}) do
    case Repo.get(Offer, session_id) do
      %Offer{owner_subject: other} when other != subject ->
        {:error, Error.new(:conflict, %{session_id: session_id, reason: "offered by somebody else"})}

      _mine_or_none ->
        :ok
    end
  end

  defp session_id(id) when is_binary(id) do
    if SessionId.valid?(id),
      do: {:ok, id},
      else: {:error, Error.new(:invalid_params, %{field: "session_id", reason: "not a session id"})}
  end

  defp session_id(_id), do: {:error, Error.new(:invalid_params, %{field: "session_id"})}

  defp label(name) when is_binary(name), do: name |> Path.basename() |> String.slice(0, 255)
  defp label(_name), do: nil
end
