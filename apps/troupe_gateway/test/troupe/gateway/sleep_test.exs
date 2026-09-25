defmodule Troupe.Gateway.SleepTest do
  @moduledoc """
  What a laptop's daemon does once its person has walked away (#119).

  A turn nobody is watching any more runs to completion. A session somebody is watching is
  not put to sleep under them on the short clock. A session left waiting on an approval
  goes to sleep, a daemon with nothing but sleeping sessions exits, and the next command
  brings the session back with the approval still in front of whoever answers it. Before,
  a session waiting on a person counted as busy for as long as nobody answered, and the
  daemon, which stays up while any session is live, stayed up with it.

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

    %{workspace: workspace, state_dir: state_dir, endpoint: endpoint}
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

  test "a session somebody is watching is not put to sleep on the short clock", context do
    %{session: session} = start_session(context, [{:text, "hi"}])
    client = connect(context)
    {:ok, _} = Client.subscribe(client, "session:#{session.id}")

    sweep(session, detached_idle_ms: 100)

    Process.sleep(600)
    assert session.id in Troupe.session_ids(), "slept while a client was subscribed to it"

    Client.close(client)
    eventually(fn -> session.id not in Troupe.session_ids() end, 5_000)
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

  defp sweep(session, clocks) do
    opts = [session_idle_ms: :timer.hours(1), sweep_ms: 25] ++ clocks

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
