defmodule Troupe.Plane.MemoryEntriesTest do
  @moduledoc """
  Memory as entries (#55): a document's `## Topic` sections are its entries, each with who
  last changed it and when (from its blame) and in how many sessions it was used (from what
  each session's last turn read); a save takes entries in place of text and writes them back
  as sections; and what is in effect for a person in a team is one list of topics, the
  closest level's entry on each with what it replaces.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Fleet, Harness, Identity, Memory}
  alias Troupe.Plane.Admin.API

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _team} = Identity.enable_team(group, %{name: "platform"})

    sales = team_with_grant("sales", "dev", name: "sales")
    design = team_with_grant("design", "dev", name: "design")
    {:ok, _} = Fleet.put_profile(%{name: "base", image: "ghcr.io/troupe/worker:1"})
    {:ok, _} = Fleet.put_profile(%{name: "dev", extends: "base", own: %{}, replicas: 1})

    root = person("root@example.test", ["platform"])
    mette = person("mette@example.test", ["sales"])
    {:ok, _} = Identity.add_team_admin(sales, mette.subject, root.subject)

    %{
      root: Admin.actor_for(root),
      mette: Admin.actor_for(mette),
      ada: person("ada@example.test", ["sales", "design"]),
      jonas: person("jonas@example.test", ["design"]),
      sales: sales,
      design: design
    }
  end

  describe "a document's entries" do
    test "are its sections, each with who last changed it, beside the text", context do
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "We are a consultancy.\n\n## Tone\n\nPlain English.", 0)

      {:ok, _} =
        API.call(
          "admin.memory.put",
          %{
            "scope" => "organisation",
            "version" => 1,
            "entries" => [
              %{"body" => "We are a consultancy."},
              %{"topic" => "Tone", "body" => "Plain English."},
              %{"topic" => "Prices", "body" => "Use the 2026 rate card."}
            ]
          },
          context.root
        )

      assert {:ok, shown} = Admin.memory_get(context.root, "organisation", nil, nil)
      assert shown.text == "We are a consultancy.\n\n## Tone\n\nPlain English.\n\n## Prices\n\nUse the 2026 rate card."

      assert [
               %{"topic" => "General", "heading" => false, "version" => 1, "by" => "root@example.test"},
               %{"topic" => "Tone", "body" => "Plain English.", "version" => 1},
               %{"topic" => "Prices", "body" => "Use the 2026 rate card.", "version" => 2, "used" => 0}
             ] = shown.entries

      assert is_binary(hd(shown.entries)["at"])

      # The version shown, as it stood.
      assert {:ok, first} = Admin.memory_get(context.root, "organisation", nil, 1)
      assert Enum.map(first.entries, & &1["topic"]) == ["General", "Tone"]
    end

    test "a save of entries is checked, and a preview takes them as a save does", context do
      assert {:error, %{message: "invalid_params", data: %{field: "entries", reason: reason}}} =
               API.call(
                 "admin.memory.preview",
                 %{"scope" => "team", "name" => "sales", "entries" => [%{"topic" => "A", "body" => "x\n## B"}]},
                 context.mette
               )

      assert reason =~ "## heading"

      assert {:ok, preview} =
               API.call(
                 "admin.memory.preview",
                 %{"scope" => "team", "name" => "sales", "entries" => [%{"topic" => "Prices", "body" => "Framework."}]},
                 context.mette
               )

      assert %{"op" => "add", "text" => "## Prices"} in preview.diff

      assert {:error, %{message: "invalid_params"}} =
               API.call("admin.memory.put", %{"scope" => "team", "name" => "sales", "version" => 0}, context.mette)
    end

    test "are refused to whoever may not change the level, as the text is", context do
      assert {:error, %{message: "forbidden"}} =
               API.call(
                 "admin.memory.put",
                 %{"scope" => "organisation", "version" => 0, "entries" => [%{"topic" => "Tone", "body" => "Loud."}]},
                 context.mette
               )

      assert {:error, %{message: "not_found"}} =
               API.call(
                 "admin.memory.put",
                 %{"scope" => "team", "name" => "design", "version" => 0, "entries" => [%{"topic" => "Tone", "body" => "x"}]},
                 context.mette
               )

      assert {:error, _} = API.call("admin.memory.get", %{"scope" => "team", "name" => "sales"}, Admin.actor_for(context.ada))
      assert Memory.current(:organisation) == nil
    end

    test "say in how many sessions they were used since they came in", context do
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "## Tone\n\nPlain.", 0)
      v1 = Memory.current(:organisation)
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "## Tone\n\nPlain.\n\n## Prices\n\nRate card.", 1)
      v2 = Memory.current(:organisation)

      stamp = &%{"scope" => "organisation", "name" => nil, "version" => &1.version, "hash" => &1.hash}

      :ok =
        Memory.machine(context.ada, [
          %{"session_id" => "s-old", "documents" => [stamp.(v1)]},
          %{"session_id" => "s-new", "documents" => [stamp.(v2)]}
        ])

      :ok = Memory.machine(context.jonas, [%{"session_id" => "s-jonas", "documents" => [stamp.(v2)]}])

      assert {:ok, %{entries: [%{"topic" => "Tone", "used" => 3}, %{"topic" => "Prices", "used" => 2}]}} =
               Admin.memory_get(context.root, "organisation", nil, nil)
    end
  end

  describe "a person's own, as entries" do
    test "me.memory answers every document's entries and the organisation's name when asked", context do
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "## Tone\n\nPlain English.", 0)
      {:ok, _} = Admin.memory_put(context.mette, "team", "sales", "## Prices\n\nFramework.", 0)

      assert {:ok, %{"user" => %{"version" => 1}}} =
               Harness.call(
                 "me.memory.put",
                 %{"version" => 0, "entries" => [%{"topic" => "Tone", "body" => "Keep answers short."}]},
                 as(context.ada)
               )

      assert {:ok, plain} = Harness.call("me.memory", %{}, as(context.ada))
      refute Map.has_key?(hd(plain["documents"]), "entries")
      assert plain["organisation"]["name"]

      assert {:ok, answer} = Harness.call("me.memory", %{"entries" => true}, as(context.ada))

      assert [
               %{"scope" => "organisation", "entries" => [%{"topic" => "Tone", "by" => "root@example.test"}]},
               %{"scope" => "team", "name" => "sales", "entries" => [%{"topic" => "Prices", "by" => "mette@example.test"}]},
               %{"scope" => "user", "entries" => [%{"topic" => "Tone"}]}
             ] = answer["documents"]

      assert [%{"topic" => "Tone", "body" => "Keep answers short.", "by" => "ada@example.test"}] = answer["user"]["entries"]
      # Every team of hers, design's with no document among them.
      assert answer["teams"] == ["design", "sales"]
      assert answer["user"]["text"] == "## Tone\n\nKeep answers short."
    end
  end

  describe "memory.in_effect" do
    setup context do
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "## Tone\n\nPlain English.\n\n## Prices\n\nRate card.\n\n## Dates\n\nISO.", 0)
      {:ok, _} = Admin.memory_put(context.mette, "team", "sales", "## Prices\n\nFramework agreement.", 0)
      {:ok, _} = Admin.memory_put(context.root, "team", "design", "## Interviews\n\nConsent first.", 0)
      {:ok, _} = Admin.memory_put(context.root, "profile", "base", "## Dates\n\nThe base's dates.", 0)
      {:ok, _} = Harness.call("me.memory.put", %{"version" => 0, "text" => "## tone\n\nShort answers."}, as(context.ada))
      :ok
    end

    test "is one list of topics, the closest level's entry on each with what it replaces", context do
      assert {:ok, effect} = Harness.call("memory.in_effect", %{"team" => "sales"}, as(context.ada))
      assert effect["team"] == "sales"
      assert effect["organisation"]["name"]

      assert Enum.map(effect["levels"], &{&1["scope"], &1["name"], &1["entries"]}) == [
               {"organisation", nil, 3},
               {"team", "sales", 1},
               {"user", nil, 1}
             ]

      assert Enum.map(effect["entries"], &{&1["topic"], &1["level"]["scope"], Enum.map(&1["replaces"], fn r -> {r["level"]["scope"], r["body"]} end)}) == [
               {"tone", "user", [{"organisation", "Plain English."}]},
               {"Prices", "team", [{"organisation", "Rate card."}]},
               {"Dates", "organisation", []}
             ]

      # Her first team by name where none is named.
      assert {:ok, %{"team" => "design", "entries" => entries}} = Harness.call("memory.in_effect", %{}, as(context.ada))
      assert Enum.map(entries, & &1["topic"]) == ["tone", "Prices", "Dates", "Interviews"]
    end

    test "with a profile named, reads its chain between the team's and the person's", context do
      assert {:ok, effect} = Harness.call("memory.in_effect", %{"team" => "sales", "profile" => "dev"}, as(context.ada))
      assert Enum.map(effect["levels"], &{&1["scope"], &1["name"]}) == [{"organisation", nil}, {"team", "sales"}, {"profile", "base"}, {"profile", "dev"}, {"user", nil}]

      assert %{"level" => %{"scope" => "profile", "name" => "base"}, "replaces" => [%{"body" => "ISO."}]} =
               Enum.find(effect["entries"], &(&1["topic"] == "Dates"))
    end

    test "is for a team the person is in and a profile they may use through it", context do
      assert {:error, %{message: "not_found"}} = Harness.call("memory.in_effect", %{"team" => "sales"}, as(context.jonas))

      assert {:error, %{message: "not_found"}} =
               Harness.call("memory.in_effect", %{"team" => "sales", "profile" => "base"}, as(context.ada))

      assert {:ok, %{"team" => nil, "entries" => entries}} =
               Harness.call("memory.in_effect", %{}, as(person("loner@example.test")))

      assert Enum.map(entries, & &1["topic"]) == ["Tone", "Prices", "Dates"]
    end
  end

  defp as(user), do: %{user: user, platform_admin?: false}
end
