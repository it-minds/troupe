defmodule Troupe.Plane.GitopsGitHubAppTest do
  @moduledoc """
  The plane's GitHub App from a repository, in GitOps mode (#653): a `GitHubApp` resource
  holds the App's ID, API URL and installations and each team's repositories and caps, the
  plane's App and teams follow it, the console's writes of them are refused, and the App's
  key and webhook secret stay what the admin API puts into OpenBao.

  The reproduction on the chunk tip: a pass read no `GitHubApp` (`Gitops.sources/0` had
  profiles and triggers), and `admin.github.put` took an App ID on a GitOps plane.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, FakeCluster, GitHub, Gitops, Identity}
  alias Troupe.Plane.Gitops.GitHubApp, as: GitopsGitHubApp

  @moduletag timeout: 60_000

  @flux "kustomize-controller"
  @source "https://git.example.com/fleet.git, platform/"
  @root %{subject: "root@example.test", role: :platform_admin, teams: []}

  setup do
    Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
    Application.put_env(:troupe_plane, :gitops_source, @source)

    on_exit(fn ->
      for key <- ~w(provisioning_mode gitops_source)a,
          do: Application.delete_env(:troupe_plane, key)
    end)

    FakeCluster.start()
    engineering = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)

    docs =
      team_with_grant("docs", "dev",
        name: "docs",
        budget_micros: 0,
        github: %{"repositories" => ["example-org/handbook"]}
      )

    %{engineering: engineering, docs: docs}
  end

  defp manifest(spec, name \\ "github") do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "GitHubApp",
      "metadata" => %{"name" => name, "namespace" => FakeCluster.namespace()},
      "spec" => spec
    }
  end

  @app_spec %{
    "appId" => 123_456,
    "apiUrl" => "https://github.example.test/api/v3",
    "installations" => [%{"owner" => "example-org", "installationId" => 7_890_123}],
    "teams" => %{
      "engineering" => %{
        "repositories" => ["example-org/widgets", "example-org/*"],
        "maxPushes" => 10,
        "maxRuns" => 2,
        "maxAttempts" => 3
      }
    }
  }

  defp flux(manifest) do
    {:ok, applied} = FakeCluster.apply_as(@flux, manifest)
    applied
  end

  defp pass do
    {:ok, outcomes} = Gitops.sync(GitopsGitHubApp)
    Map.new(outcomes, &{&1.name, &1})
  end

  describe "the App follows the cluster" do
    test "a resource becomes the App's settings and every team's repositories, with a trail" do
      flux(manifest(@app_spec))
      assert %{"github" => %{state: :created, problem: nil}} = pass()

      app = GitHub.describe()
      assert app.app_id == 123_456
      assert app.api_url == "https://github.example.test/api/v3"
      assert app.git_url == "https://github.example.test"
      assert app.installations == [%{"owner" => "example-org", "installation_id" => 7_890_123}]
      assert app.resource_generation == 1
      assert app.updated_by == "system:gitops"

      assert Identity.get_team("engineering").github == %{
               "repositories" => ["example-org/widgets", "example-org/*"],
               "max_pushes" => 10,
               "max_runs" => 2,
               "max_attempts" => 3
             }

      # A team the resource does not name lists nothing: the resource is the whole of it.
      assert Identity.get_team("docs").github == nil

      trail = Audit.list(actor: "system:gitops", limit: 20)

      assert Enum.any?(
               trail,
               &(&1.action == "github.put" and &1.detail["app_id"]["to"] == 123_456)
             )

      assert Enum.any?(trail, &(&1.action == "team.update" and &1.subject_id == "engineering"))
      assert Enum.any?(trail, &(&1.action == "team.update" and &1.subject_id == "docs"))

      # The same resource again changes nothing and records nothing.
      count = length(Audit.list(actor: "system:gitops", limit: 100))
      assert %{"github" => %{state: :unchanged}} = pass()
      assert length(Audit.list(actor: "system:gitops", limit: 100)) == count

      # A commit that changes it changes them.
      flux(
        manifest(
          Map.merge(@app_spec, %{
            "apiUrl" => nil,
            "teams" => %{"docs" => %{"repositories" => ["example-org/handbook"]}}
          })
        )
      )

      assert %{"github" => %{state: :changed}} = pass()
      assert GitHub.describe().api_url == "https://api.github.com"
      assert Identity.get_team("engineering").github == nil
      assert Identity.get_team("docs").github["repositories"] == ["example-org/handbook"]
    end

    test "a resource the plane cannot use is refused, saying why, and the App stays as it was" do
      flux(manifest(@app_spec))
      pass()

      refused = [
        {manifest(Map.put(@app_spec, "appId", "x")), "spec.appId"},
        {manifest(Map.put(@app_spec, "privateKey", "-----BEGIN RSA PRIVATE KEY-----")),
         "spec.privateKey is not a field"},
        {manifest(Map.put(@app_spec, "apiUrl", "https://example.test/")), "spec.apiUrl"},
        {manifest(Map.put(@app_spec, "installations", [%{"owner" => "a", "id" => 1}])),
         "owner and installationId"},
        {manifest(put_in(@app_spec, ["teams", "engineering", "repositories"], ["widgets"])),
         "spec.teams.engineering"},
        {manifest(put_in(@app_spec, ["teams", "engineering", "maxRuns"], 0)),
         "spec.teams.engineering"},
        {manifest(Map.put(@app_spec, "teams", %{"engineering" => %{"admins" => []}})),
         "not admins"}
      ]

      for {resource, said} <- refused do
        flux(resource)
        assert %{"github" => %{state: :refused, reasons: reasons}} = pass()
        assert Enum.join(reasons, " ") =~ said, "#{said}: #{inspect(reasons)}"
        refute Enum.join(reasons, " ") =~ "-----BEGIN"
        assert GitHub.describe().app_id == 123_456
        assert Identity.get_team("engineering").github["max_runs"] == 2
      end

      assert %{problem: "refused"} = Gitops.report("GitHubApp", "github")
    end

    test "one named otherwise is refused, and a team it names that the plane has not got is " <>
           "reported while the rest is used" do
      flux(manifest(@app_spec, "second-app"))
      assert %{"second-app" => %{state: :refused, reasons: [reason]}} = pass()
      assert reason =~ "a plane has one GitHub App"
      assert GitHub.describe().app_id == nil

      FakeCluster.delete("GitHubApp", "second-app")

      flux(
        manifest(
          put_in(@app_spec, ["teams", "research"], %{"repositories" => ["example-org/lab"]})
        )
      )

      assert %{"github" => %{state: :created, problem: "unknown_teams", reasons: [reason]}} =
               pass()

      assert reason =~ "research"
      assert GitHub.describe().app_id == 123_456

      assert Identity.get_team("engineering").github["repositories"] == [
               "example-org/widgets",
               "example-org/*"
             ]
    end

    test "a resource gone takes the settings and the teams' repositories, and an App set " <>
           "before the plane read the cluster is reported missing and kept" do
      flux(manifest(@app_spec))
      pass()

      FakeCluster.delete("GitHubApp", "github")
      assert %{"github" => %{state: :removed}} = pass()
      app = GitHub.describe()
      assert app.app_id == nil and app.installations == [] and app.resource_generation == nil
      assert Identity.get_team("engineering").github == nil

      # An App an administrator set before the switch: kept, and reported.
      Application.put_env(:troupe_plane, :provisioning_mode, :direct)

      {:ok, _} =
        Admin.github_put(@root, %{
          "app_id" => 42,
          "installations" => [%{"owner" => "example-org", "installation_id" => 1}]
        })

      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)

      assert %{"github" => %{state: :missing, reasons: [reason]}} = pass()
      assert reason =~ "admin.profiles.export"
      assert GitHub.describe().app_id == 42

      # That one, and only that one, may still be removed here.
      assert {:ok, _} = Admin.github_delete(@root, 42)
    end
  end

  describe "on a GitOps plane" do
    test "the App's settings and a team's github are the resource's to change, and the " <>
           "answer says where they come from" do
      flux(manifest(@app_spec))
      pass()

      for {call, field} <- [
            {fn -> Admin.github_put(@root, %{"app_id" => 9}) end, "app_id"},
            {fn -> Admin.github_put(@root, %{"installations" => []}) end, "installations"},
            {fn -> Admin.team_update(@root, "engineering", %{"github" => %{"max_runs" => 5}}) end,
             "github"}
          ] do
        assert {:error, error} = call.()
        assert error.message == "managed_by_gitops", field
        assert error.data.kind == "GitHubApp"
        assert error.data.reason =~ @source
      end

      assert {:error, %{message: "managed_by_gitops"}} = Admin.github_delete(@root, 123_456)
      assert GitHub.describe().app_id == 123_456
      assert Identity.get_team("engineering").github["max_runs"] == 2

      # Other settings of a team are still its admins'.
      assert {:ok, _} = Admin.team_update(@root, "engineering", %{"idle_timeout_seconds" => 600})

      {:ok, described} = Admin.github_get(@root)

      assert described.gitops == %{
               resource: "github",
               generation: 1,
               source: @source,
               problem: nil,
               reasons: []
             }
    end

    test "the App's key and webhook secret are still put into OpenBao through the admin API" do
      suffix = System.unique_integer([:positive])
      transit = Application.get_env(:troupe_plane, :transit, [])
      key_name = "troupe-gitops-github-test-app-#{suffix}"
      secret_name = "troupe-gitops-github-test-secret-#{suffix}"

      Application.put_env(
        :troupe_plane,
        :transit,
        transit
        |> Keyword.put(:github_key, key_name)
        |> Keyword.put(:github_webhook_key, secret_name)
      )

      on_exit(fn ->
        Application.put_env(:troupe_plane, :transit, transit)

        for name <- [key_name, secret_name] do
          url = "#{transit[:address]}/v1/#{transit[:mount] || "transit"}/keys/#{name}"
          headers = [{"x-vault-token", transit[:token]}]

          Req.request(
            method: :post,
            url: url <> "/config",
            headers: headers,
            json: %{"deletion_allowed" => true},
            retry: false
          )

          Req.request(method: :delete, url: url, headers: headers, retry: false)
        end
      end)

      flux(manifest(@app_spec))
      pass()

      key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      secret = String.duplicate("s", 40)

      assert {:ok, now} =
               Admin.github_put(@root, %{"private_key" => pem, "webhook_secret" => secret})

      assert now.private_key.set and now.webhook.secret.set
      assert now.app_id == 123_456
      assert now.gitops.resource == "github"

      # The next pass leaves them be: a repository never holds them.
      assert %{"github" => %{state: :unchanged}} = pass()
      assert GitHub.describe().private_key.version == 1
      assert GitHub.describe().webhook.secret.version == 1
    end

    test "the CRD has the fields the plane reads, and nothing for a key or a secret" do
      crd =
        "../../../../../charts/troupe/crds/githubapp.yaml"
        |> Path.expand(__DIR__)
        |> YamlElixir.read_from_file!()

      assert crd["spec"]["names"]["kind"] == GitopsGitHubApp.kind()
      assert crd["spec"]["group"] <> "/v1alpha1" == GitopsGitHubApp.api_version()
      [%{"schema" => %{"openAPIV3Schema" => schema}}] = crd["spec"]["versions"]
      spec = schema["properties"]["spec"]
      assert Enum.sort(Map.keys(spec["properties"])) == Enum.sort(GitopsGitHubApp.spec_keys())
      assert spec["x-kubernetes-preserve-unknown-fields"]

      team = spec["properties"]["teams"]["additionalProperties"]["properties"]
      assert Enum.sort(Map.keys(team)) == ~w(maxAttempts maxPushes maxRuns repositories)

      rbac =
        File.read!(Path.expand("../../../../../charts/troupe/templates/plane-rbac.yaml", __DIR__))

      assert rbac =~ ~s(resources: ["triggers", "githubapps"])
    end

    test "export holds the App and the teams' repositories, never a key, and reads back" do
      flux(manifest(@app_spec))
      pass()

      assert [%{name: "github", path: "github/github.yaml", yaml: yaml}] = Gitops.export().github
      refute yaml =~ "privateKey:"
      refute yaml =~ "webhookSecret:"
      assert yaml =~ "appId: 123456"
      assert yaml =~ "maxAttempts: 3"

      exported = GitopsGitHubApp.manifest(GitHub.app())
      assert {:ok, read} = GitopsGitHubApp.read(exported, GitopsGitHubApp.context())
      assert read.settings.app_id == 123_456
      assert read.teams["engineering"]["max_attempts"] == 3
    end
  end
end
