defmodule Troupe.Session.SensitiveTest do
  @moduledoc """
  A session becomes sensitive by what it read (#1239): a call the profile's
  `sensitive.markedBy` names marks it at the gate, before the call runs, once, in a mark
  the root and every subagent read; nothing clears it.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Config.Permissions
  alias Troupe.Session.Sensitive

  defp sensitive(marked_by, deny) do
    [
      sensitive: %{
        marked_by: Permissions.from(%{"deny" => marked_by}, :sensitive, "records"),
        deny: Permissions.from(%{"deny" => deny}, :sensitive, "records"),
        profile: "records"
      }
    ]
  end

  defp run(session, input \\ "go") do
    Troupe.subscribe(session.id)
    Troupe.send_input(session.id, input)
    await_state(session.id, [:idle], 10_000)
  end

  describe "the mark" do
    test "is in the log before the marking call's result is", context do
      write_file(context, "records/ann.txt", "Ann: allergic to penicillin")

      %{session: session} =
        start_session(context,
          config_overrides: sensitive(["read_file(records/**)"], ["web_fetch"]),
          steps: [{:tools, [{"read_file", %{"path" => "records/ann.txt"}}]}, {:text, "read"}]
        )

      run(session)

      [marked] = events_of_type(session.id, "session_marked_sensitive")
      [completed] = events_of_type(session.id, "tool_call_completed")
      [started] = events_of_type(session.id, "tool_call_started")

      assert marked.seq > started.seq
      assert marked.seq < completed.seq
      assert completed.data["ok"]

      assert %{"how" => "call", "by" => "read_file", "rule" => "read_file(records/**)"} =
               marked.data

      assert marked.data["call_id"] == completed.data["call_id"]
      assert marked.agent == ["root"]
      assert Sensitive.mark_of(session.id)["by"] == "read_file"
    end

    test "is made once, whatever calls match after it", context do
      write_file(context, "records/a.txt", "a")
      write_file(context, "records/b.txt", "b")

      %{session: session} =
        start_session(context,
          config_overrides: sensitive(["read_file(records/**)"], ["web_fetch"]),
          steps: [
            {:tools, [{"read_file", %{"path" => "records/a.txt"}}]},
            {:tools, [{"read_file", %{"path" => "records/b.txt"}}]},
            {:text, "read both"}
          ]
        )

      run(session)

      assert [marked] = events_of_type(session.id, "session_marked_sensitive")
      [first | _] = events_of_type(session.id, "tool_call_completed")
      assert marked.data["call_id"] == first.data["call_id"]
    end

    test "is not made by a call that matches nothing, nor by one a rule refused", context do
      write_file(context, "notes.txt", "public")
      write_file(context, "records/a.txt", "a")

      %{session: session} =
        start_session(context,
          config_overrides:
            sensitive(["read_file(records/**)"], ["web_fetch"]) ++
              [permissions: Permissions.from(%{"deny" => ["read_file(records/**)"]}, :profile, "records")],
          steps: [
            {:tools, [{"read_file", %{"path" => "notes.txt"}}]},
            {:tools, [{"read_file", %{"path" => "records/a.txt"}}]},
            {:text, "done"}
          ]
        )

      run(session)

      assert events_of_type(session.id, "session_marked_sensitive") == []
      assert Sensitive.mark_of(session.id) == nil
      [_ok, refused] = events_of_type(session.id, "tool_call_completed")
      assert refused.data["content"] =~ "refused by the rule deny read_file(records/**)"
    end

    test "is folded back from the log when the session comes back", context do
      write_file(context, "records/a.txt", "a")
      overrides = sensitive(["read_file(records/**)"], ["web_fetch"])

      %{session: session} =
        start_session(context,
          config_overrides: overrides,
          steps: [{:tools, [{"read_file", %{"path" => "records/a.txt"}}]}, {:text, "read"}]
        )

      run(session)
      mark = Sensitive.mark_of(session.id)
      :ok = Troupe.stop_session(session.id)

      %{session: again} =
        start_session(context, session_id: session.id, config_overrides: overrides, steps: [])

      assert Sensitive.mark_of(again.id) == mark
      assert [_one] = events_of_type(again.id, "session_marked_sensitive")
    end

    test "a wake that carries the plane's mark logs it once, and the log then agrees", context do
      given = %{"at" => "2026-11-28T10:14:00Z", "by" => "ann", "how" => "person"}
      %{session: session} = start_session(context, sensitive: given, steps: [])

      assert [marked] = events_of_type(session.id, "session_marked_sensitive")
      assert %{"how" => "person", "by" => "ann", "at" => "2026-11-28T10:14:00Z"} = marked.data
      :ok = Troupe.stop_session(session.id)

      %{session: again} = start_session(context, session_id: session.id, sensitive: given, steps: [])
      assert [_still_one] = events_of_type(again.id, "session_marked_sensitive")
      assert Sensitive.mark_of(again.id)["by"] == "ann"
    end

    test "is in the summary and in a checkpoint's facts", context do
      write_file(context, "records/a.txt", "a")

      %{session: session} =
        start_session(context,
          config_overrides: sensitive(["read_file(records/**)"], ["web_fetch"]),
          steps: [{:tools, [{"read_file", %{"path" => "records/a.txt"}}]}, {:text, "read"}]
        )

      run(session)

      snapshot =
        Enum.reduce(Troupe.events(session.id), %{}, &Troupe.Session.Summary.fold(&2, &1))

      assert %{"how" => "call", "by" => "read_file"} = snapshot["sensitive"]

      alias Troupe.Session.Checkpoint
      facts = Checkpoint.facts(Checkpoint.fold_all(Troupe.events(session.id)))
      assert %{"how" => "call", "by" => "read_file", "rule" => "read_file(records/**)"} = facts["sensitive"]
    end
  end

  describe "nothing clears it" do
    test "no function, no event and no second mark takes it away", context do
      given = %{"at" => "2026-11-28T10:14:00Z", "by" => "ann", "how" => "person"}
      %{session: session} = start_session(context, sensitive: given, steps: [])

      # The holder has no way to unmark, and the protocol no event that says one.
      exports = Sensitive.__info__(:functions) |> Keyword.keys() |> Enum.map(&to_string/1)
      refute Enum.any?(exports, &(&1 =~ ~r/clear|unmark|reset|forget|drop|remove/))

      refute Enum.any?(Map.keys(Troupe.Protocol.Schema.events()), fn type ->
               type =~ "sensitive" and type != "session_marked_sensitive"
             end)

      # A later mark, by anybody, answers the first and logs nothing.
      assert {:ok, %{"by" => "ann"}} =
               Sensitive.mark(session.id, %{"how" => "person", "by" => "bob"})

      assert {:ok, %{"by" => "ann"}} =
               Sensitive.mark(session.id, %{"how" => "call", "by" => "read_file"})

      assert [_one] = events_of_type(session.id, "session_marked_sensitive")
      assert Sensitive.mark_of(session.id)["by"] == "ann"
    end
  end
end
