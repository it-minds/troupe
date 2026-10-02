# The core suite's fake authorization server and protected MCP server (Decision 741).
Code.require_file("../../../../apps/troupe_core/test/support/fake_oauth.exs", __DIR__)

defmodule Troupe.RemoteClientToolsTest do
  @moduledoc """
  A person's own signed-in MCP servers, offered to a session on a pod (issue #308, root
  Decision 748): the TUI lists their tools on the daemon (`mcp.list`, `mcp.tools`),
  registers them with the session through the consent round trip (PROTOCOL.md section 8),
  asks the person in the session's window, serves the pod's `tool.invoke` by asking the
  daemon to make the call (`mcp.call`), and registers them again on every new socket
  without asking again. The suite's one config directory is written here, which is why
  this runs alone.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers, only: [eventually: 1, eventually: 2]

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote
  alias Troupe.Test.FakeOAuth

  @moduletag :remote

  setup do
    config_home = System.fetch_env!("TROUPE_CONFIG_HOME")
    fake = FakeOAuth.start(self())

    File.write!(
      Path.join(config_home, "mcp.json"),
      Jason.encode!(%{
        "mcpServers" => %{
          "notes" => %{"url" => fake.mcp_url, "oauth" => %{"client_id" => FakeOAuth.client_id()}}
        }
      })
    )

    on_exit(fn ->
      _ = Link.call("mcp.sign_out", %{name: "notes", command_id: Troupe.Remote.RPC.command_id()})
      File.rm_rf!(Path.join(config_home, "mcp.json"))
      FakeOAuth.stop(fake)
    end)

    {:ok, %{"url" => url}} =
      Link.call("mcp.sign_in", %{name: "notes", command_id: Troupe.Remote.RPC.command_id()})

    {200, _page} = FakeOAuth.browse(url)
    eventually(fn -> signed_in?() end, 10_000)

    session =
      FakeRemote.session(
        id: "s-tools",
        events: [%{"type" => "message.completed", "data" => %{"text" => "ready"}}]
      )

    {remote, plane} = start_remote!(sessions: [session])
    %{remote: remote, origin: connect!(remote, plane)}
  end

  test "the person's signed-in server is offered once they say yes, called through the daemon, and offered again after a drop",
       %{remote: remote, origin: origin} do
    sid = attach!(origin, "s-tools")
    :ok = Client.subscribe(sid)

    # The session's question, in the window, naming the tool.
    assert_receive {:troupe_event, %{type: :approval_requested, data: %{call_id: ask} = asked}},
                   15_000

    assert asked.name =~ "notes.search"
    assert asked.name =~ "Let this session run 1 tool on your machine?"
    assert FakeRemote.registered(remote) == []

    :ok = Client.approve(sid, ask, :allow)
    assert_receive {:troupe_event, %{type: :approval_answered, data: %{call_id: ^ask}}}, 5_000
    eventually(fn -> FakeRemote.registered(remote) == ["notes.search"] end)

    [{_, unconsented}, {_, consented}] = registrations(remote)
    refute Map.has_key?(unconsented, "consent")
    assert %{"challenge" => "ch-" <> _} = consented["consent"]

    # The pod's agent calls it: the daemon makes the call with the person's sign-in, and
    # the pod gets what the server said, under the call id it named.
    assert %{"result" => %{"content" => content}} =
             FakeRemote.invoke_tool(remote, "notes.search", %{"topic" => "the plan"})

    assert inspect(content) =~ "notes on the plan, for #{FakeOAuth.account()}"

    # A tool this client did not offer is refused rather than left to time out.
    assert {:error, :not_registered} = FakeRemote.invoke_tool(remote, "notes.delete", %{})

    # A new socket: the registration went with the old one, and comes back through a fresh
    # challenge, answered with the consent already given for the same tools.
    FakeRemote.kill_workers(remote)
    eventually(fn -> length(registrations(remote)) == 4 end, 15_000)
    eventually(fn -> FakeRemote.registered(remote) == ["notes.search"] end)
    refute_received {:troupe_event, %{type: :approval_requested}}

    assert %{"result" => %{"content" => _}} =
             FakeRemote.invoke_tool(remote, "notes.search", %{"topic" => "again"}, "call-2")
  end

  test "a no holds for the attachment: nothing is registered, then or after a drop",
       %{remote: remote, origin: origin} do
    sid = attach!(origin, "s-tools")
    :ok = Client.subscribe(sid)

    assert_receive {:troupe_event, %{type: :approval_requested, data: %{call_id: ask}}}, 15_000
    :ok = Client.approve(sid, ask, :deny)
    assert_receive {:troupe_event, %{type: :approval_answered, data: %{call_id: ^ask}}}, 5_000

    FakeRemote.kill_workers(remote)
    await_up(sid)
    # The next socket lists the tools again, and asks nobody.
    refute_receive {:troupe_event, %{type: :approval_requested}}, 2_000
    assert FakeRemote.registered(remote) == []
    assert length(registrations(remote)) == 1
  end

  test "the window opened again while the session asks still shows the question",
       %{origin: origin} do
    sid = attach!(origin, "s-tools")
    :ok = Client.subscribe(sid)

    assert_receive {:troupe_event, %{type: :approval_requested, data: %{call_id: ask}}}, 15_000

    assert Enum.any?(
             Client.events(sid),
             &match?(%{type: :approval_requested, data: %{call_id: ^ask}}, &1)
           )

    :ok = Client.approve(sid, ask, :allow)
    assert_receive {:troupe_event, %{type: :approval_answered, data: %{call_id: ^ask}}}, 5_000
    refute Enum.any?(Client.events(sid), &(&1.type == :approval_requested))
  end

  defp registrations(remote),
    do: remote |> FakeRemote.calls() |> Enum.filter(&match?({"tools.register", _}, &1))

  defp signed_in? do
    case Link.call("mcp.list", %{}) do
      {:ok, %{"servers" => servers}} ->
        Enum.any?(servers, &match?(%{"name" => "notes", "auth" => %{"state" => "signed_in"}}, &1))

      _ ->
        false
    end
  end
end
