defmodule Troupe.Gateway.FleetTest do
  @moduledoc """
  A `fleet` subscription carries the lifecycle of every session, the ones created and woken
  after it was answered among them (#669). It used to follow only the sessions that were
  running when it was answered, so a session started or woken a moment later never reached
  it, and dropping it unfollowed every running session, a subscription to one of them on the
  same connection included.
  """

  use Troupe.Gateway.HarnessCase, async: false

  @ada "ada@example.test"
  @env ~w(TROUPE_PROVIDER TROUPE_CONFIG_HOME)

  @moduletag timeout: 60_000

  # A woken session is started from the configuration, as the daemon starts any dormant
  # one, so the machine's own settings are kept out of it.
  setup context do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    config = Path.join(context.base, "config")
    File.mkdir_p!(config)
    System.put_env(%{"TROUPE_PROVIDER" => "fake", "TROUPE_CONFIG_HOME" => config})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "a session created after the subscription was answered reaches it", context do
    ada = attach(context, @ada)
    {:ok, %{"subscription_id" => _}} = Client.subscribe(ada, "fleet")

    %{session: session} = start_session(context)
    sid = session.id

    assert_receive {:troupe_event, "fleet", ^sid, %Event{type: "session_created"}}, 5_000
  end

  test "a session woken after the subscription was answered reaches it", context do
    %{session: session} = start_session(context)
    sid = session.id
    :ok = Troupe.stop_session(sid)
    eventually(fn -> sid not in Troupe.session_ids() end)

    ada = attach(context, @ada)
    {:ok, %{"subscription_id" => _}} = Client.subscribe(ada, "fleet")

    {:ok, _pid} = Troupe.activate(sid)

    assert_receive {:troupe_event, "fleet", ^sid, %Event{type: "session_resumed"}}, 5_000
    assert_receive {:troupe_event, "fleet", ^sid, %Event{type: "session_activated"}}, 5_000
  end

  test "beside a session's own subscription each event arrives once on each, and dropping the fleet leaves the session's whole",
       context do
    %{session: session} = start_session(context)
    sid = session.id
    topic = "session:#{sid}"

    ada = attach(context, @ada)
    {:ok, %{"subscription_id" => fleet}} = Client.subscribe(ada, "fleet")
    {:ok, _} = Client.subscribe(ada, topic)

    :ok = Troupe.stop_session(sid)

    assert_receive {:troupe_event, "fleet", ^sid, %Event{type: "session_dormant"}}, 5_000
    assert_receive {:troupe_event, ^topic, ^sid, %Event{type: "session_dormant"}}, 5_000
    refute_receive {:troupe_event, _topic, ^sid, %Event{type: "session_dormant"}}, 300

    {:ok, _} = Client.unsubscribe(ada, fleet)
    {:ok, _pid} = Troupe.activate(sid)

    assert_receive {:troupe_event, ^topic, ^sid, %Event{type: "session_activated"}}, 5_000
    refute_received {:troupe_event, "fleet", ^sid, _event}
  end
end
