defmodule Troupe.Plane.MemoryTest do
  @moduledoc """
  The organisation's memory documents (#55): the organisation's, each team's and each
  worker profile's, every version kept and audited, edited by the administrators whose
  they are, and handed to the sessions in their scope: `me.memory`, signed, for a person's
  own machine, and the activation for a pod (`BundlesTest`).

  Against the development OpenBao for the signature, as `SigningTest` is.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Fleet, Harness, Identity, Memory, Signing}
  alias Troupe.Protocol.PlaneSignature

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _team} = Identity.enable_team(group, %{name: "platform"})

    engineering = team_with_grant("engineering", "dev", name: "engineering")
    design = team_with_grant("design", "dev", name: "design")
    {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 1})

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    ada = person("ada@example.test", ["engineering"])
    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)

    %{
      root: Admin.actor_for(root),
      lead: Admin.actor_for(lead),
      ada: ada,
      engineering: engineering,
      design: design
    }
  end

  describe "a document's versions" do
    test "each save is the next version, kept with who saved it, and audited", context do
      assert {:ok, %{document: %{"version" => 1}, changes: changes}} =
               Admin.memory_put(context.root, "organisation", nil, "We deploy on Tuesdays.", 0)

      assert changes["version"] == %{"from" => 0, "to" => 1}

      assert {:ok, %{document: %{"version" => 2}}} =
               Admin.memory_put(
                 context.root,
                 "organisation",
                 nil,
                 "We deploy on Tuesdays.\nThe on-call rota is in the wiki.\r\n\n",
                 1
               )

      assert {:ok, shown} = Admin.memory_get(context.root, "organisation", nil, nil)
      # Kept as it will be read: line endings made plain, nothing trailing.
      assert shown.text == "We deploy on Tuesdays.\nThe on-call rota is in the wiki."
      assert shown.version == 2
      assert Enum.map(shown.versions, & &1["version"]) == [2, 1]
      assert Enum.all?(shown.versions, &(&1["changed_by"] == "root@example.test"))

      # What version 2 changed against version 1, line by line.
      assert shown.diff == [
               %{"op" => "same", "text" => "We deploy on Tuesdays."},
               %{"op" => "add", "text" => "The on-call rota is in the wiki."}
             ]

      assert {:ok, first} = Admin.memory_get(context.root, "organisation", nil, 1)
      assert first.text == "We deploy on Tuesdays."
      assert first.diff == [%{"op" => "add", "text" => "We deploy on Tuesdays."}]

      assert {:ok, [latest, earlier | _]} = Admin.audit_list(context.root, kind: "memory")
      assert latest.action == "memory.put"
      assert latest.subject_id == "organisation"
      assert latest.detail["version"] == %{"from" => 1, "to" => 2}
      assert earlier.detail["version"] == %{"from" => 0, "to" => 1}
    end

    test "the same text again makes no version and no audit row", context do
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "One rule.", 0)

      assert {:ok, %{changes: changes}} =
               Admin.memory_put(context.root, "organisation", nil, "One rule.\n", 1)

      assert changes == %{}
      assert length(Memory.versions(:organisation)) == 1
      assert {:ok, [_one]} = Admin.audit_list(context.root, kind: "memory")
    end

    test "a save over a version somebody else replaced is refused, naming the one in force",
         context do
      {:ok, _} = Admin.memory_put(context.root, "team", "engineering", "First.", 0)
      {:ok, _} = Admin.memory_put(context.lead, "team", "engineering", "Second.", 1)

      assert {:error, error} = Admin.memory_put(context.root, "team", "engineering", "Mine.", 1)
      assert error.message == "conflict"
      assert error.data.version == 2
      assert error.data.reason =~ "version 2 is in force"
      assert Memory.current(context.engineering).text == "Second."
    end

    test "a document past the limit is refused at the preview and the save, and nothing is written",
         context do
      long = String.duplicate("x", Troupe.Protocol.Memory.max_bytes() + 1)

      assert {:error, preview} = Admin.memory_preview(context.root, "organisation", nil, long)
      assert preview.data.reason =~ "at most 8192 bytes"

      assert {:error, put} = Admin.memory_put(context.root, "organisation", nil, long, 0)
      assert put.message == "invalid_params"
      assert Memory.current(:organisation) == nil
    end

    test "a preview shows the lines it changes, the size and who reads it, and writes nothing",
         context do
      {:ok, _} = Admin.memory_put(context.lead, "team", "engineering", "Use the monorepo.", 0)

      assert {:ok, preview} =
               Admin.memory_preview(
                 context.lead,
                 "team",
                 "engineering",
                 "Use the monorepo.\nReview within a day."
               )

      assert preview.version == 1
      assert preview.bytes == byte_size("Use the monorepo.\nReview within a day.")
      assert preview.limit == 8192
      refute preview.unchanged
      assert %{"op" => "add", "text" => "Review within a day."} in preview.diff
      assert preview.effect =~ "no other team's session reads it"
      assert length(Memory.versions(context.engineering)) == 1
    end
  end

  describe "who edits which" do
    test "a team admin changes their team's, reads the organisation's, and nothing else",
         context do
      assert {:ok, _} = Admin.memory_put(context.lead, "team", "engineering", "Ours.", 0)

      assert {:error, %{message: "forbidden"}} =
               Admin.memory_put(context.lead, "organisation", nil, "Everyone's.", 0)

      assert {:ok, %{editable: false}} = Admin.memory_get(context.lead, "organisation", nil, nil)

      # Another team's is not there, as another team is not.
      assert {:error, %{message: "not_found"}} =
               Admin.memory_put(context.lead, "team", "design", "Theirs.", 0)

      assert {:error, %{message: "forbidden"}} =
               Admin.memory_put(context.lead, "profile", "dev", "The pod's.", 0)

      assert {:ok, listing} = Admin.memory_list(context.lead)
      assert Enum.map(listing.teams, & &1.name) == ["engineering"]
      assert listing.profiles == []
      refute listing.organisation.editable

      # The team's own change is in the audit its admin reads.
      assert {:ok, [row]} = Admin.audit_list(context.lead, kind: "memory")
      assert row.subject_id == "team/engineering"
    end

    test "a platform admin edits the organisation's, every team's and each profile's", context do
      assert {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "All.", 0)
      assert {:ok, _} = Admin.memory_put(context.root, "team", "design", "Design.", 0)
      assert {:ok, _} = Admin.memory_put(context.root, "profile", "dev", "On dev.", 0)

      assert {:error, %{message: "not_found"}} =
               Admin.memory_put(context.root, "profile", "nowhere", "No such.", 0)

      assert {:error, %{message: "invalid_params"}} =
               Admin.memory_put(context.root, "user", "ada", "Hers.", 0)

      assert {:ok, listing} = Admin.memory_list(context.root)
      assert listing.organisation.current["version"] == 1
      assert Enum.map(listing.profiles, & &1.name) == ["dev"]
      assert Enum.find(listing.teams, &(&1.name == "design")).current["version"] == 1
    end

    test "someone who administers nothing reads none of it", context do
      nobody = Admin.actor_for(context.ada)
      assert {:error, %{message: "forbidden"}} = Admin.memory_list(nobody)
      assert {:error, %{message: "forbidden"}} = Admin.memory_get(nobody, "organisation", nil, nil)
    end
  end

  describe "what reaches a session" do
    test "a pod's session reads the organisation's, its team's and its profile's, in that order",
         context do
      {:ok, _} = Admin.memory_put(context.root, "profile", "dev", "On dev.", 0)
      {:ok, _} = Admin.memory_put(context.root, "team", "design", "Design only.", 0)
      {:ok, _} = Admin.memory_put(context.root, "team", "engineering", "Engineering.", 0)
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "Everyone.", 0)

      documents = Memory.for_session(context.engineering, "dev")

      assert Enum.map(documents, &{&1["scope"], &1["name"], &1["text"]}) == [
               {"organisation", nil, "Everyone."},
               {"team", "engineering", "Engineering."},
               {"profile", "dev", "On dev."}
             ]

      assert Enum.all?(documents, &(&1["version"] == 1 and String.starts_with?(&1["hash"], "sha256:")))
    end

    test "a cleared document reaches no session", context do
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "Everyone.", 0)
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "", 1)

      assert Memory.for_session(context.engineering, "dev") == []
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

    test "a person's machine gets the organisation's and their teams', signed as memory",
         context do
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "Everyone.", 0)
      {:ok, _} = Admin.memory_put(context.root, "team", "engineering", "Engineering.", 0)
      {:ok, _} = Admin.memory_put(context.root, "team", "design", "Design only.", 0)
      {:ok, _} = Admin.memory_put(context.root, "profile", "dev", "On dev.", 0)

      assert {:ok, answer} = Harness.call("me.memory", %{}, as(context.ada))

      # Not the design team's, which is not hers, nor a profile's: no laptop runs on one.
      assert Enum.map(answer["documents"], &{&1["scope"], &1["name"]}) == [
               {"organisation", nil},
               {"team", "engineering"}
             ]

      {:ok, served} = Signing.published()
      {:ok, key} = PlaneSignature.read_key(served)

      assert {:ok, %{body: body}} = PlaneSignature.verify(answer["signed"], key, "memory")
      assert body == Map.delete(answer, "signed")

      # Not something to pass off as the organisation's settings.
      assert {:error, {:wrong_kind, "memory"}} =
               PlaneSignature.verify(answer["signed"], key, "client_defaults")
    end

    test "a person in no team gets the organisation's alone", context do
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "Everyone.", 0)
      {:ok, _} = Admin.memory_put(context.root, "team", "engineering", "Engineering.", 0)
      outsider = person("out@example.test", [])

      assert {:ok, %{"documents" => [%{"scope" => "organisation"}]}} =
               Harness.call("me.memory", %{}, as(outsider))
    end
  end

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
