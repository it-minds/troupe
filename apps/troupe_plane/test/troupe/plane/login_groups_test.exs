defmodule Troupe.Plane.LoginGroupsTest do
  @moduledoc """
  What a token's groups claim does to a person's memberships — and what its absence does
  not. An MCP client's access token is minted for the scopes it asked for; one minted
  without `groups` carries no claim, and reading that as "in no groups" removed every
  membership a platform admin had on their first tool call.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Identity, Login}

  setup do
    {:ok, ada, _teams} =
      Login.from_claims(%{"sub" => "idp|ada", "email" => "ada@example.test", "groups" => ["platform", "eng"]})

    %{ada: ada}
  end

  test "a token that carries groups sets them, and one that carries none clears them", %{ada: ada} do
    assert Identity.group_ids_for(ada) == ["eng", "platform"]

    {:ok, ada, _} = Login.from_claims(%{"sub" => "idp|ada", "groups" => ["eng"]})
    assert Identity.group_ids_for(ada) == ["eng"]

    # Present and empty is the provider saying so.
    {:ok, ada, _} = Login.from_claims(%{"sub" => "idp|ada", "groups" => []})
    assert Identity.group_ids_for(ada) == []
  end

  test "a token with no groups claim at all leaves memberships as they were" do
    for claims <- [%{"sub" => "idp|ada"}, %{"sub" => "idp|ada", "groups" => nil}] do
      {:ok, ada, _} = Login.from_claims(claims)
      assert Identity.group_ids_for(ada) == ["eng", "platform"], "a groupless token changed memberships: #{inspect(claims)}"
    end
  end
end
