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

  test "a sign-in names a group it creates by its id, and leaves a known group's name alone" do
    # The claim carries ids and no names, so a group first seen at a sign-in is its id.
    assert Repo.get_by!(Identity.Group, external_id: "eng").display_name == "eng"

    # A provider's SCIM push names it, and names one no sign-in has carried yet.
    {:ok, _} = Identity.upsert_group(%{external_id: "eng", display_name: "Engineering"})
    {:ok, _} = Identity.upsert_group(%{external_id: "ops", display_name: "Operations"})

    {:ok, ada, _} = Login.from_claims(%{"sub" => "idp|ada", "groups" => ["eng", "ops", "new"]})

    assert Identity.group_ids_for(ada) == ["eng", "new", "ops"]
    assert Repo.get_by!(Identity.Group, external_id: "eng").display_name == "Engineering"
    assert Repo.get_by!(Identity.Group, external_id: "ops").display_name == "Operations"
    assert Repo.get_by!(Identity.Group, external_id: "new").display_name == "new"
  end

  test "a token with no groups claim at all leaves memberships as they were" do
    for claims <- [%{"sub" => "idp|ada"}, %{"sub" => "idp|ada", "groups" => nil}] do
      {:ok, ada, _} = Login.from_claims(claims)
      assert Identity.group_ids_for(ada) == ["eng", "platform"], "a groupless token changed memberships: #{inspect(claims)}"
    end
  end
end
