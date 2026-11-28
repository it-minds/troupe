defmodule Troupe.Plane.ArtifactKeepsTest do
  @moduledoc """
  An artifact a person keeps at the top of their own gallery (#978): `artifact.keep {id,
  on}`, said as `kept` on each row of `artifact.list` and on `artifact.get`. It is the
  person's own, so another person's list does not show it; the artifact's deletion takes the
  row; and one the person may no longer open is not listed, kept or not. Not audited. Through
  `Harness`, as `/rpc` reaches it.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Audit, Harness, Identity, Repo}
  alias Troupe.Plane.Artifacts.Keep

  setup do
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    _engineering = team_with_grant("engineering", "dev", name: "engineering")
    ada = person("ada@example.test", ["engineering"])

    publish = fn title, team ->
      {:ok, artifact} =
        call(ada, "artifact.publish", %{
          "title" => title,
          "kind" => "html",
          "teams" => [team],
          "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<h1>#{title}</h1>")}]
        })

      artifact
    end

    older = publish.("Older", "engineering")
    newer = publish.("Newer", "engineering")

    %{ada: ada, bo: person("bo@example.test", ["engineering"]), older: older, newer: newer}
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp keep(user, artifact, on), do: call(user, "artifact.keep", %{"id" => artifact["id"], "on" => on})

  defp rows(user) do
    {:ok, %{"artifacts" => rows}} = call(user, "artifact.list", %{})
    Enum.map(rows, &{&1["title"], &1["kept"]})
  end

  test "kept and let go round-trip through artifact.list and artifact.get, newest first still", context do
    assert rows(context.bo) == [{"Newer", false}, {"Older", false}]

    assert {:ok, %{"id" => id, "kept" => true}} = keep(context.bo, context.older, true)
    assert id == context.older["id"]
    # Kept twice is kept once.
    assert {:ok, %{"kept" => true}} = keep(context.bo, context.older, true)

    # The list stays newest first; the client puts the kept ones in their own group.
    assert rows(context.bo) == [{"Newer", false}, {"Older", true}]
    assert {:ok, %{"kept" => true}} = call(context.bo, "artifact.get", %{"id" => id})

    assert {:ok, %{"kept" => false}} = keep(context.bo, context.older, false)
    assert rows(context.bo) == [{"Newer", false}, {"Older", false}]
    # Let go of one not kept: nothing to do, and no error.
    assert {:ok, %{"kept" => false}} = keep(context.bo, context.older, false)
  end

  test "is the person's own: another person's list does not show it, and nothing is audited", context do
    {:ok, _} = keep(context.bo, context.older, true)

    assert rows(context.ada) == [{"Newer", false}, {"Older", false}]
    assert rows(context.bo) == [{"Newer", false}, {"Older", true}]

    assert Repo.all(from(e in Audit.Event, where: like(e.action, "artifact.keep%"))) == []
  end

  test "goes with the artifact's deletion", context do
    {:ok, _} = keep(context.bo, context.older, true)
    assert Repo.aggregate(Keep, :count) == 1

    assert {:ok, %{"deleted" => true}} = call(context.ada, "artifact.delete", %{"id" => context.older["id"]})

    assert Repo.aggregate(Keep, :count) == 0
    assert rows(context.bo) == [{"Newer", false}]
  end

  test "one the person may no longer open is not listed, and comes back kept when they may again", context do
    {:ok, _} = keep(context.bo, context.older, true)

    {:ok, _} = Identity.set_memberships(context.bo, [])
    assert rows(context.bo) == []
    assert {:error, %{message: "not_found"}} = keep(context.bo, context.older, true)

    {:ok, _} = Identity.set_memberships(context.bo, ["engineering"])
    assert rows(context.bo) == [{"Newer", false}, {"Older", true}]
  end

  test "refuses one the person may not open, an on that is not a boolean, and no id", context do
    cy = person("cy@example.test", [])

    assert {:error, %{message: "not_found"}} = keep(cy, context.older, true)
    assert {:error, %{message: "invalid_params"}} = keep(context.bo, context.older, "yes")
    assert {:error, %{message: "invalid_params"}} = call(context.bo, "artifact.keep", %{"on" => true})
    assert Repo.aggregate(Keep, :count) == 0
  end
end
