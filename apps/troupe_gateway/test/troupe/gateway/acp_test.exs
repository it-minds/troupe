defmodule Troupe.Gateway.ACPTest do
  @moduledoc """
  An editor that speaks ACP, driving a Troupe session on the socket that already exists.

  The claim is that this is an *adapter*, and the way to test an adapter is to check that
  nothing underneath changed. So the assertions are mostly about things staying true: the
  same scopes refuse the same things, the durable log is the same log, the approval flow is
  the approval flow, and a session outlives the editor that opened it.

  What ACP genuinely brings is the last of those. ACP was designed for an agent subprocess
  that dies with the editor; here the session is on the other side of a socket, and the
  done item that matters is that killing the client mid-turn costs nothing and the next
  client sees the whole turn.
  """

  use Troupe.Gateway.HarnessCase, async: false

  alias Troupe.Gateway.ACP
  alias Troupe.Session.Log

  @moduletag timeout: 120_000

  # These sessions are created by the editor, over the protocol, so the harness's
  # per-session `Fake` handle never reaches them — there is nothing to hand it to. A
  # scripted file plus the environment is how any daemon-created session gets a model, and
  # is what the restart suite already does for the same reason.
  setup context do
    script = Path.join(context.base, "script.json")
    File.write!(script, Jason.encode!(%{"steps" => [], "default" => %{"text" => "ok"}}))

    previous = {System.get_env("TROUPE_PROVIDER"), System.get_env("TROUPE_FAKE_SCRIPT")}
    System.put_env("TROUPE_PROVIDER", "fake")
    System.put_env("TROUPE_FAKE_SCRIPT", script)

    on_exit(fn ->
      case previous do
        {nil, _} -> System.delete_env("TROUPE_PROVIDER")
        {provider, _} -> System.put_env("TROUPE_PROVIDER", provider)
      end

      case previous do
        {_, nil} -> System.delete_env("TROUPE_FAKE_SCRIPT")
        {_, path} -> System.put_env("TROUPE_FAKE_SCRIPT", path)
      end
    end)

    %{script: script}
  end

  # Rewrite the script a session will pick up when it starts. Written before the session is
  # created, because the steps are read once at start.
  defp script!(context, steps, default \\ %{"text" => "ok"}) do
    File.write!(context.script, Jason.encode!(%{"steps" => steps, "default" => default}))
  end

  # A raw socket rather than `Troupe.Protocol.Client`, because the client speaks Troupe's
  # protocol and the whole point here is to be something that does not.
  defp acp_connect(context, opts \\ []) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, context.port, [:binary, active: false, packet: :raw])

    on_exit(fn -> :gen_tcp.close(socket) end)

    request(socket, 1, "initialize", %{
      "protocolVersion" => 1,
      "clientInfo" => %{"name" => "zed", "version" => "1"},
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => true, "writeTextFile" => true},
        "terminal" => true
      },
      "auth" => %{"token" => Keyword.get(opts, :token, "ada@example.test")}
    })

    {socket, await(socket, 1)}
  end

  defp request(socket, id, method, params) do
    line =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    :ok = :gen_tcp.send(socket, [line, "\n"])
  end

  # Read until the frame answering this id arrives. Everything else on the way is the
  # other direction — `session/update` notifications, permission requests — and is not
  # this function's business.
  defp await(socket, id, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(socket, id, deadline, "")
  end

  defp do_await(socket, id, deadline, buffer) do
    {frames, rest} = frames(buffer)

    case Enum.find(frames, &(Map.get(&1, "id") == id and not Map.has_key?(&1, "method"))) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("no answer to id #{id}; saw #{inspect(Enum.map(frames, & &1["method"]))}")
        end

        {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        do_await(socket, id, deadline, rest <> data)

      answer ->
        answer
    end
  end

  # Collect notifications and server-to-client requests until `done?` says stop.
  defp collect_until(socket, done?, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(socket, done?, deadline, "", [])
  end

  defp do_collect(socket, done?, deadline, buffer, seen) do
    {frames, rest} = frames(buffer)
    seen = seen ++ frames

    cond do
      Enum.any?(seen, done?) ->
        seen

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("gave up; saw #{inspect(Enum.map(seen, & &1["method"]))}")

      true ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, data} -> do_collect(socket, done?, deadline, rest <> data, seen)
          {:error, :timeout} -> do_collect(socket, done?, deadline, rest, seen)
        end
    end
  end

  defp frames(buffer) do
    {complete, [rest]} = buffer |> String.split("\n") |> Enum.split(-1)
    {Enum.map(complete, &Jason.decode!/1), rest}
  end

  # Created over the protocol, so the harness's own bookkeeping never sees it — nothing
  # registered it and nothing will stop it. A session left running is visible to every
  # later test in this VM, which is how `session.list is empty before anything runs`
  # started failing about something that happened in another file.
  defp new_session(socket, context, id) do
    request(socket, id, "session/new", %{"cwd" => context.workspace, "mcpServers" => []})
    session_id = await(socket, id)["result"]["sessionId"]
    on_exit(fn -> Troupe.stop_session(session_id) end)
    session_id
  end

  defp update?(frame, kind) do
    frame["method"] == "session/update" and
      get_in(frame, ["params", "update", "sessionUpdate"]) == kind
  end

  describe "the handshake" do
    test "an ACP client is answered in ACP, on the same socket and the same token", context do
      {_socket, hello} = acp_connect(context)

      assert hello["result"]["protocolVersion"] == ACP.version()
      assert hello["result"]["agentInfo"]["name"] == "troupe"

      # Empty on purpose. The socket said who this is before ACP was mentioned, so there is
      # nothing for an editor to authenticate with and offering a method would invite a
      # round trip that could only fail.
      assert hello["result"]["authMethods"] == []
    end

    test "a Troupe client on the same listener still gets Troupe", context do
      # The discriminator is what the client sent, not a port or a flag somebody sets. Both
      # protocols are answered on one listener and neither has to know about the other.
      client = attach(context, "ada@example.test")
      assert {:ok, %{"sessions" => _}} = Client.call(client, "session.list", %{})
    end

    test "a method ACP does not define here is refused rather than ignored", context do
      {socket, _hello} = acp_connect(context)

      request(socket, 2, "session/load", %{
        "sessionId" => "s-1",
        "cwd" => "/tmp",
        "mcpServers" => []
      })

      answer = await(socket, 2)

      # `loadSession` is advertised false, and the refusal matches: an editor discovers a
      # missing capability by being told, not by a call that silently does nothing.
      assert answer["error"]["code"] == -32_601
    end
  end

  describe "a session" do
    test "is created, subscribed and streamed without the editor asking for any of it",
         context do
      script!(context, [%{"text" => "hello from the agent"}])
      {socket, _hello} = acp_connect(context)

      request(socket, 2, "session/new", %{"cwd" => context.workspace, "mcpServers" => []})
      created = await(socket, 2)

      # ACP's shape, not Troupe's.
      session_id = created["result"]["sessionId"]
      on_exit(fn -> Troupe.stop_session(session_id) end)
      assert is_binary(session_id)
      refute Map.has_key?(created["result"], "session_id")

      request(socket, 3, "session/prompt", %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => "say something"}]
      })

      # ACP has no `subscribe`; the adapter did it, which is the mapping in the table made
      # to happen rather than described.
      seen = collect_until(socket, &update?(&1, "agent_message_chunk"))

      chunk = Enum.find(seen, &update?(&1, "agent_message_chunk"))
      assert chunk["params"]["sessionId"] == session_id
      assert chunk["params"]["update"]["content"]["type"] == "text"
    end

    test "a relative cwd is refused, because it is not anywhere the person meant", context do
      {socket, _hello} = acp_connect(context)

      request(socket, 2, "session/new", %{"cwd" => "relative/path", "mcpServers" => []})
      answer = await(socket, 2)

      assert answer["error"]["data"]["reason"] =~ "absolute"
    end
  end

  describe "the durable log" do
    test "is the same log, and says nothing about ACP", context do
      script!(context, [%{"text" => "ok"}])
      {socket, _hello} = acp_connect(context)

      session_id = new_session(socket, context, 2)

      request(socket, 3, "session/prompt", %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => "a thing somebody typed"}]
      })

      collect_until(socket, &update?(&1, "agent_message_chunk"))

      # The record is the record. An ACP client is a way in, and a transcript does not say
      # which door somebody used — the events are the ones any other client would produce.
      events = Log.replay(session_id)
      types = Enum.map(events, & &1.type)

      assert "user_input" in types
      assert "session_created" in types
      refute Enum.any?(types, &String.contains?(&1, "acp"))

      input = Enum.find(events, &(&1.type == "user_input"))
      assert input.data["text"] == "a thing somebody typed"
    end
  end

  describe "a permission request" do
    test "is ACP's, the decision is Troupe's, and allow-always is the one that exists",
         context do
      script!(
        context,
        [
          %{
            "tools" => [
              %{"name" => "write_file", "args" => %{"path" => "a.txt", "content" => "hi"}}
            ]
          }
        ],
        %{"text" => "done"}
      )

      {socket, _hello} = acp_connect(context)
      session_id = new_session(socket, context, 2)

      request(socket, 3, "session/prompt", %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => "write the file"}]
      })

      seen = collect_until(socket, &(&1["method"] == "session/request_permission"))
      ask = Enum.find(seen, &(&1["method"] == "session/request_permission"))

      assert ask["params"]["sessionId"] == session_id
      assert ask["params"]["toolCall"]["title"] == "write_file"

      kinds = Enum.map(ask["params"]["options"], & &1["kind"])
      assert "allow_once" in kinds
      assert "allow_always" in kinds

      # And not offered, because it cannot be honoured: a standing refusal would have to
      # deny every later call without asking, and nothing records that.
      refute "reject_always" in kinds

      # Answering it is answering the approval flow. Nothing is blocked on this connection
      # — first-wins still settles two clients answering at once.
      answer = %{
        "jsonrpc" => "2.0",
        "id" => ask["id"],
        "result" => %{
          "outcome" => %{"outcome" => "selected", "optionId" => "allow_session"}
        }
      }

      :ok = :gen_tcp.send(socket, [Jason.encode!(answer), "\n"])

      collect_until(socket, &update?(&1, "tool_call_update"))

      events = Log.replay(session_id)
      decided = Enum.find(events, &(&1.type == "approval_decided"))
      # `allow_session`, not `allow`. That is the evidence for the mapping: ACP's
      # `allow_always` landed on the decision the approval flow already had, rather than on
      # an allow plus a switch set beside it.
      assert decided.data["decision"] == "allow_session"
    end
  end

  describe "the session is not the editor's process" do
    test "killing the client mid-turn leaves the turn running, and the next client sees it",
         context do
      script!(context, [%{"text" => "a long answer the editor will not see"}])

      {socket, _hello} = acp_connect(context)
      session_id = new_session(socket, context, 2)

      request(socket, 3, "session/prompt", %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => "start something"}]
      })

      # The editor dies the moment the turn begins. This is the done item, and it is the
      # one property ACP's own design does not have: an ACP agent is a subprocess that goes
      # with its editor, and this one is not.
      collect_until(socket, &update?(&1, "user_message_chunk"))
      :gen_tcp.close(socket)

      # The turn runs on without it, and `llm_response` is the proof: the model was called
      # and answered after the socket was closed. Waited for on the log rather than on an
      # event, because the editor is gone and there is nobody left to tell.
      eventually(
        fn -> Enum.any?(Log.replay(session_id), &(&1.type == "llm_response")) end,
        30_000
      )

      # And a fresh client, speaking Troupe, is handed the whole of it from the beginning.
      watcher = attach(context, "bob@example.test")
      {:ok, _} = Client.subscribe(watcher, "session:#{session_id}", from_seq: 0)

      assert_receive {:troupe_event, _topic, _id, %Event{type: "user_input"}}, 15_000

      events = Log.replay(session_id)
      assert Enum.any?(events, &(&1.type == "llm_response"))
      assert Enum.any?(events, &(&1.type == "user_input"))
    end

    test "session/close detaches and does not end the session", context do
      script!(context, [%{"text" => "ok"}])

      {socket, _hello} = acp_connect(context)
      session_id = new_session(socket, context, 2)

      request(socket, 4, "session/close", %{"sessionId" => session_id})
      assert await(socket, 4)["result"] == %{}

      # Still there, and still somebody's.
      assert Troupe.get_session(session_id)
    end
  end

  describe "a protocol is a way in, never a second set of permissions" do
    test "an observer over ACP cannot steer, and is refused the same way", context do
      script!(context, [%{"text" => "ok"}])

      # The harness maps `#observe` to the observe scope alone. ACP does not change that,
      # because the scope came from the connection and not from the protocol.
      {socket, _hello} = acp_connect(context, token: "bob@example.test#observe")

      request(socket, 2, "session/new", %{"cwd" => context.workspace, "mcpServers" => []})
      answer = await(socket, 2)

      assert answer["error"]["message"] == "forbidden"

      # Whichever scope creating needs, the point is that it came from the connection: an
      # editor speaking ACP is refused for want of it exactly as any other client is.
      assert answer["error"]["data"]["required_scope"] in ["control", "admin"]
    end
  end
end
