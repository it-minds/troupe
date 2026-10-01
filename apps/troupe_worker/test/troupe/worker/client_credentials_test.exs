defmodule Troupe.Worker.ClientCredentialsTest do
  @moduledoc """
  A worker calls an MCP server as its profile's own identity (issue #315, Decision 747).

  The bundle marks the server `client_credentials`; the profile names its client, its
  scope, its token endpoint and the OpenBao transit key that signs its assertion, with the
  thumbprint of the certificate registered for that key. Against a token endpoint that
  checks the assertion as an identity provider would (the signature against the
  registered certificate's key, `aud`, `exp`, `jti`, `x5t#S256`) and an MCP server that
  answers only its tokens, the pod lists and calls the server's tools as that profile,
  renews the token before it runs out without a restart, asks once more after a `401`,
  and picks up a rotated key from its next token.

  The transit key is a real one, in the development OpenBao: the claim that the private
  key never leaves OpenBao is a claim about what transit does, and a double would agree
  with whatever this code believes.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.MCP.Server
  alias Troupe.Tool
  alias Troupe.Tool.Ctx
  alias Troupe.Worker.{ClientCredentials, FakeIdentityProvider, MCP}
  alias Troupe.WorkerProfile.MCPIdentity

  @moduletag timeout: 120_000

  setup context do
    if context[:store] do
      unique = System.unique_integer([:positive])
      fake = FakeIdentityProvider.start()
      namespace = "troupe-w-test#{unique}"
      key = transit_key!("#{namespace}.jira")

      FakeIdentityProvider.register(fake, "client-dev", %{thumbprint(key.v1) => key.v1},
        scope: "api://jira/.default",
        tools: ["search", "create_issue"]
      )

      path = Path.join(context.base, "mcp-identities/identities.json")

      identity = %{
        "server" => "jira",
        "clientId" => "client-dev",
        "scope" => "api://jira/.default",
        "tokenUrl" => fake.token_url,
        "transitKey" => key.name,
        "certificateThumbprint" => thumbprint(key.v1)
      }

      write_identities!(path, [identity])

      previous = Application.get_env(:troupe_worker, :mcp_identities_path)
      Application.put_env(:troupe_worker, :mcp_identities_path, path)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:troupe_worker, :mcp_identities_path, previous),
          else: Application.delete_env(:troupe_worker, :mcp_identities_path)

        for key <- [:profile_tokens, :remote_tools, :mcp_servers],
            do: Application.delete_env(:troupe_core, key)
      end)

      tokens = start_supervised!(ClientCredentials)
      registry = start_supervised!({MCP, servers: []})

      %{
        fake: fake,
        key: key,
        namespace: namespace,
        path: path,
        identity: identity,
        tokens: tokens,
        registry: registry,
        configs: [
          # The bundle's wire shape, as `Bundle.mcp_server_configs/1` hands it to the pod.
          %{
            "name" => "jira",
            "url" => fake.mcp_url,
            "credential_mode" => "client_credentials",
            "permission" => "auto",
            "tools" => "all"
          }
        ]
      }
    else
      :ok
    end
  end

  describe "a profile's own identity" do
    test "lists and calls the server's tools as the profile", context do
      context = requires_tier(context)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, names} = MCP.put_servers(context.configs)
          assert Enum.sort(names) == ["mcp.jira.create_issue", "mcp.jira.search"]
        end)

      # One token, issued to the profile's client, against an assertion the token
      # endpoint checked: the signature under the registered certificate's key (RS256 by
      # default), the thumbprint, the audience, the scope.
      assert_received {:fake_idp, :issued, issued}
      assert issued.client_id == "client-dev"
      assert issued.alg == "RS256"
      assert issued.thumbprint == thumbprint(context.key.v1)
      assert issued.aud == context.fake.token_url
      assert issued.scope == "api://jira/.default"
      assert_received {:fake_mcp, "tools/list", bearer}
      assert bearer == issued.token

      assert {:ok, "search as client-dev"} = invoke("mcp.jira.search", %{"query" => "q"})
      assert_received {:fake_mcp, "tools/call", ^bearer}

      # The token is held and used again; nothing asked for a second one.
      refute_received {:fake_idp, :issued, _}
      assert ClientCredentials.held() == ["jira"]

      # Nor did the token go anywhere a person reads, a crash report included.
      refute log =~ issued.token
      refute inspect(:sys.get_status(context.tokens)) =~ issued.token
    end

    test "renews the token before it runs out, without a restart", context do
      context = requires_tier(context)
      FakeIdentityProvider.set(context.fake, :expires_in, 6)

      assert {:ok, [_ | _]} = MCP.put_servers(context.configs)
      assert_received {:fake_idp, :issued, first}

      # Past three quarters of its six seconds and before its end: the next call gets a
      # new one rather than the one about to run out.
      Process.sleep(4_700)

      assert {:ok, "search as client-dev"} = invoke("mcp.jira.search", %{})
      assert_received {:fake_idp, :issued, second}
      assert second.token != first.token
      assert second.issued_at < first.expires_at
      assert_received {:fake_mcp, "tools/call", bearer}
      assert bearer == second.token

      # The same processes throughout: nothing was restarted to get it.
      assert Process.alive?(context.tokens)
      assert Process.alive?(context.registry)
    end

    test "asks for a new token once after a 401, and stops at the second", context do
      context = requires_tier(context)

      assert {:ok, [_ | _]} = MCP.put_servers(context.configs)
      assert_received {:fake_idp, :issued, first}

      # The server stops honouring what it was given: one new token, and the call works.
      FakeIdentityProvider.revoke_all(context.fake)
      assert {:ok, "search as client-dev"} = invoke("mcp.jira.search", %{})
      assert_received {:fake_idp, :issued, second}
      assert second.token != first.token

      # A server that refuses even a token just issued gets one more and no third.
      FakeIdentityProvider.refuse_tokens(context.fake)
      assert {:error, refusal} = invoke("mcp.jira.search", %{})
      assert refusal =~ "401"
      assert_received {:fake_idp, :issued, _third}
      refute_received {:fake_idp, :issued, _fourth}
    end

    test "a tool the identity lacks is refused by the server, and said so", context do
      context = requires_tier(context)

      FakeIdentityProvider.register(
        context.fake,
        "client-dev",
        %{thumbprint(context.key.v1) => context.key.v1},
        scope: "api://jira/.default",
        tools: ["search"]
      )

      server = Server.from_config(hd(context.configs))
      tool = Troupe.MCP.Tool.new(server, %{"name" => "create_issue"})

      assert {:error, refusal} = Tool.invoke(tool, %{}, ctx())
      assert refusal =~ "403"
      assert refusal =~ "may not use this tool"
    end

    test "a second profile, with its own identity, gets only its own tools", context do
      context = requires_tier(context)
      other = transit_key!("troupe-w-other#{System.unique_integer([:positive])}.jira")

      FakeIdentityProvider.register(
        context.fake,
        "client-ux",
        %{thumbprint(other.v1) => other.v1},
        tools: ["read_only"]
      )

      # The other profile's pod: its own process and its own identity.
      ux =
        start_supervised!(
          {ClientCredentials,
           name: :ux_tokens,
           install: false,
           identities: [
             MCPIdentity.from_spec(%{
               "server" => "jira",
               "clientId" => "client-ux",
               "tokenUrl" => context.fake.token_url,
               "transitKey" => other.name,
               "certificateThumbprint" => thumbprint(other.v1)
             })
           ]},
          id: :ux_tokens
        )

      server = Server.from_config(hd(context.configs))
      ClientCredentials.install(ux)
      assert ["mcp.jira.read_only"] == server |> Troupe.MCP.tools() |> Enum.map(& &1.name)

      ClientCredentials.install()

      assert ["mcp.jira.create_issue", "mcp.jira.search"] ==
               server |> Troupe.MCP.tools() |> Enum.map(& &1.name) |> Enum.sort()
    end

    test "signs with PS256 when the profile says so", context do
      context = requires_tier(context)
      write_identities!(context.path, [Map.put(context.identity, "algorithm", "PS256")])

      assert {:ok, [_ | _]} = MCP.put_servers(context.configs)
      assert_received {:fake_idp, :issued, %{alg: "PS256", client_id: "client-dev"}}
    end

    test "finds the token endpoint in the authorization server's metadata when none is named",
         context do
      context = requires_tier(context)
      write_identities!(context.path, [Map.delete(context.identity, "tokenUrl")])

      assert {:ok, [_ | _]} = MCP.put_servers(context.configs)
      assert_received {:fake_idp, :issued, %{aud: aud}}
      assert aud == context.fake.token_url
    end
  end

  describe "rotation" do
    test "a new key version and thumbprint are used from the next token, without a restart",
         context do
      context = requires_tier(context)

      assert {:ok, [_ | _]} = MCP.put_servers(context.configs |> pinned(context, 1))
      assert_received {:fake_idp, :issued, first}
      assert first.thumbprint == thumbprint(context.key.v1)

      # The administrator's order: a new version in transit, its certificate registered
      # beside the old one, then the profile changed to name both in one write. The pod's
      # identities file is what the kubelet replaces when the ConfigMap changes.
      v2 = rotate!(context.key.name)
      FakeIdentityProvider.add_certificate(context.fake, "client-dev", thumbprint(v2), v2)

      write_identities!(context.path, [
        context.identity
        |> Map.put("keyVersion", 2)
        |> Map.put("certificateThumbprint", thumbprint(v2))
      ])

      assert {:ok, "search as client-dev"} = invoke("mcp.jira.search", %{})
      assert_received {:fake_idp, :issued, second}
      assert second.thumbprint == thumbprint(v2)
      assert Process.alive?(context.tokens)
    end

    test "a pinned version keeps signing while transit already has a newer one", context do
      context = requires_tier(context)
      write_identities!(context.path, [Map.put(context.identity, "keyVersion", 1)])
      _v2 = rotate!(context.key.name)

      assert {:ok, [_ | _]} = MCP.put_servers(context.configs)
      assert_received {:fake_idp, :issued, %{thumbprint: thumbprint}}
      assert thumbprint == thumbprint(context.key.v1)
    end
  end

  describe "errors" do
    test "a client the token endpoint refuses names the server and the cause", context do
      context = requires_tier(context)
      FakeIdentityProvider.unregister(context.fake, "client-dev")

      assert {:error, sentence} = ClientCredentials.token(server(context), nil)
      assert sentence =~ "mcp server jira"
      assert sentence =~ "refused client client-dev"
      assert sentence =~ "invalid_client"

      # And the server's tools are absent rather than broken.
      assert {:ok, []} = MCP.put_servers(context.configs)
    end

    test "a key that is not in OpenBao is named", context do
      context = requires_tier(context)

      write_identities!(context.path, [
        Map.put(context.identity, "transitKey", "#{context.namespace}.gone")
      ])

      assert {:error, sentence} = ClientCredentials.token(server(context), nil)
      assert sentence =~ "mcp server jira"
      assert sentence =~ "the transit key #{context.namespace}.gone is not in OpenBao"
    end

    test "a server the profile gives no identity is named", context do
      context = requires_tier(context)
      write_identities!(context.path, [])

      assert {:error, sentence} = ClientCredentials.token(server(context), nil)
      assert sentence =~ "mcp server jira"
      assert sentence =~ "no identity"
    end
  end

  describe "the event log" do
    test "holds the call and its result, and no token or assertion", context do
      context = requires_tier(context)
      assert {:ok, [_ | _]} = MCP.put_servers(context.configs)
      assert_received {:fake_idp, :issued, issued}

      assert {:ok, _} =
               activate(context,
                 steps: [
                   {:tools, [{"mcp.jira.search", %{"query" => "open bugs"}}]},
                   {:text, "found them"}
                 ]
               )

      run_turn(context.session_id, "look for open bugs", 20_000)

      events = Troupe.replay_from(context.session_id, 0)
      logged = Jason.encode!(Enum.map(events, &Map.take(&1, [:type, :agent, :data])))

      assert logged =~ "search as client-dev"
      refute logged =~ issued.token
      # Nor anything shaped like a signed assertion: a JWT's header always starts so.
      refute logged =~ "eyJ"
      refute logged =~ "client_assertion"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp invoke(name, args) do
    tool = Enum.find(MCP.tools(), &(&1.name == name))
    Tool.invoke(tool, args, ctx())
  end

  defp ctx do
    %Ctx{
      session_id: "s-client-credentials",
      agent_path: ["root"],
      workspace: %Troupe.Workspace{root: "/tmp", root_real: "/tmp", root_key: "/tmp"},
      call_id: "call-1",
      agent_pid: self()
    }
  end

  defp server(context), do: Server.from_config(hd(context.configs))

  defp pinned(configs, context, version) do
    write_identities!(context.path, [Map.put(context.identity, "keyVersion", version)])
    configs
  end

  defp write_identities!(path, identities) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(identities))
  end

  # A stand-in for a certificate's SHA-256 thumbprint: what matters to the token endpoint
  # is that the header names the certificate whose key made the signature.
  defp thumbprint(pem), do: :sha256 |> :crypto.hash(pem) |> Base.url_encode64(padding: false)

  defp transit_key!(name) do
    {:ok, %{status: status}} = bao(:post, "/v1/transit/keys/#{name}", %{"type" => "rsa-2048"})
    true = status in 200..299

    on_exit(fn ->
      bao(:post, "/v1/transit/keys/#{name}/config", %{"deletion_allowed" => true})
      bao(:delete, "/v1/transit/keys/#{name}", nil)
    end)

    %{name: name, v1: public_key(name, 1)}
  end

  defp rotate!(name) do
    {:ok, %{status: status}} = bao(:post, "/v1/transit/keys/#{name}/rotate", %{})
    true = status in 200..299
    public_key(name, 2)
  end

  defp public_key(name, version) do
    {:ok, %{status: 200, body: body}} = bao(:get, "/v1/transit/keys/#{name}", nil)
    get_in(body, ["data", "keys", to_string(version), "public_key"])
  end

  defp bao(method, path, body) do
    kms = Application.get_env(:troupe_worker, :kms, [])

    [
      method: method,
      url: (kms[:address] || "http://localhost:28200") <> path,
      headers: [{"x-vault-token", kms[:token] || "troupe-dev-root"}],
      retry: false
    ]
    |> then(fn request -> if body, do: Keyword.put(request, :json, body), else: request end)
    |> Req.request()
  end
end
