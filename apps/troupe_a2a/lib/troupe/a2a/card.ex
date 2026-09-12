defmodule Troupe.A2A.Card do
  @moduledoc """
  The agent card for a profile, rendered from what `profiles.list` says about it.

  Nothing in the card is written by hand. The skills are the bundle's skills — same
  word, same meaning, one source — and the version is the bundle's channel and version,
  so a caller can tell when the capability behind the card changed. The card is public;
  everything else on the route needs a token.

  The security block is spelled both ways the A2A card has spelled it: `securitySchemes`
  and `security` as the current specification has them, and `authentication.schemes`
  for a client written against the earlier one. Both say the same thing — a bearer
  token — and a client reads whichever it knows.
  """

  @protocol_version "0.3.0"

  @doc """
  The card anybody may fetch, rendered from the profile's name alone.

  The facade holds no credential, so without the caller's it cannot ask the plane what
  the bundle offers. What it can say without asking is still a card: the name, where to
  call, how to authenticate, and one skill named for the profile — and that the
  authenticated card says more. A caller that fetches the card with its credential, or
  calls `agent/getAuthenticatedExtendedCard`, gets `build/1`.
  """
  @spec public(String.t()) :: map()
  def public(name) do
    %{"name" => name}
    |> build()
    |> Map.merge(%{"version" => "unknown", "supportsAuthenticatedExtendedCard" => true})
  end

  @doc "The card for `profile`, as `profiles.list` described it."
  @spec build(map()) :: map()
  def build(%{"name" => name} = profile) do
    description = description(profile)

    %{
      "name" => name,
      "description" => description,
      "url" => "#{Troupe.A2A.public_url()}/a2a/#{name}",
      "version" => version(profile),
      "protocolVersion" => @protocol_version,
      "preferredTransport" => "JSONRPC",
      "provider" => %{"organization" => "Troupe", "url" => Troupe.A2A.public_url()},
      "capabilities" => %{
        "streaming" => true,
        "pushNotifications" => false,
        "stateTransitionHistory" => true
      },
      "securitySchemes" => %{"bearer" => %{"type" => "http", "scheme" => "bearer"}},
      "security" => [%{"bearer" => []}],
      "authentication" => %{"schemes" => ["Bearer"]},
      "defaultInputModes" => ["text/plain", "text/markdown"],
      "defaultOutputModes" => ["text/markdown", "application/octet-stream"],
      "skills" => skills(profile, description),
      "supportsAuthenticatedExtendedCard" => false
    }
  end

  # The first primary agent's description when the plane offers one; the profile's name
  # otherwise. `agents` is a list of names today and may grow into a list of objects,
  # and the card should read either without a release.
  defp description(%{"name" => name} = profile) do
    profile
    |> Map.get("agents", [])
    |> Enum.find_value(fn
      %{"description" => description} when is_binary(description) and description != "" ->
        description

      _agent ->
        nil
    end)
    |> case do
      nil -> "Troupe profile #{name}"
      description -> description
    end
  end

  defp version(profile) do
    channel = profile["channel"] || "stable"
    version = profile["bundle_version"] || profile["bundle_hash"] || "0"
    "bundle:#{channel}/#{version}"
  end

  # A profile with no skills of its own is still callable, so it advertises one skill
  # named for itself: an A2A client that routes by skill has something to route to.
  defp skills(%{"name" => name} = profile, description) do
    case Map.get(profile, "skills", []) do
      skills when is_list(skills) and skills != [] ->
        Enum.map(skills, fn skill ->
          %{
            "id" => skill["name"],
            "name" => skill["name"],
            "description" => skill["description"] || skill["name"],
            "tags" => ["troupe", name]
          }
        end)

      _none ->
        [%{"id" => name, "name" => name, "description" => description, "tags" => ["troupe"]}]
    end
  end
end
