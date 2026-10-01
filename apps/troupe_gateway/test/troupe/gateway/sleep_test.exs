defmodule Troupe.Gateway.SleepTest do
  @moduledoc """
  What a laptop's daemon does once its person has walked away (#119).

  A turn nobody is watching any more runs to completion. A session somebody is watching is
  not put to sleep under them on the short clock. A session left waiting on an approval or
  a question goes to sleep, a daemon with nothing but sleeping sessions exits, and the next
  command brings the session back with what it asked still in front of whoever answers it,
  and the answer finishes the turn. Before, a session waiting on a person counted as busy
  for as long as nobody answered, and the daemon, which stays up while any session is live,
  stayed up with it.

  The sleeping is a private `Troupe.Sessions.Index` with clocks short enough to test,
  sweeping the real session. The daemon's idle watch is the real one on short clocks, with
  its exit replaced by a message.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Client, Endpoint, Event}
  alias Troupe.Sessions.Index

  @env ~w(TROUPE_STATE_HOME TROUPE_PROVIDER TROUPE_FAKE_SCRIPT)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-sleep-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    # A session woken by a command is started the way the daemon starts any dormant one,
    # from its log and the configuration, so its model is the one a packaged daemon runs
    # with no model behind it.
    script = Path.join(base, "script.json")
    File.write!(script, Jason.encode!(%{"steps" => [%{"text" => "carried on after the answer"}]}))

    previous = Map.new(@env, &{&1, System.get_env(&1)})

    System.put_env(%{
      "TROUPE_STATE_HOME" => state_dir,
      "TROUPE_PROVIDER" => "fake",
      "TROUPE_FAKE_SCRIPT" => script
    })

    test = self()
    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}

    start_supervised!(
      {Daemon,
       endpoint: endpoint,
       idle_shutdown_ms: 300,
       idle_check_ms: 50,
       on_idle: fn -> send(test, {:daemon_would_exit, System.monotonic_time(:millisecond)}) end}
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(base)
    end)

    %{workspace: workspace, state_dir: state_dir, endpoint: endpoint, script: script}
  end

  test "a turn whose client has gone runs to completion, and its result is in the log", context do
    %{session: session} =
      start_session(context, [{:text, "finished with nobody there"}], delay_ms: 1_000)

    client = connect(context)

    {:ok, _} = Client.call(client, "input.send", input(session.id, "take your time"))
    Client.close(client)
    refute logged?(session.id, "llm_response"), "the turn was over before its client left"

    eventually(fn -> logged?(session.id, "llm_response") end, 10_000)

    [response] = Enum.filter(Troupe.events(session.id), &(&1.type == "llm_response"))
    assert inspect(response.data) =~ "finished with nobody there"
  end

  test "a session a client is subscribed to is not put to sleep on either clock", context do
    %{session: session} = start_session(context, [{:text, "hi"}])
    client = connect(context)
    {:ok, _} = Client.subscribe(client, "session:#{session.id}")

    # Both clocks well inside the wait: a session somebody is reading is not stopped under
    # them, so the state change they would otherwise have to handle never happens.
    sweep(session, session_idle_ms: 200, detached_idle_ms: 100)

    Process.sleep(700)
    assert session.id in Troupe.session_ids(), "slept while a client was subscribed to it"

    Client.close(client)
    eventually(fn -> session.id not in Troupe.session_ids() end, 5_000)
  end

  test "a client tool call whose client left fails once the grace is up, the session sleeps, and the tool is served again once a client is back and it wakes",
       context do
    grace(300)

    %{session: session} =
      start_session(context, [
        {:tools, [{"client.notes.search", %{"q" => "before the nap"}}]},
        {:text, "did without it"}
      ])

    sid = session.id
    client = connect(context)
    {:ok, _} = register(client, sid)
    {:ok, _} = Client.call(client, "input.send", input(sid, "search my notes"))
    assert_receive {:troupe_request, _id, "tool.invoke", _params}, 15_000

    # The client goes mid-call and nobody comes back within the grace: the call fails once,
    # naming the tool, and the turn carries on to its end without it.
    Client.close(client)

    eventually(fn -> logged?(sid, "turn_ended") end, 15_000)
    [failed] = Enum.filter(Troupe.events(sid), &(&1.type == "tool_call_completed"))
    assert failed.data["ok"] == false
    assert failed.data["content"] =~ "notes.search"
    assert failed.data["content"] =~ "left"

    # Idle and unwatched, so it sleeps; the registration did not outlive the connection
    # and the tree does not outlive the clock.
    sweep(session, detached_idle_ms: 300)
    eventually(fn -> sid not in Troupe.session_ids() end, 5_000)

    # The person is back. Offering the tool again is an activating command, so it is what
    # wakes the session, and the woken model asks for the tool once more.
    File.write!(
      context.script,
      Jason.encode!(%{
        "steps" => [
          %{"tools" => [%{"name" => "client.notes.search", "input" => %{"q" => "after the nap"}}]},
          %{"text" => "served after the nap"}
        ]
      })
    )

    client = connect(context)
    {:ok, _} = Client.subscribe(client, "session:#{sid}")
    {:ok, _} = register(client, sid)
    assert {:ok, %{"state" => "active"}} = Client.call(client, "session.get", %{"session_id" => sid})

    {:ok, _} = Client.call(client, "input.send", input(sid, "search again"))

    # The woken session runs with the machine's own settings rather than this test's, so
    # the tool asks first, as a client's tool does by default (the consent was to offering
    # it, not to every call); then the call reaches the client that offered it.
    %Event{data: %{"call_id" => call_id}} =
      List.last(collect_until(&(&1.type == "approval_requested")))

    {:ok, _} =
      Client.call(client, "approval.respond", %{
        "command_id" => Client.command_id(),
        "session_id" => sid,
        "call_id" => call_id,
        "decision" => "allow"
      })

    assert_receive {:troupe_request, id, "tool.invoke", %{"arguments" => %{"q" => "after the nap"}}}, 15_000
    :ok = Client.respond(client, id, %{"content" => "one note, after the nap"})

    events = collect_until(&(&1.type == "llm_response"))
    served = Enum.find(events, &(&1.type == "tool_call_completed"))
    assert served.data["ok"] == true
    assert served.data["content"] =~ "after the nap"
    assert inspect(List.last(events).data) =~ "served after the nap"
  end

  test "a session left waiting on an approval sleeps, the daemon then exits, and the next command brings the approval back",
       context do
    %{session: session} =
      start_session(context, [{:tools, [{"needs_approval", %{"note" => "while you were away"}}]}],
        auto_approve: false
      )

    sid = session.id
    client = connect(context)
    {:ok, _} = Client.subscribe(client, "session:#{sid}")
    {:ok, _} = Client.call(client, "input.send", input(sid, "ask me something"))

    %Event{data: %{"call_id" => call_id}} =
      List.last(collect_until(&(&1.type == "approval_requested")))

    # What the idle watch said before anything was attached or running is old news.
    flush_idle()
    Client.close(client)

    # Nobody attached, and nobody going to answer. Slower than the daemon's own clock, so
    # the daemon would have gone already if a live session did not hold it.
    sweep(session, detached_idle_ms: 1_000)
    eventually(fn -> sid not in Troupe.session_ids() end, 5_000)
    slept_at = System.monotonic_time(:millisecond)

    refute_received {:daemon_would_exit, _}, "the daemon left while the session was still live"
    assert_receive {:daemon_would_exit, at}, 5_000
    assert at > slept_at

    # The next command. A client that was not there reads the approval from the log, and
    # reading wakes nothing.
    client = connect(context)

    assert {:ok, %{"state" => "dormant", "head_seq" => head}} =
             Client.call(client, "session.get", %{"session_id" => sid})

    {:ok, _} = Client.subscribe(client, "session:#{sid}", from_seq: 0)
    history = collect_events(head)

    assert Enum.any?(
             history,
             &(&1.type == "approval_requested" and &1.data["call_id"] == call_id)
           )

    refute Enum.any?(history, &(&1.type == "approval_decided"))

    assert {:ok, %{"state" => "dormant"}} =
             Client.call(client, "session.get", %{"session_id" => sid})

    # Answering it is what wakes the session, and the turn carries on from the approval.
    {:ok, _} =
      Client.call(client, "approval.respond", %{
        "command_id" => Client.command_id(),
        "session_id" => sid,
        "call_id" => call_id,
        "decision" => "allow"
      })

    events = collect_until(&(&1.type == "llm_response"))

    assert %{"call_id" => ^call_id, "ok" => true, "content" => "approved: while you were away"} =
             Enum.find(events, &(&1.type == "tool_call_completed")).data

    assert inspect(List.last(events).data) =~ "carried on after the answer"

    assert {:ok, %{"state" => "active"}} =
             Client.call(client, "session.get", %{"session_id" => sid})
  end

  test "a session left waiting on a question sleeps, the daemon then exits, and the answer wakes it and finishes the turn",
       context do
    %{session: session} =
      start_session(context, [
        {:tools, [{"ask_user", %{"question" => "Which colour?", "options" => ["red", "blue"]}}]}
      ])

    sid = session.id
    client = connect(context)
    {:ok, _} = Client.subscribe(client, "session:#{sid}")
    {:ok, _} = Client.call(client, "input.send", input(sid, "pick a colour"))

    %Event{data: %{"call_id" => call_id}} =
      List.last(collect_until(&(&1.type == "question_asked")))

    flush_idle()
    Client.close(client)

    sweep(session, detached_idle_ms: 1_000)
    eventually(fn -> sid not in Troupe.session_ids() end, 5_000)
    slept_at = System.monotonic_time(:millisecond)

    refute_received {:daemon_would_exit, _}, "the daemon left while the session was still live"
    assert_receive {:daemon_would_exit, at}, 5_000
    assert at > slept_at

    # Answering is what wakes it, through the method a client answers with.
    client = connect(context)
    {:ok, _} = Client.subscribe(client, "session:#{sid}")

    assert {:ok, %{"state" => "dormant"}} =
             Client.call(client, "session.get", %{"session_id" => sid})

    {:ok, _} =
      Client.call(client, "question.answer", %{
        "command_id" => Client.command_id(),
        "session_id" => sid,
        "call_id" => call_id,
        "text" => "blue"
      })

    collect_until(&(&1.type == "llm_response"))

    # The call ran once, before and after the sleep together: one answer, one result.
    events = Enum.filter(Troupe.events(sid), &(&1.data["call_id"] == call_id))

    assert [%{data: %{"ok" => true} = completed}] =
             Enum.filter(events, &(&1.type == "tool_call_completed"))

    assert (completed["result"] || completed["content"]) =~ "blue"
    assert [%{data: %{"text" => "blue"}}] = Enum.filter(events, &(&1.type == "question_answered"))

    response = Troupe.events(sid) |> Enum.filter(&(&1.type == "llm_response")) |> List.last()
    assert inspect(response.data) =~ "carried on after the answer"
  end

  # -- helpers ----------------------------------------------------------------

  defp connect(context) do
    {address, port} = Endpoint.connect_args(context.endpoint)

    {:ok, client} =
      Client.connect(
        address: address,
        port: port,
        client_info: %{"name" => "test", "version" => "1"}
      )

    client
  end

  defp start_session(context, steps, opts \\ []) do
    fake =
      start_supervised!(
        {Troupe.LLM.Fake, [steps: steps] ++ Keyword.take(opts, [:delay_ms])},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: context.workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          auto_approve: Keyword.get(opts, :auto_approve, true),
          model: "fake",
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    %{session: session, fake: fake}
  end

  # The grace a parked client tool call waits for its client, short enough to test.
  defp grace(ms) do
    previous = Application.get_env(:troupe_core, :client_tool_grace_ms)
    Application.put_env(:troupe_core, :client_tool_grace_ms, ms)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:troupe_core, :client_tool_grace_ms, previous),
        else: Application.delete_env(:troupe_core, :client_tool_grace_ms)
    end)
  end

  # Offer `notes.search` from this client, consenting the way a harness does: the first
  # registration is refused with the challenge to show, and the second carries it back.
  defp register(client, session_id) do
    tool = %{"name" => "notes.search", "description" => "Search my notes.", "schema" => %{"type" => "object"}}
    params = %{"session_id" => session_id, "tools" => [tool]}

    {:error, %{data: %{"challenge" => challenge}}} =
      Client.call(client, "tools.register", Map.put(params, "command_id", Client.command_id()))

    Client.call(
      client,
      "tools.register",
      params
      |> Map.put("command_id", Client.command_id())
      |> Map.put("consent", %{"challenge" => challenge, "confirmed_by" => "the person"})
    )
  end

  # The clocks given win over the defaults here: an hour watched, a sweep every 25 ms.
  defp sweep(session, clocks) do
    opts = clocks ++ [session_idle_ms: :timer.hours(1), sweep_ms: 25]

    index =
      start_supervised!(%{
        id: {Index, make_ref()},
        start: {GenServer, :start_link, [Index, opts]}
      })

    GenServer.cast(
      index,
      {:register, session.id, session.pid,
       %{workspace: session.workspace.root_real, profile: "build"}}
    )
  end

  defp input(session_id, text) do
    %{"command_id" => Client.command_id(), "session_id" => session_id, "text" => text}
  end

  defp logged?(session_id, type), do: Enum.any?(Troupe.events(session_id), &(&1.type == type))

  defp flush_idle do
    receive do
      {:daemon_would_exit, _} -> flush_idle()
    after
      0 -> :ok
    end
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
      10_000 ->
        flunk("never saw it; saw #{inspect(acc |> Enum.reverse() |> Enum.map(& &1.type))}")
    end
  end

  defp eventually(fun, timeout), do: poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp poll(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
      true -> Process.sleep(20) && poll(fun, deadline)
    end
  end
end
