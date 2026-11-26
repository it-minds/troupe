defmodule Troupe.Worker.GitHubRepositoriesTest do
  @moduledoc """
  A pod session holding several GitHub repositories (#1207): the one it was created on at
  the workspace's root and each other one in `<owner>/<name>`, every clone with a token of
  its own for that repository alone; one attached while it runs, cloned without a restart;
  one taken off, its directory deleted and its tokens revoked, refused while a push on it
  is going; the fix loop's tools acting on the repository they name, each with its own
  branch and record; and the root told what it holds.

  End to end, as `github_fix_loop_test.exs` is: a real plane at the other end of the pod's
  link, minting with the App's key in the development OpenBao's transit engine, and the
  fake GitHub serving both repositories.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox, as: DatabaseSandbox
  alias Troupe.LLM.Fake
  alias Troupe.Plane.{Admin, Audit, FakeGitHub, Fleet, Identity, Repo}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Plane.Sessions.Session, as: PlaneSession
  alias Troupe.Sandbox
  alias Troupe.Worker.{GitCredentials, GitHub}
  alias Troupe.Worker.Plane.{Commands, Link}
  alias Troupe.Worker.PlaneHelper

  @moduletag timeout: 300_000

  @app_id 5252
  @installation 99_002
  @owner "idp|ada"
  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @widgets %{"owner" => "example-org", "name" => "widgets", "ref" => nil, "path" => "."}
  @gadgets %{
    "owner" => "example-org",
    "name" => "gadgets",
    "ref" => nil,
    "path" => "example-org/gadgets"
  }
  @tools [
    Troupe.Worker.Tools.GitPush,
    Troupe.Worker.Tools.PrOpen,
    Troupe.Worker.Tools.PrComment,
    Troupe.Worker.Tools.PrChecks
  ]

  setup context do
    context = requires_tier(context)

    unless Process.whereis(Repo),
      do: flunk("no database for the plane; bring one up with `scripts/dev-up`")

    owner = DatabaseSandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> DatabaseSandbox.stop_owner(owner) end)

    if Sandbox.available?() do
      Application.put_env(:troupe_core, :sandbox, :always)
      on_exit(fn -> Application.delete_env(:troupe_core, :sandbox) end)
    end

    tools = Application.get_env(:troupe_core, :extra_tools, [])
    Application.put_env(:troupe_core, :extra_tools, tools ++ @tools)
    on_exit(fn -> Application.put_env(:troupe_core, :extra_tools, tools) end)

    key_name = "troupe-github-repositories-test-#{System.unique_integer([:positive])}"
    transit = Application.get_env(:troupe_plane, :transit, [])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :github_key, key_name))

    on_exit(fn ->
      Application.put_env(:troupe_plane, :transit, transit)
      delete_transit_key(transit, key_name)
    end)

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &verify/1})

    start_supervised!(
      {Link,
       host: "127.0.0.1",
       port: Listener.port(),
       token: "dev-token",
       disk_path: context.base,
       claims: %{
         "pod_name" => "troupe-w-dev-0",
         "capacity" => 4,
         "disk_total_bytes" => 1_000_000,
         "version" => "test"
       }}
    )

    start_supervised!(GitCredentials)
    start_supervised!(GitHub)
    eventually(fn -> Link.connected?() end, 10_000)

    fake = FakeGitHub.start()
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    FakeGitHub.app(fake, @app_id, key, slug: "example-org-troupe")
    FakeGitHub.install(fake, @installation, @app_id, "example-org", ["widgets", "gadgets"])

    upstreams =
      for name <- ["widgets", "gadgets"], into: %{} do
        path = upstream(context.base, name)
        FakeGitHub.repo(fake, "example-org/#{name}", path)
        FakeGitHub.ruleset(fake, "example-org/#{name}", "troupe/")
        {name, path}
      end

    {:ok, _} =
      Fleet.put_profile(%{
        name: "dev",
        spec: %{
          "egress" => %{"gitHosts" => [fake.host]},
          "github" => %{"permissions" => %{"contents" => "write", "pull_requests" => "write"}}
        }
      })

    name = "fixers-#{System.unique_integer([:positive])}"
    {:ok, group} = Identity.upsert_group(%{external_id: name, display_name: name})
    {:ok, team} = Identity.enable_team(group, %{name: name})

    {:ok, team} =
      Identity.update_team(team, %{
        github: %{"repositories" => ["example-org/widgets", "example-org/gadgets"]}
      })

    {:ok, _} =
      Admin.github_put(@root, %{
        "app_id" => @app_id,
        "api_url" => fake.api_url,
        "installations" => [%{"owner" => "example-org", "installation_id" => @installation}],
        "private_key" =>
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      })

    on_exit(fn ->
      try do
        Troupe.cancel(context.session_id)
        Troupe.stop_session(context.session_id)
      catch
        :exit, _ -> :ok
      end
    end)

    Map.merge(context, %{fake: fake, upstreams: upstreams, plane_team: team})
  end

  test "a session on two repositories clones each into its own directory with its own token, " <>
         "leaves the other out of the root's clone, and its root is told both",
       context do
    held(context, [@widgets, @gadgets])
    {:ok, _} = activate_with(context, [@widgets, @gadgets])
    ws = context.workspace

    assert File.read!(Path.join(ws, "README.md")) == "# widgets\n"
    assert File.read!(Path.join([ws, "example-org", "gadgets", "README.md"])) == "# gadgets\n"
    assert File.read!(Path.join([ws, ".git", "info", "exclude"])) =~ "/example-org/gadgets/"

    # Each clone's token was for its own repository alone, and each is in the trail.
    assert context.fake |> FakeGitHub.requests() |> Enum.map(& &1.repositories) |> Enum.sort() ==
             [["gadgets"], ["widgets"]]

    tokens = Enum.filter(Audit.list(kind: "github"), &(&1.action == "github.token"))

    assert Enum.sort(Enum.map(tokens, & &1.subject_id)) == [
             "example-org/gadgets",
             "example-org/widgets"
           ]

    eventually(fn -> length(Troupe.repositories(context.session_id) || []) == 2 end, 10_000)

    assert [
             %{"repository" => "example-org/widgets", "path" => "."},
             %{"path" => "example-org/gadgets"}
           ] =
             Troupe.repositories(context.session_id)

    # The root clone's tree is its own: the other clone is not something it would stage.
    {status, 0} = git(ws, ["status", "--porcelain"])
    assert status == ""

    finish()
  end

  test "git_push names the repository where there are two, each with its own branch and record",
       context do
    held(context, [@widgets, @gadgets])
    {:ok, _} = activate_with(context, [@widgets, @gadgets])
    ws = context.workspace
    id = context.session_id

    assert {:error, ambiguous} = GitHub.push(id, ws, "Fix", "troupe/fix", [])

    assert ambiguous ==
             "this session holds example-org/widgets and example-org/gadgets: name the " <>
               "repository to act on as repository"

    File.write!(Path.join([ws, "example-org", "gadgets", "FIX.md"]), "fixed\n")

    assert {:ok, pushed} =
             GitHub.push(id, ws, "Fix the gadgets", "troupe/gadgets",
               repository: "example-org/gadgets"
             )

    assert pushed.repository == "example-org/gadgets"
    assert pushed.files == 1

    {count, 0} =
      git(context.upstreams["gadgets"], [
        "rev-list",
        "--count",
        "refs/heads/main..refs/heads/troupe/gadgets"
      ])

    assert String.trim(count) == "1"

    {_out, status} =
      git(context.upstreams["widgets"], ["rev-parse", "--verify", "refs/heads/troupe/gadgets"])

    refute status == 0

    # Each clone's starting commit is its own, and the push is gadgets' alone; the row's
    # `github` is the first repository's, which has pushed nothing.
    row = PlaneSessions.get(id)

    assert [
             %{"github" => widgets},
             %{"github" => %{"branch" => "troupe/gadgets", "pushes" => 1} = gadgets}
           ] =
             row.repositories

    assert row.github == widgets
    refute widgets["branch"]
    assert widgets["base"] != gadgets["base"]
    finish()
  end

  test "one attached while the session runs is cloned without a restart, and its root told",
       context do
    held(context, [@widgets])
    {:ok, _} = activate_with(context, [@widgets])
    pid = Troupe.Registry.whereis({:session, context.session_id})

    held(context, [@widgets, @gadgets])

    assert {:ok, %{"cloned" => true, "path" => "example-org/gadgets"}} =
             Commands.handle("session.repository.add", %{
               "session_id" => context.session_id,
               "epoch" => 1,
               "repository" => @gadgets,
               "by" => @owner,
               "by_name" => "Ada"
             })

    assert Troupe.Registry.whereis({:session, context.session_id}) == pid

    assert File.read!(Path.join([context.workspace, "example-org", "gadgets", "README.md"])) ==
             "# gadgets\n"

    assert length(GitHub.holding(context.session_id)) == 2

    [said] =
      context.session_id
      |> Troupe.events()
      |> Enum.filter(
        &(&1.type == "session_repository_changed" and
            &1.data["repository"] == "example-org/gadgets")
      )

    assert said.data["action"] == "attached"
    assert said.data["by_name"] == "Ada"
    assert length(said.data["repositories"]) == 2
    finish()
  end

  test "one taken off while a push on it is going is busy; otherwise its directory and its " <>
         "tokens go",
       context do
    held(context, [@widgets, @gadgets])
    {:ok, _} = activate_with(context, [@widgets, @gadgets])
    id = context.session_id
    {:ok, read} = GitCredentials.credential(id, repository: "example-org/gadgets")
    test = self()

    # A push on gadgets, held where a real one would be between its steps.
    pusher =
      spawn(fn ->
        :global.trans(
          {{GitHub, {id, "example-org/gadgets"}}, self()},
          fn ->
            send(test, :pushing)

            receive do
              :done -> :ok
            end
          end,
          [node()]
        )
      end)

    assert_receive :pushing, 5_000
    remove = %{"session_id" => id, "epoch" => 1, "repository" => @gadgets, "by" => @owner}

    assert {:error, %{message: "conflict", data: %{reason: "busy", detail: detail}}} =
             Commands.handle("session.repository.remove", remove)

    assert detail =~ "example-org/gadgets has a push"
    assert File.dir?(Path.join([context.workspace, "example-org", "gadgets"]))
    send(pusher, :done)

    assert {:ok, %{"removed" => true}} = Commands.handle("session.repository.remove", remove)
    refute File.exists?(Path.join([context.workspace, "example-org"]))
    assert [%{"name" => "widgets"}] = GitHub.holding(id)
    eventually(fn -> read["token"] in FakeGitHub.revoked(context.fake) end, 10_000)
    refute File.read!(Path.join([context.workspace, ".git", "info", "exclude"])) =~ "gadgets"

    assert [%{"repository" => "example-org/widgets"}] = Troupe.repositories(id)
    finish()
  end

  # -- helpers ------------------------------------------------------------------

  # The plane's row holding these, and the session placed on this pod, as the plane's
  # create and attach leave it.
  defp held(context, entries) do
    attrs =
      Map.merge(
        %{
          id: context.session_id,
          owner_subject: @owner,
          team_id: context.plane_team.id,
          profile: "dev",
          epoch: 1
        },
        PlaneSession.holding(entries)
      )

    case PlaneSessions.get(context.session_id) do
      nil -> {:ok, _} = PlaneSessions.create(attrs)
      row -> {:ok, _} = Repo.update(Ecto.Changeset.change(row, PlaneSession.holding(entries)))
    end

    [pod] = Fleet.list_workers("dev")

    eventually(
      fn ->
        {:ok, _} = PlaneSessions.place(context.session_id, pod)
        Process.sleep(300)
        PlaneSessions.get(context.session_id).worker_id == pod.id
      end,
      10_000
    )
  end

  defp activate_with(context, entries) do
    fake =
      start_supervised!(
        Supervisor.child_spec({Fake, steps: [], default: {:text, "done"}},
          id: {Fake, System.unique_integer([:positive])}
        )
      )

    Sessions.activate(
      context.session_id,
      activation(context, owner_subject: @owner, fake: fake) ++ [repositories: entries]
    )
  end

  defp upstream(base, name) do
    path = Path.join(base, "upstream-#{name}")
    File.mkdir_p!(path)
    {_, 0} = git(path, ["init", "--quiet", "--initial-branch=main"])
    File.write!(Path.join(path, "README.md"), "# #{name}\n")
    {_, 0} = git(path, ["add", "README.md"])

    {_, 0} =
      git(path, [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.test",
        "commit",
        "--quiet",
        "-m",
        "the first commit"
      ])

    path
  end

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

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

  defp verify("dev-token") do
    {:ok,
     %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}

  defp finish do
    stop_supervised!(Link)
    PlaneHelper.stop_plane()
  end
end
