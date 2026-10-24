defmodule Troupe.E2E.Upgrade.SeedTest do
  @moduledoc """
  What a running organisation has, written to the release before this one.

  The first half of the upgrade check (`scripts/kind-upgrade-check`): run against the
  previous release, installed from the registry, before the upgrade. A team with a profile
  granted, a session that ran a turn and went dormant, a webhook trigger with its key that
  has fired, the organisation's memory, a client-version policy the plane signs, and the
  audit rows all of that wrote. What it made goes to `Troupe.E2E.Upgrade.state_path/0` for
  `check_test.exs` to ask the new release about.

  The profile follows the release (`image: release`), as a deployment's profiles do, and
  its model is the scripted `fake` provider, so a turn needs no model and answers the same
  way on both releases.

  Not part of `mix troupe.e2e`'s default run: it is tagged `:e2e`, so plain `mix test`
  never runs it, and it lives outside `test/e2e`, so the fresh install's suite does not.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, Upgrade, World}
  alias Troupe.Protocol.PlaneSignature

  @moduletag :e2e
  @moduletag timeout: 1_500_000

  # A host the kind policy's egress list already names, so the profile passes it. The fake
  # provider dials nothing.
  @model_endpoint "https://llm-gw.example.test/v1"

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  test "an organisation, as the previous release keeps one" do
    build = Upgrade.build()

    if from = Upgrade.from() do
      assert build["version"] == from,
             "the plane says it is #{inspect(build)}, and the release to upgrade from is #{from}"
    end

    profile = World.profile()
    channel = "stable"

    # -- a team with a profile granted ------------------------------------------------

    Plane.call!("admin.profile.put", %{
      "profile" => %{
        "name" => profile,
        "image" => "release",
        "size_class" => "standard",
        "warm_workers" => 1,
        "spec" => %{
          "configBundleChannel" => channel,
          "llm" => %{"endpoint" => @model_endpoint, "provider" => "fake"}
        }
      }
    })

    team = Plane.team!("engineering", profile)["name"]

    bundle =
      Plane.publish!(channel, %{
        "schema" => 1,
        "agents" => [
          %{
            "name" => "prober",
            "definition" => "---\nmode: primary\n---\nYou are a helpful assistant on a cluster."
          }
        ]
      })

    Plane.reclaim(profile)
    settled!(profile)
    Upgrade.placeable!(profile)

    # -- a session that ran a turn and went dormant ------------------------------------

    said = "Upgrade check: a turn on #{build["version"]}."
    created = Plane.call!("session.create", %{"profile" => profile})
    session_id = created["session_id"]
    {client, _so_far} = Upgrade.attach!(created, session_id)
    turn = Upgrade.turn!(client, session_id, said)
    assert Enum.any?(turn, &(&1.type == "llm_response")), "the turn had no model answer"

    Plane.call!("session.archive", %{"session_id" => session_id})

    World.eventually(
      fn -> Plane.call!("session.get", %{"session_id" => session_id})["state"] == "dormant" end,
      timeout: 180_000,
      what: "#{session_id} to go dormant"
    )

    dormant = Plane.call!("session.get", %{"session_id" => session_id})
    assert is_binary(dormant["head_hash"]) and dormant["last_seq"] > 0, inspect(dormant)

    # -- the organisation's memory -----------------------------------------------------

    current = Plane.call!("admin.memory.get", %{"scope" => "organisation"})
    memory_text = "Upgrade check: the organisation's memory, saved on #{build["version"]}."

    saved =
      Plane.call!("admin.memory.put", %{
        "scope" => "organisation",
        "text" => memory_text,
        "version" => current["version"] || 0
      })

    memory_version = get_in(saved, ["document", "version"])
    assert is_integer(memory_version), inspect(saved)

    # -- a client-version policy, signed -----------------------------------------------

    recommended = Upgrade.from() || build["version"]

    Plane.call!("admin.clients.put", %{
      "component" => "tui",
      "policy" => %{"recommended" => recommended}
    })

    pinned = Upgrade.signing_key()
    {:ok, key} = PlaneSignature.read_key(pinned)
    versions = Plane.call!("me.client_versions")

    assert {:ok, _verified} = PlaneSignature.verify(versions["signed"], key, "client_versions"),
           "the previous release does not sign its client versions: #{inspect(versions)}"

    # -- a webhook trigger with its key, fired once -------------------------------------

    principal =
      Plane.call!("admin.principal.create", %{
        "team" => team,
        "principal" => %{
          "name" => Plane.unique("upgrade-hook"),
          "profiles" => [profile],
          "sponsor" => Plane.subject()
        }
      })

    trigger = Plane.unique("upgrade-hook")

    Plane.call!("admin.trigger.put", %{
      "trigger" => %{
        "team" => team,
        "name" => trigger,
        "principal" => principal["subject"],
        "profile" => profile,
        "source" => %{"kind" => "webhook", "provider" => "generic"},
        "prompt_template" => "Look at {{event.issue}}, from the upgrade check.",
        "enabled" => true
      }
    })

    minted = Plane.call!("admin.trigger.key.rotate", %{"team" => team, "name" => trigger})
    fired = Upgrade.fire!(minted, %{"issue" => "UPG-1"})

    assert fired.status == 202,
           "the trigger did not fire on the previous release: #{inspect(fired.body)}"

    # Erased once it is there, so the profile's pod holds no session through the upgrade
    # and moves to the new release by itself.
    Upgrade.erase(fired.body["session_id"])

    # -- the audit rows all of that wrote ----------------------------------------------

    rows = "admin.audit.list" |> Plane.call!(%{}) |> List.wrap() |> Enum.take(20)
    assert rows != [], "no audit rows after the seed"
    assert Plane.call!("admin.audit.verify")["result"] == "ok"

    Upgrade.write!(%{
      "from" => build,
      "profile" => profile,
      "team" => team,
      "bundle" => bundle,
      "worker_image" => World.worker_image(profile),
      "pod_images" => Upgrade.pod_images(profile),
      "session" => %{
        "id" => session_id,
        "said" => said,
        "head_hash" => dormant["head_hash"],
        "last_seq" => dormant["last_seq"],
        "epoch" => dormant["epoch"]
      },
      "memory" => %{"version" => memory_version, "text" => memory_text},
      "client_versions" => %{"component" => "tui", "recommended" => recommended},
      "signing_key" => pinned,
      "trigger" => %{
        "team" => team,
        "name" => trigger,
        "principal" => principal["subject"],
        "url" => minted["url"],
        "key" => minted["key"]
      },
      "audit" => Enum.map(rows, &Map.take(&1, ["action", "subject_id", "occurred_at"]))
    })
  end

  # Writing the profile through the plane gave its pods the fake model, a new revision, and
  # the pod there was replaced once it held no session; the seed starts once every pod
  # runs that revision. Asked of the pods themselves: the conditions say nothing until the
  # operator has seen the write.
  defp settled!(profile) do
    World.eventually(
      fn ->
        conditions = Upgrade.conditions(profile)
        providers = Upgrade.pod_env(profile, "TROUPE_PROVIDER")

        conditions["Ready"] == "True" and conditions["UpgradePending"] != "True" and
          providers != [] and Enum.all?(providers, &(&1 == "fake")) and
          ready_pods?(profile)
      end,
      timeout: 600_000,
      every: 5_000,
      what: "#{profile}'s pods to run the fake model and be Ready",
      explain: fn ->
        "conditions #{inspect(Upgrade.conditions(profile))}, providers " <>
          inspect(Upgrade.pod_env(profile, "TROUPE_PROVIDER"))
      end
    )
  end

  defp ready_pods?(profile) do
    path = ~s|jsonpath={.items[*].status.conditions[?(@.type=="Ready")].status}|

    case World.kubectl(
           [
             "get",
             "pods",
             "-n",
             World.worker_namespace(profile),
             "-l",
             "app.kubernetes.io/name=troupe-worker",
             "-o",
             path
           ],
           stderr: false
         ) do
      {output, 0} ->
        statuses = String.split(output, " ", trim: true)
        statuses != [] and Enum.all?(statuses, &(&1 == "True"))

      _other ->
        false
    end
  end
end
