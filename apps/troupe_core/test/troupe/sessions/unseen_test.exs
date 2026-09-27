defmodule Troupe.Sessions.UnseenTest do
  @moduledoc """
  What a listing says happened while nobody was attached (#119): a turn that ended, an
  approval or a question raised, counted from the moment the last client reading the
  session left, and cleared by the next one that reads it. A client attached to a session
  sees it all as it happens, so nothing is unseen while one is there, and a session asleep
  answers from its log exactly as it answered awake.

  The listing is a private `Troupe.Sessions.Index` over this test's state directory; the
  test follows the session's events as `:internal`, which is not being attached.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Events
  alias Troupe.Sessions.Index

  @none %{turns: 0, approvals: 0, questions: 0, since: nil}

  describe "a turn that ends" do
    test "while nobody is attached is counted, and the count survives the session's sleep",
         context do
      %{session: session} = start_session(context, steps: [{:text, "one"}, {:text, "two"}])
      sid = session.id
      index = listing(context)
      follow(sid)

      # A client reads the session through its first turn, then leaves.
      Troupe.attach(sid)
      Troupe.send_input(sid, "first")
      await_event(sid, :turn_ended)
      Troupe.detach(sid)
      assert %{unseen: @none} = get(index, sid)

      # The next one ends with nobody there.
      Troupe.send_input(sid, "second")
      await_event(sid, :turn_ended)
      assert %{unseen: %{turns: 1, approvals: 0, questions: 0, since: since}} = get(index, sid)
      assert is_binary(since)

      # Asleep it is only its log, and the log says the same, in the listing too.
      :ok = Troupe.stop_session(sid)
      asleep(sid)
      assert %{state: :dormant, unseen: %{turns: 1, since: ^since}} = get(index, sid)
      assert [%{id: ^sid, unseen: %{turns: 1}}] = GenServer.call(index, {:list, %{}})
    end

    test "while a client is attached is seen as it happens, so nothing is left over when it leaves",
         context do
      %{session: session} = start_session(context, steps: [{:text, "one"}, {:text, "two"}])
      sid = session.id
      index = listing(context)
      follow(sid)

      Troupe.attach(sid)
      Troupe.send_input(sid, "first")
      await_event(sid, :turn_ended)
      Troupe.send_input(sid, "second")
      await_event(sid, :turn_ended)
      assert %{unseen: @none} = get(index, sid)

      Troupe.detach(sid)
      assert %{unseen: @none} = get(index, sid)
    end

    test "in a session no client has ever read is nobody's news", context do
      %{session: session} = start_session(context, steps: [{:text, "one"}])
      sid = session.id
      index = listing(context)
      follow(sid)

      # Nothing marks where a reader got to, so nothing has happened since a reader left.
      Troupe.send_input(sid, "first")
      await_event(sid, :turn_ended)
      assert %{unseen: @none} = get(index, sid)
    end
  end

  describe "a question to a person" do
    test "raised while nobody is attached is counted once, however often a wake asks it again",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [
            {:tools, [{"needs_approval", %{"note" => "later"}}]},
            {:tools, [{"ask_user", %{"question" => "Which colour?", "options" => ["red"]}}]}
          ]
        )

      sid = session.id
      index = listing(context)
      follow(sid)

      Troupe.attach(sid)
      Troupe.detach(sid)

      Troupe.send_input(sid, "ask me")
      %{data: %{"call_id" => call_id}} = await_event(sid, :approval_requested)
      assert %{unseen: %{turns: 0, approvals: 1, questions: 0}} = get(index, sid)

      # Asleep on the approval, and woken: the approval is asked again under the same id
      # (Decision 651), which is the same approval and not a second one.
      :ok = Troupe.stop_session(sid)
      asleep(sid)
      assert %{state: :dormant, unseen: %{approvals: 1}} = get(index, sid)

      {:ok, _} =
        Troupe.resume(sid,
          workspace: context.workspace,
          fake: fake,
          config_overrides: [
            provider: "fake",
            model: "fake-model",
            state_dir: context.state_dir,
            auto_approve: false
          ]
        )

      assert %{data: %{"call_id" => ^call_id}} = await_event(sid, :approval_requested)
      assert %{unseen: %{turns: 0, approvals: 1}} = get(index, sid)

      # Answered by a client that is not reading — a shortcut from a notification, say —
      # the turn goes on to ask a question, with nobody there for that either.
      Troupe.approve(sid, call_id, :allow)
      await_event(sid, :question_asked)
      assert %{unseen: %{turns: 0, approvals: 1, questions: 1}} = get(index, sid)

      # A client reading it clears the lot, and what it read is not counted again.
      Troupe.attach(sid)
      assert %{unseen: @none} = get(index, sid)
      Troupe.detach(sid)
      assert %{unseen: @none} = get(index, sid)
    end
  end

  # -- helpers ----------------------------------------------------------------

  # Seeing the session's events without counting as somebody attached to it.
  defp follow(sid), do: :ok = Events.subscribe(sid, :internal)

  defp get(index, sid), do: GenServer.call(index, {:get, sid})

  # An index that only lists, over this test's state directory.
  defp listing(context) do
    opts = [state_dir: context.state_dir, session_idle_ms: :infinity, detached_idle_ms: :infinity]
    start_supervised!(%{id: {Index, make_ref()}, start: {GenServer, :start_link, [Index, opts]}})
  end

  # Stopped, and the registry has let go of its names, so the same id can start again.
  defp asleep(sid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll(deadline, fn ->
      Troupe.snapshot(sid) == {:error, :no_agent} and
        is_nil(Registry.whereis({:session, sid})) and is_nil(Registry.whereis({:log, sid}))
    end)
  end

  defp poll(deadline, fun) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never held")
      true -> Process.sleep(20) && poll(deadline, fun)
    end
  end
end
