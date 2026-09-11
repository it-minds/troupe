defmodule Troupe.UI.TUIConnectorsTest do
  @moduledoc """
  The TUI as a harness for a personal MCP connection.

  Stage 4 says the TUI implements the harness side: it reads personal MCP servers from
  local config and offers them per session when the user opts in. Three things have to be
  true of that, and each is a way it could be quietly wrong.

  * **Nothing is offered until somebody says so.** Reading a config file is not consent
    and neither is attaching to a session.
  * **The consent step is a round trip the person sees.** `/connect notes` prints what
    the session asked and stops; only `/connect yes` registers.
  * **The call runs here.** The agent's `tool.invoke` arrives over this connection and is
    served against the person's own MCP server.

  The MCP server is a real HTTP server on a loopback port — the same streamable HTTP a
  real one speaks — because a stubbed client would test the stub.
  """

  use ExUnit.Case, async: false

  alias ExRatatui.Runtime
  alias Troupe.Gateway.Daemon
  alias Troupe.LLM.Fake
  alias Troupe.Protocol.Endpoint
  alias Troupe.UI.TUI.{Connectors, Server}

  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-connect-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    mcp = start_supervised!({__MODULE__.Notes, test_pid: self()})
    port = __MODULE__.Notes.port(mcp)

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{
      base: base,
      endpoint: endpoint,
      workspace: workspace,
      state_dir: state_dir,
      mcp_port: port
    }
  end

  describe "reading the config" do
    test "a missing config file means no connectors, not an error", context do
      System.put_env("TROUPE_MCP_CONFIG", Path.join(context.base, "nothing.json"))
      on_exit(fn -> System.delete_env("TROUPE_MCP_CONFIG") end)

      assert Connectors.load() == []
    end

    test "a credential reference names an environment variable, never a value", context do
      path = write_config(context, credential_ref: "TROUPE_TEST_NOTES_TOKEN")
      System.put_env("TROUPE_MCP_CONFIG", path)
      System.put_env("TROUPE_TEST_NOTES_TOKEN", "a-personal-token")

      on_exit(fn ->
        System.delete_env("TROUPE_MCP_CONFIG")
        System.delete_env("TROUPE_TEST_NOTES_TOKEN")
      end)

      assert [server] = Connectors.load()
      assert server.name == "notes"
      assert server.credential_ref == "TROUPE_TEST_NOTES_TOKEN"
      assert server.credential == "a-personal-token"

      # And the value is not in what a crash report would print.
      refute inspect(server) =~ "a-personal-token"
    end
  end

  describe "offering one" do
    test "attaching offers nothing at all", context do
      %{session: session} = start_session(context, steps: [])
      tui = start_tui(context, session, connectors: [notes(context)])

      assert tui_state(tui).offered == []
      assert Troupe.Session.ClientTools.list(session.id) == []
    end

    test "/connect prints the consent prompt and registers nothing", context do
      %{session: session} = start_session(context, steps: [])
      tui = start_tui(context, session, connectors: [notes(context)])

      submit(tui, "/connect notes")

      state = tui_state(tui)
      assert state.pending_consent
      assert state.offered == []
      assert last_notice(state) =~ "on your machine"
      assert last_notice(state) =~ "/connect yes"

      assert Troupe.Session.ClientTools.list(session.id) == [],
             "a prompt is not consent, and must not register anything"
    end

    test "/connect yes registers, taints the session, and says so", context do
      %{session: session} = start_session(context, steps: [])
      tui = start_tui(context, session, connectors: [notes(context)])

      submit(tui, "/connect notes")
      submit(tui, "/connect yes")

      state = tui_state(tui)
      assert state.offered == ["notes"]
      assert last_notice(state) =~ "client.notes.search"

      assert [%{name: "client.notes.search"}] = Troupe.Session.ClientTools.list(session.id)

      types = session.id |> Troupe.Session.Log.replay() |> Enum.map(& &1.type)
      assert "session_tainted" in types
    end

    test "/connect no leaves it alone", context do
      %{session: session} = start_session(context, steps: [])
      tui = start_tui(context, session, connectors: [notes(context)])

      submit(tui, "/connect notes")
      submit(tui, "/connect no")

      assert tui_state(tui).pending_consent == nil
      assert Troupe.Session.ClientTools.list(session.id) == []
    end

    test "a connector that is down costs that connector and nothing else", context do
      down = %Troupe.MCP.Server{name: "gone", url: "http://127.0.0.1:1/mcp"}

      %{session: session} = start_session(context, steps: [])
      tui = start_tui(context, session, connectors: [down])

      submit(tui, "/connect gone")

      assert last_notice(tui_state(tui)) =~ "unreachable"
      assert Process.alive?(tui)
      assert Troupe.head_seq(session.id) > 0
    end
  end

  describe "serving a call" do
    test "the agent's call reaches the person's own server and comes back", context do
      %{session: session} =
        start_session(context,
          steps: [{:tools, [{"client.notes.search", %{"q" => "the invariant"}}]}],
          default: {:text, "found it"}
        )

      tui = start_tui(context, session, connectors: [notes(context)])

      submit(tui, "/connect notes")
      submit(tui, "/connect yes")

      Troupe.subscribe(session.id)
      submit(tui, "search my notes")

      # The MCP server tells the test what it was asked, which is how "the call runs
      # here" is checked rather than assumed.
      assert_receive {:mcp_called, "search", args, meta}, 15_000
      assert args == %{"q" => "the invariant"}
      assert get_in(meta, ["troupe", "session_id"]) == session.id

      assert_receive {:troupe_event, _id, %{type: "tool_call_completed", data: data}}, 15_000
      assert data["name"] == "client.notes.search"
      assert data["ok"] == true
      assert data["content"] =~ "one note"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp notes(context) do
    Troupe.MCP.Server.from_config(%{
      "name" => "notes",
      "url" => "http://127.0.0.1:#{context.mcp_port}/mcp"
    })
  end

  defp write_config(context, opts) do
    path = Path.join(context.base, "mcp.json")

    server =
      %{"name" => "notes", "url" => "http://127.0.0.1:#{context.mcp_port}/mcp"}
      |> then(fn map ->
        case Keyword.get(opts, :credential_ref) do
          nil -> map
          reference -> Map.put(map, "credential_ref", reference)
        end
      end)

    File.write!(path, Jason.encode!(%{"servers" => [server]}))
    path
  end

  defp start_session(context, opts) do
    fake =
      start_supervised!({Fake, Keyword.take(opts, [:steps, :default, :delay_ms])},
        id: {Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake",
          state_dir: context.state_dir,
          auto_approve: true
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    %{session: session, fake: fake}
  end

  defp start_tui(context, session, opts) do
    start_supervised!(
      {Server,
       [
         session_id: session.id,
         connect: [endpoint: context.endpoint, spawn: false],
         name: nil,
         test_mode: {120, 32},
         test_pid: self()
       ] ++ opts},
      id: {Server, System.unique_integer([:positive])}
    )
  end

  defp submit(tui, text) do
    text |> String.graphemes() |> Enum.each(&key(tui, &1))
    key(tui, "enter")
    _ = tui_state(tui)
    :ok
  end

  defp key(tui, code) do
    Runtime.inject_event(tui, %ExRatatui.Event.Key{code: code, kind: "press"})
  end

  defp tui_state(tui), do: :sys.get_state(tui).user_state

  # Notices land in the transcript, which is where the person reads them.
  defp last_notice(state) do
    state.transcript
    |> Enum.reverse()
    |> Enum.find_value("", fn
      {:notice, text} -> text
      _entry -> nil
    end)
  end

  defmodule Notes do
    @moduledoc """
    A personal MCP server: streamable HTTP, one POST per request, on loopback.

    Real rather than stubbed, because what is under test is that a call made by an agent
    on a session reaches *this* process — and a stubbed client would prove only that the
    stub was called.
    """

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def port(server), do: GenServer.call(server, :port)

    @impl GenServer
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)

      {:ok, listener} =
        Bandit.start_link(
          plug: {__MODULE__.Router, test_pid},
          scheme: :http,
          port: 0,
          ip: {127, 0, 0, 1}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
      {:ok, {listener, port}}
    end

    @impl GenServer
    def handle_call(:port, _from, {_listener, port} = state), do: {:reply, port, state}

    defmodule Router do
      @moduledoc false

      @behaviour Plug

      @impl Plug
      def init(test_pid), do: test_pid

      @impl Plug
      def call(conn, test_pid) do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(answer(request, test_pid)))
      end

      defp answer(%{"id" => id, "method" => "tools/list"}, _test_pid) do
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "tools" => [
              %{
                "name" => "search",
                "description" => "Search my local notes.",
                "inputSchema" => %{
                  "type" => "object",
                  "properties" => %{"q" => %{"type" => "string"}}
                }
              }
            ]
          }
        }
      end

      defp answer(%{"id" => id, "method" => "tools/call", "params" => params}, test_pid) do
        send(test_pid, {:mcp_called, params["name"], params["arguments"], params["_meta"] || %{}})

        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"content" => [%{"type" => "text", "text" => "one note matched"}]}
        }
      end

      defp answer(%{"id" => id}, _test_pid) do
        %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}
      end
    end
  end
end
