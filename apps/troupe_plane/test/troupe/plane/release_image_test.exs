defmodule Troupe.Plane.ReleaseImageTest do
  @moduledoc """
  A profile whose image is `release`, and a plane that makes it follow the platform.

  Three claims. The word is resolved where the manifest is rendered, so the row keeps
  what an administrator meant and the policy checks the image a pod would run. A plane
  that cannot say what the word means refuses it, rather than writing a resource with no
  image. And a plane that starts on a new release writes those profiles again — through
  the same provisioning an edit goes through, audited as the plane and not as a person —
  without waiting for a cluster that is not answering yet.

  GitOps mode carries most of it, because a commit is a write the test can read back
  without a cluster; direct mode is where "the cluster did not answer" lives.
  """

  use Troupe.Plane.DataCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Plane.{Admin, Audit, Fleet, Identity, Provision}
  alias Troupe.Plane.Fleet.ReleaseImage
  alias Troupe.WorkerProfile

  @moduletag timeout: 60_000

  @old "ghcr.io/troupe/worker:0.2.1"
  @new "ghcr.io/troupe/worker:0.2.17"

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    root = person("root@example.test", ["platform"])

    on_exit(fn ->
      for key <- ~w(platform_admin_group worker_image provisioning_mode gitops policy)a do
        Application.delete_env(:troupe_plane, key)
      end
    end)

    %{actor: Admin.actor_for(root)}
  end

  describe "the word, resolved" do
    test "is written as the release's image, and the row keeps the word" do
      Application.put_env(:troupe_plane, :worker_image, @new)
      {:ok, profile} = Fleet.put_profile(%{name: "dev", image: "release"})

      assert Provision.manifest(profile)["spec"]["image"] ==
               %{"repository" => "ghcr.io/troupe/worker", "tag" => "0.2.17"}

      assert Fleet.get_profile("dev").image == "release"
    end

    test "is checked against the policy as the image it resolves to", context do
      Application.put_env(:troupe_plane, :policy, policy())
      Application.put_env(:troupe_plane, :worker_image, "docker.io/someone/worker:1")

      # The same refusal a typed image gets: the policy has no idea the word was ever
      # there, which is the point.
      assert {:error, error} = Admin.profile_put(context.actor, %{name: "dev", image: "release"})
      assert error.message == "invalid_params"
      assert Enum.any?(error.data.policy_violations, &(&1 =~ "docker.io/someone/worker:1"))
      assert Fleet.get_profile("dev") == nil

      Application.put_env(:troupe_plane, :worker_image, @new)
      assert {:ok, _} = Admin.profile_put(context.actor, %{name: "dev", image: "release"})
    end

    test "is refused where the plane names no worker image", context do
      assert {:error, error} = Admin.profile_put(context.actor, %{name: "dev", image: "release"})

      assert error.message == "invalid_params"
      assert error.data.image == "release"
      assert error.data.reason =~ "deployed without a worker image"
      assert Fleet.get_profile("dev") == nil
    end

    test "is never written without an image, whoever asks" do
      # A row that follows the release on a plane that cannot say what that is — deployed
      # before the chart set one, or with it removed. The scaler, a grant and a bundle all
      # end in `apply/2`, and none of them may write a resource with no image.
      {:ok, profile} = Fleet.put_profile(%{name: "dev", image: "release"})

      assert {:error, :no_worker_image} =
               Provision.apply(profile, %{subject: "system:scaler", role: :platform_admin})
    end
  end

  describe "following the release, GitOps" do
    setup :gitops

    test "an upgrade writes the new image, as the plane rather than a person", context do
      Application.put_env(:troupe_plane, :worker_image, @old)
      {:ok, _} = Admin.profile_put(context.actor, %{name: "dev", image: "release"})
      assert committed(context, "dev") == @old

      # The plane restarts on the next release.
      Application.put_env(:troupe_plane, :worker_image, @new)

      assert [%{profile: "dev", state: :written, from: @old, to: @new}] = ReleaseImage.follow()
      assert committed(context, "dev") == @new
      assert Fleet.get_profile("dev").image == "release"

      {log, 0} = System.cmd("git", ["-C", context.repo, "log", "--oneline"])
      assert log =~ "dev updated by system:release"

      assert [event] = Audit.list(actor: "system:release")
      assert event.action == "profile.put"
      assert event.subject_id == "dev"
      assert event.detail == %{"image" => %{"from" => @old, "to" => @new}}
    end

    test "a profile that already carries the release's image is left alone", context do
      Application.put_env(:troupe_plane, :worker_image, @new)
      {:ok, _} = Admin.profile_put(context.actor, %{name: "dev", image: "release"})
      commits = commits(context)

      # A second replica starting a minute after the first, which is the ordinary case.
      assert [%{profile: "dev", state: :current}] = ReleaseImage.follow()
      assert commits(context) == commits
      assert Audit.list(actor: "system:release") == []
    end

    test "a profile with an image of its own does not move", context do
      Application.put_env(:troupe_plane, :worker_image, @new)
      {:ok, _} = Admin.profile_put(context.actor, %{name: "pinned", image: @old})
      {:ok, _} = Fleet.put_profile(%{name: "dev", image: "release"})

      assert [%{profile: "dev", state: :written}] = ReleaseImage.follow()
      assert committed(context, "pinned") == @old
    end

    test "a release image outside the policy is not written", context do
      Application.put_env(:troupe_plane, :policy, policy())
      Application.put_env(:troupe_plane, :worker_image, "docker.io/someone/worker:1")
      {:ok, _} = Fleet.put_profile(%{name: "dev", image: "release"})

      assert [%{profile: "dev", state: :refused, violations: [_ | _]}] = ReleaseImage.follow()
      refute File.exists?(Path.join([context.repo, "profiles", "dev.yaml"]))
      assert Audit.list(actor: "system:release") == []
    end

    test "with no worker image nothing is written, and the log says so", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", image: "release"})

      log =
        capture_log(fn -> assert [%{profile: "dev", state: :unnamed}] = ReleaseImage.follow() end)

      assert log =~ "deployed without a worker image"
      refute File.exists?(Path.join([context.repo, "profiles", "dev.yaml"]))
    end
  end

  describe "following the release, direct" do
    setup do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)
      Application.put_env(:troupe_plane, :worker_image, @new)
      {:ok, _} = Fleet.put_profile(%{name: "dev", image: "release"})
      :ok
    end

    test "a cluster that does not answer is a failure to try again, not a crash" do
      # No `:k8s_conn`, which to this code is a cluster that is not there.
      assert [%{profile: "dev", state: :failed, reason: :no_cluster}] = ReleaseImage.follow()
      assert Audit.list(actor: "system:release") == []
    end

    test "a resource already on the release's image is not written again" do
      assert [%{profile: "dev", state: :current}] =
               ReleaseImage.follow(current: fn _ -> {:ok, @new} end)
    end

    test "a resource on another image is written, and a failed write is reported" do
      # Read, found behind, and then the write is what fails: the same cluster that
      # answered a GET is not there for the apply.
      assert [%{profile: "dev", state: :failed, reason: :no_cluster}] =
               ReleaseImage.follow(current: fn _ -> {:ok, @old} end)

      assert Audit.list(actor: "system:release") == []
    end
  end

  describe "the process" do
    setup do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)
      Application.put_env(:troupe_plane, :worker_image, @new)
      {:ok, _} = Fleet.put_profile(%{name: "dev", image: "release"})
      :ok
    end

    test "starts without waiting for the cluster, and tries until it answers" do
      test = self()

      # A pass that raises, then a cluster that does not answer, then one that does and
      # says the resource is already on the release. Three attempts and then quiet.
      {:ok, answers} = Agent.start_link(fn -> [:raise, {:error, :unreachable}, {:ok, @new}] end)

      current = fn profile ->
        send(test, {:asked, profile.name})

        case Agent.get_and_update(answers, fn [next | rest] -> {next, rest} end) do
          :raise -> raise "the database went away"
          answer -> answer
        end
      end

      start_supervised!({ReleaseImage, current: current, retry_ms: 10})

      assert_receive {:asked, "dev"}
      assert_receive {:asked, "dev"}
      assert_receive {:asked, "dev"}
      refute_receive {:asked, _}, 100
    end
  end

  defp gitops(_context) do
    repo = Path.join(System.tmp_dir!(), "troupe-release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    {_output, 0} = System.cmd("git", ["-C", repo, "init", "--quiet", "--initial-branch=main"])
    on_exit(fn -> File.rm_rf!(repo) end)

    Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
    Application.put_env(:troupe_plane, :gitops, path: repo)

    %{repo: repo}
  end

  # What the committed manifest carries, read the way the operator will read it.
  defp committed(context, name) do
    [context.repo, "profiles", "#{name}.yaml"]
    |> Path.join()
    |> YamlElixir.read_from_file!()
    |> WorkerProfile.from_resource()
    |> Map.fetch!(:image)
  end

  defp commits(context) do
    {count, 0} = System.cmd("git", ["-C", context.repo, "rev-list", "--count", "HEAD"])
    String.trim(count)
  end

  defp policy do
    %{
      "spec" => %{
        "allowedImageRepositories" => ["ghcr.io/troupe"],
        "maxReplicas" => 4,
        "maxSessionsPerPod" => 8,
        "namespacePrefix" => "troupe-w-"
      }
    }
  end
end
