defmodule Troupe.Plane.ArtifactSharesTest do
  @moduledoc """
  An artifact's links (#62): `artifact.share` makes a link on the artifacts host that
  honours the plane's sign-in, so whoever the plane signs in through it gets its role on
  that artifact, recorded per person on first use; `artifact.unshare` revokes a link or one
  person; a link widens nothing for anybody who does not hold it; an expired or revoked one
  is refused. A public link, which needs no sign-in, exists only while an administrator has
  `artifacts_public_links` on, always expires, and stops when the owner switches the
  artifact's public links off. Through `Harness`, as `/rpc` reaches them; the host's side of
  a link is in `ArtifactLinksHostTest`.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Artifacts, Audit, Harness, Repo, Settings}
  alias Troupe.Plane.Artifacts.Share

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    _engineering = team_with_grant("engineering", "dev", name: "engineering")
    _research = team_with_grant("research", "lab", name: "research")

    ada = person("ada@example.test", ["engineering"])

    {:ok, page} =
      call(ada, "artifact.publish", %{
        "title" => "Plan",
        "kind" => "html",
        "visibility" => "profile:dev",
        "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<h1>Plan</h1>")}]
      })

    %{
      ada: ada,
      bo: person("bo@example.test", ["engineering"]),
      cy: person("cy@example.test", ["research"]),
      di: person("di@example.test", ["research"]),
      page: page
    }
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp put(user, id, body),
    do:
      call(user, "artifact.put", %{
        "id" => id,
        "files" => [%{"path" => "index.html", "bytes" => Base.encode64(body)}]
      })

  defp share(context, params),
    do: call(context.ada, "artifact.share", Map.put(params, "id", context.page["id"]))

  describe "a link" do
    test "is an address on the artifacts host, made by the owner alone", context do
      assert {:ok, %{"url" => url, "token" => token, "share" => share}} =
               share(context, %{"role" => "view"})

      assert url == "https://artifacts.example.test/s/#{token}"
      assert byte_size(token) >= 32
      assert share["role"] == "view"
      assert share["public"] == false
      assert share["expires_at"] == nil

      # Bo sees it and may not share it; Cy does not see it at all.
      assert {:error, %{message: "forbidden"}} =
               call(context.bo, "artifact.share", %{"id" => context.page["id"], "role" => "view"})

      assert {:error, %{message: "not_found"}} =
               call(context.cy, "artifact.share", %{"id" => context.page["id"], "role" => "view"})

      assert {:error, %{message: "invalid_params"}} = share(context, %{"role" => "comment"})

      # The token is not kept, only what it hashes to.
      refute inspect(Repo.all(Share)) =~ token
    end

    test "gives its role to whoever the plane signs in through it, and only to them", context do
      id = context.page["id"]
      {:ok, %{"token" => view}} = share(context, %{"role" => "view"})

      # Di does not hold the link and sees nothing, however many others used it.
      assert {:ok, %{"id" => ^id, "role" => "view", "url" => ticket}} =
               call(context.cy, "artifact.redeem", %{"token" => view})

      assert ticket =~ "https://artifacts.example.test/enter?ticket="

      assert {:ok, got} = call(context.cy, "artifact.get", %{"id" => id})
      assert got["role"] == "view"
      refute got["may_edit"]
      assert {:error, %{message: "not_found"}} = call(context.di, "artifact.get", %{"id" => id})

      # Shared with Cy, so on Cy's list, and not on Di's.
      assert {:ok, %{"artifacts" => [%{"id" => ^id}]}} =
               call(context.cy, "artifact.list", %{"shared" => true})

      assert {:ok, %{"artifacts" => []}} = call(context.di, "artifact.list", %{})

      # A view link cannot put.
      assert {:error, %{message: "forbidden"}} = put(context.cy, id, "<h1>Cy</h1>")
      assert {:ok, _} = Artifacts.fetch(id, :current, nil, context.cy)
      assert {:error, :not_found} = Artifacts.fetch(id, :current, nil, context.di)
    end

    test "with edit lets its holder put, and nothing an owner does", context do
      id = context.page["id"]
      {:ok, %{"token" => edit}} = share(context, %{"role" => "edit"})
      {:ok, %{"role" => "edit"}} = call(context.cy, "artifact.redeem", %{"token" => edit})

      assert {:ok, two} = put(context.cy, id, "<h1>Cy's</h1>")
      assert two["version"] == 2
      assert {:ok, %{"may_edit" => true, "may_delete" => false}} = call(context.cy, "artifact.get", %{"id" => id})

      assert {:error, %{message: "forbidden"}} = call(context.cy, "artifact.delete", %{"id" => id})
      assert {:error, %{message: "forbidden"}} = call(context.cy, "artifact.pin", %{"id" => id, "version" => 1})

      assert {:error, %{message: "forbidden"}} =
               call(context.cy, "artifact.share", %{"id" => id, "role" => "edit"})
    end

    test "that expired or was revoked is refused, and takes its role away", context do
      id = context.page["id"]
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
      soon = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      assert {:error, %{message: "invalid_params"}} = share(context, %{"role" => "view", "expires" => past})

      {:ok, %{"token" => token, "share" => %{"id" => share_id, "expires_at" => expires}}} =
        share(context, %{"role" => "edit", "expires" => soon})

      assert expires
      {:ok, _} = call(context.cy, "artifact.redeem", %{"token" => token})

      # Expired: refused at the door, and the role it gave is gone.
      Repo.update_all(Share, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])

      assert {:error, %{message: "not_found"}} = call(context.di, "artifact.redeem", %{"token" => token})
      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.get", %{"id" => id})

      # Revoked: the same.
      Repo.update_all(Share, set: [expires_at: nil])
      assert {:ok, %{"role" => "edit"}} = call(context.cy, "artifact.get", %{"id" => id})

      assert {:ok, %{"revoked" => true}} =
               call(context.ada, "artifact.unshare", %{"id" => id, "share" => share_id})

      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.get", %{"id" => id})
      assert {:error, %{message: "not_found"}} = call(context.di, "artifact.redeem", %{"token" => token})
      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.redeem", %{"token" => "nonsense"})
    end

    test "is listed on the artifact with who used it, and revoked by person", context do
      id = context.page["id"]
      {:ok, %{"token" => token, "share" => %{"id" => share_id}}} = share(context, %{"role" => "view"})
      {:ok, _} = call(context.cy, "artifact.redeem", %{"token" => token})
      {:ok, _} = call(context.di, "artifact.redeem", %{"token" => token})

      {:ok, got} = call(context.ada, "artifact.get", %{"id" => id})
      assert [%{"id" => ^share_id, "role" => "view", "used_by" => used}] = got["shares"]

      assert used |> Enum.map(& &1["person"]["subject"]) |> Enum.sort() ==
               ["cy@example.test", "di@example.test"]

      assert Enum.all?(used, &(&1["first_used_at"] && &1["last_used_at"]))

      # Only the owner reads who holds it.
      {:ok, theirs} = call(context.cy, "artifact.get", %{"id" => id})
      refute Map.has_key?(theirs, "shares")

      # One person out; the link still works for everybody else, and not for them again.
      assert {:ok, %{"revoked" => true}} =
               call(context.ada, "artifact.unshare", %{"id" => id, "person" => "cy@example.test"})

      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.get", %{"id" => id})
      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.redeem", %{"token" => token})
      assert {:ok, _} = call(context.di, "artifact.get", %{"id" => id})

      actions = Audit.list() |> Enum.map(& &1.action)
      assert "artifact.share" in actions
      assert "artifact.share.used" in actions
      assert "artifact.unshare" in actions
      refute inspect(Audit.list()) =~ token
    end
  end

  describe "a public link" do
    test "is refused while the setting is off, with a sentence naming it", context do
      soon = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               share(context, %{"role" => "view", "public" => true, "expires" => soon})

      assert reason =~ "artifacts_public_links"
    end

    test "with the setting on, needs an expiry, is marked, and stops with the owner's switch",
         context do
      id = context.page["id"]
      {:ok, _} = Settings.put("artifacts_public_links", "true", "root@example.test")
      soon = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} =
               share(context, %{"role" => "view", "public" => true})

      assert reason =~ "expir"

      assert {:error, %{message: "invalid_params"}} =
               share(context, %{"role" => "edit", "public" => true, "expires" => soon})

      assert {:ok, %{"url" => url, "token" => token, "share" => %{"public" => true}}} =
               share(context, %{"role" => "view", "public" => true, "expires" => soon})

      assert url == "https://artifacts.example.test/s/#{token}/"
      assert {:ok, %{artifact: %{id: ^id}}} = Artifacts.public(token, nil)

      {:ok, %{"artifacts" => [listed]}} = call(context.bo, "artifact.list", %{})
      assert listed["public"] == true

      # The owner's switch for this artifact.
      assert {:ok, %{"public_links" => false, "public" => false}} =
               call(context.ada, "artifact.public", %{"id" => id, "enabled" => false})

      assert :error = Artifacts.public(token, nil)

      {:ok, _} = call(context.ada, "artifact.public", %{"id" => id, "enabled" => true})
      assert {:ok, _} = Artifacts.public(token, nil)

      # The administrator's switch for all of them.
      {:ok, _} = Settings.put("artifacts_public_links", "false", "root@example.test")
      assert :error = Artifacts.public(token, nil)
      {:ok, %{"artifacts" => [listed]}} = call(context.bo, "artifact.list", %{})
      assert listed["public"] == false
    end
  end
end
