defmodule Troupe.Plane.Login do
  @moduledoc """
  Turning a set of OIDC claims into the same identity SCIM would have created.

  Where SCIM is disabled this is the only way users and groups exist, so it has to
  produce exactly what SCIM produces — a done item requires both paths to yield the
  same teams. That is why it goes through `Troupe.Plane.Identity` rather than writing
  its own rows: there is one implementation, reached two ways.

  It creates groups it has never seen, and that is deliberate. A group is not access:
  access is a *team*, which a platform admin has to enable, and a grant on top of that.
  Learning that a group exists costs nothing and is what lets an admin enable it
  without first asking the identity provider for a list.
  """

  alias Troupe.Plane.Identity
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Settings

  @doc """
  Apply an access token's claims.

  `sub` is the identity. `groups` is read from the claim named in configuration, since
  providers disagree about whether it is `groups`, `roles`, or something
  vendor-prefixed.
  """
  @spec from_claims(map()) :: {:ok, User.t(), [Identity.Team.t()]} | {:error, term()}
  def from_claims(claims) do
    with {:ok, subject} <- fetch_subject(claims),
         {:ok, user} <- upsert(subject, claims),
         {:ok, _groups} <- sync_groups(user, groups_in(claims)) do
      {:ok, user, Identity.teams_for(user)}
    end
  end

  defp fetch_subject(claims) do
    case Map.get(claims, "sub") do
      subject when is_binary(subject) and subject != "" -> {:ok, subject}
      _ -> {:error, :no_subject}
    end
  end

  defp upsert(subject, claims) do
    Identity.upsert_user(%{
      subject: subject,
      email: Map.get(claims, "email"),
      display_name: Map.get(claims, "name") || Map.get(claims, "preferred_username"),
      active: true
    })
  end

  # Groups named in a token but not yet known are created. A group is not access — a
  # team is, and only an admin makes one — so learning that one exists is safe, and it
  # is what lets an admin enable it without asking the provider for a list first.
  defp sync_groups(user, group_ids) do
    for id <- group_ids do
      {:ok, _} = Identity.upsert_group(%{external_id: id, display_name: id})
    end

    Identity.set_memberships(user, group_ids)
  end

  defp groups_in(claims) do
    claim = Settings.get("groups_claim")

    case Map.get(claims, claim) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      value when is_binary(value) -> String.split(value, ~r/[,\s]+/, trim: true)
      _ -> []
    end
  end
end
