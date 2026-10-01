Code.require_file("../../../../troupe_core/test/support/fake_oauth.exs", __DIR__)

defmodule Troupe.Gateway.MCPSignInTest do
  @moduledoc """
  `mcp.sign_in`, `mcp.sign_out` and `mcp.list`'s `auth` through the daemon's own socket
  (Decision 741), against the suite's fake authorization server and protected MCP
  server: a client asks for the sign-in, opens the URL it is given, and reads how it
  stands from the listing — never a token. A server with no `oauth`, one nobody named,
  and a workspace's server in a workspace nobody has trusted are not signed in to.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Error}
  alias Troupe.Test.FakeOAuth

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_AUTH_TOKEN TROUPE_PROVIDER TROUPE_MODEL)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-sign-in-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))
    File.mkdir_p!(workspace)

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    File.write!(
      Path.join([base, "config", "config.yaml"]),
      "version: 1\nprovider: fake\nmodels:\n  default: fake-model\n"
    )

    fake = FakeOAuth.start(self())

    File.write!(
      Path.join([base, "config", "mcp.json"]),
      Jason.encode!(%{
        "mcpServers" => %{
          "notes" => %{"url" => fake.mcp_url, "oauth" => %{"client_id" => FakeOAuth.client_id()}},
          "plain" => %{"url" => fake.mcp_url}
        }
      })
    )

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false)

    on_exit(fn ->
      if Process.alive?(client), do: Client.close(client)
      FakeOAuth.stop(fake)

      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, fake: fake, client: client}
  end

  defp notes(client, params \\ %{}) do
    {:ok, %{"servers" => servers}} = Client.call(client, "mcp.list", params)
    Enum.find(servers, &(&1["name"] == "notes"))
  end

  test "a client asks for the sign-in, opens the URL, and reads how it stands", context do
    assert %{
             "oauth" => %{"client_id" => client_id},
             "auth" => %{"state" => "signed_out", "account" => nil, "error" => nil}
           } = notes(context.client)

    assert client_id == FakeOAuth.client_id()

    assert {:ok,
            %{"server" => "notes", "url" => url, "redirect_uri" => redirect, "expires_at" => _}} =
             Client.call(context.client, "mcp.sign_in", %{
               "command_id" => "c-1",
               "name" => "notes"
             })

    assert String.starts_with?(url, context.fake.issuer <> "/authorize?")
    assert redirect =~ ~r"^http://127\.0\.0\.1:\d+/callback$"
    assert %{"auth" => %{"state" => "signing_in"}} = notes(context.client)

    assert {200, page} = FakeOAuth.browse(url)
    assert page =~ "Signed in to notes as #{FakeOAuth.account()}"

    listed = notes(context.client)
    assert %{"auth" => %{"state" => "signed_in", "account" => "ada@example.test"}} = listed
    refute inspect(listed) =~ "at-1"
    refute inspect(listed) =~ "rt-1"

    # The server's tools come with the token now, when the server is tried.
    assert {:ok, %{"server" => %{"state" => "ready", "tools" => ["search"]}}} =
             Client.call(context.client, "mcp.check", %{"name" => "notes"})

    assert {:ok, %{"server" => "notes", "auth" => %{"state" => "signed_out"}}} =
             Client.call(context.client, "mcp.sign_out", %{
               "command_id" => "c-2",
               "name" => "notes"
             })

    assert {:ok, %{"server" => %{"state" => "sign_in", "tools" => []}}} =
             Client.call(context.client, "mcp.check", %{"name" => "notes"})
  end

  test "a server with no oauth, one nobody named, and an untrusted workspace's are not signed in to",
       context do
    assert %{"auth" => nil, "oauth" => nil} =
             context.client
             |> Client.call("mcp.list", %{})
             |> elem(1)
             |> Map.fetch!("servers")
             |> Enum.find(&(&1["name"] == "plain"))

    assert {:error, %Error{message: "invalid_params", data: %{"reason" => reason}}} =
             Client.call(context.client, "mcp.sign_in", %{
               "command_id" => "c-3",
               "name" => "plain"
             })

    assert reason =~ "oauth.client_id"

    assert {:error, %Error{message: "not_found"}} =
             Client.call(context.client, "mcp.sign_in", %{
               "command_id" => "c-4",
               "name" => "nobody"
             })

    File.mkdir_p!(Path.join(context.workspace, ".troupe"))

    File.write!(
      Path.join([context.workspace, ".troupe", "mcp.json"]),
      Jason.encode!(%{
        "mcpServers" => %{
          "theirs" => %{
            "url" => context.fake.mcp_url,
            "oauth" => %{"client_id" => FakeOAuth.client_id()}
          }
        }
      })
    )

    assert {:error, %Error{message: "invalid_params", data: %{"reason" => reason}}} =
             Client.call(context.client, "mcp.sign_in", %{
               "command_id" => "c-5",
               "name" => "theirs",
               "workspace" => context.workspace
             })

    assert reason =~ "not approved here yet"
  end
end
