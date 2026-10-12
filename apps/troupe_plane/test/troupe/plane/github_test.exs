defmodule Troupe.Plane.GitHubTest do
  @moduledoc """
  The plane's GitHub App (#147 slice 1): its settings, the key in OpenBao transit, the
  installation tokens it mints, and how a session names its repository and a pod asks for
  the token.

  Against the development OpenBao's transit engine, for real: the key is imported there
  and signs there, and a fake GitHub (`Troupe.Plane.FakeGitHub`) verifies the JWT against
  the public half of the key the test made, issues narrowed tokens and serves a clone with
  the real `git upload-pack`, refusing a token outside its scope or past its expiry.
  """

  use Troupe.Plane.DataCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.KMS.Policy
  alias Troupe.Plane.{Admin, Audit, FakeGitHub, FakePod, Fleet, GitHub, Harness, Sessions}
  alias Troupe.Plane.Admin.API
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.GitHub.Key

  @moduletag timeout: 120_000

  @app_id 4242
  @installation 77_001

  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @lead %{subject: "lead@example.test", role: :team_admin, teams: ["engineering"]}

  setup do
    unless bao_reachable?(), do: flunk("no OpenBao; bring it up with `scripts/dev-up`")

    # A transit key of this test's own: the development OpenBao is not rolled back as the
    # database is, and two runs must not rotate each other's key.
    name = "troupe-github-app-test-#{System.unique_integer([:positive])}"
    transit = Application.get_env(:troupe_plane, :transit, [])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :github_key, name))

    on_exit(fn ->
      Application.put_env(:troupe_plane, :transit, transit)
      delete_transit_key(transit, name)
    end)

    fake = FakeGitHub.start()
    key = rsa_key()
    FakeGitHub.app(fake, @app_id, key)

    {:ok, _} =
      Fleet.put_profile(%{name: "dev", spec: %{"egress" => %{"gitHosts" => [fake.host]}}})

    %{fake: fake, key: key, transit: transit, key_name: name}
  end

  describe "the App's settings" do
    test "a platform admin sets the App, and its key goes into transit and never comes back",
         context do
      pem = pem(context.key)

      assert {:ok, now} =
               API.call(
                 "admin.github.put",
                 %{
                   "app" => %{
                     "app_id" => @app_id,
                     "api_url" => context.fake.api_url,
                     "installations" => [
                       %{"owner" => "example-org", "installation_id" => @installation}
                     ],
                     "private_key" => pem
                   }
                 },
                 @root
               )

      assert now.configured
      assert now.app_id == @app_id
      assert now.git_url == context.fake.url

      assert now.installations == [
               %{"owner" => "example-org", "installation_id" => @installation}
             ]

      assert now.private_key.set
      assert now.private_key.type == "rsa-2048"
      assert now.private_key.version == 1
      assert now.private_key.fingerprint == fingerprint(context.key)
      assert now.permissions == %{"contents" => "read"}

      # Never the key, in the answer, the read, the row or the audit trail.
      assert {:ok, read} = API.call("admin.github.get", %{}, @root)
      {:ok, rows} = Repo.query("SELECT * FROM github_app")
      [audit] = Audit.list(kind: "github")

      for where <- [now, read, rows, audit.detail] do
        refute_key(where, pem)
      end

      assert audit.action == "github.put"
      assert audit.detail["fingerprint"]["to"] == fingerprint(context.key)

      # In transit, and not exportable: not even the root token takes it back out.
      assert {:ok, %{"data" => transit_key}} =
               bao(context.transit, :get, "keys/#{context.key_name}")

      assert transit_key["type"] == "rsa-2048"
      assert transit_key["exportable"] == false

      assert {:error, {400, _}} =
               bao(context.transit, :get, "export/signing-key/#{context.key_name}")
    end

    test "a team admin may read the App and may not change it", context do
      assert {:ok, %{configured: false}} = API.call("admin.github.get", %{}, @lead)

      assert {:error, refused} =
               API.call("admin.github.put", %{"app" => %{"app_id" => 1}}, @lead)

      assert refused.data.required_role == "platform_admin"
      assert GitHub.describe().app_id == nil
      _ = context
    end

    test "what does not read is refused, naming the field, and nothing is written", context do
      cases = [
        {%{"app_id" => "not a number"}, "app_id"},
        {%{"api_url" => "http://github.example.com/api/v3"}, "api_url"},
        {%{"api_url" => "https://example.com/somewhere"}, "api_url"},
        {%{"installations" => [%{"owner" => "-bad-", "installation_id" => 1}]}, "installations"},
        {%{"installations" => [%{"owner" => "example-org", "installation_id" => "x"}]},
         "installations"},
        {%{
           "installations" => [
             %{"owner" => "example-org", "installation_id" => 1},
             %{"owner" => "Example-Org", "installation_id" => 2}
           ]
         }, "installations"},
        {%{"private_key" => "not a key"}, "private_key"},
        {%{"private_key" => ec_pem()}, "private_key"},
        {%{"colour" => "blue"}, "colour"}
      ]

      for {app, field} <- cases do
        assert {:error, error} =
                 Admin.github_put(@root, Map.put(app, "app_id", app["app_id"] || 1)),
               "#{inspect(app)} was taken"

        assert error.message == "invalid_params"
        assert error.data.field == field, "#{inspect(app)}: #{inspect(error.data)}"
      end

      assert GitHub.describe().app_id == nil
      assert {:error, {404, _}} = bao(context.transit, :get, "keys/#{context.key_name}")
    end

    test "a second key becomes the next version, and the plane signs with it", context do
      configure(context)
      second = rsa_key()

      assert {:ok, now} = Admin.github_put(@root, %{"private_key" => pem(second)})
      assert now.private_key.version == 2
      assert now.private_key.fingerprint == fingerprint(second)

      assert now.changes["fingerprint"] == %{
               "from" => fingerprint(context.key),
               "to" => fingerprint(second)
             }

      # GitHub holds both while a key is rotated; the plane's JWT is the new key's.
      {:ok, jwt} = GitHub.jwt(Repo.get(Troupe.Plane.GitHub.App, "app"))
      public = second |> JOSE.JWK.from_key() |> JOSE.JWK.to_public()
      assert {true, %JOSE.JWT{fields: claims}, _} = JOSE.JWT.verify_strict(public, ["RS256"], jwt)
      assert claims["iss"] == @app_id
      assert claims["exp"] - claims["iat"] <= 600
    end

    test "the policy the plane's role needs for the key is enough, and exports nothing",
         context do
      # A token with that policy and nothing else, as a production plane's role would carry.
      policy = "troupe-github-app-test-#{System.unique_integer([:positive])}"

      {:ok, _} =
        bao(context.transit, :put_policy, policy, Policy.github_app("transit", context.key_name))

      {:ok, %{"auth" => %{"client_token" => token}}} =
        bao(context.transit, :post, "/v1/auth/token/create", %{
          "policies" => [policy],
          "ttl" => "5m"
        })

      narrow = Keyword.merge(context.transit, token: token, github_key: context.key_name)
      Application.put_env(:troupe_plane, :transit, narrow)

      configure(context)
      second = rsa_key()

      assert {:ok, %{private_key: %{version: 2}}} =
               Admin.github_put(@root, %{"private_key" => pem(second)})

      assert {:ok, _jwt} = GitHub.jwt(Repo.get(Troupe.Plane.GitHub.App, "app"))

      assert {:error, {status, _}} = bao(narrow, :get, "export/signing-key/#{context.key_name}")
      assert status in [400, 403]
    end

    test "the key wrap is RFC 5649's" do
      kek = Base.decode16!("5840DF6E29B02AF1AB493B705BF16EA1AE8338F4DCC176A8")

      assert Key.key_wrap(kek, Base.decode16!("C37B7E6492584340BED12207808941155068F738")) ==
               Base.decode16!("138BDEAA9B8FA7FC61F97742E72248EE5AE6AE5360D1AE6A5F54F373FA543B6A")

      assert Key.key_wrap(kek, Base.decode16!("466F7250617369")) ==
               Base.decode16!("AFBEB0F07DFBF5419200F2CCB50BB24F")
    end
  end

  describe "an installation token" do
    test "is for the session's one repository, read-only, an hour long, and logged nowhere",
         context do
      configure(context)
      session = session_with("s-gh-mint", %{"owner" => "example-org", "name" => "widgets"})

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, credential} = GitHub.credential(session)
          send(self(), {:credential, credential})
        end)

      assert_received {:credential, credential}

      assert [%{installation_id: @installation, iss: @app_id} = asked] =
               FakeGitHub.requests(context.fake)

      assert asked.repositories == ["widgets"]
      assert asked.permissions == %{"contents" => "read"}

      assert credential["url"] == "#{context.fake.url}/example-org/widgets.git"
      assert credential["host"] == "127.0.0.1"
      assert credential["username"] == "x-access-token"
      assert credential["repository"] == "example-org/widgets"

      {:ok, expires_at, _} = DateTime.from_iso8601(credential["expires_at"])
      lifetime = DateTime.diff(expires_at, DateTime.utc_now())
      assert lifetime > 3500 and lifetime <= 3600

      refute log =~ credential["token"]
    end

    test "clones its repository and no other, and nothing once it has expired", context do
      configure(context, ["widgets", "gadgets"])
      repos = repositories(context.fake, ["widgets", "gadgets"])
      session = session_with("s-gh-scope", %{"owner" => "example-org", "name" => "widgets"})

      {:ok, %{"token" => token}} = GitHub.credential(session)

      assert {_, 0} = clone(context.fake, token, "widgets", repos.into)
      assert File.read!(Path.join(repos.into, "README.md")) =~ "widgets"

      # The installation has both; the token was narrowed to one.
      assert {output, status} = clone(context.fake, token, "gadgets", repos.into <> "-gadgets")
      assert status != 0, output

      # And a token past its hour clones nothing, its own repository included.
      FakeGitHub.ttl(context.fake, 1)
      {:ok, %{"token" => short}} = GitHub.credential(session)
      Process.sleep(2_100)
      assert {_, status} = clone(context.fake, short, "widgets", repos.into <> "-late")
      assert status != 0
    end

    test "is refused by GitHub when the key is not the App's, and says so", context do
      configure(context)
      FakeGitHub.app(context.fake, @app_id, rsa_key())
      session = session_with("s-gh-wrong", %{"owner" => "example-org", "name" => "widgets"})

      assert {:error, {:github, 401, _, _, _} = reason} = GitHub.credential(session)
      assert GitHub.explain(reason) =~ "refused the App's JWT"
    end
  end

  describe "a session's repository" do
    setup do
      start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
      start_supervised!(Connections)
      start_supervised!(Troupe.Plane.Singleton)
      start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})
      %{port: Listener.port()}
    end

    test "is named at creation, kept on the row and carried to the pod", context do
      configure(context)
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      ada = person("ada@example.test", ["engineering"])
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      assert {:ok, %{"session_id" => id}} =
               Harness.call(
                 "session.create",
                 %{
                   "profile" => "dev",
                   "repository" => %{
                     "owner" => "example-org",
                     "name" => "widgets",
                     "ref" => "main"
                   }
                 },
                 %{user: ada, platform_admin?: false}
               )

      assert_receive {:pushed, "session.activate", %{"session_id" => ^id} = params}, 5_000
      wanted = %{"owner" => "example-org", "name" => "widgets", "ref" => "main"}
      assert params["repository"] == wanted
      refute Map.has_key?(params, "token")
      assert Sessions.get(id).repository == wanted

      assert {:ok, %{"repository" => ^wanted}} =
               Harness.call("session.get", %{"session_id" => id}, %{
                 user: ada,
                 platform_admin?: false
               })
    end

    test "is refused at creation for an owner, a host or a plane the App does not cover",
         context do
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      ada = person("ada@example.test", ["engineering"])
      as_ada = %{user: ada, platform_admin?: false}
      create = &Harness.call("session.create", %{"profile" => "dev", "repository" => &1}, as_ada)

      # No App yet.
      assert {:error, error} = create.("example-org/widgets")
      assert error.data.field == "repository"
      assert error.data.reason =~ "no GitHub App"

      configure(context)

      assert {:error, error} = create.("someone-else/widgets")
      assert error.data.reason =~ "not installed for someone-else"

      assert {:error, error} = create.("example-org/../widgets")
      assert error.data.field == "repository"

      assert {:error, error} =
               create.(%{
                 "owner" => "example-org",
                 "name" => "widgets",
                 "ref" => "--upload-pack=x"
               })

      assert error.data.field == "repository"

      {:ok, _} =
        Fleet.put_profile(%{name: "dev", spec: %{"egress" => %{"gitHosts" => ["github.com"]}}})

      assert {:error, error} = create.("example-org/widgets")
      assert error.data.reason =~ "does not declare 127.0.0.1 in egress.gitHosts"

      assert Sessions.visible_to(ada, []) == []
    end

    test "is what a pod gets a token for, and only for a session it holds", context do
      configure(context)
      worker = control(context.port, "troupe-w-dev-0")
      other = control(context.port, "troupe-w-dev-1")
      [pod, _] = Enum.sort_by(Fleet.list_workers("dev"), & &1.pod_name)

      session = session_with("s-gh-pod", %{"owner" => "example-org", "name" => "widgets"})
      {:ok, _} = Sessions.place(session.id, pod)
      {:ok, bare} = Sessions.create(%{id: "s-gh-bare", owner_subject: "idp|ada", profile: "dev"})
      {:ok, _} = Sessions.place(bare.id, pod)
      answer_index(worker, [session.id, bare.id])
      answer_index(other, [])

      log =
        capture_log([level: :debug], fn ->
          answer = call(worker, "git.credential", %{"session_id" => session.id})
          send(self(), {:answer, answer})
        end)

      assert_received {:answer, %{"result" => credential}}
      assert credential["url"] == "#{context.fake.url}/example-org/widgets.git"
      assert credential["token"] in FakeGitHub.tokens(context.fake)
      refute Map.has_key?(credential, "installation_id")
      refute log =~ credential["token"]

      [audit] = Enum.filter(Audit.list(kind: "github"), &(&1.action == "github.token"))
      assert audit.actor == "worker:troupe-w-dev-0"
      assert audit.on_behalf_of == "idp|ada"
      assert audit.subject_id == "example-org/widgets"
      assert audit.detail["session_id"] == session.id
      refute inspect(audit) =~ credential["token"]

      # Another pod's session, a session with no repository, and one that does not exist.
      assert %{"error" => %{"message" => "not_found"}} =
               call(other, "git.credential", %{"session_id" => session.id})

      assert %{"error" => %{"message" => "not_found", "data" => %{"reason" => reason}}} =
               call(worker, "git.credential", %{"session_id" => bare.id})

      assert reason =~ "names no repository"

      assert %{"error" => %{"message" => "not_found"}} =
               call(worker, "git.credential", %{"session_id" => "s-nowhere"})
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp configure(context, repositories \\ ["widgets"]) do
    FakeGitHub.install(context.fake, @installation, @app_id, "example-org", repositories)

    {:ok, _} =
      Admin.github_put(@root, %{
        "app_id" => @app_id,
        "api_url" => context.fake.api_url,
        "installations" => [%{"owner" => "example-org", "installation_id" => @installation}],
        "private_key" => pem(context.key)
      })

    :ok
  end

  defp session_with(id, repository) do
    {:ok, session} =
      Sessions.create(%{
        id: id <> "-#{System.unique_integer([:positive])}",
        owner_subject: "idp|ada",
        profile: "dev",
        repository: repository
      })

    session
  end

  defp repositories(fake, names) do
    base = Path.join(System.tmp_dir!(), "fake-github-repos-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    for name <- names do
      path = Path.join(base, name)
      File.mkdir_p!(path)
      git(path, ["init", "--quiet", "--initial-branch=main"])
      File.write!(Path.join(path, "README.md"), "# #{name}\n")
      git(path, ["add", "README.md"])

      git(path, [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.test",
        "commit",
        "--quiet",
        "-m",
        "first"
      ])

      FakeGitHub.repo(fake, "example-org/#{name}", path)
    end

    %{into: Path.join(base, "clone")}
  end

  defp clone(fake, token, name, into) do
    %URI{} = uri = URI.parse(fake.url)

    url =
      "#{uri.scheme}://x-access-token:#{token}@#{uri.host}:#{uri.port}/example-org/#{name}.git"

    System.cmd("git", ["clone", "--quiet", "--depth=1", url, into],
      stderr_to_stdout: true,
      env: [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}]
    )
  end

  defp git(dir, args), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp rsa_key, do: :public_key.generate_key({:rsa, 2048, 65_537})

  defp pem(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

  defp ec_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  end

  defp fingerprint(key) do
    {_, der, _} =
      :public_key.pem_entry_encode(
        :SubjectPublicKeyInfo,
        {:RSAPublicKey, elem(key, 2), elem(key, 3)}
      )

    "SHA256:" <> Base.encode64(:crypto.hash(:sha256, der))
  end

  # The PEM's body, in pieces long enough to mean something and short enough that a key
  # cut up and stored in parts would still be found.
  defp refute_key(where, pem) do
    text = inspect(where, limit: :infinity, printable_limit: :infinity)
    refute text =~ "PRIVATE KEY"

    body =
      pem
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "-----"))
      |> Enum.join()

    for chunk <- for(<<piece::binary-32 <- body>>, do: piece) do
      refute text =~ chunk
    end
  end

  # -- the control channel, as a pod speaks it ------------------------------------

  defp control(port, pod_name) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])

    send_line(socket, 0, "enrol", %{
      "token" => "dev-token",
      "pod_name" => pod_name,
      "capacity" => 4,
      "disk_total_bytes" => 1_000
    })

    %{"result" => _} = receive_answer(socket, 0)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  # The plane asks a pod that enrols what it holds, and marks dormant every session placed
  # on it that the answer leaves out. So the pod answers once its sessions are placed, and
  # names them.
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

  # The plane pushes as well as answers; a push is answered as a pod would and skipped.
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

  defp bao(transit, :put_policy, name, policy) do
    bao(transit, :put, "/v1/sys/policies/acl/#{name}", %{"policy" => policy})
  end

  defp bao(transit, method, "/v1/" <> _ = path, body) do
    case Req.request(
           method: method,
           url: transit[:address] <> path,
           headers: [{"x-vault-token", transit[:token]}],
           json: body,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
    end
  end

  defp bao(transit, method, path), do: bao_get(transit, method, path)

  defp bao_get(transit, method, path) do
    case Req.request(
           method: method,
           url: "#{transit[:address]}/v1/#{transit[:mount] || "transit"}/#{path}",
           headers: [{"x-vault-token", transit[:token]}],
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
    end
  end

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
