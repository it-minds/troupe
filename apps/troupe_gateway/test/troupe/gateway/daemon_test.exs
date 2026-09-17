defmodule Troupe.Gateway.DaemonTest do
  @moduledoc """
  The daemon end to end, driven through the protocol client.

  Everything here goes over a real socket with real JSON-RPC framing. That is the
  point: these exercise exactly the surface a third-party client sees, so a change
  that would break a Python client breaks these first.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Session}
  alias Troupe.Protocol.{Client, Endpoint, Error, Event}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-daemon-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    # The daemon is one per user and its index scans the whole state directory, so a
    # test gets a state directory of its own rather than the developer's real one.
    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous, do: System.put_env("TROUPE_STATE_HOME", previous), else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{base: base, workspace: workspace, state_dir: state_dir, endpoint: endpoint}
  end

  defp connect(context, opts \\ []) do
    {address, port} = Endpoint.connect_args(context.endpoint)

    {:ok, client} =
      Client.connect(
        [address: address, port: port, client_info: %{"name" => "test", "version" => "1"}] ++ opts
      )

    client
  end

  defp start_session(context, steps) do
    fake =
      start_supervised!(
        {Troupe.LLM.Fake, steps: steps},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          auto_approve: true,
          model: "fake",
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    %{session: session, fake: fake}
  end

  describe "handshake" do
    test "initialize negotiates a version and reports the principal and scopes", context do
      client = connect(context)
      info = Client.info(client)

      assert info.protocol_version == "1"
      assert info.server_info["name"] == "troupe-daemon"
      assert is_binary(info.server_info["instance_id"])
      assert info.principal["kind"] == "user"
      assert Enum.sort(info.scopes) == [:admin, :control, :observe]
    end

    test "private_sessions is false until the daemon can name a person", context do
      # Unlinked. The daemon knows an operating-system user and calls them
      # `local:<username>`, which means nothing to a plane or to another device — so a
      # client that offered the checkbox here would be offering a session that silently
      # stayed local.
      client = connect(context)
      assert Client.info(client).capabilities["private_sessions"] == false
      Client.close(client)

      {:ok, _identity} =
        Troupe.Identity.link(
          %{subject: "idp|ada", display_name: "Ada", plane_url: "https://plane.example"},
          context.state_dir
        )

      linked = connect(context)
      info = Client.info(linked)

      assert info.principal["subject"] == "idp|ada"
      assert info.capabilities["private_sessions"] == true
      Client.close(linked)
    end

    test "a version the server cannot speak is refused, with what it can", context do
      {address, port} = Endpoint.connect_args(context.endpoint)

      assert {:error, %Error{message: "unsupported_version", data: data}} =
               raw_initialize(address, port, %{"protocol_version" => "99"})

      assert data["supported"] == ["1"]
    end

    test "a command before initialize is refused", context do
      assert %{"error" => %{"message" => "not_initialized"}} =
               raw_line(context, %{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "session.list",
                 "params" => %{}
               })
    end

    test "malformed JSON gets a parse error rather than a dropped connection", context do
      {address, port} = Endpoint.connect_args(context.endpoint)
      {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false, packet: :raw])

      :ok = :gen_tcp.send(socket, "{not json\n")
      assert {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
      assert %{"error" => %{"message" => "parse_error"}} = Jason.decode!(String.trim(line))
      :gen_tcp.close(socket)
    end
  end

  describe "commands" do
    test "an unknown method is reported, not fatal", context do
      client = connect(context)

      assert {:error, %Error{message: "method_not_found"}} = Client.call(client, "nope.nope")
      # The connection survives: a client probing for a capability must not lose it.
      assert {:ok, _} = Client.call(client, "session.list")
    end

    test "session.list is empty before anything runs, and lists a session after", context do
      client = connect(context)

      assert {:ok, %{"sessions" => []}} = Client.call(client, "session.list")

      %{session: session} = start_session(context, [{:text, "hi"}])

      assert {:ok, %{"sessions" => [listed]}} = Client.call(client, "session.list")
      assert listed["id"] == session.id
      assert listed["state"] == "active"
    end

    test "session.get reports the head sequence", context do
      %{session: session} = start_session(context, [{:text, "hi"}])
      client = connect(context)

      assert {:ok, result} = Client.call(client, "session.get", %{"session_id" => session.id})
      assert result["id"] == session.id
      assert is_integer(result["head_seq"])
    end

    test "a missing session is not_found, with the id echoed back", context do
      client = connect(context)

      assert {:error, %Error{message: "not_found", data: data}} =
               Client.call(client, "session.get", %{"session_id" => "s-nope"})

      assert data["kind"] == "session"
      assert data["id"] == "s-nope"
    end

    test "a missing parameter names the field", context do
      client = connect(context)

      assert {:error, %Error{message: "invalid_params", data: %{"missing" => "session_id"}}} =
               Client.call(client, "session.get", %{})
    end
  end

  describe "subscriptions" do
    test "replays from seq 0 then follows live, with no gap and no duplicate", context do
      %{session: session} = start_session(context, [{:text, "the answer"}, {:text, "again"}])

      Troupe.send_input(session.id, "first")
      await_idle(session.id)

      client = connect(context)

      assert {:ok, %{"head_seq" => head, "subscription_id" => sub}} =
               Client.subscribe(client, "session:#{session.id}", from_seq: 0)

      assert is_binary(sub)
      assert head > 0

      replayed = collect_events(head)
      assert Enum.map(replayed, & &1.seq) == Enum.to_list(1..head)

      Troupe.send_input(session.id, "second")

      live =
        collect_until(fn event ->
          event.type == "agent_state" and event.data["state"] == "idle"
        end)

      seqs = live |> Enum.reject(&(&1.seq == nil)) |> Enum.map(& &1.seq)

      assert seqs == Enum.sort(seqs), "durable events arrived out of order"
      assert seqs == Enum.uniq(seqs), "a durable event was delivered twice"
      assert List.first(seqs) == head + 1, "the live stream did not continue from the head"
    end

    test "from_seq skips what the client already has", context do
      %{session: session} = start_session(context, [{:text, "hi"}])
      Troupe.send_input(session.id, "hello")
      await_idle(session.id)

      client = connect(context)
      {:ok, %{"head_seq" => head}} = Client.subscribe(client, "session:#{session.id}", from_seq: 2)

      replayed = collect_events(head - 2)
      assert Enum.map(replayed, & &1.seq) == Enum.to_list(3..head)
    end

    test "the durable log and the replay agree exactly, and the chain verifies", context do
      %{session: session} = start_session(context, [{:text, "hi"}])
      Troupe.send_input(session.id, "hello")
      await_idle(session.id)

      client = connect(context)
      {:ok, %{"head_seq" => head}} = Client.subscribe(client, "session:#{session.id}", from_seq: 0)
      replayed = collect_events(head)

      log = Troupe.events(session.id)
      assert Enum.map(replayed, & &1.seq) == Enum.map(log, & &1.seq)
      assert Enum.map(replayed, & &1.type) == Enum.map(log, & &1.type)
      assert Event.verify(replayed) == :ok
    end

    test "summary carries lifecycle but never the model's words", context do
      %{session: session} = start_session(context, [{:text, "a secret answer"}])
      client = connect(context)

      {:ok, _} = Client.subscribe(client, "session:#{session.id}", level: :summary)
      Troupe.send_input(session.id, "go")

      events = collect_for(700)
      types = events |> Enum.map(& &1.type) |> Enum.uniq()

      refute "llm_response" in types
      refute "llm_delta" in types

      assert Enum.all?(events, fn event ->
               event.type in Session.lifecycle_types() or event.type == "summary_diff" or
                 event.type == "agent_state"
             end)
    end

    test "unsubscribe stops delivery", context do
      %{session: session} = start_session(context, [{:text, "hi"}, {:text, "hi"}])
      client = connect(context)

      {:ok, %{"subscription_id" => sub}} = Client.subscribe(client, "session:#{session.id}")
      Troupe.send_input(session.id, "one")
      assert collect_for(500) != []

      {:ok, _} = Client.unsubscribe(client, sub)
      flush()

      Troupe.send_input(session.id, "two")
      assert collect_for(500) == []
    end

    test "subscribing to an unknown session is not_found", context do
      client = connect(context)
      assert {:error, %Error{message: "not_found"}} = Client.subscribe(client, "session:s-nope")
    end

    test "a malformed topic names the field", context do
      client = connect(context)

      assert {:error, %Error{message: "invalid_params", data: %{"field" => "topic"}}} =
               Client.subscribe(client, "nonsense")
    end
  end

  describe "idempotency" do
    test "the same command_id twice produces exactly one effect", context do
      %{session: session} = start_session(context, [{:text, "one"}, {:text, "two"}])
      client = connect(context)

      command_id = Client.command_id()
      params = %{"command_id" => command_id, "session_id" => session.id, "text" => "do it"}

      assert {:ok, first} = Client.call(client, "input.send", params)
      assert {:ok, second} = Client.call(client, "input.send", params)
      assert first["accepted"] == true
      assert second["accepted"] == true

      await_idle(session.id)

      inputs = Enum.filter(Troupe.events(session.id), &(&1.type == "user_input"))
      assert length(inputs) == 1
    end

    test "a replayed command is honoured across connections", context do
      %{session: session} = start_session(context, [{:text, "one"}, {:text, "two"}])

      command_id = Client.command_id()
      params = %{"command_id" => command_id, "session_id" => session.id, "text" => "do it"}

      client = connect(context)
      assert {:ok, _} = Client.call(client, "input.send", params)
      Client.close(client)

      # A client that reconnects and retries what it was unsure about must not send
      # the input a second time.
      other = connect(context)
      assert {:ok, _} = Client.call(other, "input.send", params)

      await_idle(session.id)
      assert length(Enum.filter(Troupe.events(session.id), &(&1.type == "user_input"))) == 1
    end
  end

  describe "input and steering" do
    test "input.send acknowledges, and the effect arrives as events", context do
      %{session: session} = start_session(context, [{:text, "the answer is 42"}])
      client = connect(context)

      {:ok, _} = Client.subscribe(client, "session:#{session.id}")

      assert {:ok, %{"accepted" => true}} =
               Client.call(client, "input.send", %{
                 "command_id" => Client.command_id(),
                 "session_id" => session.id,
                 "text" => "what is the answer?"
               })

      events = collect_until(fn e -> e.type == "llm_response" end)
      input = Enum.find(events, &(&1.type == "user_input"))

      assert input.data["text"] == "what is the answer?"
      # Who sent it is recorded, which is what makes a shared session legible.
      assert input.actor.kind == :user
      assert input.actor.subject =~ "local:"
    end

    test "turn.cancel and profile.switch are accepted", context do
      %{session: session} = start_session(context, [{:text, "hi"}])
      client = connect(context)

      assert {:ok, %{"accepted" => true}} =
               Client.call(client, "turn.cancel", %{
                 "command_id" => Client.command_id(),
                 "session_id" => session.id
               })

      assert {:ok, %{"accepted" => true}} =
               Client.call(client, "profile.switch", %{
                 "command_id" => Client.command_id(),
                 "session_id" => session.id,
                 "profile" => "plan"
               })
    end

    test "an unknown approval decision names the field", context do
      %{session: session} = start_session(context, [{:text, "hi"}])
      client = connect(context)

      assert {:error, %Error{message: "invalid_params", data: %{"field" => "decision"}}} =
               Client.call(client, "approval.respond", %{
                 "command_id" => Client.command_id(),
                 "session_id" => session.id,
                 "call_id" => "call_1",
                 "decision" => "maybe"
               })
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp raw_initialize(address, port, params) do
    {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false, packet: :raw])

    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => Map.merge(%{"client_info" => %{}, "capabilities" => %{}}, params)
      })

    :ok = :gen_tcp.send(socket, [request, "\n"])
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    case Jason.decode!(String.trim(line)) do
      %{"error" => error} -> {:error, Error.from_json(error)}
      %{"result" => result} -> {:ok, result}
    end
  end

  defp raw_line(context, message) do
    {address, port} = Endpoint.connect_args(context.endpoint)
    {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(socket, [Jason.encode!(message), "\n"])
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    Jason.decode!(String.trim(line))
  end

  defp collect_events(count, acc \\ [])
  defp collect_events(0, acc), do: Enum.reverse(acc)

  defp collect_events(count, acc) do
    receive do
      {:troupe_event, _topic, _id, %Event{seq: nil}} -> collect_events(count, acc)
      {:troupe_event, _topic, _id, event} -> collect_events(count - 1, [event | acc])
    after
      5_000 -> raise "timed out with #{count} events still expected"
    end
  end

  defp collect_until(predicate, acc \\ []) do
    receive do
      {:troupe_event, _topic, _id, event} ->
        acc = [event | acc]
        if predicate.(event), do: Enum.reverse(acc), else: collect_until(predicate, acc)
    after
      8_000 -> Enum.reverse(acc)
    end
  end

  defp collect_for(ms, acc \\ []) do
    receive do
      {:troupe_event, _topic, _id, event} -> collect_for(ms, [event | acc])
    after
      ms -> Enum.reverse(acc)
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp await_idle(session_id, attempts \\ 200) do
    case Troupe.snapshot(session_id) do
      %{state: state} when state in [:idle, :done] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(25)
        await_idle(session_id, attempts - 1)

      _ ->
        :ok
    end
  end
end
