defmodule Troupe.Ctl.VerifyTest do
  @moduledoc """
  Walking the hash chain, and finding the break.

  A done item: verify passes on a clean log, and flipping one byte in any stored event
  makes it fail *at that seq*. Naming the sequence is the point — "something is wrong
  somewhere" is not an audit result.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI
  alias Troupe.CLI.Options
  alias Troupe.Ctl.Verify
  alias Troupe.Gateway.Daemon
  alias Troupe.Protocol.{Endpoint, Event}

  @moduletag timeout: 120_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-verify-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "workspace"))
    File.mkdir_p!(Path.join(base, "state"))

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_STATE_HOME", previous),
        else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{base: base, endpoint: endpoint}
  end

  describe "a log on disk" do
    test "a clean chain verifies, and reports the head", %{base: base} do
      path = write_log(base, chain(20))

      assert {:ok, %{events: 20, head_hash: head}} = Verify.file(path)
      assert head =~ ~r/^sha256:[0-9a-f]{64}$/

      assert {message, 0} = Verify.describe(Verify.file(path))
      assert message =~ "20 events verify"
    end

    test "a byte flipped in any event breaks the chain at that seq", %{base: base} do
      events = chain(10)

      for target <- [1, 5, 10] do
        tampered =
          Enum.map(events, fn event ->
            if event.seq == target, do: %{event | data: %{"text" => "tampered"}}, else: event
          end)

        path = write_log(base, tampered)

        # The break shows at the *next* event, whose prev_hash was computed over what
        # the tampered one used to be. A tampered last event has nothing after it, so
        # what changes is the head hash the plane anchored.
        case Verify.file(path) do
          {:error, {:chain_broken, seq, :prev_hash_mismatch}} ->
            assert seq == target + 1

          {:ok, %{head_hash: head}} ->
            assert target == 10
            refute head == Event.hash(List.last(events))
        end
      end
    end

    test "a missing event in the middle is a gap, not a silent shortening", %{base: base} do
      path = write_log(base, Enum.reject(chain(10), &(&1.seq == 5)))

      assert {:error, {:chain_broken, 6, reason}} = Verify.file(path)
      assert reason in [:seq_gap, :prev_hash_mismatch]
    end

    test "an empty log is not a failure", %{base: base} do
      path = write_log(base, [])
      assert {:ok, %{events: 0}} = Verify.file(path)
      assert {"the log is empty", 0} = Verify.describe(Verify.file(path))
    end

    test "a file that is not there says so, with its own exit code" do
      outcome = Verify.file("/nowhere/at/all.jsonl")
      assert {message, 2} = Verify.describe(outcome)
      assert message =~ "could not be read"
    end
  end

  describe "a live session" do
    test "verifies what the daemon actually serves", context do
      session = run_a_turn(context)

      {output, code} = run_cli(context, ["verify", session.id])

      assert code == 0
      assert output =~ "events verify"
      assert output =~ "sha256:"
    end

    test "the offline and the live answer agree", context do
      session = run_a_turn(context)
      {:ok, client} = connect(context)

      assert {:ok, live} = Verify.session(client, session.id)
      assert {:ok, offline} = Verify.chain(Troupe.events(session.id))

      assert live.events == offline.events
      assert live.head_hash == offline.head_hash
    end

    test "asking for a session that does not exist says so", context do
      {output, code} = run_cli(context, ["verify", "s-nope"])

      assert code == 1
      assert output =~ "not_found"
    end

    test "verify with neither a session nor a log is a usage error", context do
      {output, code} = run_cli(context, ["verify"])

      assert code == 2
      assert output =~ "needs a session id"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp chain(count) do
    1..count
    |> Enum.reduce([], fn seq, acc ->
      previous = List.first(acc)

      event =
        Event.seal(
          %Event{
            type: "user_input",
            agent: ["root"],
            data: %{"text" => "line #{seq}"},
            actor: %Event.Actor{kind: :user, subject: "idp|alice"}
          },
          seq,
          previous,
          "2026-01-01T00:00:00.000Z"
        )

      [event | acc]
    end)
    |> Enum.reverse()
  end

  defp write_log(base, events) do
    path = Path.join(base, "log-#{System.unique_integer([:positive])}.jsonl")
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(Event.to_json(&1)) <> "\n")))
    path
  end

  defp run_a_turn(context) do
    fake = start_supervised!({Troupe.LLM.Fake, steps: [{:text, "an answer"}]})

    {:ok, session} =
      Troupe.start_session(
        workspace: Path.join(context.base, "workspace"),
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake",
          auto_approve: true,
          state_dir: Path.join(context.base, "state")
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)

    Troupe.send_input(session.id, "say something")
    await_idle(session.id)
    session
  end

  defp connect(context) do
    Troupe.Protocol.Daemon.connect(endpoint: context.endpoint, spawn: false)
  end

  defp run_cli(context, argv) do
    parent = self()
    reference = make_ref()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            code = CLI.dispatch(Options.parse(argv), endpoint: context.endpoint, spawn: false)
            send(parent, {reference, :code, code})
          end)

        send(parent, {reference, :stdout, stdout})
      end)

    stdout = receive_tagged(reference, :stdout, "")
    code = receive_tagged(reference, :code, nil)

    {stdout <> stderr, code}
  end

  defp receive_tagged(reference, tag, default) do
    receive do
      {^reference, ^tag, value} -> value
    after
      0 -> default
    end
  end

  defp await_idle(session_id, attempts \\ 400) do
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
