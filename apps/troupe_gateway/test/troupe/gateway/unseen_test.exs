defmodule Troupe.Gateway.UnseenTest do
  @moduledoc """
  The listing's `unseen` column (#119): what finished, or was asked, while no client was
  subscribed to a session, so a client that comes back can tell the person; cleared by the
  subscription that reads it, never by a listing. The row is the contract the desktop
  app's notification and its "while you were away" marker are drawn from.
  """

  use Troupe.Gateway.HarnessCase, async: false

  @ada "ada@example.test"

  @none %{"turns" => 0, "approvals" => 0, "questions" => 0, "since" => nil}

  test "a turn that ends, and an approval raised, with nobody subscribed are unseen until somebody subscribes",
       context do
    %{session: session} =
      start_session(context,
        steps: [
          {:text, "one"},
          {:text, "two"},
          {:tools, [{"needs_approval", %{"note" => "later"}}]}
        ],
        config: [auto_approve: false]
      )

    sid = session.id
    ada = attach(context, @ada)
    {:ok, %{"subscription_id" => sub}} = Client.subscribe(ada, "session:#{sid}", from_seq: 0)
    {:ok, _} = input(ada, sid, "first")
    collect("session:#{sid}", &(&1.type == "turn_ended"))
    assert row(ada, sid)["unseen"] == @none

    # Ada stops reading — the app closed the session — but still sends. What the turn
    # does from here on, nobody sees.
    {:ok, _} = Client.unsubscribe(ada, sub)
    {:ok, _} = input(ada, sid, "second")
    eventually(fn -> ended(sid) == 2 end)

    assert %{"turns" => 1, "approvals" => 0, "questions" => 0, "since" => since} =
             row(ada, sid)["unseen"]

    assert is_binary(since)
    # The listing says the same, and reading it changes nothing.
    assert [%{"unseen" => %{"turns" => 1}}] = listed(ada, sid)
    assert %{"turns" => 1} = row(ada, sid)["unseen"]

    {:ok, _} = input(ada, sid, "third")
    eventually(fn -> requested(sid) == 1 end)
    # `pending_approvals` says it is still open; `unseen` that it was raised with nobody there.
    assert %{"turns" => 1, "approvals" => 1, "pending_approvals" => 1} =
             with_unseen(row(ada, sid))

    # Reading it is what clears it.
    {:ok, _} = Client.subscribe(ada, "session:#{sid}")
    assert row(ada, sid)["unseen"] == @none
  end

  test "a session asleep says what happened after its last reader left, and the next reader clears it without waking it",
       context do
    %{session: session} = start_session(context, steps: [{:text, "one"}, {:text, "two"}])
    sid = session.id
    ada = attach(context, @ada)
    {:ok, %{"subscription_id" => sub}} = Client.subscribe(ada, "session:#{sid}", from_seq: 0)
    {:ok, _} = Client.unsubscribe(ada, sub)

    {:ok, _} = input(ada, sid, "first")
    eventually(fn -> ended(sid) == 1 end)
    assert %{"turns" => 1} = row(ada, sid)["unseen"]

    :ok = Troupe.stop_session(sid)
    eventually(fn -> row(ada, sid)["state"] == "dormant" end)
    assert %{"turns" => 1} = row(ada, sid)["unseen"]

    {:ok, %{"subscription_id" => sub}} = Client.subscribe(ada, "session:#{sid}", from_seq: 0)
    assert %{"state" => "dormant", "unseen" => @none} = row(ada, sid)
    {:ok, _} = Client.unsubscribe(ada, sub)
    assert %{"state" => "dormant", "unseen" => @none} = row(ada, sid)
  end

  # -- helpers ----------------------------------------------------------------

  defp row(client, sid) do
    {:ok, row} = Client.call(client, "session.get", %{"session_id" => sid})
    row
  end

  defp listed(client, sid) do
    {:ok, %{"sessions" => sessions}} = Client.call(client, "session.list", %{})
    Enum.filter(sessions, &(&1["id"] == sid))
  end

  defp with_unseen(row), do: Map.merge(row, row["unseen"])

  defp ended(sid), do: Enum.count(Troupe.events(sid), &(&1.type == "turn_ended"))
  defp requested(sid), do: Enum.count(Troupe.events(sid), &(&1.type == "approval_requested"))

  defp input(client, sid, text) do
    Client.call(client, "input.send", %{
      "command_id" => Client.command_id(),
      "session_id" => sid,
      "text" => text
    })
  end
end
