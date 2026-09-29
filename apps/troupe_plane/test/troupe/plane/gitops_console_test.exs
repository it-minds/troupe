defmodule Troupe.Plane.GitopsConsoleTest do
  @moduledoc """
  The console in GitOps mode (Decision 736): the profiles are shown as the plane read
  them, locked, with where they come from, and nothing on the page writes.

  A disabled form with no reason given reads as a broken console, so what is checked
  first is the marker and its words; then that no control that writes is there, and that
  a write sent anyway is refused by name.
  """

  use Troupe.Plane.PanelCase, async: false

  alias Troupe.Plane.{FakeCluster, Fleet, Gitops, Identity}
  alias Troupe.Plane.Gitops.Profiles

  @moduletag timeout: 60_000

  @source "https://git.example.com/fleet.git, profiles/"

  setup do
    Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
    Application.put_env(:troupe_plane, :gitops_source, @source)

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :provisioning_mode)
      Application.delete_env(:troupe_plane, :gitops_source)
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    root = person("root@example.test", ["platform"])

    FakeCluster.start()

    {:ok, _} =
      FakeCluster.apply_as("kustomize-controller", manifest("dev", "ghcr.io/troupe/worker"))

    {:ok, _} = Gitops.sync(Profiles)

    %{root: root}
  end

  defp manifest(name, repository, spec \\ %{}) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{"name" => name, "namespace" => FakeCluster.namespace()},
      "spec" =>
        Map.merge(
          %{
            "image" => %{"repository" => repository, "tag" => "1.2.3"},
            "sessionsPerPod" => 4,
            "llm" => %{"model" => "gpt-4o"}
          },
          spec
        )
    }
  end

  describe "the profile editor" do
    test "shows what the plane read, locked, and says where it comes from", context do
      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/dev")

      assert html =~ "Locked to gitops"
      assert html =~ @source
      assert html =~ "at generation 1"
      assert html =~ ~s(value="gpt-4o")

      # Every field is disabled, and nothing that writes is on the page at all.
      assert has_element?(view, "form#profile-editor fieldset[disabled]")
      refute html =~ "apply now"
      refute html =~ "delete this profile"
      refute html =~ "add a server"
      refute html =~ "What will happen"

      # A change that arrives anyway is not a preview of an edit to a profile the
      # repository holds, and a submit that arrives anyway is refused by name.
      html = view |> element("form#profile-editor") |> render_change(%{"llm.model" => "gpt-4.1"})
      refute html =~ "What will happen"

      html = view |> element("form#profile-editor") |> render_submit(%{})
      assert html =~ "managed_by_gitops"
      assert Fleet.get_profile("dev").spec["llm"]["model"] == "gpt-4o"
    end

    test "a new profile is a new manifest, not a form", context do
      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/new")

      assert html =~ "Locked to gitops"
      assert html =~ "A new profile is a new manifest in that repository"
      refute has_element?(view, "form#profile-editor")
    end

    test "a row the cluster has no resource for may be deleted, and says only the row goes",
         context do
      {:ok, _} = Fleet.put_profile(%{name: "leftover", image: "ghcr.io/troupe/worker:1"})
      {:ok, _} = Gitops.sync(Profiles)

      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/leftover")

      assert html =~ "no resource"
      assert html =~ "delete this profile"
      assert html =~ "deletes the plane&#39;s row and nothing else"
    end
  end

  describe "the Workers page" do
    test "says the profiles are locked, and shows what a pass could not use", context do
      {:ok, _} =
        FakeCluster.apply_as(
          "kustomize-controller",
          manifest("bad", "ghcr.io/troupe/worker", %{"sessionsPerPod" => 3})
        )

      {:ok, _} = Gitops.sync(Profiles)

      {:ok, _view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin/workers")

      assert html =~ "Locked to gitops."
      assert html =~ "applied from #{@source}"
      assert html =~ "generation 1 is not used"
      assert html =~ "spec.sessionsPerPod is 3"
    end

    test "gives every profile and the policy as a repository would hold them", context do
      {:ok, view, html} = context.conn |> sign_in(context.root.subject) |> live("/admin/workers")

      assert html =~ "Manifests for a repository"
      html = view |> element("button", "show the manifests") |> render_click()

      assert html =~ "profiles/dev.yaml"
      assert html =~ "kind: WorkerProfile"
      assert html =~ "spec.replicas, spec.teams, spec.mcpServers"
    end
  end

  describe "direct mode" do
    test "is not locked, and the editor applies", context do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)

      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/profile/dev")

      refute html =~ "Locked to gitops"
      assert html =~ "apply now"
      refute has_element?(view, "fieldset[disabled]")
    end
  end
end
