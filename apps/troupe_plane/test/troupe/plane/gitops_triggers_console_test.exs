defmodule Troupe.Plane.GitopsTriggersConsoleTest do
  @moduledoc """
  The Triggers page in GitOps mode (Decision 737): the triggers are shown as the plane
  read them, locked, with where they come from; what changes one is gone, and what is done
  with one — running it now, minting its key, reading its revisions — is still there.
  """

  use Troupe.Plane.PanelCase, async: false

  alias Troupe.Plane.{FakeCluster, Gitops, Identity, Triggers}
  alias Troupe.Plane.Gitops.Profiles
  alias Troupe.Plane.Gitops.Triggers, as: GitopsTriggers

  @moduletag timeout: 60_000

  @source "https://git.example.com/fleet.git, triggers/"

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

    team = team_with_grant("engineering", "dev", name: "engineering")
    {:ok, _principal, _secret} = principal!(team, %{name: "nightly", profiles: ["dev"]})

    FakeCluster.start()

    {:ok, _} =
      FakeCluster.apply_as("kustomize-controller", %{
        "apiVersion" => "troupe.dev/v1alpha1",
        "kind" => "WorkerProfile",
        "metadata" => %{"name" => "dev", "namespace" => FakeCluster.namespace()},
        "spec" => %{"image" => %{"repository" => "ghcr.io/troupe/worker", "tag" => "1.2.3"}}
      })

    {:ok, _} =
      FakeCluster.apply_as("kustomize-controller", manifest("engineering.nightly-digest"))

    {:ok, _} = Gitops.sync(Profiles)
    {:ok, _} = Gitops.sync(GitopsTriggers)

    %{root: root, team: team}
  end

  defp manifest(name, spec \\ %{}) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "Trigger",
      "metadata" => %{"name" => name, "namespace" => FakeCluster.namespace()},
      "spec" =>
        Map.merge(
          %{
            "principal" => "svc:engineering/nightly",
            "profile" => "dev",
            "source" => %{"kind" => "schedule", "cron" => "0 3 * * 1-5"},
            "promptTemplate" => "Summarise what changed yesterday."
          },
          spec
        )
    }
  end

  describe "the Triggers page" do
    test "shows what the plane read, locked, and says where it comes from", context do
      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/triggers/engineering")

      assert html =~ "Locked to gitops"
      assert html =~ "the Trigger resources a repository holds"
      assert html =~ @source
      assert html =~ "nightly-digest"
      assert html =~ "Read from engineering.nightly-digest at generation 1"

      # Nothing that changes a trigger is on the page.
      refute has_element?(view, "form#new-trigger")
      refute has_element?(view, "button[phx-click='disable']")
      refute has_element?(view, "button[phx-click='enable']")
      refute has_element?(view, "button[phx-click='confirm-delete']")

      # What is done with one still is.
      assert has_element?(view, "button[phx-click='run'][phx-value-name='nightly-digest']")
      assert has_element?(view, "button[phx-click='rotate-key'][phx-value-name='nightly-digest']")
      assert has_element?(view, "form#revisions-nightly-digest")
    end

    test "a switch sent anyway is refused by name, and the trigger is as it was", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/triggers/engineering")

      html = render_click(view, "disable", %{"name" => "nightly-digest"})
      assert html =~ "managed_by_gitops"
      assert Triggers.get(context.team, "nightly-digest").enabled

      html =
        render_submit(view, "create", %{
          "name" => "made-here",
          "principal" => "svc:engineering/nightly",
          "profile" => "dev",
          "kind" => "webhook"
        })

      assert html =~ "managed_by_gitops"
      assert Triggers.get(context.team, "made-here") == nil
    end

    test "minting a key still works, and shows it once", context do
      {:ok, view, _html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/triggers/engineering")

      html =
        view
        |> element("button[phx-click='rotate-key'][phx-value-name='nightly-digest']")
        |> render_click()

      trigger = Triggers.get(context.team, "nightly-digest")
      assert html =~ "POST /trigger/#{trigger.id} with Authorization: Bearer twk_"
      assert is_binary(trigger.key_hash)
    end

    test "shows what a pass could not use, under the trigger and on its own", context do
      {:ok, _} =
        FakeCluster.apply_as(
          "kustomize-controller",
          manifest("engineering.nightly-digest", %{"profile" => "gpu"})
        )

      {:ok, _} =
        FakeCluster.apply_as(
          "kustomize-controller",
          manifest("engineering.weekly", %{"concurrency" => 0})
        )

      {:ok, _} = FakeCluster.apply_as("kustomize-controller", manifest("research.nightly"))
      {:ok, _} = Gitops.sync(GitopsTriggers)

      {:ok, _view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/triggers/engineering")

      # The change that failed, beside the version still in use.
      assert html =~ "generation 2 is not used"
      assert html =~ "spec.profile gpu is not a profile this plane has"

      # The resource that never became a trigger.
      assert html =~ "weekly"
      assert html =~ "not in use"
      assert html =~ "spec.concurrency must be greater than 0"

      # And, for a platform admin, the one that names no team here.
      assert html =~ "Resources the plane could not place in a team"
      assert html =~ "research.nightly"
      assert html =~ "names the team research, which this plane does not have"
    end

    test "a trigger the cluster has no resource for may be deleted from here", context do
      {:ok, _} =
        Triggers.put(
          context.team,
          %{
            "name" => "leftover",
            "principal" => "svc:engineering/nightly",
            "profile" => "dev",
            "source" => %{"kind" => "webhook"}
          },
          "root@example.test"
        )

      {:ok, _} = Gitops.sync(GitopsTriggers)

      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/triggers/engineering")

      assert html =~ "no resource in the cluster"
      assert has_element?(view, "button[phx-click='confirm-delete'][phx-value-name='leftover']")

      refute has_element?(
               view,
               "button[phx-click='confirm-delete'][phx-value-name='nightly-digest']"
             )

      view
      |> element("button[phx-click='confirm-delete'][phx-value-name='leftover']")
      |> render_click()

      html =
        view |> element("button[phx-click='delete'][phx-value-name='leftover']") |> render_click()

      assert html =~ "deleted leftover"
      assert Triggers.get(context.team, "leftover") == nil
    end
  end

  describe "direct mode" do
    test "is not locked: the form, the switch and delete are there", context do
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)

      {:ok, view, html} =
        context.conn |> sign_in(context.root.subject) |> live("/admin/triggers/engineering")

      refute html =~ "Locked to gitops"
      refute html =~ "Read from"
      assert has_element?(view, "form#new-trigger")
      assert has_element?(view, "button[phx-click='disable'][phx-value-name='nightly-digest']")

      assert has_element?(
               view,
               "button[phx-click='confirm-delete'][phx-value-name='nightly-digest']"
             )

      html =
        view
        |> element("button[phx-click='disable'][phx-value-name='nightly-digest']")
        |> render_click()

      assert html =~ "nightly-digest disabled"
      refute Triggers.get(context.team, "nightly-digest").enabled
    end
  end
end
