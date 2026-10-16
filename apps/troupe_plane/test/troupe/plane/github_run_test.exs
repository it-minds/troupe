defmodule Troupe.Plane.GitHubRunTest do
  @moduledoc """
  The plane's half of a session's fix loop on GitHub (#147 slice 2): what a worker
  profile grants a session's token, the fix loop's token itself, and the record of what
  the session did there, which the pod reports a step at a time.

  Against the development OpenBao's transit engine and `Troupe.Plane.FakeGitHub`, as
  `github_test.exs` is; the pod's own half, and the loop end to end, are the worker's
  `github_fix_loop_test.exs`.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, FakeGitHub, FakePod, Fleet, GitHub, Harness, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Triggers
  alias Troupe.Plane.Triggers.Run

  @moduletag timeout: 120_000

  @app_id 4343
  @installation 77_002
  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @grants %{"contents" => "write", "pull_requests" => "write", "checks" => "read"}

  @base String.duplicate("a", 40)
  @tree String.duplicate("b", 40)
  @one String.duplicate("1", 40)
  @two String.duplicate("2", 40)
  @three String.duplicate("3", 40)

  setup do
    unless bao_reachable?(), do: flunk("no OpenBao; bring it up with `scripts/dev-up`")

    name = "troupe-github-run-test-#{System.unique_integer([:positive])}"
    transit = Application.get_env(:troupe_plane, :transit, [])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :github_key, name))

    on_exit(fn ->
      Application.put_env(:troupe_plane, :transit, transit)
      delete_transit_key(transit, name)
    end)

    fake = FakeGitHub.start()
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    FakeGitHub.app(fake, @app_id, key)
    FakeGitHub.install(fake, @installation, @app_id, "example-org", ["widgets"])

    {:ok, _} = profile(fake, @grants)

    {:ok, _} =
      Admin.github_put(@root, %{
        "app_id" => @app_id,
        "api_url" => fake.api_url,
        "installations" => [%{"owner" => "example-org", "installation_id" => @installation}],
        "private_key" =>
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      })

    # A team that lists the repository, as a team's must for its sessions to name one.
    team =
      team_with_grant("fixers", "dev",
        name: "fixers",
        github: %{"repositories" => ["example-org/widgets"]}
      )

    {:ok, session} =
      Sessions.create(%{
        id: "s-gh-run-#{System.unique_integer([:positive])}",
        owner_subject: "idp|ada",
        team_id: team.id,
        profile: "dev",
        repository: %{"owner" => "example-org", "name" => "widgets"}
      })

    %{fake: fake, session: session, team: team}
  end

  describe "what a worker profile grants" do
    test "is GitHub's permissions by name, and anything else is refused, naming it", context do
      refused = [
        %{"permissions" => %{"contents" => "Write"}},
        %{"permissions" => %{"administration" => "write"}},
        %{"permissions" => %{"checks" => "write"}},
        %{"permissions" => "everything"},
        %{"scopes" => ["repo"]},
        "write"
      ]

      for github <- refused do
        assert {:error, changeset} = profile(context.fake, nil, github),
               "#{inspect(github)} was taken"

        assert [{"github" <> _, _}] = Keyword.get_values(changeset.errors, :spec),
               "#{inspect(changeset.errors)}"
      end

      # What was refused was not saved; what the profile had stands.
      assert GitHub.grants("dev") == @grants

      {:ok, _} = profile(context.fake, nil, nil)
      assert GitHub.grants("dev") == %{"contents" => "read"}
      assert GitHub.grants(nil) == %{"contents" => "read"}
    end
  end

  describe "the fix loop's token" do
    test "carries what the profile grants and nothing more, and the clone's stays read-only",
         context do
      assert {:ok, write} = GitHub.credential(context.session, access: :write)
      assert {:ok, read} = GitHub.credential(context.session)

      assert [%{permissions: @grants}, %{permissions: %{"contents" => "read"}}] =
               FakeGitHub.requests(context.fake)

      assert write["permissions"] == @grants
      assert write["api_url"] == context.fake.api_url
      assert read["permissions"] == %{"contents" => "read"}
      # Each says where it is revoked; only the fix loop's carries the policy a push checks.
      assert read["api_url"] == context.fake.api_url
      refute Map.has_key?(read, "policy")

      assert write["policy"] == %{
               "allow_public" => false,
               "deny_paths" => Troupe.PushPaths.defaults(),
               "max_pushes" => nil
             }

      assert Enum.all?(FakeGitHub.requests(context.fake), &(&1.repositories == ["widgets"]))
    end

    test "is refused where the profile grants nothing to write with, or the API is not declared",
         context do
      {:ok, _} = profile(context.fake, nil, nil)
      assert {:error, reason} = GitHub.credential(context.session, access: :write)
      assert GitHub.explain(reason) =~ "grants GitHub nothing to write with"

      # An App whose API is on a host of its own, which the profile does not declare: refused
      # before GitHub is asked anything.
      {:ok, _} = Admin.github_put(@root, %{"api_url" => "https://api.example.test"})

      {:ok, _} =
        Fleet.put_profile(%{
          name: "dev",
          spec: %{
            "egress" => %{"gitHosts" => ["example.test"]},
            "github" => %{"permissions" => @grants}
          }
        })

      assert {:error, reason} = GitHub.credential(context.session, access: :write)
      assert GitHub.explain(reason) =~ "does not declare api.example.test, where GitHub's API is"
      assert FakeGitHub.requests(context.fake) == []
    end

    test "can no longer push once three red rounds have stopped the session", context do
      push(context.session, @one)
      record!(context.session, %{"pull_request" => pull(context, 1)})

      for {commit, n} <- [{@one, 1}, {@two, 2}, {@three, 3}] do
        if n > 1, do: push(context.session, commit)

        assert {:ok, %{stopped_now: stopped_now}} =
                 GitHub.record(fresh(context.session), %{"round" => red(commit)}, "worker:test")

        assert stopped_now == (n == 3)
      end

      assert {:ok, credential} = GitHub.credential(fresh(context.session), access: :write)
      assert credential["permissions"] == Map.put(@grants, "contents", "read")
    end
  end

  describe "a session's record" do
    test "keeps where it started, its troupe branch, its pull request and each round, " <>
           "and audits each step",
         context do
      assert {:ok, %{github: %{"base" => @base}}} =
               GitHub.record(context.session, %{"base" => @base}, "worker:test")

      push(context.session, @one)
      record!(context.session, %{"pull_request" => pull(context, 1)})

      assert {:ok, %{github: github, stopped_now: false}} =
               GitHub.record(fresh(context.session), %{"round" => red(@one)}, "worker:test")

      assert %{
               "base" => @base,
               "branch" => "troupe/fix-widgets",
               "commit" => @one,
               "tree" => @tree,
               "pushes" => 1,
               "pull_request" => %{"number" => 1},
               "rounds" => [%{"commit" => @one, "state" => "red", "failing" => ["test"]}]
             } = github

      # Once a commit: the same round again changes nothing.
      assert {:ok, %{github: ^github}} =
               GitHub.record(fresh(context.session), %{"round" => red(@one)}, "worker:test")

      actions =
        Audit.list(kind: "github") |> Enum.map(& &1.action) |> Enum.reject(&(&1 == "github.put"))

      assert Enum.sort(actions) == ["github.pull_request", "github.push", "github.round"]
      [push] = Audit.list(kind: "github") |> Enum.filter(&(&1.action == "github.push"))
      assert push.actor == "worker:test"
      assert push.on_behalf_of == "idp|ada"
      assert push.subject_id == "example-org/widgets"

      assert push.detail == %{
               "branch" => "troupe/fix-widgets",
               "commit" => @one,
               "session_id" => context.session.id
             }

      # Every listing of the session carries it, and so does its run's.
      run = %Run{fired_at: DateTime.utc_now(), state: "created", session_id: context.session.id}
      assert %{"github" => ^github} = Triggers.run_json(run, fresh(context.session))

      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      ada = person("ada@example.test", ["engineering"])

      {:ok, hers} =
        Sessions.create(%{
          id: "s-gh-hers-#{System.unique_integer([:positive])}",
          owner_id: ada.id,
          owner_subject: ada.subject,
          profile: "dev",
          repository: %{"owner" => "example-org", "name" => "widgets"}
        })

      push(hers, @two)

      assert {:ok, %{"github" => %{"branch" => "troupe/fix-widgets", "commit" => @two}}} =
               Harness.call("session.get", %{"session_id" => hers.id}, %{
                 user: ada,
                 platform_admin?: false
               })
    end

    test "refuses what is not the session's own, and keeps nothing of it", context do
      session = context.session
      refuse = &assert({:error, _} = GitHub.record(fresh(session), &1, "worker:test"))

      # A pull request or a round before there is a push.
      refuse.(%{"pull_request" => pull(context, 1)})
      refuse.(%{"round" => red(@one)})

      # A branch outside troupe/, or one that could be read as something else.
      for branch <- [
            "main",
            "refs/heads/main",
            "troupe/",
            "troupe/../main",
            "troupe/x.lock",
            "troupe/a@{1}",
            "-troupe/x"
          ] do
        refuse.(%{"push" => %{"branch" => branch, "commit" => @one, "tree" => @tree}})
      end

      refuse.(%{"push" => %{"branch" => "troupe/fix", "commit" => "HEAD", "tree" => @tree}})
      push(session, @one)

      # Then another branch, a pull request in another repository, a round on a commit that
      # is not its last, a second starting point, a key it does not take.
      refuse.(%{"push" => %{"branch" => "troupe/other", "commit" => @two, "tree" => @tree}})

      refuse.(%{
        "pull_request" => %{
          "number" => 2,
          "url" => "#{context.fake.url}/example-org/gadgets/pull/2"
        }
      })

      refuse.(%{
        "pull_request" => %{
          "number" => 2,
          "url" => "https://example.com/example-org/widgets/pull/2"
        }
      })

      record!(session, %{"pull_request" => pull(context, 1)})
      refuse.(%{"pull_request" => pull(context, 2)})
      refuse.(%{"round" => red(@two)})
      record!(session, %{"base" => @base})
      refuse.(%{"base" => @two})
      refuse.(%{"merge" => true})

      github = Sessions.get(session.id).github
      assert github["branch"] == "troupe/fix-widgets"
      assert github["pull_request"] == pull(context, 1)
      assert github["rounds"] in [nil, []]
      assert github["base"] == @base
    end

    test "over the control channel, only for a session the pod holds", context do
      start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
      start_supervised!(Connections)
      start_supervised!(Troupe.Plane.Singleton)
      start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

      worker = control(Listener.port(), "troupe-w-dev-0")
      other = control(Listener.port(), "troupe-w-dev-1")
      [pod, _] = Enum.sort_by(Fleet.list_workers("dev"), & &1.pod_name)
      {:ok, _} = Sessions.place(context.session.id, pod)
      answer_index(worker, [context.session.id])
      answer_index(other, [])

      assert %{"result" => %{"github" => %{"base" => @base}, "stopped_now" => false}} =
               call(worker, "github.record", %{
                 "session_id" => context.session.id,
                 "base" => @base
               })

      assert %{"result" => %{"github" => %{"base" => @base}}} =
               call(worker, "github.record", %{"session_id" => context.session.id})

      assert %{"error" => %{"message" => "invalid_params", "data" => %{"reason" => reason}}} =
               call(worker, "github.record", %{
                 "session_id" => context.session.id,
                 "push" => %{"branch" => "main", "commit" => @one, "tree" => @tree}
               })

      assert reason =~ "only to a branch under troupe/"

      assert %{"error" => %{"message" => "not_found"}} =
               call(other, "github.record", %{"session_id" => context.session.id, "base" => @two})

      # And the fix loop's token, asked for by name.
      assert %{"result" => %{"permissions" => @grants}} =
               call(worker, "git.credential", %{
                 "session_id" => context.session.id,
                 "access" => "write"
               })

      assert %{"error" => %{"message" => "invalid_params"}} =
               call(worker, "git.credential", %{
                 "session_id" => context.session.id,
                 "access" => "admin"
               })

      [audit | _] = Enum.filter(Audit.list(kind: "github"), &(&1.action == "github.token"))
      assert audit.detail["permissions"] == @grants
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp profile(fake, grants, github \\ :grants) do
    github = if github == :grants, do: %{"permissions" => grants}, else: github
    spec = %{"egress" => %{"gitHosts" => [fake.host]}}
    spec = if github == nil, do: spec, else: Map.put(spec, "github", github)
    Fleet.put_profile(%{name: "dev", spec: spec})
  end

  defp push(session, commit) do
    record!(session, %{
      "push" => %{"branch" => "troupe/fix-widgets", "commit" => commit, "tree" => @tree}
    })
  end

  defp record!(session, changes) do
    assert {:ok, _} = GitHub.record(fresh(session), changes, "worker:test")
  end

  defp fresh(session), do: Sessions.get(session.id)

  defp pull(context, number),
    do: %{"number" => number, "url" => "#{context.fake.url}/example-org/widgets/pull/#{number}"}

  defp red(commit), do: %{"commit" => commit, "state" => "red", "failing" => ["test"]}

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
