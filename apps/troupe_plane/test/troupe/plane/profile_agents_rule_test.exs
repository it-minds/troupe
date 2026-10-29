defmodule Troupe.Plane.ProfileAgentsRuleTest do
  @moduledoc """
  A worker profile says which agents exist on it (`spec.agents`, allow and deny), built-ins
  and its bundle's alike, and a team's grant can only narrow what that leaves.

  The rule lands where a grant's narrowing does: in the offering a person is shown, in the
  refusal `session.create` gives before anything is spent, and in what the activation
  carries to the pod, which gets the resolved primaries as the entitlement set and the rule
  itself beside it for its subagents. A child profile has its parent's rule and only
  narrows; a manifest's field reaches the row and the child's status; the export keeps it;
  `admin.profile.agents` says what the rule does to each agent.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{
    Admin,
    Bundles,
    FakeCluster,
    FakePod,
    FakeWorkerProfiles,
    Fleet,
    Gitops,
    Harness,
    Identity
  }

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Gitops.Profiles, as: GitopsProfiles

  @moduletag timeout: 60_000

  @image "ghcr.io/troupe/worker:1"

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    Application.put_env(:troupe_plane, :platform_admin_group, "platform-admins")

    on_exit(fn ->
      for key <- ~w(platform_admin_group provisioning_mode policy)a do
        Application.delete_env(:troupe_plane, key)
      end
    end)

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])
    root = "root@example.test" |> person(["platform-admins"]) |> Admin.actor_for()

    {:ok, _bundle} = Bundles.publish("stable", bundle_content(), announce: false)

    %{port: Listener.port(), team: team, ada: ada, root: root}
  end

  describe "the offering" do
    test "allow keeps only the named primaries, the bundle's and the built-ins alike", context do
      profile(%{"allow" => ["pr-reviewer", "plan"]})
      assert offered(context.ada) == ["pr-reviewer", "plan"]

      # The rule alone, as the harness asks it: a channel with nothing published offers
      # the built-ins the rule leaves.
      assert Bundles.offering(nil, [], %{allow: ["plan"], deny: []}).agents == ["plan"]
    end

    test "deny takes a built-in away, and deny beats allow", context do
      profile(%{"deny" => ["build"]})
      assert offered(context.ada) == ["pr-reviewer", "orchestrate", "plan"]

      # A spec cannot name an agent in both lists (the put refuses it), so deny over
      # allow is asked of the offering directly, as a composed rule can come to it.
      assert Bundles.offering("stable", [], %{allow: ["pr-reviewer", "build"], deny: ["build"]}).agents ==
               ["pr-reviewer"]
    end

    test "a profile that says nothing offers what it always did", context do
      profile(nil)
      assert offered(context.ada) == ["pr-reviewer", "build", "orchestrate", "plan"]
    end

    test "a grant narrows further and never widens", context do
      profile(%{"deny" => ["build"]})

      entitle(context.team, [
        %{"kind" => "agent", "name" => "build", "mode" => "allow"},
        %{"kind" => "agent", "name" => "pr-reviewer", "mode" => "allow"}
      ])

      assert offered(context.ada) == ["pr-reviewer"]

      entitle(context.team, [%{"kind" => "agent", "name" => "plan", "mode" => "deny"}])
      assert offered(context.ada) == ["pr-reviewer", "orchestrate"]
    end

    test "the built-in primaries are the files' own, and a function agent is never one" do
      # Read from the definitions Troupe ships, not a list kept here: their modes say it.
      assert Bundles.builtin_primaries() == ["build", "orchestrate", "plan"]
      assert Bundles.builtin_functions() == ["answer", "ask", "librarian", "quick"]

      offering = Bundles.offering(nil, [])
      assert offering.agents == ["build", "orchestrate", "plan"]
      assert offering.functions == ["answer", "ask", "librarian", "quick"]

      # A grant never names a function agent; the profile's rule takes one away.
      ruled = Bundles.offering(nil, [], %{allow: nil, deny: ["librarian"]})
      assert ruled.functions == ["answer", "ask", "quick"]
    end
  end

  describe "the session" do
    test "is refused a primary the profile excludes, naming the ones it could have had",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      profile(%{"deny" => ["build"]})

      params = %{"profile" => "dev", "agent" => "build", "team" => "engineering"}
      assert {:error, error} = Harness.call("session.create", params, as(context.ada))
      assert error.message == "invalid_params"
      assert error.data.reason == "no primary agent named build"
      assert error.data.agents == ["pr-reviewer", "orchestrate", "plan"]
      refute_received {:pushed, "session.activate", _}
    end

    test "is refused a function agent with what the harness runs it for", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      profile(nil)

      params = %{"profile" => "dev", "agent" => "librarian", "team" => "engineering"}
      assert {:error, error} = Harness.call("session.create", params, as(context.ada))
      assert error.message == "invalid_params"

      assert error.data.reason ==
               "librarian is a function agent the harness runs for the project brief's survey; " <>
                 "it does not carry a session"

      refute_received {:pushed, "session.activate", _}
    end

    test "is told the rule beside the set, and the set is the primaries the rule leaves",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      profile(%{"allow" => ["pr-reviewer", "helper"], "deny" => ["plan"]})

      params = %{"profile" => "dev", "team" => "engineering"}
      assert {:ok, _endpoint} = Harness.call("session.create", params, as(context.ada))
      assert_receive {:pushed, "session.activate", pushed}, 5_000

      # The set is the primaries the rule leaves; the rule itself rides beside it, so the
      # pod keeps `helper` and drops `plan` among its subagents and built-ins alike.
      assert pushed["entitlements"]["agents"] == ["pr-reviewer"]
      assert pushed["agent_rule"] == %{"allow" => ["pr-reviewer", "helper"], "deny" => ["plan"]}
    end

    test "gets no rule where the profile says nothing", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      profile(nil)

      params = %{"profile" => "dev", "team" => "engineering"}
      assert {:ok, _endpoint} = Harness.call("session.create", params, as(context.ada))
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      refute Map.has_key?(pushed, "agent_rule")
    end
  end

  describe "the admin surface" do
    test "a put refuses a name in both lists, and one that is not a name, with a sentence",
         context do
      FakeWorkerProfiles.start(%{"dev" => %{}})

      assert {:error, error} =
               Admin.profile_put(
                 context.root,
                 written(%{"allow" => ["build", "plan"], "deny" => ["plan"]})
               )

      assert error.message == "invalid_params"
      assert error.data.reason =~ "plan is in both agents.allow and agents.deny"

      assert {:error, error} = Admin.profile_put(context.root, written(%{"deny" => [7]}))
      assert error.data.reason =~ "agents.deny names agents, and 7 is not a name"

      # An unknown name is kept: a bundle may gain it.
      assert {:ok, _} = Admin.profile_put(context.root, written(%{"deny" => ["not-yet"]}))
      assert Fleet.get_profile("dev").spec["agents"] == %{"deny" => ["not-yet"]}
    end

    test "profile.agents marks each agent offered or not, and names what matches nothing",
         context do
      profile(%{"allow" => ["pr-reviewer", "build", "nobody"], "deny" => ["helper"]})

      assert {:ok, view} = Admin.profile_agents(context.root, "dev")
      assert view.rule == %{"allow" => ["pr-reviewer", "build", "nobody"], "deny" => ["helper"]}
      assert view.unmatched == ["nobody"]

      by_name = Map.new(view.agents, &{&1.name, &1})
      assert by_name["pr-reviewer"].offered
      assert by_name["build"].offered
      refute by_name["plan"].offered
      refute by_name["helper"].offered
      # A subagent the rule excludes is in no agent's delegate list.
      assert by_name["pr-reviewer"].delegate == []
    end

    test "the export carries the field, as any spec field", context do
      profile(%{"deny" => ["build"]})
      assert {:ok, export} = Admin.profiles_export(context.root)
      %{yaml: yaml} = Enum.find(export.profiles, &(&1.name == "dev"))
      manifest = YamlElixir.read_from_string!(yaml)
      assert manifest["spec"]["agents"] == %{"deny" => ["build"]}
    end
  end

  describe "a profile that extends another" do
    test "has its parent's rule as well as its own, and can only narrow", context do
      FakeWorkerProfiles.start(%{"standard" => %{}, "data-team" => %{}})

      assert {:ok, _} =
               Admin.profile_put(context.root, %{
                 "name" => "standard",
                 "image" => @image,
                 "spec" => %{
                   "agents" => %{
                     "allow" => ["pr-reviewer", "build", "helper"],
                     "deny" => ["plan"]
                   }
                 }
               })

      assert {:ok, _} =
               Admin.profile_put(context.root, %{
                 "name" => "data-team",
                 "extends" => "standard",
                 "spec" => %{
                   "agents" => %{"allow" => ["build", "helper", "other"], "deny" => ["helper"]}
                 }
               })

      assert Fleet.get_profile("data-team").spec["agents"] ==
               %{"allow" => ["build"], "deny" => ["plan", "helper"]}

      # The resource gets the composed rule, and a child that says nothing has its parent's.
      assert_receive {FakeWorkerProfiles, :applied, "data-team", resource, _query}
      assert resource["spec"]["agents"] == %{"allow" => ["build"], "deny" => ["plan", "helper"]}

      assert {:ok, _} =
               Admin.profile_put(context.root, %{
                 "name" => "data-team",
                 "extends" => "standard",
                 "spec" => %{}
               })

      assert Fleet.get_profile("data-team").spec["agents"] ==
               %{"allow" => ["pr-reviewer", "build", "helper"], "deny" => ["plan"]}
    end

    test "a manifest's field reaches the row and the child's status in gitops mode" do
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      FakeCluster.start()

      {:ok, _} =
        FakeCluster.apply_as(
          "kustomize-controller",
          manifest("standard", %{
            "image" => %{"repository" => "ghcr.io/troupe/worker", "tag" => "1"},
            "sessionsPerPod" => 4,
            "agents" => %{"deny" => ["build"]}
          })
        )

      {:ok, _} =
        FakeCluster.apply_as(
          "kustomize-controller",
          manifest("a-data-team", %{
            "extends" => "standard",
            "agents" => %{"allow" => ["pr-reviewer", "build"]}
          })
        )

      {:ok, outcomes} = Gitops.sync(GitopsProfiles)
      assert Enum.all?(outcomes, &is_nil(&1.problem)), inspect(outcomes)

      assert Fleet.get_profile("standard").spec["agents"] == %{"deny" => ["build"]}

      assert Fleet.get_profile("a-data-team").spec["agents"] == %{
               "allow" => ["pr-reviewer"],
               "deny" => ["build"]
             }

      status = get_in(FakeCluster.get("WorkerProfile", "a-data-team"), ["status", "effective"])
      assert status["spec"]["agents"] == %{"allow" => ["pr-reviewer"], "deny" => ["build"]}

      # And one the pods could not read is refused as the put refuses it.
      {:ok, _} =
        FakeCluster.apply_as(
          "kustomize-controller",
          manifest("broken", %{
            "image" => %{"repository" => "ghcr.io/troupe/worker", "tag" => "1"},
            "sessionsPerPod" => 4,
            "agents" => %{"allow" => ["build"], "deny" => ["build"]}
          })
        )

      {:ok, outcomes} = Gitops.sync(GitopsProfiles)
      %{state: :refused, reasons: reasons} = Enum.find(outcomes, &(&1.name == "broken"))
      assert Enum.any?(reasons, &(&1 =~ "build is in both agents.allow and agents.deny"))
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp as(user), do: %{user: user, platform_admin?: false}

  defp profile(rule) do
    spec = if rule, do: %{"agents" => rule}, else: %{}

    {:ok, _profile} =
      Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1, spec: spec})

    :ok
  end

  defp written(rule) do
    %{"name" => "dev", "image" => @image, "spec" => %{"agents" => rule}}
  end

  defp offered(user) do
    assert {:ok, %{"profiles" => [profile]}} = Harness.call("profiles.list", %{}, as(user))
    profile["agents"]
  end

  defp entitle(team, rows) do
    {:ok, _} = Identity.grant(team, "dev", %{"entitlements" => rows})
    :ok
  end

  defp manifest(name, spec) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{"name" => name, "namespace" => FakeCluster.namespace()},
      "spec" => spec
    }
  end

  defp bundle_content do
    %{
      "schema" => 1,
      "agents" => [
        %{
          "name" => "pr-reviewer",
          "definition" => "---\nmode: primary\ntools: [read_file, delegate]\n---\nReview."
        },
        %{"name" => "helper", "definition" => "---\nmode: subagent\n---\nYou help."}
      ],
      "skills" => [],
      "mcp_servers" => []
    }
  end
end
