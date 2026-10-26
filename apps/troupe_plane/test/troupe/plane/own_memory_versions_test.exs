defmodule Troupe.Plane.OwnMemoryVersionsTest do
  @moduledoc """
  A person's own memory's history (#55): `me.memory` with `versions` answers their versions,
  newest first, each with its text and who saved it, for the terminal's and the desktop app's
  memory screens to compare two and to save an old one again. Nobody else's, and nothing
  without the flag.

  Against the development OpenBao for the signature, as `UserMemoryTest` is.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Harness

  @moduletag timeout: 60_000

  test "me.memory with versions answers the person's own, newest first, with their text" do
    ada = %{user: person("ada@example.test", []), platform_admin?: false}
    bea = %{user: person("bea@example.test", []), platform_admin?: false}

    {:ok, _} = Harness.call("me.memory.put", %{"text" => "One.", "version" => 0}, ada)
    {:ok, _} = Harness.call("me.memory.put", %{"text" => "One.\nTwo.", "version" => 1}, ada)
    {:ok, _} = Harness.call("me.memory.put", %{"text" => "Bea's.", "version" => 0}, bea)

    assert {:ok, %{"user" => own}} = Harness.call("me.memory", %{"versions" => true}, ada)
    assert [two, one] = own["versions"]
    assert %{"version" => 2, "text" => "One.\nTwo.", "changed_by" => "ada@example.test"} = two
    assert %{"version" => 1, "text" => "One."} = one
    assert is_binary(two["hash"]) and is_binary(two["changed_at"])

    # Saving an old version's text again is a new version over the one in force.
    {:ok, _} = Harness.call("me.memory.put", %{"text" => one["text"], "version" => 2}, ada)
    assert {:ok, %{"user" => %{"version" => 3, "text" => "One."}}} = Harness.call("me.memory", %{}, ada)

    assert {:ok, %{"user" => plain}} = Harness.call("me.memory", %{}, ada)
    refute Map.has_key?(plain, "versions")

    assert {:ok, %{"user" => %{"versions" => [%{"text" => "Bea's."}]}}} =
             Harness.call("me.memory", %{"versions" => true}, bea)
  end
end
