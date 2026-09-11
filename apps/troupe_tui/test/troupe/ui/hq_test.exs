defmodule Troupe.UI.HQTest do
  @moduledoc """
  HQ against a real daemon with three sessions blocked on approvals.

  The property being proved is that an approval raised in a session nobody has open
  still reaches a person, and that two people answering the same prompt produces one
  effect and one clear answer for the loser.
  """

  use ExUnit.Case, async: false

  alias ExRatatui.Runtime
  alias Troupe.Gateway.Daemon
  alias Troupe.LLM.Fake
  alias Troupe.Protocol.{Client, Endpoint}
  alias Troupe.UI.HQ.{Server, State}

  @moduletag timeout: 120_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-hq-#{System.unique_integer([:positive])}")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous, do: System.put_env("TROUPE_STATE_HOME", previous), else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{base: base, state_dir: state_dir, endpoint: endpoint}
  end

  test "three sessions blocked on approvals all show up in HQ, and answering resolves them",
       context do
    sessions = Enum.map(1..3, fn n -> blocked_session(context, n) end)

    hq = start_hq(context)

    # Every one of them, without HQ ever having opened a session.
    await(fn -> length(hq_state(hq).approvals) == 3 end, "HQ did not list all three approvals")

    listed = hq_state(hq).approvals
    assert Enum.map(listed, & &1.session_id) |> Enum.sort() == Enum.sort(Enum.map(sessions, & &1.id))
    assert Enum.all?(listed, &(&1.tool == "needs_approval"))

    # Answer each from HQ.
    for _ <- 1..3 do
      Runtime.inject_event(hq, %ExRatatui.Event.Key{code: "y", kind: "press"})
      Process.sleep(50)
    end

    for session <- sessions do
      await_idle(session.id)
      [completed] = events_of_type(session.id, "tool_call_completed")
      assert completed.data["ok"], "the tool did not run after HQ allowed it"
    end

    await(fn -> hq_state(hq).approvals == [] end, "HQ still lists answered approvals")
  end

  test "a second client answering an already-decided approval gets approval_resolved",
       context do
    session = blocked_session(context, 1)

    first = connect(context)
    second = connect(context)
    {:ok, _} = Client.subscribe(second, "session:#{session.id}")

    call_id = await_approval(session.id)

    assert {:ok, %{"accepted" => true}} = respond(first, session.id, call_id, "allow")
    await_idle(session.id)

    # Deliberately a different command_id: this is a second client's own decision, not
    # a retry of the first one's, so idempotency is not what protects the session here.
    assert {:ok, %{"accepted" => true}} = respond(second, session.id, call_id, "deny")

    await(
      fn -> Enum.any?(events_of_type(session.id, "approval_resolved")) end,
      "no approval_resolved event reached the second client"
    )

    [resolved] = events_of_type(session.id, "approval_resolved")
    assert resolved.data["call_id"] == call_id
    assert is_binary(resolved.data["resolved_by"])

    # And no second effect: one decision, one tool run.
    assert length(events_of_type(session.id, "approval_decided")) == 1
    assert length(events_of_type(session.id, "tool_call_completed")) == 1
    assert hd(events_of_type(session.id, "tool_call_completed")).data["ok"]
  end

  test "the fold drops an approval once the session says it was resolved" do
    state =
      State.new()
      |> State.apply_event("s-1", event("approval_requested", %{"call_id" => "c1", "tool" => "shell"}))
      |> State.apply_event("s-2", event("approval_requested", %{"call_id" => "c2", "tool" => "shell"}))

    assert length(state.approvals) == 2

    resolved = State.apply_event(state, "s-1", event("approval_resolved", %{"call_id" => "c1"}))
    assert Enum.map(resolved.approvals, & &1.session_id) == ["s-2"]
  end

  # -- helpers ----------------------------------------------------------------

  defp blocked_session(context, n) do
    workspace = Path.join(context.base, "workspace-#{n}")
    File.mkdir_p!(workspace)

    fake =
      start_supervised!(
        {Fake, steps: [{:tools, [{"needs_approval", %{"note" => "n#{n}"}}]}, {:text, "done"}]},
        id: {Fake, n}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: workspace,
        fake: fake,
        config_overrides: [
          provider: "fake",
          model: "fake",
          auto_approve: false,
          state_dir: context.state_dir
        ]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)

    Troupe.send_input(session.id, "please ask")
    await_approval(session.id)
    session
  end

  defp connect(context) do
    {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: context.endpoint, spawn: false)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  defp respond(client, session_id, call_id, decision) do
    Client.call(client, "approval.respond", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id,
      "call_id" => call_id,
      "decision" => decision
    })
  end

  defp start_hq(context) do
    start_supervised!(
      {Server,
       connect: [endpoint: context.endpoint, spawn: false],
       name: nil,
       test_mode: {120, 32},
       test_pid: self()},
      id: {Server, System.unique_integer([:positive])}
    )
  end

  defp hq_state(hq), do: :sys.get_state(hq).user_state

  defp event(type, data) do
    %Troupe.Protocol.Event{type: type, agent: ["root"], data: data, ts: "2026-01-01T00:00:00Z"}
  end

  defp events_of_type(session_id, type) do
    session_id |> Troupe.events() |> Enum.filter(&(&1.type == type))
  end

  defp await_approval(session_id, attempts \\ 400) do
    case events_of_type(session_id, "approval_requested") do
      [event | _] ->
        event.data["call_id"]

      [] when attempts > 0 ->
        Process.sleep(25)
        await_approval(session_id, attempts - 1)

      [] ->
        raise "no approval was ever requested in #{session_id}"
    end
  end

  defp await(predicate, message, attempts \\ 400) do
    cond do
      predicate.() -> :ok
      attempts > 0 -> Process.sleep(25) && await(predicate, message, attempts - 1)
      true -> flunk(message)
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
