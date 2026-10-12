Code.require_file("../support/fake_oauth.exs", __DIR__)

defmodule Troupe.MCPOAuthTest do
  @moduledoc """
  A person's own MCP server that wants them signed in, not a machine (Decision 741),
  against a fake authorization server and a fake protected MCP server on loopback
  (`test/support/fake_oauth.exs`).

  A local session finds the server waiting for a sign-in; the sign-in is discovered from
  the server's `401`, sent through the browser with PKCE, a `state` and the resource
  indicator, and comes back to the daemon's loopback listener; the session asks for the
  tools with the person's token; a token about to run out is refreshed once however
  many ask; a `401` is refreshed and tried again; a refused refresh turns into "sign in
  again" for the model and the person; and the token is never in `mcp.json`, an event,
  or a request to anything but the server and the token endpoint.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.MCP.{Client, Import, Local, OAuth, Server}
  alias Troupe.MCP.OAuth.{Store, Tokens}
  alias Troupe.Session.MCP
  alias Troupe.Test.FakeOAuth
  alias Troupe.Tool

  @moduletag timeout: 60_000

  setup context do
    fake = FakeOAuth.start(self(), Map.get(context, :fake, []))
    on_exit(fn -> FakeOAuth.stop(fake) end)
    Map.put(context, :fake, fake)
  end

  defp with_server(context, oauth \\ %{"client_id" => FakeOAuth.client_id()}) do
    write_file(
      context,
      ".troupe/mcp.json",
      Jason.encode!(%{
        "mcpServers" => %{"notes" => %{"url" => context.fake.mcp_url, "oauth" => oauth}}
      })
    )

    start_session(context)
  end

  defp config(extra \\ %{}) do
    {:ok, config} = OAuth.config(Map.merge(%{"client_id" => FakeOAuth.client_id()}, extra))
    config
  end

  defp sign_in_of(context),
    do: OAuth.binding("notes", context.fake.mcp_url, config(), context.state_dir)

  defp sign_in(context, extra \\ %{}) do
    {:ok, started} =
      OAuth.sign_in("notes", context.fake.mcp_url, config(extra), state_dir: context.state_dir)

    started
  end

  defp wait_for_state(session_id, name, states, waited \\ 0) do
    entry = Enum.find(MCP.status(session_id), &(&1.name == name))

    cond do
      entry && entry.state in states -> entry
      waited > 10_000 -> flunk("#{name} never reached #{inspect(states)}: #{inspect(entry)}")
      true -> Process.sleep(50) && wait_for_state(session_id, name, states, waited + 50)
    end
  end

  defp tool(session_id) do
    Enum.find(MCP.tools(session_id), &(Tool.name(&1) == "mcp.notes.search"))
  end

  defp ctx(session, context) do
    %Troupe.Tool.Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self()
    }
  end

  defp requests do
    receive do
      {:fake_oauth, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  defp signed_in(context) do
    {200, _page} = context |> sign_in() |> Map.fetch!(:url) |> FakeOAuth.browse()
    _ = requests()
    sign_in_of(context)
  end

  defp revocations, do: Enum.filter(requests(), &(&1.path == "/tenant/revoke"))

  describe "a local session" do
    test "waits for the sign-in, and once it is made asks with the person's token", context do
      %{session: session} = with_server(context)

      assert %{state: :sign_in, tools: [], error: "sign in to notes" <> _} =
               wait_for_state(session.id, "notes", [:sign_in])

      assert MCP.tools(session.id) == []
      # Nothing was sent: there was no token, and a call without one is not worth making.
      refute Enum.any?(requests(), &(&1.path == "/mcp"))

      started = sign_in(context)
      params = started.url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert String.starts_with?(started.url, context.fake.issuer <> "/authorize?")
      assert params["client_id"] == FakeOAuth.client_id()
      assert params["code_challenge_method"] == "S256"
      assert params["resource"] == context.fake.mcp_url
      # The 401's scope, and offline_access because the authorization server offers it.
      assert params["scope"] == "notes.read offline_access"
      assert params["redirect_uri"] =~ ~r"^http://127\.0\.0\.1:\d+/callback$"
      assert params["redirect_uri"] == started.redirect_uri
      assert OAuth.status(sign_in_of(context)).state == :signing_in

      # Discovery went the way the specification orders it: the 401, the metadata it
      # named, then the issuer's three places in turn.
      paths = Enum.map(requests(), &{&1.method, &1.path})
      assert {"POST", "/mcp"} in paths
      assert {"GET", "/.well-known/oauth-protected-resource/mcp"} in paths

      assert Enum.filter(paths, fn {_m, path} -> String.contains?(path, "well-known/o") end)
             |> Enum.map(&elem(&1, 1))
             |> Enum.drop(1) == [
               "/.well-known/oauth-authorization-server/tenant",
               "/.well-known/openid-configuration/tenant",
               "/tenant/.well-known/openid-configuration"
             ]

      assert {200, page} = FakeOAuth.browse(started.url)
      assert page =~ "Signed in to notes as ada@example.test"

      assert %{state: :ready, tools: ["search"]} = wait_for_state(session.id, "notes", [:ready])
      assert %{state: :signed_in, account: "ada@example.test"} = OAuth.status(sign_in_of(context))

      assert {:ok, "notes on trains, for ada@example.test"} =
               Tool.invoke(tool(session.id), %{"topic" => "trains"}, ctx(session, context))

      crossed = requests()
      [call | _] = Enum.filter(crossed, &(&1.path == "/mcp" and &1.body =~ "tools/call"))
      assert call.headers["authorization"] == "Bearer at-1"

      # The refresh token and the verifier went to the token endpoint and nowhere else.
      refute Enum.any?(crossed, &(&1.path == "/mcp" and &1.raw =~ "rt-1"))

      # Kept in the state directory, readable by its owner alone; never in mcp.json or
      # the session's log.
      assert %{"access_token" => "at-1", "refresh_token" => "rt-1"} =
               Store.get(context.state_dir, sign_in_of(context).key)

      # Mode 0600, and on Windows an access list naming the user alone.
      assert Troupe.OwnerOnly.restricted?(Store.path(context.state_dir))

      refute read_file(context, ".troupe/mcp.json") =~ "at-1"
      logged = session.id |> Troupe.events() |> inspect(limit: :infinity)
      refute logged =~ "at-1"
      refute logged =~ "rt-1"
    end

    @tag fake: [expires_in: 30]
    test "a token about to run out is refreshed once, however many ask at once", context do
      started = sign_in(context)
      {200, _page} = FakeOAuth.browse(started.url)
      FakeOAuth.set(context.fake, :expires_in, 3600)
      _ = requests()

      # Thirty seconds is inside the minute a token is refreshed ahead of its end.
      tokens =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> Tokens.token(sign_in_of(context)) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.uniq(tokens) == [{:ok, "at-2"}]

      refreshes =
        Enum.filter(requests(), &(&1.path == "/tenant/token" and &1.body =~ "refresh_token"))

      assert length(refreshes) == 1
      assert hd(refreshes).body =~ "refresh_token=rt-1"
    end

    test "a 401 is refreshed and tried again; a refused refresh asks the person to sign in again",
         context do
      %{session: session} = with_server(context)
      started = sign_in(context)
      {200, _page} = FakeOAuth.browse(started.url)
      wait_for_state(session.id, "notes", [:ready])
      search = tool(session.id)

      # The server stopped taking the token: refreshed, and the call goes through.
      FakeOAuth.revoke_access(context.fake)

      assert {:ok, "notes on boats" <> _} =
               Tool.invoke(search, %{"topic" => "boats"}, ctx(session, context))

      assert %{"access_token" => "at-2", "refresh_token" => "rt-2"} =
               Store.get(context.state_dir, sign_in_of(context).key)

      # Now the refresh is refused too: the model gets a result it can relay, and every
      # client sees the server wanting a sign-in again, for whom it was.
      FakeOAuth.revoke_access(context.fake)
      FakeOAuth.refuse_refresh(context.fake)

      assert {:ok, output} = Tool.invoke(search, %{"topic" => "planes"}, ctx(session, context))

      assert %{"error" => "sign_in_required", "server" => "notes", "hint" => hint} =
               Jason.decode!(output)

      assert hint =~ "/mcp sign-in notes"

      assert %{state: :expired, account: "ada@example.test"} = OAuth.status(sign_in_of(context))

      assert %{state: :sign_in, error: "the sign-in to notes has run out" <> _} =
               wait_for_state(session.id, "notes", [:sign_in])

      refute Map.has_key?(Store.get(context.state_dir, sign_in_of(context).key), "refresh_token")

      # Signing in again brings it back without restarting anything.
      FakeOAuth.set(context.fake, :refuse_refresh, false)
      {200, _page} = context |> sign_in() |> Map.fetch!(:url) |> FakeOAuth.browse()
      assert %{state: :ready} = wait_for_state(session.id, "notes", [:ready])

      assert {:ok, "notes on cars" <> _} =
               Tool.invoke(search, %{"topic" => "cars"}, ctx(session, context))
    end

    # Issue #586: the MCP authorization specification's step-up.
    @tag fake: [write_tool: true]
    test "a 403 insufficient_scope asks the person to sign in for the wider scope, the tokens held are kept till then, and the call then goes through",
         context do
      %{session: session} = with_server(context)
      {200, _page} = context |> sign_in() |> Map.fetch!(:url) |> FakeOAuth.browse()
      assert %{tools: ["search", "write"]} = wait_for_state(session.id, "notes", [:ready])
      search = tool(session.id)
      write = Enum.find(MCP.tools(session.id), &(Tool.name(&1) == "mcp.notes.write"))
      _ = requests()

      # The server wants notes.write, which the sign-in did not ask for: the model gets the
      # answer a run-out sign-in gets, with the scope the server named.
      assert {:ok, output} = Tool.invoke(write, %{"topic" => "boats"}, ctx(session, context))

      assert %{
               "error" => "sign_in_required",
               "server" => "notes",
               "scope" => "notes.write",
               "hint" => hint
             } = Jason.decode!(output)

      assert hint =~ "notes.write"
      assert hint =~ "/mcp sign-in notes"

      # Nothing signed in on its own, and nothing went where the 403 pointed.
      crossed = requests()
      refute OAuth.status(sign_in_of(context)).state == :signing_in
      refute Enum.any?(crossed, &String.starts_with?(&1.path, "/tenant/"))
      refute Enum.any?(crossed, &(&1.path =~ "elsewhere"))

      # The sign-in held is kept, and says what the server wants on top of it.
      assert %{"access_token" => "at-1", "refresh_token" => "rt-1", "step_up" => ["notes.write"]} =
               Store.get(context.state_dir, sign_in_of(context).key)

      assert %{state: :signed_in, step_up: "notes.write"} = OAuth.status(sign_in_of(context))
      assert %{state: :ready} = wait_for_state(session.id, "notes", [:ready])

      assert {:ok, "notes on trains" <> _} =
               Tool.invoke(search, %{"topic" => "trains"}, ctx(session, context))

      # The person signs in again, at the authorization server the server's metadata names,
      # for what was granted and what the server named.
      started = sign_in(context)
      params = started.url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert String.starts_with?(started.url, context.fake.issuer <> "/authorize?")
      wanted = ~w(notes.read offline_access notes.write)
      assert Enum.sort(String.split(params["scope"])) == Enum.sort(wanted)
      assert Enum.sort(started.scopes) == Enum.sort(wanted)
      refute Enum.any?(requests(), &(&1.path =~ "elsewhere"))

      # Until it lands, the tokens held are the ones used.
      assert {:ok, "notes on planes" <> _} =
               Tool.invoke(search, %{"topic" => "planes"}, ctx(session, context))

      assert {200, _page} = FakeOAuth.browse(started.url)
      assert %{state: :ready} = wait_for_state(session.id, "notes", [:ready])

      assert {:ok, "wrote a note on boats, for ada@example.test"} =
               Tool.invoke(write, %{"topic" => "boats"}, ctx(session, context))

      refute Map.has_key?(Store.get(context.state_dir, sign_in_of(context).key), "step_up")
      assert %{state: :signed_in, step_up: nil} = OAuth.status(sign_in_of(context))
    end

    @tag fake: [write_tool: true]
    test "a step-up the person refuses leaves the sign-in held as it was", context do
      %{session: session} = with_server(context)
      {200, _page} = context |> sign_in() |> Map.fetch!(:url) |> FakeOAuth.browse()
      wait_for_state(session.id, "notes", [:ready])
      write = Enum.find(MCP.tools(session.id), &(Tool.name(&1) == "mcp.notes.write"))

      assert {:ok, output} = Tool.invoke(write, %{"topic" => "x"}, ctx(session, context))
      assert %{"error" => "sign_in_required", "scope" => "notes.write"} = Jason.decode!(output)

      FakeOAuth.set(context.fake, :deny, true)
      assert {200, page} = context |> sign_in() |> Map.fetch!(:url) |> FakeOAuth.browse()
      assert page =~ "access_denied"

      assert %{"access_token" => "at-1", "refresh_token" => "rt-1", "step_up" => ["notes.write"]} =
               Store.get(context.state_dir, sign_in_of(context).key)

      assert %{state: :signed_in, step_up: "notes.write", error: "the authorization server" <> _} =
               OAuth.status(sign_in_of(context))

      assert {:ok, "notes on y" <> _} =
               Tool.invoke(tool(session.id), %{"topic" => "y"}, ctx(session, context))
    end

    test "a server with no oauth that answers 401 says what it wants", context do
      write_file(
        context,
        ".troupe/mcp.json",
        Jason.encode!(%{"mcpServers" => %{"notes" => %{"url" => context.fake.mcp_url}}})
      )

      %{session: session} = start_session(context)
      assert %{state: :error, error: error} = wait_for_state(session.id, "notes", [:error])
      assert error =~ "oauth.client_id"
    end
  end

  describe "the sign-in" do
    @tag fake: [deny: true]
    test "a refusal is kept for the person to read, and nothing is signed in", context do
      started = sign_in(context)
      assert {200, page} = FakeOAuth.browse(started.url)
      assert page =~ "failed"
      assert page =~ "access_denied"

      assert %{
               state: :signed_out,
               error: "the authorization server refused: access_denied (the person said no)"
             } =
               OAuth.status(sign_in_of(context))
    end

    test "an answer with another state is turned away, and the real one still lands", context do
      started = sign_in(context)

      {:ok, forged} =
        Req.get(started.redirect_uri <> "?code=stolen&state=not-ours",
          retry: false,
          decode_body: false
        )

      assert forged.status == 400
      assert OAuth.status(sign_in_of(context)).state == :signing_in

      assert {200, _page} = FakeOAuth.browse(started.url)
      assert OAuth.status(sign_in_of(context)).state == :signed_in
    end

    test "a second sign-in replaces the first, and signing out forgets it", context do
      first = sign_in(context)
      second = sign_in(context)
      refute first.redirect_uri == second.redirect_uri and first.url == second.url

      assert {200, _page} = FakeOAuth.browse(second.url)
      assert OAuth.status(sign_in_of(context)).state == :signed_in

      assert {:ok, %{state: :revoked}} = OAuth.sign_out(sign_in_of(context))
      assert %{state: :signed_out, account: nil} = OAuth.status(sign_in_of(context))
      assert Store.get(context.state_dir, sign_in_of(context).key) == nil
    end

    @tag fake: [challenge_metadata: false]
    test "finds the metadata at the well-known place when the 401 does not name it", context do
      started = sign_in(context)
      assert String.starts_with?(started.url, context.fake.issuer <> "/authorize?")

      assert "/.well-known/oauth-protected-resource/mcp" in Enum.map(requests(), & &1.path)
    end

    @tag fake: [require_resource: false]
    test "names the issuer itself, and leaves the resource out when told to", context do
      started =
        sign_in(context, %{
          "issuer" => context.fake.issuer,
          "resource" => false,
          "scopes" => "notes.read"
        })

      params = started.url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      refute Map.has_key?(params, "resource")
      assert params["scope"] == "notes.read offline_access"
      refute Enum.any?(requests(), &String.contains?(&1.path, "oauth-protected-resource"))

      assert {200, _page} = FakeOAuth.browse(started.url)
      token_request = Enum.find(requests(), &(&1.path == "/tenant/token"))
      refute token_request.body =~ "resource="
    end

    test "listens where the entry's redirect_uri says", context do
      port = free_port()
      started = sign_in(context, %{"redirect_uri" => "http://localhost:#{port}/back"})
      assert started.redirect_uri == "http://localhost:#{port}/back"
      assert {200, page} = FakeOAuth.browse(started.url)
      assert page =~ "Signed in"
    end
  end

  # Issue #587: signing out ends the sign-in at the provider too (RFC 7009), or says it
  # could not; either way it is forgotten here.
  describe "signing out" do
    test "revokes the refresh token at the provider, then forgets the sign-in", context do
      binding = signed_in(context)

      assert {:ok, %{state: :revoked, reason: nil}} = OAuth.sign_out(binding)

      assert [revoke] = revocations()

      assert URI.decode_query(revoke.body) == %{
               "token" => "rt-1",
               "token_type_hint" => "refresh_token",
               "client_id" => FakeOAuth.client_id()
             }

      refute FakeOAuth.refresh_token?(context.fake, "rt-1")
      assert Store.get(context.state_dir, binding.key) == nil
      assert %{state: :signed_out} = OAuth.status(binding)
    end

    @tag fake: [revocation: :refuse]
    test "a provider that refuses is said not to have been told, and the sign-in is forgotten anyway",
         context do
      binding = signed_in(context)

      assert {:ok, %{state: :failed, reason: reason}} = OAuth.sign_out(binding)
      assert reason =~ "invalid_request"
      assert [_revoke] = revocations()
      assert Store.get(context.state_dir, binding.key) == nil
      assert FakeOAuth.refresh_token?(context.fake, "rt-1")
    end

    @tag fake: [revocation: :slow]
    test "a provider that does not answer in time is said not to have been told", context do
      binding = signed_in(context)
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{state: :failed, reason: reason}} = OAuth.sign_out(binding, timeout_ms: 300)
      assert System.monotonic_time(:millisecond) - started < 1_500
      assert reason =~ "could not be reached"
      assert Store.get(context.state_dir, binding.key) == nil
    end

    @tag fake: [revocation: :none]
    test "a provider with no revocation endpoint is named as such", context do
      binding = signed_in(context)

      assert {:ok, %{state: :unsupported, reason: nil}} = OAuth.sign_out(binding)
      assert revocations() == []
      assert Store.get(context.state_dir, binding.key) == nil
    end

    @tag fake: [revocation_endpoint: "https://169.254.169.254/latest/revoke"]
    test "a revocation endpoint at a link-local address is not sent the token", context do
      binding = signed_in(context)

      assert {:ok, %{state: :failed, reason: reason}} = OAuth.sign_out(binding)
      assert reason =~ "link-local"
      assert Store.get(context.state_dir, binding.key) == nil
    end

    test "a sign-in kept before revocation was looked for finds the endpoint in the metadata",
         context do
      binding = signed_in(context)
      entry = Store.get(context.state_dir, binding.key)
      :ok = Store.put(context.state_dir, binding.key, Map.delete(entry, "revocation_endpoint"))

      assert {:ok, %{state: :revoked}} = OAuth.sign_out(binding)
      assert [_revoke] = revocations()
    end

    test "nothing held is nothing to tell", context do
      assert {:ok, %{state: :none}} = OAuth.sign_out(sign_in_of(context))
      assert revocations() == []
    end

    test "every sign-in at once, for troupe logout", context do
      binding = signed_in(context)

      assert {:ok, [%{server: "notes", state: :revoked}]} =
               OAuth.sign_out_all(context.state_dir)

      assert Store.all(context.state_dir) == %{}
      refute FakeOAuth.refresh_token?(context.fake, "rt-1")
      assert %{state: :signed_out} = OAuth.status(binding)
    end
  end

  describe "reading the entry" do
    test "oauth is read from mcp.json, with the spellings other tools write" do
      assert {:ok, entry, []} =
               Import.normalize("notes", %{
                 "url" => "https://mcp.example.com/mcp",
                 "oauth" => %{"clientId" => "abc", "callbackPort" => 33_418, "scope" => "a b"}
               })

      assert entry["oauth"] == %{
               "client_id" => "abc",
               "redirect_uri" => "http://localhost:33418/callback",
               "scopes" => ["a", "b"]
             }

      assert {:error, "oauth is not an object"} =
               Import.normalize("notes", %{"url" => "x", "oauth" => "yes"})
    end

    test "a server's config carries the sign-in, or refuses to start without what it needs" do
      config =
        Local.to_config(
          "notes",
          %{"url" => "https://mcp.example.com/mcp", "oauth" => %{"client_id" => "abc"}},
          nil
        )

      assert %{oauth: %{client_id: "abc", resource: true, scopes: nil}} = config
      refute Map.has_key?(config, :refused)

      assert %{refused: "notes: oauth has no client_id" <> _} =
               Local.to_config(
                 "notes",
                 %{"url" => "https://mcp.example.com/mcp", "oauth" => %{"scopes" => ["a"]}},
                 nil
               )

      assert %{refused: "notes has oauth but no url" <> _} =
               Local.to_config(
                 "notes",
                 %{"command" => "x", "oauth" => %{"client_id" => "abc"}},
                 nil
               )

      assert %{refused: "notes: oauth.redirect_uri must be" <> _} =
               Local.to_config(
                 "notes",
                 %{
                   "url" => "https://mcp.example.com/mcp",
                   "oauth" => %{"client_id" => "abc", "redirect_uri" => "https://example.com/cb"}
                 },
                 nil
               )

      # A changed client is a changed server, for a workspace's trust.
      plain = Local.to_config("notes", %{"url" => "https://mcp.example.com/mcp"}, nil)

      other =
        Local.to_config(
          "notes",
          %{"url" => "https://mcp.example.com/mcp", "oauth" => %{"client_id" => "xyz"}},
          nil
        )

      assert Local.fingerprint(plain) != Local.fingerprint(config)
      assert Local.fingerprint(config) != Local.fingerprint(other)
    end

    test "the challenge, the resource and the places metadata is looked for" do
      assert OAuth.challenge(
               ~s(Bearer resource_metadata="https://mcp.example.com/.well-known/x", scope="a b", error=invalid_token)
             ) ==
               %{
                 "resource_metadata" => "https://mcp.example.com/.well-known/x",
                 "scope" => "a b",
                 "error" => "invalid_token"
               }

      assert OAuth.challenge(~s(Basic realm="x")) == %{}
      assert OAuth.challenge(nil) == %{}

      assert OAuth.resource("HTTPS://MCP.Example.com/") == "https://mcp.example.com"

      assert OAuth.metadata_places("https://login.example.com/tenant/v2.0") == [
               "https://login.example.com/.well-known/oauth-authorization-server/tenant/v2.0",
               "https://login.example.com/.well-known/openid-configuration/tenant/v2.0",
               "https://login.example.com/tenant/v2.0/.well-known/openid-configuration"
             ]

      assert {:error, _} = OAuth.secure("http://mcp.example.com/mcp", "the server")
      assert :ok = OAuth.secure("http://127.0.0.1:4000/mcp", "the server")
      assert {:ok, {"127.0.0.1", 0, "/"}} = OAuth.loopback_redirect("http://127.0.0.1")
      assert :error = OAuth.loopback_redirect("http://192.0.2.1:80/cb")
    end

    # A name is resolved now (Decision 875); names are in `Troupe.MCPOAuthAddressTest`,
    # which says what they resolve to.
    test "a token goes to no link-local, metadata or unspecified address (Decision 856's list)" do
      assert :ok = OAuth.outbound("https://192.0.2.10/oauth2/revoke", "the endpoint")
      assert :ok = OAuth.outbound("http://127.0.0.1:4000/revoke", "the endpoint")
      assert :ok = OAuth.outbound("https://10.0.0.5/revoke", "the endpoint")

      assert {:error, "the revocation endpoint (https://169.254.169.254/r) is link-local"} =
               OAuth.outbound("https://169.254.169.254/r", "the revocation endpoint")

      for url <- ~w(https://[fe80::1]/r https://[::ffff:169.254.169.254]/r
                    https://100.100.100.200/r https://[fd00:ec2::254]/r https://0.0.0.0/r
                    http://login.example.com/r) do
        assert {:error, _why} = OAuth.outbound(url, "the endpoint"), url
      end
    end

    test "a 403 that wants a scope comes back as one, with the challenge that names it",
         context do
      binding = signed_in(context)
      token = Store.get(context.state_dir, binding.key)["access_token"]

      server = Server.from_config(%{"name" => "notes", "url" => context.fake.mcp_url})

      assert {:error, {:insufficient_scope, header}} =
               Client.call_tool(%{server | credential: token}, "write", %{})

      assert %{"error" => "insufficient_scope", "scope" => "notes.write"} =
               OAuth.challenge(header)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
