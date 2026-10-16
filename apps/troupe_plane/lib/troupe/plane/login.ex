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

  alias Troupe.Plane.{Audit, Identity, Settings}
  alias Troupe.Plane.Identity.User

  require Logger

  @doc """
  Apply an access token's claims.

  The identity is the claim `subject_claim` names: `sub` unless the deployment says
  otherwise, `oid` for Entra ID (Decision 751). `groups` is read from the claim named in
  configuration, since providers disagree about whether it is `groups`, `roles`, or
  something vendor-prefixed.
  """
  @spec from_claims(map()) :: {:ok, User.t(), [Identity.Team.t()]} | {:error, term()}
  def from_claims(claims) do
    claim = Settings.get("subject_claim")

    with {:ok, subject} <- fetch_subject(claims, claim),
         :ok <- rekey(claims, claim, subject),
         :ok <- adopt(subject, claim, claims),
         {:ok, user} <- upsert(subject, claims),
         :ok <- sync_groups(user, groups_in(claims)) do
      {:ok, user, Identity.teams_for(user)}
    end
  end

  # The reason names the claim, because "no subject" from a token that plainly has a `sub`
  # sends whoever reads it looking in the wrong place.
  defp fetch_subject(claims, claim) do
    case Map.get(claims, claim) do
      subject when is_binary(subject) and subject != "" -> unreserved(subject, claim)
      _ -> {:error, {:no_subject, claim}}
    end
  end

  # The plane's own subjects: a removed person's sessions are owned by `removed:<id>` and a
  # service principal is `svc:<team>/<name>`. Somebody signing in under either would be
  # the owner of what it names, so a subject that starts with one is no person's.
  @reserved ["removed:", "svc:"]

  defp unreserved(subject, claim) do
    if String.starts_with?(subject, @reserved),
      do: {:error, {:reserved_subject, claim}},
      else: {:ok, subject}
  end

  # A plane switched to another claim already knows its people by their `sub`. Somebody
  # it has never seen under the new value but knows under the `sub` this same token
  # carries is the same person, and is moved over once, here, with everything they own
  # (Decision 751). Under `sub` itself, or when the two values agree, there is nothing to
  # move; after the move there is nobody left under the old value, so the next sign-in
  # finds nothing to do either.
  #
  # The token that moves somebody is one that would have signed in as them under `sub`
  # the day before, so the move gives it nothing it did not have.
  defp rekey(_claims, "sub", _subject), do: :ok

  defp rekey(claims, claim, subject) do
    case Map.get(claims, "sub") do
      old when is_binary(old) and old != "" and old != subject ->
        case Identity.rekey(old, subject) do
          {:ok, :none} -> :ok
          {:ok, outcome} -> announce(outcome, old, subject, claim)
          {:error, reason} -> {:error, {:rekey_failed, reason}}
        end

      _same_or_absent ->
        :ok
    end
  end

  # Somebody nobody is under, whose subject is the `externalId` SCIM gave a row, is that
  # row's person: SCIM names a person by the value the subject claim carries, and their row
  # is under another value only because a sign-in under another claim moved it there. They
  # are moved back once, here, as a re-key moves anybody, rather than made a second time.
  #
  # Only when the row's email or `userName` agrees with the token's too. The `externalId`
  # alone is one provisioning attribute, and mapped wrongly it would hand somebody else's
  # row, sessions and administration to this token. Refused, the token signs in as a row
  # of its own, and the pair is left for an administrator (`admin.identity.duplicates`).
  defp adopt(subject, claim, claims) do
    carried = %{
      email: Map.get(claims, "email"),
      user_name: Map.get(claims, "preferred_username") || Map.get(claims, "upn")
    }

    case Identity.adoption(subject, subject, carried) do
      :none ->
        :ok

      {:adopt, %User{subject: old}} ->
        case Identity.rekey(old, subject) do
          {:ok, :none} -> :ok
          {:ok, outcome} -> announce(outcome, old, subject, claim)
          {:error, reason} -> {:error, {:rekey_failed, reason}}
        end

      {:refused, held} ->
        refuse_adoption(held, subject, claim)

      {:fold, signed, held} ->
        fold(signed, held, subject, claim)
    end
  end

  # A row of its own was all an earlier sign-in under this subject could be given: its
  # token carried nothing that agreed with SCIM's row, or nothing at all, as an MCP
  # client's access token minted without the email or profile scopes does. This token
  # carries what agrees, by the rule an adoption needs, so the two are one person: the
  # sign-in's row is folded into SCIM's, which takes the subject (`Identity.fold/2`).
  defp fold(signed, held, subject, claim) do
    case Identity.fold(held, signed) do
      {:ok, detail} ->
        Logger.info(
          "troupe plane: a sign-in under #{subject}, the #{claim} claim, now agrees with " <>
            "the row SCIM gave that externalId (#{held.id}); folded the row an earlier " <>
            "sign-in made (#{signed.id}) into it"
        )

        detail = Map.merge(detail, %{"via" => "sign-in", "claim" => claim})
        {:ok, _} = Audit.record(subject, "person.adopt", subject, detail)
        :ok

      {:error, :settled} ->
        :ok

      {:error, reason} ->
        {:error, {:rekey_failed, reason}}
    end
  end

  # The identifiers and nothing the token said about the person, as for a move.
  defp refuse_adoption(held, subject, claim) do
    Logger.warning(
      "troupe plane: a sign-in under #{subject}, the #{claim} claim, found the row SCIM " <>
        "gave that externalId (#{held.id}, under #{held.subject}), and neither its email " <>
        "nor its userName agrees with the token's; it signs in as a row of its own, and " <>
        "admin.identity.duplicates lists the pair"
    )

    {:ok, _} =
      Audit.record(subject, "person.adopt_refused", subject, %{
        "subject" => subject,
        "row" => held.id,
        "row_subject" => held.subject,
        "via" => "sign-in",
        "claim" => claim
      })

    :ok
  end

  # The two identifiers and the claim's name, and nothing else the token said: this is a
  # log line and an audit entry, and neither is a place for an email or a tenant.
  defp announce(outcome, old, new, claim) do
    Logger.info(
      "troupe plane: #{if outcome == :merged, do: "merged", else: "re-keyed"} a person " <>
        "from #{old} to #{new}, the #{claim} claim (Decision 751)"
    )

    detail = %{"from" => old, "to" => new, "claim" => claim}
    detail = if outcome == :merged, do: Map.put(detail, "merged", true), else: detail
    {:ok, _} = Audit.record(new, "person.rekey", new, detail)
    :ok
  end

  # A person the identity provider has deactivated is refused here, before anything else
  # happens, and **is not reactivated by signing in**. `active: true` used to be written
  # on every login, which meant a SCIM deprovision lasted exactly until its subject next
  # authenticated — and a token issued after that is a token every other check in the
  # plane then trusts.
  #
  # Only a person we have never seen is created active. That is what a deployment with no
  # SCIM means by "active", and it is the case the flag defaults for.
  defp upsert(subject, claims) do
    attrs = %{
      subject: subject,
      email: Map.get(claims, "email"),
      display_name: Map.get(claims, "name") || Map.get(claims, "preferred_username")
    }

    case Identity.get_user(subject) do
      %User{active: false} -> {:error, :deactivated}
      %User{} -> Identity.upsert_user(attrs)
      nil -> Identity.upsert_user(Map.put(attrs, :active, true))
    end
  end

  # Groups named in a token but not yet known are created. A group is not access — a
  # team is, and only an admin makes one — so learning that one exists is safe, and it
  # is what lets an admin enable it without asking the provider for a list first.
  #
  # A token with no groups claim at all says nothing about groups, and is left to say
  # nothing: an MCP client's access token is minted for the scopes the client asked for,
  # and one that did not ask for `groups` carries none. Reading that as "in no groups"
  # removed every membership a person had — their platform-admin group included — on
  # their first MCP call, and again on every call after. Only a claim that is present
  # and empty is the provider saying they are in none.
  defp sync_groups(_user, :absent), do: :ok

  defp sync_groups(user, group_ids) do
    for id <- group_ids do
      {:ok, _} = Identity.upsert_group(%{external_id: id, display_name: id})
    end

    with {:ok, _groups} <- Identity.set_memberships(user, group_ids), do: :ok
  end

  defp groups_in(claims) do
    claim = Settings.get("groups_claim")

    case Map.fetch(claims, claim) do
      :error -> :absent
      {:ok, nil} -> :absent
      {:ok, list} when is_list(list) -> Enum.filter(list, &is_binary/1)
      {:ok, value} when is_binary(value) -> String.split(value, ~r/[,\s]+/, trim: true)
      {:ok, _other} -> []
    end
  end
end
