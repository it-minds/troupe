defmodule Troupe.Worker.GitCloneTest do
  @moduledoc """
  A pod session that names a GitHub repository starts from a clone of it, made with a
  short-lived installation token the plane minted for that one repository (#147 slice 1).

  End to end, with nothing doubled that this is about: a real plane at the other end of
  the pod's link, minting with the plane's App key in the development OpenBao's transit
  engine; a fake GitHub (`Troupe.Plane.FakeGitHub`) that verifies the App's JWT, narrows
  the token and serves the clone with the real `git upload-pack`; and the worker's own
  sandbox around every command, as a pod runs them.

  The token-leak check is the first test: every log line of the run at debug level, every
  event, every tool result, every file of the workspace, the plane's rows and audit trail,
  and the pod's processes' state are searched for each token the fake issued, and none is
  found. The agent's own shell is asked for it every way it could look, and has nothing.
  """

  use Troupe.Worker.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox, as: DatabaseSandbox
  alias Troupe.Plane.Admin
  alias Troupe.Plane.Audit
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{FakeGitHub, Fleet, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Sandbox
  alias Troupe.Worker.GitCredentials
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.PlaneHelper
  alias Troupe.Worker.Session.Clone

  @moduletag timeout: 180_000

  @app_id 5150
  @installation 99_001
  @owner "idp|ada"
  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @repository %{"owner" => "example-org", "name" => "widgets", "ref" => nil}

  setup context do
    context = requires_tier(context)

    unless Process.whereis(Repo),
      do: flunk("no database for the plane; bring one up with `scripts/dev-up`")

    owner = DatabaseSandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> DatabaseSandbox.stop_owner(owner) end)

    # Every command in the sandbox, as a pod's configuration has it, where bubblewrap is
    # here to start one; without it the clone still runs, outside, as on a laptop.
    if Sandbox.available?() do
      Application.put_env(:troupe_core, :sandbox, :always)
      on_exit(fn -> Application.delete_env(:troupe_core, :sandbox) end)
    end

    # The App's key in a transit key of this run's own.
    key_name = "troupe-github-app-worker-test-#{System.unique_integer([:positive])}"
    transit = Application.get_env(:troupe_plane, :transit, [])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :github_key, key_name))

    on_exit(fn ->
      Application.put_env(:troupe_plane, :transit, transit)
      delete_transit_key(transit, key_name)
    end)

    # The plane, and this pod's link to it.
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
    eventually(fn -> Link.connected?() end)

    # GitHub, with the App installed on example-org for widgets alone, and the repository.
    fake = FakeGitHub.start()
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    FakeGitHub.app(fake, @app_id, key)
    FakeGitHub.install(fake, @installation, @app_id, "example-org", ["widgets"])
    FakeGitHub.repo(fake, "example-org/widgets", repository(context.base))

    {:ok, _} =
      Fleet.put_profile(%{name: "dev", spec: %{"egress" => %{"gitHosts" => [fake.host]}}})

    {:ok, _} =
      Admin.github_put(@root, %{
        "app_id" => @app_id,
        "api_url" => fake.api_url,
        "installations" => [%{"owner" => "example-org", "installation_id" => @installation}],
        "private_key" =>
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      })

    # The session, on its row as the plane's, held by this pod.
    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_subject: @owner,
        profile: "dev",
        epoch: 1,
        repository: @repository
      })

    hold(context.session_id)

    on_exit(fn ->
      try do
        Troupe.cancel(context.session_id)
        Troupe.stop_session(context.session_id)
      catch
        :exit, _ -> :ok
      end
    end)

    Map.merge(context, %{fake: fake})
  end

  test "the session starts from a clone, and its token is nowhere the session or a log can see",
       context do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    test = self()

    log =
      capture_log([level: :debug], fn ->
        {:ok, _} =
          Sessions.activate(
            context.session_id,
            activation(context,
              owner_subject: @owner,
              steps: [
                {:tools, [{"shell", %{"command" => "env"}}]},
                {:tools,
                 [
                   {"shell",
                    %{
                      "command" =>
                        "cat .git/config; git config --list --show-origin; git remote -v"
                    }}
                 ]},
                {:tools,
                 [{"shell", %{"command" => "ls -la; cat README.md; git log --oneline -1"}}]},
                {:tools,
                 [
                   {"shell",
                    %{
                      "command" =>
                        "grep -rs ghs_ . /tmp; cat /proc/*/environ 2>/dev/null | tr '\\0' '\\n' | grep -i -e token -e ghs_; echo searched"
                    }}
                 ]},
                {:tools,
                 [
                   {"shell",
                    %{"command" => "GIT_TERMINAL_PROMPT=0 git fetch origin 2>&1; echo fetched=$?"}}
                 ]},
                {:text, "done"}
              ]
            ) ++ [repository: @repository]
          )

        send(test, {:results, tool_results(context.session_id, "shell", "look for the token", 5)})
      end)

    assert_received {:results, [env, config, listing, search, fetch]}

    # The clone is the workspace, at the repository's head.
    assert File.read!(Path.join(context.workspace, "README.md")) =~ "widgets"
    assert listing["content"] =~ "README.md"
    assert listing["content"] =~ "the first commit"

    # Its .git names the remote, and no credential.
    git_config = File.read!(Path.join(context.workspace, ".git/config"))
    assert git_config =~ "#{context.fake.url}/example-org/widgets.git"
    refute git_config =~ "x-access-token"
    refute git_config =~ "helper"
    assert config["content"] =~ "remote.origin.url=#{context.fake.url}/example-org/widgets.git"

    # The agent's shell has no way to it: not its environment, not a file, not a process,
    # and git there cannot authenticate.
    refute env["content"] =~ "TROUPE_GIT_TOKEN"
    assert search["content"] =~ "searched"
    refute search["content"] =~ "ghs_"
    assert fetch["content"] =~ "fetched="
    refute fetch["content"] =~ "fetched=0"

    # One token was minted, for this session's one repository, read-only.
    assert [token] = FakeGitHub.tokens(context.fake)
    assert String.starts_with?(token, "ghs_") and byte_size(token) > 20

    assert %{repositories: ["widgets"], permissions: %{"contents" => "read"}} =
             FakeGitHub.token(context.fake, token)

    # And it is nowhere.
    {:ok, _} = Sessions.dormant(context.session_id)

    places = %{
      "the log, at debug" => log,
      "every tool result" => inspect([env, config, listing, search, fetch]),
      "every event in storage" => inspect(sealed_events(context), limit: :infinity),
      "the plane's audit trail" => inspect(Audit.list(limit: 1_000), limit: :infinity),
      "the plane's session row" => inspect(PlaneSessions.get(context.session_id)),
      "the link's state" => inspect(:sys.get_status(Link), limit: :infinity),
      "the credentials' state" => inspect(:sys.get_status(GitCredentials), limit: :infinity)
    }

    # The search is over something: the run was logged, at debug, plane and pod both.
    assert log =~ "cloned example-org/widgets for #{context.session_id}"
    assert log =~ "github_app"

    for {where, text} <- places do
      refute text =~ token, "the token is in #{where}"
    end

    # The workspace went to storage at dormancy and the pod's copy is gone; what it held
    # before then was searched by the agent's own grep above, and is the archive's now.
    assert GitCredentials.sessions() == []
    finish()
  end

  test "an activation that comes back restores the tree, and its next use gets a new token",
       context do
    {:ok, _} = activate_with_repository(context)
    assert [first] = FakeGitHub.tokens(context.fake)
    assert {:ok, _} = Sessions.dormant(context.session_id)
    assert GitCredentials.sessions() == []

    # Back from the archive, not cloned a second time: GitHub is not asked.
    {:ok, _} = activate_with_repository(context, epoch: 2)
    assert File.read!(Path.join(context.workspace, "README.md")) =~ "widgets"
    assert FakeGitHub.tokens(context.fake) == [first]

    # The activation holds none of the last one's; the first use asks for a new one.
    assert {:ok, %{"token" => second}} = GitCredentials.credential(context.session_id)
    assert second != first
    assert {:ok, %{"token" => ^second}} = GitCredentials.credential(context.session_id)

    # And one about to run out is not handed out again.
    later = System.system_time(:second) + 3_400
    assert {:ok, %{"token" => third}} = GitCredentials.credential(context.session_id, now: later)
    assert third not in [first, second]
    finish()
  end

  test "a clone that cannot be made fails the activation, says why, and leaves nothing",
       context do
    # The installation no longer covers the repository the session names.
    FakeGitHub.install(context.fake, @installation, @app_id, "example-org", ["gadgets"])

    log =
      capture_log(fn ->
        assert {:error, {:clone_failed, "example-org/widgets", reason}} =
                 activate_with_repository(context)

        send(self(), {:reason, reason})
      end)

    assert_received {:reason, {:refused, "unavailable", why}}
    assert why =~ "would not narrow a token to example-org/widgets"
    assert log =~ "could not clone example-org/widgets"
    refute File.exists?(context.workspace) and File.ls!(context.workspace) != []
    finish()
  end

  test "the clone's command line carries no token" do
    credential = %{
      "token" => "ghs_secretsecretsecret",
      "url" => "https://github.com/example-org/widgets.git",
      "ref" => "main",
      "username" => "x-access-token"
    }

    argv = Clone.argv(credential)
    refute Enum.any?(argv, &(&1 =~ "ghs_secretsecretsecret"))
    assert "credential.helper=" in argv
    assert Enum.any?(argv, &String.starts_with?(&1, "credential.https://github.com.helper="))

    assert ["--branch", "main", "--", "https://github.com/example-org/widgets.git", "."] ==
             Enum.take(argv, -5)

    finish()
  end

  # -- helpers ------------------------------------------------------------------

  # The session placed on this pod, and still there once the plane has reconciled the pod's
  # enrolment: the plane asks a pod that enrols what it holds and marks dormant whatever it
  # placed there that the answer leaves out, which for a session placed a moment before the
  # answer arrives is this one. Placed again if so; the reconciliation happens once.
  defp hold(session_id) do
    [pod] = Fleet.list_workers("dev")

    eventually(fn ->
      {:ok, _} = PlaneSessions.place(session_id, pod)
      Process.sleep(300)
      PlaneSessions.get(session_id).worker_id == pod.id
    end)
  end

  defp activate_with_repository(context, opts \\ []) do
    Sessions.activate(
      context.session_id,
      activation(context, Keyword.merge([owner_subject: @owner], opts)) ++
        [repository: @repository]
    )
  end

  defp tool_results(session_id, name, input, count) do
    :ok = Troupe.subscribe(session_id)
    Troupe.send_input(session_id, input)

    for _ <- 1..count do
      receive do
        {:troupe_event, ^session_id,
         %Event{type: "tool_call_completed", data: %{"name" => ^name} = completed}} ->
          completed
      after
        60_000 -> flunk("no #{name} result")
      end
    end
  after
    Troupe.unsubscribe(session_id)
  end

  # A repository with one commit, as the fake serves it.
  defp repository(base) do
    path = Path.join(base, "upstream-widgets")
    File.mkdir_p!(path)
    git!(path, ["init", "--quiet", "--initial-branch=main"])
    File.write!(Path.join(path, "README.md"), "# widgets\n")
    git!(path, ["add", "README.md"])

    git!(path, [
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

  defp git!(dir, args), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

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

  # The plane's connection is stopped through its own loop rather than killed inside a
  # query on the shared sandbox connection (`PlaneHelper`), and the link before it.
  defp finish do
    stop_supervised!(Link)
    PlaneHelper.stop_plane()
  end
end
