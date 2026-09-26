defmodule Troupe.Plane.ProvisionerTest do
  @moduledoc """
  What makes a worker exist, behind an interface.

  The claim is a negative one and it is the whole package: **nothing above the seam learns
  there is more than one substrate.** Placement, the control channel, the seal format and
  the session log are the same whichever provisioner made the worker — so what is asserted
  here is that the differences are confined to three callbacks and one honest list.

  The other half is that the difference which *does* matter is impossible to miss. A host
  is not in a cluster, so four guarantees are gone, and they are named individually rather
  than summed into a flag: "unenforced" is not a useful thing to tell somebody deciding
  whether their team's work may run there.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Enrolment, FakeWorkerProfiles, Fleet, Identity}
  alias Troupe.Plane.Fleet.{Host, Hosts, Provisioner}

  @moduletag timeout: 60_000

  defp profile(name, attrs \\ %{}) do
    {:ok, profile} = Fleet.put_profile(Map.merge(%{name: name}, attrs))
    profile
  end

  describe "which provisioner a profile uses" do
    test "is kubernetes unless it says otherwise" do
      # Every profile that existed before this, and the right answer for one created by
      # something that does not know the question.
      assert profile("dev").provisioner == "kubernetes"
      assert Provisioner.for(profile("dev")) == Provisioner.Kubernetes
      assert Provisioner.for(nil) == Provisioner.Kubernetes
    end

    test "is chosen by name, and an unknown name is refused" do
      assert profile("laptops", %{provisioner: "ssh"}).provisioner == "ssh"
      assert Provisioner.for(profile("laptops", %{provisioner: "ssh"})) == Provisioner.SSH

      assert {:error, changeset} = Fleet.put_profile(%{name: "nope", provisioner: "podman"})
      assert Keyword.has_key?(changeset.errors, :provisioner)

      # And the database says the same thing, because the row is what a placement reads and
      # application code is not the only thing that writes it.
      assert Provisioner.names() == ~w(kubernetes ssh)
    end
  end

  describe "what a substrate guarantees" do
    test "is everything on Kubernetes where the operator says it wrote the FQDN rules" do
      dev = profile("dev")
      FakeWorkerProfiles.start(%{"dev" => FakeWorkerProfiles.egress_by_hostname(true)})

      assert :fqdn_egress in Provisioner.Kubernetes.guarantees(dev)
      assert Provisioner.missing(dev) == []
      refute Provisioner.unenforced?(dev)
    end

    test "is not egress by hostname on Kubernetes without Cilium, and says what is instead" do
      dev = profile("dev")
      FakeWorkerProfiles.start(%{"dev" => FakeWorkerProfiles.egress_by_hostname(false)})

      # Without Cilium the allowlist is a check at admission and at every reconcile, and a
      # worker reaches any public host on 443 and 80, so egress by hostname is not claimed.
      given = Provisioner.Kubernetes.guarantees(dev)
      refute :fqdn_egress in given
      assert :egress_checked_at_admission in given

      assert Provisioner.missing(dev) == [:fqdn_egress]

      assert Provisioner.account(dev).instead == %{
               fqdn_egress: :egress_checked_at_admission
             }

      # Less than egress by hostname, and not nothing: a profile in the cluster, whose
      # allowlist admission still enforces, is not one a team needs allowing onto.
      refute Provisioner.unenforced?(dev)
    end

    test "is the weaker one wherever the operator has not said, rather than the stronger" do
      dev = profile("dev")

      # No cluster to ask, which is a plane under test or one drafting profiles.
      assert Provisioner.missing(dev) == [:fqdn_egress]

      # And a cluster that has not reconciled this profile yet.
      FakeWorkerProfiles.start(%{})
      assert Provisioner.missing(dev) == [:fqdn_egress]
    end

    test "is nothing on a host, named one at a time" do
      laptops = profile("laptops", %{provisioner: "ssh"})

      # Four names, not a flag. Done item 3 is that the console says *which* guarantee is
      # missing, and it can only do that if this list exists.
      assert Enum.sort(Provisioner.missing(laptops)) ==
               Enum.sort(~w(admission_policy network_policy fqdn_egress disruption_budget)a)

      assert Provisioner.unenforced?(laptops)
    end

    test "is asked of the provisioner, so no row can claim a guarantee the cluster never made" do
      # There is deliberately no column for this. A profile that recorded its own
      # enforcement would be a claim nobody checked, in the one place it matters most.
      refute Map.has_key?(profile("laptops", %{provisioner: "ssh"}), :unenforced)
      refute Map.has_key?(profile("laptops", %{provisioner: "ssh"}), :guarantees)
    end
  end

  describe "granting a team a profile nothing enforces" do
    setup do
      {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
      {:ok, _} = Identity.enable_team(group, %{name: "platform"})

      {:ok, user} =
        Identity.upsert_user(%{subject: "root@example.test", display_name: "root"})

      {:ok, _} = Identity.set_memberships(user, ["platform"])
      Application.put_env(:troupe_plane, :platform_admin_group, "platform")
      on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

      {:ok, delivery_group} =
        Identity.upsert_group(%{external_id: "delivery", display_name: "delivery"})

      {:ok, delivery} = Identity.enable_team(delivery_group, %{name: "delivery"})
      _laptops = profile("laptops", %{provisioner: "ssh"})
      _dev = profile("dev")

      %{actor: Admin.actor_for_subject("root@example.test"), team: delivery}
    end

    test "is refused, and the refusal names every guarantee that is missing", context do
      assert {:error, error} = Admin.team_grant(context.actor, "delivery", "laptops")

      assert error.message == "forbidden"
      assert error.data.profile == "laptops"
      assert error.data.provisioner == "ssh"

      # Four names rather than one word. "Unenforced" is not a useful thing to tell
      # somebody deciding whether their team's work may run on somebody's build box.
      assert Enum.sort(error.data.missing) ==
               ~w(admission_policy disruption_budget fqdn_egress network_policy)

      assert error.data.reason =~ "a platform admin must allow unenforced workers"

      # And nothing was granted, which is the half a refusal that only logged would miss.
      refute "laptops" in Enum.map(Identity.grants_for_team(context.team), & &1.profile)
    end

    test "a profile the cluster enforces is granted without any of that", context do
      # Including without Cilium, which is this test: no operator has said `dev` has egress
      # by hostname, so it has the allowlist checked at admission in its place, and that is
      # missing egress by hostname but not unenforced.
      assert Provisioner.missing(Fleet.get_profile("dev")) == [:fqdn_egress]
      assert {:ok, _team} = Admin.team_grant(context.actor, "delivery", "dev")
      assert "dev" in Enum.map(Identity.grants_for_team(context.team), & &1.profile)
    end

    test "and is granted once a platform admin has allowed this team", context do
      assert {:ok, _} =
               Admin.team_update(context.actor, "delivery", %{allow_unenforced_workers: true})

      assert {:ok, _team} = Admin.team_grant(context.actor, "delivery", "laptops")
      assert "laptops" in Enum.map(Identity.grants_for_team(context.team), & &1.profile)
    end

    test "which a team admin cannot do for themselves", context do
      {:ok, lead} = Identity.upsert_user(%{subject: "lead@example.test", display_name: "lead"})
      {:ok, _} = Identity.set_memberships(lead, ["delivery"])
      {:ok, _} = Identity.add_team_admin(context.team, "lead@example.test", "root@example.test")

      lead_actor = Admin.actor_for_subject("lead@example.test")
      assert lead_actor.role == :team_admin

      assert {:error, error} =
               Admin.team_update(lead_actor, "delivery", %{allow_unenforced_workers: true})

      assert error.message == "forbidden"
      assert error.data.field == "allow_unenforced_workers"

      # Refused rather than dropped: a form that accepted the value and ignored it would
      # leave somebody believing their team may run somewhere it may not.
      refute Identity.get_team("delivery").allow_unenforced_workers
    end

    test "and cannot be taken back while the grant it allowed still stands", context do
      {:ok, _} = Admin.team_update(context.actor, "delivery", %{allow_unenforced_workers: true})
      {:ok, _} = Admin.team_grant(context.actor, "delivery", "laptops")

      assert {:error, error} =
               Admin.team_update(context.actor, "delivery", %{allow_unenforced_workers: false})

      assert error.data.profiles == ["laptops"]
      assert error.data.reason =~ "revoke them first"

      # Revoke it and the permission goes back, which is the order that leaves no moment
      # where the grant stands and the permission does not.
      assert {:ok, _} = Admin.team_revoke(context.actor, "delivery", "laptops")

      assert {:ok, _} =
               Admin.team_update(context.actor, "delivery", %{allow_unenforced_workers: false})

      refute Identity.get_team("delivery").allow_unenforced_workers
    end
  end

  describe "registering a machine, from a surface" do
    setup do
      {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
      {:ok, _} = Identity.enable_team(group, %{name: "platform"})
      {:ok, user} = Identity.upsert_user(%{subject: "root@example.test", display_name: "root"})
      {:ok, _} = Identity.set_memberships(user, ["platform"])
      Application.put_env(:troupe_plane, :platform_admin_group, "platform")
      on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

      _laptops = profile("laptops", %{provisioner: "ssh"})
      %{actor: Admin.actor_for_subject("root@example.test")}
    end

    test "mints a secret that crosses once and is kept only as a hash", context do
      assert {:ok, host} =
               Admin.host_register(context.actor, "laptops", %{
                 "name" => "build-box",
                 "address" => "10.0.0.9"
               })

      assert host.name == "build-box"
      assert String.starts_with?(host.secret, "twh_")

      # Registered and never seen, which is its own state: a worker nobody has installed
      # there yet is a different job from a machine that is switched off.
      assert host.state == :never_seen

      # And nothing else can produce it. The listing has no secret at all, and the row
      # keeps a hash — a secret the plane could show twice is a secret the plane is keeping.
      assert {:ok, [listed]} = Admin.hosts_list(context.actor, "laptops")
      refute Map.has_key?(listed, :secret)
      refute Hosts.by_name("laptops", "build-box").secret_hash == host.secret
    end

    test "and the secret it minted is the one enrolment accepts", context do
      {:ok, host} = Admin.host_register(context.actor, "laptops", %{"name" => "build-box"})

      assert {:ok, accepted} = Hosts.authenticate(host.secret, "build-box")
      assert accepted.name == "build-box"

      # Rotating keeps the machine and replaces the secret. The id has to survive: a new
      # row would leave the new secret naming a host nothing knows about, which looks
      # exactly like a rotation that did not take.
      {:ok, rotated} = Admin.host_rotate(context.actor, "laptops", "build-box")

      assert rotated.secret != host.secret
      assert {:error, :unauthenticated} = Hosts.authenticate(host.secret, "build-box")
      assert {:ok, _} = Hosts.authenticate(rotated.secret, "build-box")
    end

    test "and a machine stopped from enrolling is refused with everything else's refusal",
         context do
      {:ok, host} = Admin.host_register(context.actor, "laptops", %{"name" => "build-box"})

      assert {:ok, disabled} =
               Admin.host_set_enabled(context.actor, "laptops", "build-box", false)

      assert disabled.state == :disabled
      assert {:error, :unauthenticated} = Hosts.authenticate(host.secret, "build-box")

      # One refusal for every way of failing, so a caller learns nothing from which.
      assert {:ok, _} = Admin.host_set_enabled(context.actor, "laptops", "build-box", true)
      assert {:ok, _} = Hosts.authenticate(host.secret, "build-box")
    end

    test "and a team admin registers nothing", context do
      {:ok, lead} = Identity.upsert_user(%{subject: "lead@example.test", display_name: "lead"})
      {:ok, _} = Identity.set_memberships(lead, ["platform"])

      lead_actor = %{subject: "lead@example.test", role: :team_admin, teams: ["platform"]}

      assert {:error, error} =
               Admin.host_register(lead_actor, "laptops", %{"name" => "their-laptop"})

      assert error.message == "forbidden"
      assert Hosts.for_profile("laptops") == []
    end
  end

  describe "ensure, on a substrate that cannot make machines" do
    test "reports the shortfall rather than failing at it" do
      laptops = profile("laptops", %{provisioner: "ssh", replicas: 3})

      # Nothing the plane does next will conjure two more laptops. A shortfall is a fact to
      # show somebody, not an error to retry every fifteen seconds for ever.
      {:ok, _host, _secret} =
        Hosts.register("laptops", %{name: "ada-laptop", registered_by: "root"})

      assert {:ok, report} = Provisioner.SSH.ensure(laptops, [])
      assert report.wanted == 3
      assert report.available == 1
      assert report.short == 2
      assert report.state == :applied
    end

    test "does not count a host somebody took out of service" do
      laptops = profile("laptops", %{provisioner: "ssh", replicas: 2})
      {:ok, one, _} = Hosts.register("laptops", %{name: "one", registered_by: "root"})
      {:ok, _two, _} = Hosts.register("laptops", %{name: "two", registered_by: "root"})

      assert {:ok, %{short: 0}} = Provisioner.SSH.ensure(laptops, [])

      {:ok, _} = Hosts.set_enabled(one, false)
      assert {:ok, %{available: 1, short: 1}} = Provisioner.SSH.ensure(laptops, [])

      # Disabled is not deleted: the listing keeps it, so the audit trail still points at
      # something and somebody can put it back.
      assert laptops.name |> Hosts.for_profile() |> length() == 2
    end
  end

  describe "describe" do
    test "says what the substrate has, which is not the same as what has enrolled" do
      laptops = profile("laptops", %{provisioner: "ssh"})
      {:ok, _, _} = Hosts.register("laptops", %{name: "build-box", registered_by: "root"})

      assert {:ok, [listed]} = Provisioner.SSH.describe(laptops)
      assert listed.name == "build-box"
      assert listed.profile == "laptops"

      # And the fleet has nothing, because nothing has dialled in. That gap is the useful
      # part: it is the state somebody debugging an install is in.
      assert Fleet.list_workers("laptops") == []
    end
  end

  describe "a host proves which profile it is" do
    setup do
      profile("laptops", %{provisioner: "ssh"})
      profile("other", %{provisioner: "ssh"})

      {:ok, host, secret} =
        Hosts.register("laptops", %{name: "ada-laptop", registered_by: "root@example.test"})

      %{host: host, secret: secret}
    end

    test "with the secret it was issued, and the profile comes from the row", context do
      assert {:ok, identity} = Enrolment.verify(context.secret)

      # From the row it opened, not from anything the worker said — which is the property
      # the namespace gives a pod and the thing that has to survive the substrate changing.
      assert identity.profile == "laptops"
      assert identity.pod_name == "ada-laptop"
      assert identity.ordinal == context.host.ordinal

      # And its workers are not recorded as being in a Kubernetes namespace, because they
      # are not in one: a host sharing a namespace with a pod of the same profile would be
      # two machines claiming to be one row.
      assert identity.namespace == "ssh:laptops"
      refute identity.namespace == "troupe-w-laptops"
    end

    test "and enrolling records a worker placement can use like any other", context do
      {:ok, identity} = Enrolment.verify(context.secret)

      assert {:ok, worker} =
               Enrolment.enrol(identity, %{"capacity" => 4, "disk_total_bytes" => 1_000_000})

      assert worker.profile == "laptops"
      assert worker.pod_name == "ada-laptop"
      assert worker.ordinal == context.host.ordinal
      assert worker.healthy

      # Placement never learns there is more than one substrate.
      assert Fleet.placeable("laptops") |> Enum.map(& &1.id) == [worker.id]

      # And the listing can now say it has been seen, which it could not before.
      refute is_nil(Hosts.get(context.host.id).last_enrolled_at)
    end

    test "and another host's secret is refused with the same answer a wrong namespace gets",
         context do
      {:ok, _other, other_secret} =
        Hosts.register("other", %{name: "someone-else", registered_by: "root@example.test"})

      # Done item 2. Every one of these is `:unauthenticated` and nothing in the answer
      # says which check refused, because that difference is what an attacker would like.
      assert {:error, :unauthenticated} =
               Enrolment.verify(other_secret, name: context.host.name)

      assert {:error, :unauthenticated} = Enrolment.verify("twh_nope.nothing")

      assert {:error, :unauthenticated} =
               Enrolment.verify(context.secret, name: "a-name-that-is-not-its-own")

      # Including the id on its own, which is public: it is in every listing.
      forged = "twh_" <> String.replace_prefix(context.host.id, "wh_", "") <> ".guess"
      assert {:error, :unauthenticated} = Enrolment.verify(forged)
    end

    test "and a host somebody disabled cannot get back in", context do
      {:ok, _} = Hosts.set_enabled(context.host, false)
      assert {:error, :unauthenticated} = Enrolment.verify(context.secret)

      {:ok, _} = Hosts.set_enabled(context.host, true)
      assert {:ok, _identity} = Enrolment.verify(context.secret)
    end

    test "and rotating invalidates the old secret at the next attempt", context do
      {:ok, _host, fresh} = Hosts.rotate(context.host, "root@example.test")

      assert {:error, :unauthenticated} = Enrolment.verify(context.secret)
      assert {:ok, %{profile: "laptops"}} = Enrolment.verify(fresh)

      assert Hosts.get(context.host.id).secret_rotated_by == "root@example.test"
    end

    test "and the plane keeps a digest, never the secret", context do
      row = Hosts.get(context.host.id)

      refute row.secret_hash == context.secret
      refute inspect(Map.from_struct(row)) =~ context.secret

      # Handed back once. There is no call that reads it again, which is what makes losing
      # one a rotation rather than a lookup.
      refute function_exported?(Hosts, :secret_for, 1)
      refute function_exported?(Hosts, :reveal, 1)
    end
  end

  describe "the inventory" do
    test "gives each host a number of its own, never reused" do
      profile("laptops", %{provisioner: "ssh"})

      {:ok, one, _} = Hosts.register("laptops", %{name: "one", registered_by: "root"})
      {:ok, two, _} = Hosts.register("laptops", %{name: "two", registered_by: "root"})

      # Drain takes the highest first, which needs a stable order — and a machine called
      # `build-box` has no trailing integer to read one out of.
      assert one.ordinal == 0
      assert two.ordinal == 1
      assert Host.enrollable?(one)
    end

    test "refuses two hosts of one profile sharing a name" do
      profile("laptops", %{provisioner: "ssh"})
      {:ok, _, _} = Hosts.register("laptops", %{name: "build-box", registered_by: "root"})

      assert {:error, changeset} =
               Hosts.register("laptops", %{name: "build-box", registered_by: "root"})

      assert Keyword.has_key?(changeset.errors, :profile) or
               Keyword.has_key?(changeset.errors, :name)
    end
  end
end
