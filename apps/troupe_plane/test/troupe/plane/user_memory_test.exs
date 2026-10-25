defmodule Troupe.Plane.UserMemoryTest do
  @moduledoc """
  A person's own memory document (#55, the user level): one document a person keeps on the
  plane, versioned and audited as the organisation's levels are, read by every session they
  run after those levels, changed by them (`me.memory.put`) and added to by an agent of
  theirs one entry at a time, and read by nobody else. A pod's session adds to its owner's
  (`ControlTest`); the push to a pod is in `BundlesTest`.

  Against the development OpenBao for the signature, as `MemoryTest` is.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, Harness, Identity, Memory, Signing}
  alias Troupe.Protocol.PlaneSignature

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _team} = Identity.enable_team(group, %{name: "platform"})
    engineering = team_with_grant("engineering", "dev", name: "engineering")

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)

    %{
      root: Admin.actor_for(root),
      lead: Admin.actor_for(lead),
      ada: person("ada@example.test", ["engineering"]),
      bo: person("bo@example.test", ["engineering"]),
      engineering: engineering
    }
  end

  describe "a person's own document" do
    test "is theirs to save, versioned, conflict-checked and audited without its text", context do
      assert {:ok, %{"user" => %{"version" => 1, "text" => "I write British English."}}} =
               put(context.ada, %{"text" => "I write British English.\r\n", "version" => 0})

      assert {:ok, %{"changed" => false}} =
               put(context.ada, %{"text" => "I write British English.", "version" => 1})

      assert {:ok, %{"user" => %{"version" => 2}}} =
               put(context.ada, %{
                 "text" => "I write British English.\nTabs, not spaces.",
                 "version" => 1
               })

      # Saved from a machine that had not seen version 2.
      assert {:error, conflict} = put(context.ada, %{"text" => "Mine.", "version" => 1})
      assert conflict.message == "conflict"
      assert conflict.data.version == 2

      assert {:error, %{message: "invalid_params"}} = put(context.ada, %{"text" => "No base."})

      assert Enum.map(Memory.versions(context.ada), &{&1.version, &1.changed_by}) == [
               {2, "ada@example.test"},
               {1, "ada@example.test"}
             ]

      rows = Enum.filter(Audit.list(), &(&1.action == "memory.put"))
      assert Enum.map(rows, & &1.subject_id) == ["user/ada@example.test", "user/ada@example.test"]
      refute inspect(rows) =~ "British"
    end

    test "a preview says what a save would change and writes nothing", context do
      {:ok, _} = put(context.ada, %{"text" => "One.", "version" => 0})

      assert {:ok, preview} =
               Harness.call("me.memory.preview", %{"text" => "One.\nTwo."}, as(context.ada))

      assert preview["version"] == 1
      assert preview["limit"] == 8192
      assert %{"op" => "add", "text" => "Two."} in preview["diff"]
      assert preview["effect"] =~ "Nobody else reads it"
      assert length(Memory.versions(context.ada)) == 1

      long = String.duplicate("x", 8193)

      assert {:error, refused} =
               Harness.call("me.memory.preview", %{"text" => long}, as(context.ada))

      assert refused.data.reason =~ "at most 8192 bytes"
      assert {:error, _} = put(context.ada, %{"text" => long, "version" => 1})
      assert Memory.current(context.ada).text == "One."
    end

    test "an entry is added under the day's heading, never in place of what is there", context do
      {:ok, _} = put(context.ada, %{"text" => "Call me Ada.", "version" => 0})

      {:ok, _} =
        Memory.append_own(context.ada, "Prefers\nsmall   pull requests.", today: ~D[2026-10-24])

      {:ok, _} =
        Memory.append_own(context.ada, "Runs the tests before pushing.", today: ~D[2026-10-24])

      {:ok, saved} =
        Memory.append_own(context.ada, "Reviews in the morning.", today: ~D[2026-10-25])

      assert saved.entry == "Reviews in the morning."

      assert Memory.current(context.ada).text == """
             Call me Ada.

             ## 2026-10-24

             - Prefers small pull requests.
             - Runs the tests before pushing.

             ## 2026-10-25

             - Reviews in the morning.\
             """

      assert {:error, "nothing to remember: the entry is empty"} =
               Memory.append_own(context.ada, "  \n ")
    end

    test "an entry that would take it past the limit is refused, naming troupe memory --edit",
         context do
      {:ok, _} = put(context.ada, %{"text" => String.duplicate("x", 8150), "version" => 0})

      assert {:error, refused} =
               Harness.call(
                 "me.memory.put",
                 %{"append" => "One sentence too many for it."},
                 as(context.ada)
               )

      assert refused.data.reason =~ "your memory is full"
      assert refused.data.reason =~ "troupe memory --edit"
      assert Memory.current(context.ada).version == 1
    end

    test "a service principal has none", _context do
      principal = %Identity.User{subject: "svc:build", kind: "service"}

      assert {:error, %{message: "forbidden"}} =
               Harness.call("me.memory.put", %{"text" => "x", "version" => 0}, as(principal))
    end
  end

  describe "nobody else reads it" do
    test "no administrator's method lists, reads or changes a person's", context do
      {:ok, _} = put(context.ada, %{"text" => "Hers alone.", "version" => 0})

      for actor <- [context.root, context.lead] do
        assert {:ok, listing} = Admin.memory_list(actor)
        refute inspect(listing) =~ "Hers alone"

        assert {:error, %{message: "invalid_params"}} =
                 Admin.memory_get(actor, "user", "ada@example.test", nil)

        assert {:error, %{message: "invalid_params"}} =
                 Admin.memory_put(actor, "user", "ada@example.test", "x", 1)
      end

      # Another person's machine, and another person's session on a pod, read none of it.
      assert {:ok, answer} = Harness.call("me.memory", %{}, as(context.bo))
      refute inspect(answer) =~ "Hers alone"
      assert answer["user"]["version"] == 0
      assert Memory.for_session(context.engineering, "dev", context.bo) == []
    end
  end

  describe "what reaches a session" do
    test "a pod's session reads its owner's own after the organisation's levels", context do
      {:ok, _} = Memory.put(:organisation, "Everyone.", "root@example.test")
      {:ok, _} = Memory.put(context.engineering, "Engineering.", "root@example.test")
      {:ok, _} = Memory.put("dev", "On dev.", "root@example.test")
      {:ok, _} = put(context.ada, %{"text" => "Hers.", "version" => 0})

      assert Enum.map(
               Memory.for_session(context.engineering, "dev", context.ada),
               &{&1["scope"], &1["name"]}
             ) == [
               {"organisation", nil},
               {"team", "engineering"},
               {"profile", "dev"},
               {"user", nil}
             ]

      # Cleared, it reaches none.
      {:ok, _} = put(context.ada, %{"text" => "", "version" => 1})

      assert Enum.map(Memory.for_session(context.engineering, "dev", context.ada), & &1["scope"]) ==
               ["organisation", "team", "profile"]
    end

    test "a re-key keeps it, and so does a fold into the row SCIM made", context do
      {:ok, _} = put(context.ada, %{"text" => "Still hers.", "version" => 0})
      {:ok, :rekeyed} = Identity.rekey("ada@example.test", "idp|ada")
      ada = Identity.get_user("idp|ada")
      assert Memory.current(ada).text == "Still hers."

      provisioned = person("idp|ada-scim", [])
      {:ok, :merged} = Identity.rekey("idp|ada", "idp|ada-scim")
      assert Memory.current(Identity.get_user(provisioned.subject)).text == "Still hers."
    end

    test "removing the person deletes it, every version", context do
      {:ok, _} = put(context.ada, %{"text" => "First.", "version" => 0})
      {:ok, _} = put(context.ada, %{"text" => "Second.", "version" => 1})

      {:ok, _tombstone, _effect} = Identity.remove_user(context.ada, "scim")
      assert Repo.aggregate(from(d in "memory_documents", where: d.scope == "user"), :count) == 0
    end
  end

  describe "me.memory" do
    setup do
      unless bao_reachable?(), do: flunk("no OpenBao; bring it up with `scripts/dev-up`")

      name = "troupe-plane-signing-test-#{System.unique_integer([:positive])}"
      transit = Application.get_env(:troupe_plane, :transit, [])
      Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :plane_signing_key, name))

      on_exit(fn ->
        Application.put_env(:troupe_plane, :transit, transit)
        delete_transit_key(transit, name)
      end)

      :ok
    end

    test "carries the person's own last, and the version they edit, signed", context do
      {:ok, _} = Memory.put(:organisation, "Everyone.", "root@example.test")
      {:ok, _} = put(context.ada, %{"text" => "Hers.", "version" => 0})

      assert {:ok, answer} = Harness.call("me.memory", %{}, as(context.ada))

      assert Enum.map(answer["documents"], &{&1["scope"], &1["text"]}) == [
               {"organisation", "Everyone."},
               {"user", "Hers."}
             ]

      assert %{"version" => 1, "text" => "Hers.", "limit" => 8192} = answer["user"]

      {:ok, served} = Signing.published()
      {:ok, key} = PlaneSignature.read_key(served)
      assert {:ok, %{body: body}} = PlaneSignature.verify(answer["signed"], key, "memory")
      assert body == Map.delete(answer, "signed")
    end
  end

  defp put(user, params), do: Harness.call("me.memory.put", params, as(user))

  defp as(user), do: %{user: user, platform_admin?: false}

  defp delete_transit_key(transit, name) do
    mount = transit[:mount] || "transit"
    headers = [{"x-vault-token", transit[:token]}]
    url = "#{transit[:address]}/v1/#{mount}/keys/#{name}"

    Req.request(
      method: :post,
      url: url <> "/config",
      headers: headers,
      json: %{"deletion_allowed" => true},
      retry: false
    )

    Req.request(method: :delete, url: url, headers: headers, retry: false)
  end

  defp bao_reachable? do
    address = Application.get_env(:troupe_plane, :transit, [])[:address]

    match?(
      {:ok, %{status: 200}},
      Req.request(method: :get, url: address <> "/v1/sys/health", retry: false)
    )
  rescue
    _ -> false
  end
end
