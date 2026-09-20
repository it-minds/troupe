defmodule Troupe.Plane.SCIM do
  @moduledoc """
  SCIM 2.0, translated into the identity the plane keeps.

  An identity provider pushes users and groups here; Troupe mirrors them and adds
  nothing. The one thing worth being careful about is which field is the *identity*:
  SCIM's `id` is the provider's handle for the record, and `externalId` — or failing
  that `userName` — is the subject that will appear in an access token at login. Keying
  on the wrong one means a user who logs in is a different person from the one SCIM
  created.

  Where SCIM is disabled, `Troupe.Plane.Login` creates the same rows from the `groups`
  claim. A done item requires both paths to yield the same teams, which is why both end
  in `Troupe.Plane.Identity` rather than in two parallel implementations.
  """

  alias Troupe.Plane.{Audit, Identity, Principals, Settings}
  alias Troupe.Plane.Identity.{Group, User}
  alias Troupe.Plane.SCIM.Connector

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"

  @doc "Apply a SCIM User resource."
  @spec put_user(map()) :: {:ok, User.t()} | {:error, term()}
  def put_user(resource) do
    Identity.upsert_user(%{
      subject: subject_of(resource),
      external_id: Map.get(resource, "externalId"),
      email: primary_email(resource),
      display_name: display_name(resource),
      active: Map.get(resource, "active", true)
    })
  end

  @doc """
  Apply a SCIM Group resource, including its membership.

  Members are replaced, not merged: a SCIM push carries the whole list, so a user who
  is absent has been removed, and merging would leave their access behind.
  """
  @spec put_group(map()) :: {:ok, Group.t()} | {:error, term()}
  def put_group(resource) do
    with {:ok, group} <-
           Identity.upsert_group(%{
             external_id: Map.get(resource, "externalId") || Map.fetch!(resource, "id"),
             display_name: Map.get(resource, "displayName") || Map.fetch!(resource, "id")
           }) do
      replace_members(group, Map.get(resource, "members", []))
      maybe_enable_team(group)
      {:ok, group}
    end
  end

  # The connector's switch. A group nobody has made a team of becomes one, named from its
  # display name with the platform's defaults, and the audit trail says `scim` did it. A
  # group that is already a team, or whose name another team holds, is left alone: the
  # first is done, the second is a collision an administrator can see and this cannot.
  defp maybe_enable_team(group) do
    if Connector.teams_from_groups?() do
      attrs = Map.put(Settings.team_defaults(), "enabled_by", "scim")

      case Identity.enable_team_if_new(group, attrs) do
        {:ok, team} ->
          {:ok, _} =
            Audit.record("scim", "team.enable", team.name, %{
              "group" => group.external_id,
              "by" => "scim"
            })

        {:error, _reason} ->
          :ok
      end
    end

    :ok
  end

  # SCIM members reference users by the id this plane gave them.
  defp replace_members(group, members) do
    wanted =
      members
      |> Enum.map(&Map.get(&1, "value"))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Identity.get_user_by_id/1)
      |> Enum.reject(&is_nil/1)

    Identity.set_group_members(group, Enum.map(wanted, & &1.id))
  end

  @doc "Mark a user inactive. SCIM deletes are soft, because an audit trail outlives a person's account."
  @spec deactivate_user(String.t()) :: {:ok, User.t()} | {:error, term()}
  def deactivate_user(id) do
    case Identity.get_user_by_id(id) do
      nil ->
        {:error, :not_found}

      user ->
        # And everything that person was answerable for. A service principal is a
        # credential that starts sessions and spends a budget; one whose sponsor has left
        # the provider has nobody to ask about it, so it stops firing within this push
        # rather than at whatever point somebody notices.
        {:ok, _stopped} = Principals.sponsor_left(user.subject)
        Identity.upsert_user(%{subject: user.subject, active: false})
    end
  end

  # -- rendering --------------------------------------------------------------

  @doc "A user as SCIM describes it."
  @spec render_user(User.t()) :: map()
  def render_user(%User{} = user) do
    %{
      "schemas" => [@user_schema],
      "id" => user.id,
      "externalId" => user.external_id,
      "userName" => user.subject,
      "displayName" => user.display_name,
      "active" => user.active,
      "emails" => emails(user),
      "meta" => meta("User", user.id, user.updated_at)
    }
  end

  defp emails(%User{email: nil}), do: []
  defp emails(%User{email: email}), do: [%{"value" => email, "primary" => true}]

  @doc "A group as SCIM describes it, with its members."
  @spec render_group(Group.t(), [User.t()]) :: map()
  def render_group(%Group{} = group, members \\ []) do
    %{
      "schemas" => [@group_schema],
      "id" => group.id,
      "externalId" => group.external_id,
      "displayName" => group.display_name,
      "members" =>
        Enum.map(members, &%{"value" => &1.id, "display" => &1.display_name || &1.subject}),
      "meta" => meta("Group", group.id, group.updated_at)
    }
  end

  @doc "A SCIM list response."
  @spec render_list([map()], non_neg_integer()) :: map()
  def render_list(resources, total \\ nil) do
    %{
      "schemas" => [@list_schema],
      "totalResults" => total || length(resources),
      "itemsPerPage" => length(resources),
      "startIndex" => 1,
      "Resources" => resources
    }
  end

  defp meta(kind, id, updated_at) do
    %{
      "resourceType" => kind,
      "location" => "/scim/v2/#{kind}s/#{id}",
      "lastModified" => updated_at && DateTime.to_iso8601(updated_at)
    }
  end

  # -- reading a resource -----------------------------------------------------

  # `externalId` is the identity provider's own id for the person and is what shows up
  # as `sub` in a token; `userName` is the fallback for providers that do not send one.
  defp subject_of(resource) do
    Map.get(resource, "externalId") || Map.fetch!(resource, "userName")
  end

  defp primary_email(resource) do
    resource
    |> Map.get("emails", [])
    |> Enum.find(&Map.get(&1, "primary", false))
    |> case do
      %{"value" => value} -> value
      _ -> resource |> Map.get("emails", []) |> List.first() |> then(&(&1 && &1["value"]))
    end
  end

  defp display_name(resource) do
    Map.get(resource, "displayName") ||
      get_in(resource, ["name", "formatted"]) ||
      join_name(resource) ||
      Map.get(resource, "userName")
  end

  defp join_name(resource) do
    given = get_in(resource, ["name", "givenName"])
    family = get_in(resource, ["name", "familyName"])

    case Enum.reject([given, family], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end
end
