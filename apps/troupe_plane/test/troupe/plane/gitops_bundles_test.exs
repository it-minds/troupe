defmodule Troupe.Plane.GitopsBundlesTest do
  @moduledoc """
  A channel's configuration bundle in GitOps mode (#1198): a repository holds it as a
  `ConfigBundle` resource, something else applies it, and the plane's pass publishes it as
  the channel's next version when its content changes, as `system:gitops`.
  """

  use Troupe.Plane.DataCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Plane.{Admin, Audit, Bundles, FakeCluster, Fleet, Gitops, Identity, Repo}
  alias Troupe.Plane.Fleet.Bundle
  alias Troupe.Plane.Gitops.Bundles, as: GitopsBundles
  alias Troupe.Plane.Gitops.Triggers
  alias Troupe.Protocol.Bundle, as: Document

  @moduletag timeout: 60_000

  @flux "kustomize-controller"
  @source "https://git.example.com/fleet.git, bundles/"

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
    Application.put_env(:troupe_plane, :gitops_source, @source)

    on_exit(fn ->
      for key <- ~w(platform_admin_group provisioning_mode gitops_source)a do
        Application.delete_env(:troupe_plane, key)
      end
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    FakeCluster.start()

    %{root: Admin.actor_for(person("root@example.test", ["platform"]))}
  end

  defp document(prompt \\ "You review pull requests.") do
    %{
      "schema" => 1,
      "agents" => [
        %{"name" => "pr-reviewer", "definition" => "---\nmode: primary\n---\n#{prompt}"}
      ],
      "skills" => [
        %{
          "name" => "checklist",
          "description" => "How we review.",
          "files" => %{"SKILL.md" => "---\nname: checklist\n---\nRead the diff first."}
        }
      ]
    }
  end

  defp manifest(channel, spec, annotations \\ nil) do
    metadata = %{"name" => channel, "namespace" => FakeCluster.namespace()}

    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "ConfigBundle",
      "metadata" =>
        if(annotations, do: Map.put(metadata, "annotations", annotations), else: metadata),
      "spec" => spec
    }
  end

  defp flux(manifest) do
    {:ok, applied} = FakeCluster.apply_as(@flux, manifest)
    applied
  end

  defp pass do
    {:ok, outcomes} = Gitops.sync(GitopsBundles)
    Map.new(outcomes, &{&1.name, &1})
  end

  defp versions(channel), do: channel |> Bundles.list() |> Enum.map(& &1.version)

  # What the plane recorded of the bundles it read, newest first.
  defp trail, do: Audit.list(actor: "system:gitops", kind: "bundle")

  defp profile(name, spec) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{"name" => name, "namespace" => FakeCluster.namespace()},
      "spec" =>
        Map.merge(
          %{
            "image" => %{"repository" => "ghcr.io/troupe/worker", "tag" => "1.2.3"},
            "sessionsPerPod" => 4,
            "llm" => %{"endpoint" => "https://gateway.example.test/v1", "model" => "gpt-4o"}
          },
          spec
        )
    }
  end

  describe "a channel follows its ConfigBundle" do
    test "a new resource is the channel's first version, by system:gitops, with its generation" do
      flux(manifest("stable", document(), %{"troupe.dev/revision" => "4f2a9c1"}))

      assert %{"stable" => %{state: :created, problem: nil, generation: 1}} = pass()

      assert [%Bundle{} = v1] = Bundles.list("stable")
      assert v1.version == 1
      assert v1.published_by == "system:gitops"
      assert v1.resource_generation == 1
      assert v1.source_revision == "4f2a9c1"
      # The file's hash is the version's: the spec is published as it is.
      assert v1.hash == Document.hash(document())
      assert v1.content == document()

      hold = Bundles.hold("stable")
      assert {hold.version, hold.hash, hold.resource_generation} == {1, v1.hash, 1}

      assert [event] = trail()
      assert event.action == "bundle.publish"
      assert event.subject_id == "stable"

      assert %{
               "version" => 1,
               "hash" => hash,
               "resource" => "stable",
               "generation" => 1,
               "revision" => "4f2a9c1"
             } = event.detail

      assert hash == v1.hash
    end

    test "two passes over one resource publish once" do
      flux(manifest("stable", document()))

      assert %{"stable" => %{state: :created}} = pass()
      assert %{"stable" => %{state: :unchanged}} = pass()
      assert %{"stable" => %{state: :unchanged}} = pass()

      assert versions("stable") == [1]
      assert length(trail()) == 1
    end

    test "a changed spec is the next version, and a revert is one more, never the old number" do
      flux(manifest("stable", document()))
      pass()

      flux(manifest("stable", document("You review, and you are brief.")))
      assert %{"stable" => %{state: :changed, generation: 2}} = pass()
      assert versions("stable") == [2, 1]
      assert Bundles.current("stable").resource_generation == 2

      flux(manifest("stable", document()))
      assert %{"stable" => %{state: :changed, generation: 3}} = pass()

      assert versions("stable") == [3, 2, 1]
      assert Bundles.current("stable").content == document()
      assert Bundles.hold("stable").version == 3
    end

    test "the first resource for a channel whose current version is its content adopts it" do
      {:ok, v1} = Bundles.publish("stable", document(), by: "root@example.test", announce: false)

      flux(manifest("stable", document()))
      assert %{"stable" => %{state: :created, problem: nil}} = pass()

      assert versions("stable") == [1]
      assert Bundles.hold("stable").version == 1
      assert Bundles.hold("stable").hash == v1.hash

      assert [event] = trail()
      assert event.action == "bundle.hold"
      assert event.detail["version"] == 1

      # A different content on a channel published by hand is its next version.
      flux(manifest("beta", document("Another.")))
      {:ok, _} = Bundles.publish("beta", document(), by: "root@example.test", announce: false)
      pass()
      assert versions("beta") == [2, 1]
      assert Bundles.get("beta", 2).published_by == "system:gitops"
    end

    test "a resource the repository removes releases the channel and retires nothing" do
      flux(manifest("stable", document()))
      pass()
      flux(manifest("stable", document("Second.")))
      pass()

      FakeCluster.delete("ConfigBundle", "stable")

      log = capture_log(fn -> assert %{"stable" => %{state: :removed}} = pass() end)
      assert log =~ "ConfigBundle stable is gone from the cluster"

      assert Bundles.hold("stable") == nil

      assert Enum.map(Bundles.list("stable"), &{&1.version, &1.retired_at}) == [
               {2, nil},
               {1, nil}
             ]

      assert Bundles.current("stable").version == 2

      # A session pinned to the first version still has what it had.
      assert %{bundle_version: 1, agents: agents} = Bundles.offering_at("stable", 1)
      assert "pr-reviewer" in agents

      assert [released | _] = trail()
      assert released.action == "bundle.release"

      assert released.detail == %{
               "resource" => "stable",
               "last_generation" => 2,
               "version" => 2,
               "hash" => Bundles.get("stable", 2).hash
             }

      # Nothing is said of it again.
      assert pass() == %{}
    end

    test "a version an administrator retires is reported, and not published again" do
      flux(manifest("stable", document()))
      pass()
      flux(manifest("stable", document("Second.")))
      pass()

      {:ok, _} = Bundles.retire("stable", 2, by: "root@example.test")

      for _pass <- 1..2 do
        assert %{"stable" => %{state: :unchanged, problem: "retired", reasons: [reason]}} = pass()
        assert reason =~ "v2, the repository's content, is retired: new sessions get v1"
      end

      assert versions("stable") == [2, 1]
      assert Bundles.current("stable").version == 1
      assert Gitops.report("ConfigBundle", "stable").problem == "retired"

      # A commit is what publishes again.
      flux(manifest("stable", document("Third.")))
      assert %{"stable" => %{state: :changed, problem: nil}} = pass()
      assert versions("stable") == [3, 2, 1]
      assert Gitops.report("ConfigBundle", "stable") == nil
    end
  end

  describe "a resource the plane cannot use" do
    test "publishes nothing, keeps the current version and is said once" do
      flux(manifest("stable", document()))
      pass()

      broken = Map.put(document(), "agents", [%{"name" => "Bad Name", "definition" => "x"}])
      flux(manifest("stable", broken))

      log =
        capture_log(fn ->
          assert %{"stable" => %{state: :refused, problem: "refused", reasons: [_ | _]}} = pass()
          assert %{"stable" => %{state: :refused}} = pass()
        end)

      assert length(String.split(log, "ConfigBundle stable at generation 2 is not used")) == 2

      assert versions("stable") == [1]
      assert Bundles.hold("stable").version == 1
      assert Gitops.report("ConfigBundle", "stable").generation == 2

      # Fixed, it is read again and published.
      flux(manifest("stable", document("Fixed.")))
      assert %{"stable" => %{state: :changed, problem: nil}} = pass()
      assert versions("stable") == [2, 1]
    end

    test "a new one that fails gets no hold" do
      flux(manifest("stable", Map.put(document(), "agentz", [])))

      assert %{"stable" => %{state: :refused, reasons: reasons}} = pass()
      assert Enum.any?(reasons, &(&1 =~ "agentz"))
      assert Bundles.hold("stable") == nil
      assert versions("stable") == []
    end

    test "over 1 MiB is refused, naming the limit" do
      big = document(String.duplicate("Review carefully. ", 70_000))
      flux(manifest("stable", big))

      assert %{"stable" => %{state: :refused, reasons: [reason]}} = pass()
      assert reason =~ "the limit is 1 MiB"
      assert reason =~ "#{byte_size(Jason.encode!(big))} bytes"
      assert versions("stable") == []
    end

    test "a channel the plane composes for a profile, or a document of no schema, is refused" do
      FakeCluster.put(manifest("profile:data-team", document()))
      flux(manifest("legacy", Map.delete(document(), "schema")))

      outcomes = pass()

      assert %{state: :refused, reasons: [composed]} = outcomes["profile:data-team"]
      assert composed =~ "is the bundle the plane composes for a profile"

      assert %{state: :refused, reasons: [schema]} = outcomes["legacy"]
      assert schema =~ "schema 1"

      assert versions("profile:data-team") == []
      assert versions("legacy") == []
    end
  end

  describe "the pass" do
    test "reads the bundles before the profiles, so a profile and its servers land in one pass" do
      assert hd(Gitops.sources()) == GitopsBundles

      server = %{"name" => "wiki", "url" => "https://wiki.example.test/mcp"}
      flux(manifest("stable", Map.put(document(), "mcp_servers", [server])))
      flux(profile("dev", %{"configBundleChannel" => "stable"}))

      assert %{"ConfigBundle" => {:ok, [_]}, "WorkerProfile" => {:ok, _}} = Gitops.sync_all()

      assert Bundles.current("stable").version == 1

      assert [%{"name" => "wiki"}] =
               get_in(FakeCluster.get("WorkerProfile", "dev"), ["spec", "mcpServers"])
    end

    test "a cluster without the CRD reads every other kind, and the holds stay" do
      flux(manifest("stable", document()))
      pass()

      FakeCluster.unserve("ConfigBundle")
      flux(profile("dev", %{}))

      outcomes = Gitops.sync_all()
      assert {:error, %K8s.Discovery.Error{} = reason} = outcomes["ConfigBundle"]
      assert {:ok, [%{state: :created}]} = outcomes["WorkerProfile"]
      assert {:ok, _} = outcomes[Triggers.kind()]

      assert Gitops.unread("ConfigBundle", reason) =~ "apply this release's CRDs"
      assert Bundles.hold("stable")
      assert Fleet.get_profile("dev")
    end

    test "a child profile composed from a held channel is composed again when it changes" do
      Application.put_env(:troupe_plane, :egress_allowed, fn _host -> true end)
      on_exit(fn -> Application.delete_env(:troupe_plane, :egress_allowed) end)

      flux(manifest("standard-channel", document()))
      flux(profile("standard", %{"configBundleChannel" => "standard-channel"}))

      flux(%{
        "apiVersion" => "troupe.dev/v1alpha1",
        "kind" => "WorkerProfile",
        "metadata" => %{"name" => "data-team", "namespace" => FakeCluster.namespace()},
        "spec" => %{"extends" => "standard", "configBundleChannel" => "data"}
      })

      flux(manifest("data", %{"schema" => 1, "agents" => [agent("analyst")]}))
      Gitops.sync_all()

      composed = Fleet.get_profile("data-team").config_bundle_channel
      assert Bundles.Effective.reserved?(composed)
      before = Bundles.current(composed)
      assert before, "data-team has no bundle in effect"

      flux(manifest("standard-channel", Map.put(document(), "agents", [agent("lead")])))
      assert %{"standard-channel" => %{state: :changed}} = pass()

      after_change = Bundles.current(composed)
      assert after_change.version > before.version
      names = Enum.map(after_change.content["agents"], & &1["name"])
      assert "lead" in names and "analyst" in names
    end
  end

  describe "a person's publish and the pass on one channel" do
    test "one is first and the other after it, and nothing is corrupt" do
      flux(manifest("stable", document("From the repository.")))
      parent = self()

      by_hand =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

          Bundles.publish("stable", document("By hand."),
            by: "root@example.test",
            unheld: true,
            announce: false
          )
        end)

      pass()
      published = Task.await(by_hand)

      hold = Bundles.hold("stable")
      rows = Bundles.list("stable")

      # Consecutive numbers, and the hold names the repository's version.
      assert Enum.map(rows, & &1.version) == Enum.to_list(length(rows)..1//-1)

      assert Bundles.get("stable", hold.version).hash ==
               Document.hash(document("From the repository."))

      case published do
        # Before the pass: the pass published after it, and holds the channel now.
        {:ok, %Bundle{version: 1}} -> assert hold.version == 2
        # After it: refused, and only the repository's version is there.
        {:error, {:held, _hold}} -> assert Enum.map(rows, & &1.version) == [1]
      end
    end
  end

  defp agent(name),
    do: %{"name" => name, "definition" => "---\nmode: primary\n---\nYou are #{name}."}

  describe "the CRD" do
    setup do
      crd =
        "../../../../../charts/troupe/crds/configbundle.yaml"
        |> Path.expand(__DIR__)
        |> YamlElixir.read_from_file!()

      %{crd: crd}
    end

    test "is a namespaced ConfigBundle whose spec is the bundle document as it is", %{crd: crd} do
      assert crd["spec"]["names"]["kind"] == "ConfigBundle"
      assert crd["spec"]["names"]["shortNames"] == ["cb"]
      assert crd["spec"]["scope"] == "Namespaced"
      assert crd["spec"]["group"] == "troupe.dev"

      assert [%{"name" => "v1alpha1", "schema" => %{"openAPIV3Schema" => schema}}] =
               crd["spec"]["versions"]

      spec = schema["properties"]["spec"]

      # The document's own keys, in its own spelling, and a schema it must say.
      assert Enum.sort(Map.keys(spec["properties"])) ==
               ~w(about acp_agents agents mcp_servers schema skills)

      assert spec["required"] == ["schema"]

      # Nothing a person writes is dropped before the plane can say it is wrong.
      assert spec["x-kubernetes-preserve-unknown-fields"]

      # The limit is said where `kubectl explain` shows it.
      assert spec["description"] =~ "1 MiB"
    end

    test "fills nothing in, since a default would be content nobody committed", %{crd: crd} do
      refute defaults?(crd), "the ConfigBundle CRD has a default"
    end

    test "a gitops plane may read them and write none, and a direct plane has no grant" do
      rbac =
        "../../../../../charts/troupe/templates/plane-rbac.yaml"
        |> Path.expand(__DIR__)
        |> File.read!()

      [gitops, direct] =
        rbac
        |> String.split("{{- if eq .Values.plane.provisioningMode \"gitops\" }}")
        |> List.last()
        |> String.split("{{- else }}")

      assert gitops =~
               ~s(resources: ["configbundles"]\n    verbs: ["get", "list", "watch"]\n)

      refute direct |> String.split("{{- end }}") |> hd() =~ "configbundles"
    end
  end

  defp defaults?(map) when is_map(map),
    do: Map.has_key?(map, "default") or Enum.any?(Map.values(map), &defaults?/1)

  defp defaults?(list) when is_list(list), do: Enum.any?(list, &defaults?/1)
  defp defaults?(_value), do: false
end
