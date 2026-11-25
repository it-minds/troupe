defmodule Troupe.Plane.GitHubRepositoriesTest do
  @moduledoc """
  A session holds several GitHub repositories (#1207): named at creation as
  `repositories`, attached and taken off later by its owner (`session.repository.add` and
  `.remove`), each in its own directory of the workspace with its own token and its own
  record, within the profile's `spec.github` and its `maxRepositories`.

  Against the development OpenBao's transit engine, as `Troupe.Plane.GitHubTest` is: the
  App's key is imported there, and a fake GitHub (`Troupe.Plane.FakeGitHub`) holds the
  installation and mints the narrowed tokens.
  """

  use Troupe.Plane.DataCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Plane.{Admin, Audit, FakeGitHub, FakePod, Fleet, GitHub, Harness, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Protocol.Error

  @moduletag timeout: 120_000

  @app_id 4545
  @installation 77_003

  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @widgets %{"owner" => "example-org", "name" => "widgets", "ref" => "main"}
  @gadgets %{"owner" => "example-org", "name" => "gadgets", "ref" => nil}

  setup do
    unless bao_reachable?(), do: flunk("no OpenBao; bring it up with `scripts/dev-up`")

    name = "troupe-github-repositories-test-#{System.unique_integer([:positive])}"
    transit = Application.get_env(:troupe_plane, :transit, [])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :github_key, name))

    on_exit(fn ->
      Application.put_env(:troupe_plane, :transit, transit)
      delete_transit_key(transit, name)
    end)

    fake = FakeGitHub.start()
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    FakeGitHub.app(fake, @app_id, key)

    FakeGitHub.install(fake, @installation, @app_id, "example-org", ["widgets", "gadgets", "docs"])

    profile(fake, %{})

    {:ok, _} =
      Admin.github_put(@root, %{
        "app_id" => @app_id,
        "api_url" => fake.api_url,
        "installations" => [%{"owner" => "example-org", "installation_id" => @installation}],
        "private_key" =>
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      })

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team =
      team_with_grant("engineering", "dev",
        name: "engineering",
        budget_micros: 0,
        github: %{"repositories" => ["example-org/widgets", "example-org/gadgets"]}
      )

    ada = person("ada@example.test", ["engineering"])
    bea = person("bea@example.test", ["engineering"])

    %{fake: fake, team: team, ada: ada, bea: bea, as_ada: as(ada), port: Listener.port()}
  end

  describe "at creation" do
    test "two repositories are both held, the first at the root and the next in owner/name, " <>
           "and the pod is handed both",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      assert {:ok, %{"session_id" => id}} =
               create(context, %{"repositories" => ["example-org/widgets", @gadgets]})

      assert_receive {:pushed, "session.activate", %{"session_id" => ^id} = params}, 5_000
      assert params["repository"] == %{@widgets | "ref" => nil}

      assert [%{"path" => ".", "name" => "widgets"}, %{"path" => "example-org/gadgets"}] =
               params["repositories"]

      refute Enum.any?(params["repositories"], &Map.has_key?(&1, "github"))

      row = Sessions.get(id)
      assert row.repository == %{@widgets | "ref" => nil}
      assert [first, second] = row.repositories
      assert first["attached_by"] == context.ada.subject
      assert second["path"] == "example-org/gadgets"

      assert {:ok, %{"repositories" => [_, %{"path" => "example-org/gadgets"}]}} =
               Harness.call("session.get", %{"session_id" => id}, context.as_ada)
    end

    test "a profile with no spec.github is offered none and is refused a list, saying why; " <>
           "repository and repositories together are refused",
         context do
      profile(context.fake, nil)
      {:ok, %{"profiles" => [listed]}} = Harness.call("profiles.list", %{}, context.as_ada)
      assert listed["max_repositories"] == nil

      assert {:error, %Error{message: "invalid_params", data: data}} =
               create(context, %{"repositories" => ["example-org/widgets"]})

      assert data.field == "repositories"

      assert data.reason ==
               "the profile dev has no spec.github, so its sessions hold no GitHub repository " <>
                 "beyond the one they were created on"

      assert {:error, %Error{data: %{field: "repositories", reason: both}}} =
               create(context, %{
                 "repository" => "example-org/widgets",
                 "repositories" => ["example-org/gadgets"]
               })

      assert both =~ "not both"

      # The one repository a session was always created on still clones there.
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      assert {:ok, %{"session_id" => _id}} =
               create(context, %{"repository" => "example-org/widgets"})
    end

    test "is held to the profile's maxRepositories and the team's list, naming them", context do
      profile(context.fake, %{"maxRepositories" => 1})

      {:ok, %{"profiles" => [listed]}} = Harness.call("profiles.list", %{}, context.as_ada)
      assert listed["max_repositories"] == 1

      {:ok, %{"teams" => [team]}} = Harness.call("teams.list", %{}, context.as_ada)
      assert team["repositories"] == ["example-org/widgets", "example-org/gadgets"]

      assert {:error, %Error{data: %{field: "repositories", reason: reason}}} =
               create(context, %{"repositories" => ["example-org/widgets", "example-org/gadgets"]})

      assert reason ==
               "a session on the profile dev holds at most 1 repository " <>
                 "(spec.github.maxRepositories)"

      profile(context.fake, %{})

      assert {:error, %Error{data: %{reason: unlisted}}} =
               create(context, %{"repositories" => ["example-org/widgets", "example-org/docs"]})

      assert unlisted =~ "example-org/docs: the team engineering does not list example-org/docs"

      assert {:error, %Error{data: %{reason: twice}}} =
               create(context, %{"repositories" => ["example-org/widgets", "Example-Org/widgets"]})

      assert twice =~ "holds example-org/widgets already"
    end

    test "a fork starts on its parent's repositories", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      parent = held_session(context, [@widgets, @gadgets], state: "active")
      {:ok, _} = Sessions.seal(parent.id, %{last_seq: 12, head_hash: "sha256:whatever"})

      assert {:ok, %{"session_id" => fork}} =
               Harness.call("session.fork", %{"session_id" => parent.id}, context.as_ada)

      assert [%{"name" => "widgets", "path" => "."}, %{"name" => "gadgets"}] =
               Sessions.get(fork).repositories

      assert_receive {:pushed, "session.activate", %{"session_id" => ^fork} = params}, 5_000
      assert length(params["repositories"]) == 2
    end
  end

  describe "attaching" do
    test "by the owner, to a running session: the pod clones it, the row and the trail say so",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      {:ok, %{"session_id" => id}} = create(context, %{"repositories" => ["example-org/widgets"]})
      assert_receive {:pushed, "session.activate", %{"session_id" => ^id}}, 5_000

      assert {:ok, row} = add(id, "example-org/gadgets", context.ada)
      assert [_, %{"path" => "example-org/gadgets", "attached_by" => by}] = row["repositories"]
      assert by == context.ada.subject

      assert_receive {:pushed, "session.repository.add", pushed}, 5_000
      assert pushed["session_id"] == id
      assert pushed["repository"]["path"] == "example-org/gadgets"
      assert pushed["by"] == context.ada.subject

      assert [audit] = audit_rows(id, "session.repository.add")
      assert audit.detail["repository"] == "example-org/gadgets"

      # Held once, and within the cap.
      assert {:error, %Error{data: %{field: "repository", reason: again}}} =
               add(id, "example-org/gadgets", context.ada)

      assert again =~ "holds example-org/gadgets already"

      profile(context.fake, %{"maxRepositories" => 2})

      assert {:error, %Error{data: %{reason: capped}}} = add(id, "example-org/docs", context.ada)
      assert capped =~ "holds at most 2 repositories (spec.github.maxRepositories)"
    end

    test "is the owner's: somebody who steers the session is refused", context do
      session = held_session(context, [@widgets], visibility: "team")

      assert {:error, %Error{message: "forbidden", data: %{required_role: "owner"}}} =
               add(session.id, "example-org/gadgets", context.bea)

      assert {:error, %Error{message: "forbidden"}} =
               remove(session.id, "example-org/widgets", context.bea)

      assert length(Sessions.get(session.id).repositories) == 1
    end

    test "to a dormant session writes the row only, for its next wake to clone", context do
      session = held_session(context, [@widgets])

      assert {:ok, %{"repositories" => [_, _]}} =
               add(session.id, "example-org/gadgets", context.ada)

      refute_receive {:pushed, "session.repository.add", _}, 200
    end

    test "on a profile with no spec.github is refused saying why", context do
      profile(context.fake, nil)
      session = held_session(context, [@widgets])

      assert {:error, %Error{data: %{field: "repository", reason: reason}}} =
               add(session.id, "example-org/gadgets", context.ada)

      assert reason =~ "the profile dev has no spec.github"
    end

    test "that the pod could not clone leaves the row as it was", context do
      _pod =
        FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0",
          refuse: %{
            "session.repository.add" => %{
              "code" => -32_010,
              "message" => "unavailable",
              "data" => %{"reason" => "git said: repository not found"}
            }
          }
        )

      {:ok, %{"session_id" => id}} = create(context, %{"repositories" => ["example-org/widgets"]})

      assert {:error, %Error{message: "unavailable", data: %{reason: reason}}} =
               add(id, "example-org/gadgets", context.ada)

      assert reason ==
               "the pod could not clone example-org/gadgets: git said: repository not found"

      assert [%{"name" => "widgets"}] = Sessions.get(id).repositories
      assert audit_rows(id, "session.repository.add") == []
    end
  end

  describe "taking one off" do
    test "while the pod pushes to it is busy, and the row keeps it", context do
      _pod =
        FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0",
          refuse: %{
            "session.repository.remove" => %{
              "code" => -32_006,
              "message" => "conflict",
              "data" => %{"reason" => "busy", "detail" => "example-org/gadgets has a push going"}
            }
          }
        )

      {:ok, %{"session_id" => id}} =
        create(context, %{"repositories" => ["example-org/widgets", "example-org/gadgets"]})

      assert {:error, %Error{message: "conflict", data: %{reason: "busy", detail: detail}}} =
               remove(id, "example-org/gadgets", context.ada)

      assert detail == "example-org/gadgets has a push going"
      assert length(Sessions.get(id).repositories) == 2
    end

    test "deletes it on the pod and from the row; the one created on goes only beside another",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      {:ok, %{"session_id" => id}} =
        create(context, %{"repositories" => ["example-org/widgets", "example-org/gadgets"]})

      assert {:ok, %{"repositories" => [%{"name" => "widgets"}]}} =
               remove(id, "example-org/gadgets", context.ada)

      assert_receive {:pushed, "session.repository.remove", %{"repository" => removed}}, 5_000
      assert removed["path"] == "example-org/gadgets"
      assert [_audit] = audit_rows(id, "session.repository.remove")

      assert {:error, %Error{message: "conflict", data: %{reason: alone}}} =
               remove(id, "example-org/widgets", context.ada)

      assert alone =~ "taken off only while another remains"

      assert {:error, %Error{data: %{field: "repository", reason: unheld}}} =
               remove(id, "example-org/docs", context.ada)

      assert unheld =~ "holds no repository example-org/docs"

      # Beside another, the first goes too, and the next is the row's repository.
      {:ok, _} = add(id, "example-org/gadgets", context.ada)
      assert {:ok, _} = remove(id, "example-org/widgets", context.ada)
      assert Sessions.get(id).repository == %{@gadgets | "ref" => nil}
    end
  end

  describe "on the pod" do
    test "each repository has a token of its own, for it alone, audited under its name; " <>
           "with two and none named the pod is told to name one",
         context do
      worker = control(context.port, "troupe-w-dev-0")
      [pod] = Fleet.list_workers("dev")
      session = held_session(context, [@widgets, @gadgets])
      {:ok, _} = Sessions.place(session.id, pod)
      answer_index(worker, [session.id])

      log =
        capture_log([level: :debug], fn ->
          for name <- ["example-org/widgets", "example-org/gadgets"] do
            assert %{"result" => credential} =
                     call(worker, "git.credential", %{
                       "session_id" => session.id,
                       "repository" => name
                     })

            send(self(), {:credential, credential})
          end
        end)

      assert_received {:credential, %{"path" => ".", "repository" => "example-org/widgets"} = one}

      assert_received {:credential,
                       %{"path" => "example-org/gadgets", "repository" => "example-org/gadgets"} =
                         two}

      refute log =~ one["token"]
      refute log =~ two["token"]

      assert [["widgets"], ["gadgets"]] =
               context.fake |> FakeGitHub.requests() |> Enum.map(& &1.repositories)

      audits = Enum.filter(Audit.list(kind: "github"), &(&1.action == "github.token"))

      assert Enum.sort(Enum.map(audits, & &1.subject_id)) ==
               ["example-org/gadgets", "example-org/widgets"]

      assert %{"error" => %{"data" => %{"reason" => reason}}} =
               call(worker, "git.credential", %{"session_id" => session.id})

      assert reason ==
               "this session holds example-org/widgets and example-org/gadgets: name the repository"
    end

    test "a record is one repository's, the first's mirrored as the row's github", context do
      session = held_session(context, [@widgets, @gadgets])
      base = String.duplicate("a", 40)
      other = String.duplicate("b", 40)

      assert {:error, ambiguous} = GitHub.record(session, %{"base" => base}, "worker:test")
      assert ambiguous =~ "name the repository"

      assert {:ok, %{github: %{"base" => ^other}}} =
               GitHub.record(
                 session,
                 %{"base" => other, "repository" => "example-org/gadgets"},
                 "worker:test"
               )

      assert Sessions.get(session.id).github == nil

      {:ok, _} =
        GitHub.record(session, %{"base" => base, "repository" => "example-org/widgets"}, "w")

      row = Sessions.get(session.id)
      assert row.github == %{"base" => base}

      assert [%{"github" => %{"base" => ^base}}, %{"github" => %{"base" => ^other}}] =
               row.repositories
    end
  end

  # The migration's backfill, run over a row as it was before it: one repository, at the
  # workspace's root, with its record.
  test "a session from before the list holds its one repository at the root", context do
    {:ok, row} =
      Sessions.create(%{
        id: "s-before-#{System.unique_integer([:positive])}",
        owner_subject: context.ada.subject,
        profile: "dev",
        repository: @widgets,
        github: %{"branch" => "troupe/x"}
      })

    assert Session.repositories(row) == [
             Map.merge(@widgets, %{"path" => ".", "github" => %{"branch" => "troupe/x"}})
           ]

    [migration] =
      Path.wildcard(
        Path.expand("../../../priv/repo/migrations/*_session_repositories.exs", __DIR__)
      )

    [_whole, statement] = Regex.run(~r/execute\("""\n(.*?)"""\)/s, File.read!(migration))
    Repo.query!(statement)

    assert Sessions.get(row.id).repositories == [
             Map.merge(@widgets, %{"path" => ".", "github" => %{"branch" => "troupe/x"}})
           ]
  end

  # -- helpers ------------------------------------------------------------------

  defp profile(fake, github) do
    spec = %{"egress" => %{"gitHosts" => [fake.host]}}
    spec = if github, do: Map.put(spec, "github", github), else: spec
    {:ok, _} = Fleet.put_profile(%{name: "dev", spec: spec})
  end

  defp create(context, params),
    do: Harness.call("session.create", Map.put(params, "profile", "dev"), context.as_ada)

  defp add(id, repository, user),
    do:
      Harness.call(
        "session.repository.add",
        %{"session_id" => id, "repository" => repository},
        as(user)
      )

  defp remove(id, repository, user),
    do:
      Harness.call(
        "session.repository.remove",
        %{"session_id" => id, "repository" => repository},
        as(user)
      )

  defp as(user), do: %{user: user, platform_admin?: false}

  defp held_session(context, repositories, opts \\ []) do
    entries =
      repositories
      |> Enum.with_index()
      |> Enum.map(fn
        {repository, 0} -> Map.put(repository, "path", ".")
        {repository, _n} -> Map.put(repository, "path", GitHub.full(repository))
      end)

    {:ok, session} =
      %{
        id: "s-held-#{System.unique_integer([:positive])}",
        owner_id: context.ada.id,
        owner_subject: context.ada.subject,
        team_id: context.team.id,
        profile: "dev",
        visibility: Keyword.get(opts, :visibility, "private"),
        state: Keyword.get(opts, :state, "dormant"),
        epoch: 1
      }
      |> Map.merge(Session.holding(entries))
      |> Sessions.create()

    session
  end

  defp audit_rows(id, action) do
    Repo.all(from(a in Audit.Event, where: a.action == ^action and a.subject_id == ^id))
  end

  # -- the control channel, as a pod speaks it ------------------------------------

  defp control(port, pod_name) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])

    send_line(socket, 0, "enrol", %{
      "token" => FakePod.token("dev-token"),
      "pod_name" => pod_name,
      "capacity" => 4,
      "disk_total_bytes" => 1_000
    })

    %{"result" => _} = receive_answer(socket, 0)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp answer_index(socket, held, attempts \\ 8)
  defp answer_index(_socket, _held, 0), do: flunk("no session.index request arrived")

  defp answer_index(socket, held, attempts) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)

    case Jason.decode!(line) do
      %{"method" => "session.index", "id" => id} ->
        sessions = Enum.map(held, &%{"id" => &1})
        reply = %{"jsonrpc" => "2.0", "id" => id, "result" => %{"sessions" => sessions}}
        :ok = :gen_tcp.send(socket, [Jason.encode!(reply), ?\n])

      _other ->
        answer_index(socket, held, attempts - 1)
    end
  end

  defp call(socket, method, params) do
    id = System.unique_integer([:positive])
    send_line(socket, id, method, params)
    receive_answer(socket, id)
  end

  defp send_line(socket, id, method, params) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    :ok = :gen_tcp.send(socket, [Jason.encode!(message), ?\n])
  end

  defp receive_answer(socket, id) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)

    case Jason.decode!(line) do
      %{"id" => ^id} = answer ->
        answer

      %{"id" => push_id, "method" => _method} ->
        reply = %{"jsonrpc" => "2.0", "id" => push_id, "result" => %{"sessions" => []}}
        :ok = :gen_tcp.send(socket, [Jason.encode!(reply), ?\n])
        receive_answer(socket, id)

      _notification ->
        receive_answer(socket, id)
    end
  end

  # -- the development OpenBao, with the root token ---------------------------------

  defp delete_transit_key(transit, name) do
    mount = transit[:mount] || "transit"

    Req.request(
      method: :post,
      url: "#{transit[:address]}/v1/#{mount}/keys/#{name}/config",
      headers: [{"x-vault-token", transit[:token]}],
      json: %{"deletion_allowed" => true},
      retry: false
    )

    Req.request(
      method: :delete,
      url: "#{transit[:address]}/v1/#{mount}/keys/#{name}",
      headers: [{"x-vault-token", transit[:token]}],
      retry: false
    )
  end

  defp bao_reachable? do
    address = Application.get_env(:troupe_plane, :transit, [])[:address]

    is_binary(address) and
      match?({:ok, %{status: 200}}, Req.request(url: address <> "/v1/sys/health", retry: false))
  rescue
    _ -> false
  end
end
