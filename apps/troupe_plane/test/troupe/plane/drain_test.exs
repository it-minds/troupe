defmodule Troupe.Plane.DrainTest do
  @moduledoc """
  How long the plane waits for a pod it told to drain.

  A pod lets running turns finish, up to the drain's timeout, and then puts its sessions to
  sleep one after another, each given up to two minutes to seal and upload. Three busy
  sessions can take longer than the timeout and a margin, and a plane that stopped waiting
  then marked them dormant while the pod was still archiving them: what the pod uploaded
  after that was for a session the plane had already let go. So the pod says how far it
  has got, and the plane waits while it hears that, up to a ceiling it names; a pod that
  stops saying anything is the failure, however long it was given.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, Drain, FakePod, Fleet, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}

  @moduletag timeout: 60_000

  # Small numbers, so a drain that outlives its timeout takes seconds here rather than
  # minutes: a timeout of 300 ms with 300 ms to spare, and two seconds for each session.
  @windows [timeout_ms: 300, slack_ms: 300, per_session_ms: 2_000, poll_ms: 20]

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])

    {:ok, _profile} =
      Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})

    pod =
      FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 4, hold: ["drain"])

    worker = Fleet.get_worker(pod.worker_id)
    context = %{team: team, ada: ada}
    sessions = for _ <- 1..3, do: on_pod(context, worker).id

    %{pod: pod, worker: worker, sessions: sessions}
  end

  test "waits for a pod that is still putting its sessions to sleep", context do
    drain = Task.async(fn -> Drain.pod(context.worker, @windows) end)

    assert_receive {:held, "drain", %{"timeout_ms" => 300}, answer}, 5_000

    # Each session takes most of a second, three of them well past the timeout and its
    # margin, and the pod says before each one which it has in hand.
    left = length(context.sessions)

    for {id, n} <- Enum.with_index(context.sessions) do
      :ok =
        FakePod.say(context.pod, "drain.progress", %{
          "left" => left - n,
          "total" => left,
          "session_id" => id
        })

      Process.sleep(800)
      :ok = FakePod.say(context.pod, "session.dormant", %{"session_id" => id})
    end

    answer.()

    assert {:ok, report} = Task.await(drain, 10_000)
    refute report[:unreachable]
    assert report.sessions == 3
    assert Enum.all?(context.sessions, &(Sessions.get(&1).state == "dormant"))
    assert Sessions.on_worker(context.worker.id) == []
    assert gave_up() == []
  end

  test "gives up on a pod that stops saying how far it has got, and says so", context do
    {elapsed_ms, result} =
      :timer.tc(
        fn ->
          drain = Task.async(fn -> Drain.pod(context.worker, @windows) end)
          assert_receive {:held, "drain", _params, _answer}, 5_000

          [first | _] = context.sessions

          :ok =
            FakePod.say(context.pod, "drain.progress", %{
              "left" => 3,
              "total" => 3,
              "session_id" => first
            })

          Task.await(drain, 10_000)
        end,
        :millisecond
      )

    # Its timeout and two seconds for the session in hand, and not the ceiling of three.
    assert {:error, {:gave_up, :silent, stranded}} = result
    assert elapsed_ms < 5_000
    assert Enum.sort(stranded) == Enum.sort(context.sessions)

    # What a lost pod's sessions get: dormant as of their last seal, not left claiming a
    # pod that is not answering.
    assert Enum.all?(context.sessions, &(Sessions.get(&1).state == "dormant"))

    assert [%{actor: "system:drain", subject_id: "troupe-w-dev-0", detail: detail}] =
             gave_up()

    assert detail["why"] == "silent"
    assert detail["ceiling_seconds"] == 6.6
  end

  test "stops at its ceiling however much the pod says", context do
    drain = Task.async(fn -> Drain.pod(context.worker, @windows) end)
    assert_receive {:held, "drain", _params, _answer}, 5_000

    talker =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          FakePod.say(context.pod, "drain.progress", %{"left" => 3, "total" => 3})
          Process.sleep(200)
        end)
        |> Stream.run()
      end)

    {elapsed_ms, result} = :timer.tc(fn -> Task.await(drain, 10_000) end, :millisecond)
    Process.unlink(talker)
    Process.exit(talker, :kill)

    assert {:error, {:gave_up, :ceiling, _stranded}} = result
    # The ceiling is the timeout, two seconds a session and the margin: 6.6 s from the start.
    assert elapsed_ms < 9_000

    assert [%{detail: %{"why" => "ceiling", "ceiling_seconds" => 6.6}}] =
             gave_up()
  end

  test "an old pod that says nothing gets the timeout and its margin, as before", context do
    # A session's time shorter than the timeout, so what the pod gets is the timeout and
    # its margin, 3.3 s: its three reports and its answer take most of a second to land.
    windows = Keyword.merge(@windows, timeout_ms: 3_000, per_session_ms: 100)
    drain = Task.async(fn -> Drain.pod(context.worker, windows) end)
    assert_receive {:held, "drain", _params, answer}, 5_000

    for id <- context.sessions,
        do: :ok = FakePod.say(context.pod, "session.dormant", %{"session_id" => id})

    answer.()

    assert {:ok, %{sessions: 3}} = Task.await(drain, 10_000)
    assert gave_up() == []
  end

  defp gave_up, do: Enum.filter(Audit.list(kind: "pod"), &(&1.action == "pod.drain.gave_up"))

  # A session running on the pod, as placement leaves it.
  defp on_pod(context, worker) do
    {:ok, session} =
      Sessions.create(%{
        id: "s-#{System.unique_integer([:positive])}",
        owner_id: context.ada.id,
        owner_subject: context.ada.subject,
        team_id: context.team.id,
        profile: "dev",
        state: "pending",
        epoch: 1
      })

    {:ok, session} = Sessions.place(session.id, worker)
    session
  end
end
