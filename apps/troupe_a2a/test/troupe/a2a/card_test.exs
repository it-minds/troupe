defmodule Troupe.A2A.CardTest do
  @moduledoc """
  The agent card: public without a credential, the bundle's own with one.
  """

  use Troupe.A2A.Case, async: false

  test "the public card names the profile, where to call it, and how", context do
    {:ok, %{status: 200, body: card}} =
      Req.get("#{context.url}/a2a/reviewer/.well-known/agent-card.json", retry: false)

    assert card["name"] == "reviewer"
    assert card["url"] == "#{context.url}/a2a/reviewer"

    assert card["capabilities"] == %{
             "streaming" => true,
             "pushNotifications" => false,
             "stateTransitionHistory" => true
           }

    assert card["securitySchemes"] == %{"bearer" => %{"type" => "http", "scheme" => "bearer"}}
    assert card["authentication"] == %{"schemes" => ["Bearer"]}
    assert card["defaultInputModes"] == ["text/plain", "text/markdown"]
    assert card["supportsAuthenticatedExtendedCard"] == true
    assert card["version"] == "unknown"

    # Without the plane's word there is one skill, named for the profile, so a client
    # that routes by skill still has something to route to.
    assert [%{"id" => "reviewer", "name" => "reviewer"}] = card["skills"]
  end

  test "with a credential the card carries the bundle's skills and version", context do
    {:ok, %{status: 200, body: card}} =
      Req.get("#{context.url}/a2a/reviewer/.well-known/agent-card.json",
        headers: [{"authorization", auth(:litellm)}],
        retry: false
      )

    assert card["version"] == "bundle:stable/7"
    assert card["description"] == "Troupe profile reviewer"

    assert [%{"id" => "review-checklist", "description" => "How we review a pull request"}] =
             card["skills"]

    # The same card through the method the specification names for it.
    assert {200, %{"result" => ^card}} = rpc(context, "agent/getAuthenticatedExtendedCard", %{})
  end

  test "a profile the caller may not use has no authenticated card", context do
    {:ok, %{status: 404}} =
      Req.get("#{context.url}/a2a/nope/.well-known/agent-card.json",
        headers: [{"authorization", auth(:litellm)}],
        retry: false
      )
  end

  test "a Basic credential is the same principal", context do
    {:ok, %{status: 200, body: card}} =
      Req.get("#{context.url}/a2a/reviewer/.well-known/agent-card.json",
        headers: [{"authorization", auth(:basic)}],
        retry: false
      )

    assert card["version"] == "bundle:stable/7"
  end
end
