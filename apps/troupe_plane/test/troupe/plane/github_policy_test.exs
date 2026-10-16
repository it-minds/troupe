defmodule Troupe.Plane.GitHubPolicyTest do
  @moduledoc """
  The plane's half of the fix loop's autonomy policy (#147 slice 4, #653): what a worker
  profile and a team say a session may do on GitHub, the repositories a team lists, the
  cap of pushes a run may make, and what the pod is handed to check a push against.

  Against the development OpenBao's transit engine and `Troupe.Plane.FakeGitHub`, as
  `github_run_test.exs` is. The pod's half (visibility at push time, the paths in a tree,
  the stop and its comment, revoking tokens) is the worker's `github_fix_loop_test.exs`.

  The reproduction on the chunk tip: `spec.github` refused every key but `permissions`, a
  team had no repository list and every team named any repository the App reached, a
  token carried no policy, and a run's pushes had no cap but three red rounds.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, FakeGitHub, Fleet, GitHub, Identity, Sessions}
  alias Troupe.Plane.Admin.API
  alias Troupe.Plane.Fleet.Extends

  @moduletag timeout: 120_000

  @app_id 4545
  @installation 77_004
  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @lead %{subject: "lead@example.test", role: :team_admin, teams: ["fixers"]}
  @grants %{"contents" => "write", "pull_requests" => "write"}

  @tree String.duplicate("b", 40)
  @one String.duplicate("1", 40)
  @two String.duplicate("2", 40)
  @three String.duplicate("3", 40)

  setup do
    unless bao_reachable?(), do: flunk("no OpenBao; bring it up with `scripts/dev-up`")

    name = "troupe-github-policy-test-#{System.unique_integer([:positive])}"
    transit = Application.get_env(:troupe_plane, :transit, [])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :github_key, name))

    on_exit(fn ->
      Application.put_env(:troupe_plane, :transit, transit)
      delete_transit_key(transit, name)
    end)

    fake = FakeGitHub.start()
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    FakeGitHub.app(fake, @app_id, key)
    FakeGitHub.install(fake, @installation, @app_id, "example-org", ["widgets", "gadgets"])

    {:ok, _} = profile(fake, %{})

    {:ok, _} =
      Admin.github_put(@root, %{
        "app_id" => @app_id,
        "api_url" => fake.api_url,
        "installations" => [%{"owner" => "example-org", "installation_id" => @installation}],
        "private_key" =>
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      })

    team =
      team_with_grant("fixers", "dev",
        name: "fixers",
        github: %{"repositories" => ["example-org/widgets"]}
      )

    %{fake: fake, team: team, session: session(team, "widgets")}
  end

  describe "a worker profile's policy" do
    test "is read by name, and anything else is refused, naming it", context do
      refused = [
        {%{"allowPublic" => "yes"}, "github.allowPublic is true or false"},
        {%{"denyPaths" => ".env"}, "github.denyPaths is a list of patterns"},
        {%{"denyPaths" => [""]}, "empty pattern"},
        {%{"denyPaths" => ["../outside"]}, "climbs out of the repository"},
        {%{"denyPaths" => [7]}, "not a pattern"},
        {%{"maxPushes" => 0}, "github.maxPushes is a whole number from 1 to 1000"},
        {%{"maxRuns" => "3"}, "github.maxRuns is a whole number from 1 to 1000"},
        {%{"autonomy" => "merge"}, "not autonomy"}
      ]

      for {policy, said} <- refused do
        assert {:error, changeset} = profile(context.fake, policy), "#{inspect(policy)} was taken"
        problems = Keyword.get_values(changeset.errors, :spec) |> inspect()
        assert problems =~ said, "#{inspect(policy)}: #{problems}"
      end

      assert {:ok, _} =
               profile(context.fake, %{
                 "allowPublic" => true,
                 "denyPaths" => ["secrets/", "*.tfstate"],
                 "maxPushes" => 5,
                 "maxRuns" => 2
               })
    end

    test "is what the pod is handed with the fix loop's token, with the lower cap of the " <>
           "profile's and the team's, and the defaults it cannot drop",
         context do
      {:ok, _} =
        profile(context.fake, %{
          "allowPublic" => true,
          "denyPaths" => ["secrets/"],
          "maxPushes" => 5
        })

      {:ok, _} =
        Identity.update_team(context.team, %{
          github: %{"repositories" => ["example-org/widgets"], "max_pushes" => 3}
        })

      assert {:ok, write} = GitHub.credential(context.session, access: :write)

      assert write["policy"] == %{
               "allow_public" => true,
               "deny_paths" => Troupe.PushPaths.defaults() ++ ["secrets/"],
               "max_pushes" => 3
             }

      # An empty list takes nothing away.
      {:ok, _} = profile(context.fake, %{"denyPaths" => []})
      assert {:ok, write} = GitHub.credential(context.session, access: :write)
      assert write["policy"]["deny_paths"] == Troupe.PushPaths.defaults()
      assert write["policy"]["allow_public"] == false
    end

    test "is inherited as a parent decides: its denied paths stay, its no to public holds, " <>
           "and its caps can only be lowered" do
      parent = %{
        "spec" => %{
          "github" => %{
            "permissions" => @grants,
            "allowPublic" => false,
            "denyPaths" => ["secrets/"],
            "maxPushes" => 3,
            "maxRuns" => 2
          }
        }
      }

      child = %{
        "spec" => %{
          "github" => %{
            "allowPublic" => true,
            "denyPaths" => ["*.tfstate"],
            "maxPushes" => 10,
            "maxRuns" => 1
          }
        }
      }

      base = Extends.merge(%{attrs: %{"spec" => %{}}, from: %{}, problems: []}, parent, "base")
      merged = Extends.merge(base, child, "child")

      assert merged.attrs["spec"]["github"] == %{
               "permissions" => @grants,
               "allowPublic" => false,
               "denyPaths" => ["secrets/", "*.tfstate"],
               "maxPushes" => 3,
               "maxRuns" => 1
             }
    end
  end

  describe "a team's repositories" do
    test "are its own administrators' to list, checked by name, audited and shown" do
      assert {:ok, %{team: team}} =
               API.call(
                 "admin.team.update",
                 %{
                   "name" => "fixers",
                   "attrs" => %{
                     "github" => %{
                       "repositories" => ["example-org/widgets", "Example-Org/*"],
                       "max_runs" => 2
                     }
                   }
                 },
                 @lead
               )

      assert team.github == %{
               repositories: ["example-org/widgets", "Example-Org/*"],
               max_pushes: nil,
               max_runs: 2
             }

      # Only the keys sent change.
      assert {:ok, %{team: team}} =
               Admin.team_update(@lead, "fixers", %{"github" => %{"max_pushes" => 4}})

      assert team.github.repositories == ["example-org/widgets", "Example-Org/*"]
      assert team.github.max_pushes == 4

      for {github, field} <- [
            {%{"repositories" => ["widgets"]}, "github.repositories"},
            {%{"repositories" => ["example-org/../x"]}, "github.repositories"},
            {%{"repositories" => "example-org/widgets"}, "github.repositories"},
            {%{"max_runs" => -1}, "github.max_runs"},
            {%{"merge" => true}, "github.merge"},
            {"everything", "github"}
          ] do
        assert {:error, error} = Admin.team_update(@lead, "fixers", %{"github" => github})
        assert error.message == "invalid_params"
        assert error.data.field == field, inspect(error.data)
      end

      assert Identity.get_team("fixers").github["max_pushes"] == 4

      [audit | _] = Enum.filter(Audit.list(limit: 50), &(&1.action == "team.update"))
      assert inspect(audit.detail) =~ "max_pushes"

      # Another team's administrator lists nothing here.
      other = %{subject: "other@example.test", role: :team_admin, teams: ["others"]}

      assert {:error, _} =
               Admin.team_update(other, "fixers", %{"github" => %{"repositories" => []}})
    end

    test "bound every token: one the team stops listing gets none, and neither does a " <>
           "session with no team",
         context do
      assert {:ok, _} = GitHub.credential(context.session)

      gadgets = session(context.team, "gadgets")
      assert {:error, reason} = GitHub.credential(gadgets)
      assert GitHub.explain(reason) =~ "the team fixers does not list example-org/gadgets"

      {:ok, _} =
        Identity.update_team(context.team, %{github: %{"repositories" => ["example-org/*"]}})

      assert {:ok, _} = GitHub.credential(gadgets)

      {:ok, _} = Identity.update_team(context.team, %{github: nil})
      assert {:error, reason} = GitHub.credential(context.session, access: :write)
      assert GitHub.explain(reason) =~ "the team fixers lists no GitHub repositories"

      {:ok, teamless} =
        Sessions.create(%{
          id: "s-gh-teamless-#{System.unique_integer([:positive])}",
          owner_subject: "idp|ada",
          profile: "dev",
          repository: %{"owner" => "example-org", "name" => "widgets"}
        })

      assert {:error, reason} = GitHub.credential(teamless)
      assert GitHub.explain(reason) =~ "this one has no team"

      # And the App still bounds the list: an owner it is not installed for is refused
      # however the team lists it.
      {:ok, _} = Identity.update_team(context.team, %{github: %{"repositories" => ["acme/*"]}})
      acme = session(context.team, "widgets", "acme")
      assert {:error, reason} = GitHub.credential(acme)
      assert GitHub.explain(reason) =~ "not installed for acme"
    end
  end

  describe "a run's cap of pushes" do
    test "refuses a push past it, takes the pod's stop only at it, and its tokens after " <>
           "cannot push",
         context do
      {:ok, _} = profile(context.fake, %{"maxPushes" => 2})
      session = context.session

      push!(session, @one)

      assert {:error, reason} =
               GitHub.record(fresh(session), %{"stop" => %{"reason" => "pushes"}}, "worker:test")

      assert reason =~ "has pushes left under its cap"

      push!(session, @two)

      # The token minted at the cap cannot push, whether or not the pod says it stopped.
      assert {:ok, credential} = GitHub.credential(fresh(session), access: :write)
      assert credential["permissions"]["contents"] == "read"

      assert {:error, reason} =
               GitHub.record(
                 fresh(session),
                 %{"push" => %{"branch" => "troupe/capped", "commit" => @three, "tree" => @tree}},
                 "worker:test"
               )

      assert reason =~ "as many as its cap of 2 allows"

      assert {:ok, %{github: github, stopped_now: true}} =
               GitHub.record(fresh(session), %{"stop" => %{"reason" => "pushes"}}, "worker:test")

      assert %{"reason" => "its cap of 2 pushes", "cap" => "pushes"} = github["stopped"]
      assert github["pushes"] == 2

      # Said once: the stop again changes nothing.
      assert {:ok, %{stopped_now: false}} =
               GitHub.record(fresh(session), %{"stop" => %{"reason" => "pushes"}}, "worker:test")

      assert "github.stopped" in Enum.map(Audit.list(kind: "github"), & &1.action)
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp profile(fake, policy) do
    Fleet.put_profile(%{
      name: "dev",
      spec: %{
        "egress" => %{"gitHosts" => [fake.host]},
        "github" => Map.merge(%{"permissions" => @grants}, policy)
      }
    })
  end

  defp session(team, name, owner \\ "example-org") do
    {:ok, session} =
      Sessions.create(%{
        id: "s-gh-policy-#{System.unique_integer([:positive])}",
        owner_subject: "idp|ada",
        team_id: team.id,
        profile: "dev",
        repository: %{"owner" => owner, "name" => name}
      })

    session
  end

  defp push!(session, commit) do
    assert {:ok, _} =
             GitHub.record(
               fresh(session),
               %{"push" => %{"branch" => "troupe/capped", "commit" => commit, "tree" => @tree}},
               "worker:test"
             )
  end

  defp fresh(session), do: Sessions.get(session.id)

  defp delete_transit_key(transit, name) do
    mount = transit[:mount] || "transit"
    headers = [{"x-vault-token", transit[:token]}]
    url = "#{transit[:address]}/v1/#{mount}/keys/#{name}"

    Req.request(
      method: :post,
      url: url <> "/config",
      headers: headers,
      json: %{"deletion_allowed" => true},
      retry: false
    )

    Req.request(method: :delete, url: url, headers: headers, retry: false)
  end

  defp bao_reachable? do
    address = Application.get_env(:troupe_plane, :transit, [])[:address]

    match?(
      {:ok, %{status: 200}},
      Req.request(method: :get, url: address <> "/v1/sys/health", retry: false)
    )
  rescue
    _ -> false
  end
end
