Code.require_file("../../../../troupe_core/test/support/fake_oauth.exs", __DIR__)

defmodule Troupe.Gateway.MCPCallTest do
  @moduledoc """
  `mcp.tools` and `mcp.call` (Decision 748): a person's own server, listed and called by
  the daemon outside any session, with their sign-in, for a client that offers its tools
  to a session somewhere else — a pod's — as tools it hosts (PROTOCOL.md §8).

  The daemon makes the call, so the token stays where the sign-in put it; what goes back
  is what a session's model would read, a refresh and `sign_in_required` included. The
  last test is the whole path: a session that reads none of the person's files, as a
  pod's does not, has its agent call the person's server through the client that offered
  it, and nothing of the token is in the session.
  """

  use Troupe.Gateway.HarnessCase, async: false

  alias Troupe.LLM.Fake
  alias Troupe.Protocol.Error
  alias Troupe.Session.Log
  alias Troupe.Test.FakeOAuth

  @ada "ada@example.test"
  @vars ~w(TROUPE_CONFIG_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH)

  # The fake's access and refresh tokens are `at-<n>` and `rt-<n>`.
  @token ~r/\b[ar]t-\d+\b/

  setup context do
    config = Path.join(context.base, "config")
    File.mkdir_p!(config)

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    System.put_env("TROUPE_CONFIG_HOME", config)
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(context.base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(context.base, "none.json"))

    File.write!(
      Path.join(config, "config.yaml"),
      "version: 1\nprovider: fake\nmodels:\n  default: fake-model\n"
    )

    fake = FakeOAuth.start(self())

    File.write!(
      Path.join(config, "mcp.json"),
      Jason.encode!(%{
        "mcpServers" => %{
          "notes" => %{"url" => fake.mcp_url, "oauth" => %{"client_id" => FakeOAuth.client_id()}},
          "shell" => %{"command" => "true"}
        }
      })
    )

    on_exit(fn ->
      FakeOAuth.stop(fake)

      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)
    end)

    %{fake: fake, daemon: attach(context, @ada)}
  end

  test "a signed-in server's tools are listed with what a model needs, and one is called with the person's sign-in",
       context do
    sign_in(context)

    assert {:ok, listed} = Client.call(context.daemon, "mcp.tools", %{"name" => "notes"})

    assert %{"server" => "notes", "state" => "ready", "error" => nil, "tools" => [search]} =
             listed

    assert search["name"] == "search"
    assert search["description"] =~ "Search my notes."
    assert search["schema"]["properties"]["topic"] == %{"type" => "string"}

    assert {:ok, called} = call(context.daemon, "search", %{"topic" => "the plan"})

    assert called == %{
             "server" => "notes",
             "tool" => "search",
             "content" => "notes on the plan, for #{@ada}"
           }

    # The daemon made the call, with the token the sign-in left in its state directory.
    assert {"tools/call", "Bearer at-1"} in server_calls()

    refute inspect(listed) =~ @token
    refute inspect(called) =~ @token
  end

  test "before a sign-in the server waits for one, and a call says so as a session's model is told",
       context do
    assert {:ok, %{"state" => "sign_in", "tools" => [], "error" => why}} =
             Client.call(context.daemon, "mcp.tools", %{"name" => "notes"})

    assert why =~ "sign in to notes"

    assert {:ok, %{"content" => content}} = call(context.daemon, "search", %{"topic" => "x"})

    assert %{"error" => "sign_in_required", "server" => "notes", "hint" => hint} =
             Jason.decode!(content)

    assert hint =~ "Servers and skills"
  end

  test "a token the server stops taking is refreshed and the call made again, and a refused refresh asks for a sign-in",
       context do
    sign_in(context)

    FakeOAuth.revoke_access(context.fake)

    assert {:ok, %{"content" => "notes on again, for " <> _}} =
             call(context.daemon, "search", %{"topic" => "again"})

    assert refreshed?()

    FakeOAuth.revoke_access(context.fake)
    FakeOAuth.refuse_refresh(context.fake)

    assert {:ok, %{"content" => content}} =
             call(context.daemon, "search", %{"topic" => "once more"})

    assert %{"error" => "sign_in_required"} = Jason.decode!(content)

    # And every client says so, as it does after a local session found out.
    {:ok, %{"servers" => servers}} = Client.call(context.daemon, "mcp.list", %{})
    assert %{"auth" => %{"state" => "expired"}} = Enum.find(servers, &(&1["name"] == "notes"))
  end

  test "a server that runs a command, one nobody named, an unapproved workspace's, and a caller without admin are refused",
       context do
    assert {:error, %Error{message: "invalid_params", data: %{"reason" => reason}}} =
             Client.call(context.daemon, "mcp.tools", %{"name" => "shell"})

    assert reason =~ "url"

    assert {:error, %Error{message: "not_found"}} =
             Client.call(context.daemon, "mcp.tools", %{"name" => "nobody"})

    File.mkdir_p!(Path.join(context.workspace, ".troupe"))

    File.write!(
      Path.join([context.workspace, ".troupe", "mcp.json"]),
      Jason.encode!(%{"mcpServers" => %{"theirs" => %{"url" => context.fake.mcp_url}}})
    )

    assert {:error, %Error{message: "invalid_params", data: %{"reason" => reason}}} =
             Client.call(context.daemon, "mcp.call", %{
               "command_id" => Client.command_id(),
               "name" => "theirs",
               "tool" => "search",
               "workspace" => context.workspace
             })

    assert reason =~ "not approved here yet"

    watcher = attach(context, "bob@example.test#observe")

    assert {:error, %Error{message: "forbidden", data: %{"required_scope" => "admin"}}} =
             Client.call(watcher, "mcp.tools", %{"name" => "notes"})
  end

  test "a pod session's agent calls the person's server through the client that offered it, and no token reaches the session",
       context do
    sign_in(context)

    session =
      pod_session(context, steps: [{:tools, [{"client.notes.search", %{"topic" => "the plan"}}]}])

    # The desktop app's two connections: one to the pod, one to the person's daemon.
    pod = attach(context, @ada)
    {:ok, %{"tools" => [tool]}} = Client.call(context.daemon, "mcp.tools", %{"name" => "notes"})

    offered = %{
      "name" => "notes." <> tool["name"],
      "description" => tool["description"],
      "schema" => tool["schema"]
    }

    assert {:ok, %{"registered" => ["client.notes.search"]}} = register(pod, session.id, offered)

    {:ok, _} = Client.subscribe(pod, "session:#{session.id}", from_seq: 0)

    {:ok, _} =
      Client.call(pod, "input.send", %{
        "command_id" => Client.command_id(),
        "session_id" => session.id,
        "text" => "what do my notes say about the plan?"
      })

    # The pod asks the client that offered the tool; the client asks the daemon, which
    # calls the server with the person's sign-in; the answer goes back as the tool's.
    assert_receive {:troupe_request, id, "tool.invoke",
                    %{"name" => "client.notes.search"} = invoke},
                   15_000

    {:ok, %{"content" => content}} =
      Client.call(context.daemon, "mcp.call", %{
        "command_id" => "call-#{session.id}-#{invoke["call_id"]}",
        "name" => "notes",
        "tool" => "search",
        "arguments" => invoke["arguments"]
      })

    :ok = Client.respond(pod, id, %{"content" => content})

    events = collect("session:#{session.id}", &(&1.type == "tool_call_completed"))
    completed = Enum.find(events, &(&1.type == "tool_call_completed"))
    assert completed.data["ok"] == true
    assert completed.data["content"] =~ "notes on the plan, for #{@ada}"

    assert {"tools/call", "Bearer at-1"} in server_calls()

    # Nothing the session holds — and so nothing a pod logs or a plane is sent — has the
    # token in it: the registration, the call, the answer.
    logged = session.id |> Log.replay() |> Enum.map(&Jason.encode!(&1.data))
    assert Enum.any?(logged, &(&1 =~ "notes on the plan"))
    refute Enum.any?(logged, &(&1 =~ @token))
  end

  # -- helpers ----------------------------------------------------------------

  defp sign_in(context) do
    {:ok, %{"url" => url}} =
      Client.call(context.daemon, "mcp.sign_in", %{
        "command_id" => Client.command_id(),
        "name" => "notes"
      })

    {200, _page} = FakeOAuth.browse(url)
    :ok
  end

  # Every request that has reached the MCP server so far, as its JSON-RPC method and the
  # authorization it carried.
  defp server_calls do
    receive do
      {:fake_oauth, %{path: "/mcp", headers: headers, body: body}} ->
        [{Jason.decode!(body)["method"], headers["authorization"]} | server_calls()]
    after
      0 -> []
    end
  end

  defp refreshed? do
    receive do
      {:fake_oauth, %{path: "/tenant/token", body: body}} ->
        body =~ "grant_type=refresh_token" or refreshed?()
    after
      0 -> false
    end
  end

  defp call(client, tool, arguments) do
    Client.call(client, "mcp.call", %{
      "command_id" => Client.command_id(),
      "name" => "notes",
      "tool" => tool,
      "arguments" => arguments
    })
  end

  # A session as a pod runs one: it reads none of the person's `mcp.json`, so the only
  # way it has to their server is a tool a client offers it.
  defp pod_session(context, opts) do
    fake =
      start_supervised!({Fake, Keyword.put(opts, :default, {:text, "found it"})},
        id: {Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        kind: :team,
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake",
          state_dir: context.state_dir,
          auto_approve: true
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  defp register(client, session_id, tool) do
    {:error, %Error{message: "consent_required", data: %{"challenge" => challenge}}} =
      Client.call(client, "tools.register", %{
        "command_id" => Client.command_id(),
        "session_id" => session_id,
        "tools" => [tool]
      })

    Client.call(client, "tools.register", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id,
      "tools" => [tool],
      "consent" => %{"challenge" => challenge, "confirmed_by" => @ada}
    })
  end
end
