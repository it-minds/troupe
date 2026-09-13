defmodule Troupe.Plane.ProvisionManifestTest do
  @moduledoc """
  What the plane writes, the operator reads back.

  The plane composes a `WorkerProfile` and the operator parses one, and between them sits
  a CRD that prunes what it does not declare. Nothing checked that the three agreed, and
  they did not: the plane wrote a team's volume as `volume`, the schema declares
  `claimName`, and the parser reads `claimName`. The write was refused by the API server
  with `field not declared in schema` — and if the schema had been permissive, the parser
  would have read `nil` and the volume would simply never have been bound, which is the
  worse of the two failures because nothing would have said so.

  It hid for as long as it did because `teams` is a *projection of grants*: a profile with
  no team granted projects an empty list, and an empty list round-trips perfectly. The
  first grant anybody made broke every subsequent write of that profile.

  So this round-trips the manifest through the parser that the operator uses. It is the
  same module — `Troupe.WorkerProfile` lives in `troupe_protocol`, which both apps depend
  on — so this is the real reader and not a copy of it.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Fleet, Identity, Provision}
  alias Troupe.WorkerProfile

  setup do
    {:ok, _profile} =
      Fleet.put_profile(%{
        name: "dev",
        image: "ghcr.io/troupe/worker:1",
        replicas: 2,
        sessions_per_pod: 4,
        spec: %{
          "llm" => %{"endpoint" => "https://gateway.example.test", "model" => "code-default"},
          "storage" => %{"size" => "10Gi"}
        }
      })

    :ok
  end

  defp manifest, do: Provision.manifest(Fleet.get_profile("dev"))

  describe "a profile with no grants" do
    test "projects no teams, which is why this went unnoticed" do
      parsed = WorkerProfile.from_resource(manifest())
      assert parsed.teams == []
    end

    test "still round-trips everything else" do
      parsed = WorkerProfile.from_resource(manifest())

      assert parsed.name == "dev"
      assert parsed.image == "ghcr.io/troupe/worker:1"
      assert parsed.replicas == 2
      assert parsed.sessions_per_pod == 4
      assert parsed.llm_model == "code-default"
      assert parsed.storage_size == "10Gi"
    end
  end

  describe "a profile a team with a volume has been granted" do
    setup do
      team =
        team_with_grant("engineering", "dev",
          name: "engineering",
          volume_mode: "rw",
          volume_storage_class: "shared-files",
          volume_size: "25Gi"
        )

      %{team: team}
    end

    test "names the team's volume where the parser looks for it" do
      [team] = WorkerProfile.from_resource(manifest()).teams

      assert team.name == "engineering"
      # The assertion that would have failed: `volume` parsed as nothing at all.
      assert team.claim_name == "troupe-team-engineering"
      assert team.mode == :rw
    end

    test "says which class and how big, rather than leaving the cluster to guess" do
      [team] = WorkerProfile.from_resource(manifest()).teams

      # Projected as nothing at all until now, so the operator fell back to whatever the
      # cluster's default class was. Where that default is block storage, a `ro` team
      # volume becomes a `ReadOnlyMany` claim the CSI driver refuses outright — the claim
      # never binds, the pod never schedules, and the profile is down.
      assert team.storage_class == "shared-files"
      assert team.size == "25Gi"
    end

    test "writes no key the resource does not declare" do
      # The API server prunes or refuses what is not in the schema, and `field not declared
      # in schema` arrives as a provisioning failure long after the write looked fine.
      declared = ~w(name claimName storageClassName size mode)

      [team] = get_in(manifest(), ["spec", "teams"])

      assert Map.keys(team) -- declared == [],
             "the plane writes #{inspect(Map.keys(team) -- declared)}, which the WorkerProfile CRD does not declare"
    end
  end

  describe "the grant is the only source" do
    test "a revoked grant takes the team out of the resource", %{} do
      team =
        team_with_grant("engineering", "dev",
          name: "engineering",
          volume_storage_class: "shared-files"
        )

      assert [_one] = WorkerProfile.from_resource(manifest()).teams

      :ok = Identity.revoke(team, "dev")
      assert WorkerProfile.from_resource(manifest()).teams == []
    end
  end

  describe "a team that was never given a volume" do
    test "gets no claim, because a grant is not a volume" do
      team_with_grant("engineering", "dev", name: "engineering", volume_mode: "ro")

      # `volume_mode` has no third value, so every grant used to project a claim whether
      # or not anybody had asked for storage. On an installation with no many-reader
      # storage class that made granting a team access to a profile the thing that took
      # the profile down: an unbindable claim, a pod stuck `Pending`, and `session.create`
      # answering "every pod is full" about a pod that was never there.
      assert WorkerProfile.from_resource(manifest()).teams == []
    end

    test "and a team given one later gets it", %{} do
      team = team_with_grant("engineering", "dev", name: "engineering", volume_mode: "ro")
      assert WorkerProfile.from_resource(manifest()).teams == []

      {:ok, _team} = Identity.update_team(team, %{volume_storage_class: "shared-files"})

      assert [%{name: "engineering", storage_class: "shared-files"}] =
               WorkerProfile.from_resource(manifest()).teams
    end
  end
end
