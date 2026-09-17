defmodule Troupe.Sessions.ForkTest do
  @moduledoc """
  A fork, against real object storage.

  The claim being tested is independence. A fork that were a pointer into its parent would
  pass a test that only read it while the parent was there — so the interesting assertions
  are the ones made *after* the parent is erased, and they are the reason the copy model
  was chosen over the reference one.

  The other half is the chain. Resealing gives the child its own sequence numbers, and a
  child whose events kept the parent's numbering would verify against nothing; `verify/1`
  on both logs, separately, is what says the copy is a log and not a transcript of one.
  """

  use Troupe.ObjectStoreCase, async: false

  alias Troupe.Protocol.Event
  alias Troupe.Sessions.{Context, Fork, Storage}

  @moduletag timeout: 120_000

  setup context do
    if store = context[:store] do
      parent = session(store, "parent")
      child = session(store, "child")

      on_exit(fn ->
        Storage.erase(store, parent.session_id)
        Storage.erase(store, child.session_id)
      end)

      %{store: store, parent: parent, child: child}
    else
      :ok
    end
  end

  defp session(store, role) do
    %Context{
      session_id: unique("fork-#{role}"),
      team: "engineering",
      epoch: 1,
      # Different keys, deliberately. A child that could be opened with its parent's key
      # would not have one of its own in the sense that matters.
      data_key: :crypto.strong_rand_bytes(32),
      store: store
    }
  end

  defp contexts(context) do
    context = requires_store(context)
    {context.parent, context.child}
  end

  # A small real history: a create carrying entitlements, then some typing.
  defp write_history(%Context{} = parent, count) do
    created =
      %Event{
        type: "session_created",
        data: %{
          "workspace" => "/w",
          "profile" => "dev",
          "visibility" => "team",
          "entitlements" => %{"agents" => ["reviewer"], "mcp" => ["jira"]}
        }
      }

    rest =
      for n <- 2..count do
        %Event{type: "user_input", data: %{"source" => "chat", "text" => "line #{n}"}}
      end

    chain =
      [created | rest]
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn {event, seq}, {acc, previous} ->
        sealed = Event.seal(event, seq, previous, "2026-01-0#{min(seq, 9)}T00:00:00Z")
        {[sealed | acc], sealed}
      end)
      |> elem(0)
      |> Enum.reverse()

    {:ok, segment} =
      Storage.seal_segment(parent.store, parent.session_id, parent.data_key, %{
        events: Enum.map(chain, &Event.to_json/1),
        epoch: parent.epoch,
        head_hash: chain |> List.last() |> Event.hash()
      })

    {chain, segment}
  end

  defp read_child(%Context{} = child) do
    {:ok, segments} = Storage.list_segments(child.store, child.session_id)

    segments
    |> Storage.live_segments()
    |> Enum.flat_map(fn segment ->
      {:ok, events} = Storage.read_segment(child.store, child.session_id, child.data_key, segment.key)
      events
    end)
    |> Enum.map(&Event.from_json/1)
  end

  describe "the copy" do
    test "takes the parent's events up to seq and no further", context do
      {parent, child} = contexts(context)
      {_chain, _segment} = write_history(parent, 6)

      assert {:ok, result} = Fork.copy(parent, child, seq: 3, reason: "attempt")

      # One opening event plus three carried: the fork point is inclusive, which is what
      # "fork at seq 3" means to somebody looking at seq 3 on their screen.
      assert result.parent_seq == 3
      assert result.events == 4
      assert result.last_seq == 4

      events = read_child(child)
      assert Enum.map(events, & &1.type) == ~w(session_forked session_created user_input user_input)
      assert Enum.map(events, & &1.seq) == [1, 2, 3, 4]
      assert Enum.map(events, & &1.data["text"]) |> Enum.reject(&is_nil/1) == ["line 2", "line 3"]
    end

    test "opens with session_forked, which is where the lineage is written", context do
      {parent, child} = contexts(context)
      {chain, _} = write_history(parent, 6)
      at = Enum.at(chain, 2)

      assert {:ok, result} = Fork.copy(parent, child, seq: 3, reason: "branch")

      assert [forked | _] = read_child(child)
      assert forked.type == "session_forked"
      assert forked.seq == 1
      assert is_nil(forked.prev_hash)
      assert forked.data["reason"] == "branch"
      assert forked.data["parent"]["session_id"] == parent.session_id
      assert forked.data["parent"]["seq"] == 3

      # The parent's head *at the fork point*, not the parent's head now — the difference
      # is the whole of what makes the claim checkable by somebody holding only the child.
      assert forked.data["parent"]["head_hash"] == Event.hash(at)
      assert result.parent_head_hash == Event.hash(at)
    end

    test "verifies as a chain of its own", context do
      {parent, child} = contexts(context)
      {chain, _} = write_history(parent, 6)

      assert {:ok, result} = Fork.copy(parent, child, seq: 4)

      events = read_child(child)
      assert Event.verify(events) == :ok
      assert events |> List.last() |> Event.hash() == result.head_hash

      # And so does the parent, unchanged. Two chains, each valid, neither needing the
      # other to be read — which a child holding the parent's numbering could not manage.
      assert Event.verify(chain) == :ok
    end

    test "keeps what each event said and changes only its numbering", context do
      {parent, child} = contexts(context)
      {chain, _} = write_history(parent, 5)

      assert {:ok, _} = Fork.copy(parent, child, seq: 5)

      [_forked | carried] = read_child(child)

      for {original, copy} <- Enum.zip(chain, carried) do
        assert copy.type == original.type
        assert copy.data == original.data
        # The timestamp especially. An event says when it happened, and forking does not
        # make the parent's history happen a second time.
        assert copy.ts == original.ts
        assert copy.seq == original.seq + 1
      end
    end

    test "at no seq at all is a fork at the head", context do
      {parent, child} = contexts(context)
      {chain, _} = write_history(parent, 6)

      assert {:ok, result} = Fork.copy(parent, child, reason: "import")

      assert result.parent_seq == 6
      assert result.events == 7
      assert result.parent_head_hash == chain |> List.last() |> Event.hash()
    end
  end

  describe "the parent" do
    test "is not written to, and does not learn it was forked", context do
      {parent, child} = contexts(context)
      {chain, segment} = write_history(parent, 6)

      {:ok, before} = Storage.list_segments(parent.store, parent.session_id)
      assert {:ok, _} = Fork.copy(parent, child, seq: 3)
      {:ok, after_fork} = Storage.list_segments(parent.store, parent.session_id)

      assert Enum.map(before, & &1.key) == Enum.map(after_fork, & &1.key)
      assert Enum.map(after_fork, & &1.key) == [segment.key]

      {:ok, events} = Storage.read_segment(parent.store, parent.session_id, parent.data_key, segment.key)
      assert length(events) == 6
      refute Enum.any?(events, &(&1["type"] == "session_forked"))
      assert events |> List.last() |> Event.from_json() |> Event.hash() == chain |> List.last() |> Event.hash()
    end

    test "can be erased and the child is still readable", context do
      {parent, child} = contexts(context)
      write_history(parent, 6)

      assert {:ok, _} = Fork.copy(parent, child, seq: 4)

      # Both halves of erasure, as far as a test can do them: the objects go, and the key
      # is not the child's to begin with. If the child were a reference this is the point
      # at which it would stop being a session.
      assert {:ok, _} = Storage.erase(parent.store, parent.session_id)
      assert {:ok, []} = Storage.list_segments(parent.store, parent.session_id)

      events = read_child(child)
      assert length(events) == 5
      assert Event.verify(events) == :ok
      assert Enum.map(events, & &1.data["text"]) |> Enum.reject(&is_nil/1) == ["line 2", "line 3", "line 4"]

      # The lineage still reads. It names a session that no longer exists, which is the
      # honest thing for it to say and not a broken pointer.
      assert [forked | _] = events
      assert forked.data["parent"]["session_id"] == parent.session_id
    end
  end

  describe "what the child may run" do
    test "is what the parent's session_created recorded, not what is on offer now", context do
      {parent, child} = contexts(context)
      write_history(parent, 6)

      assert {:ok, result} = Fork.copy(parent, child, seq: 6)
      assert result.entitlements == %{"agents" => ["reviewer"], "mcp" => ["jira"]}
    end

    test "is nil where the parent recorded nothing, which is not the same as nothing", context do
      {parent, child} = contexts(context)

      created = Event.seal(%Event{type: "session_created", data: %{"workspace" => "/w", "profile" => "dev", "visibility" => "team"}}, 1, nil, "2026-01-01T00:00:00Z")

      {:ok, _} =
        Storage.seal_segment(parent.store, parent.session_id, parent.data_key, %{
          events: [Event.to_json(created)],
          epoch: 1,
          head_hash: Event.hash(created)
        })

      assert {:ok, result} = Fork.copy(parent, child)
      assert is_nil(result.entitlements)
    end
  end

  describe "what a child may run" do
    test "is what the parent recorded, narrowed by what the team has now" do
      recorded = %{"agents" => ["reviewer", "migrator"], "mcp_servers" => ["jira"]}

      # The case the rule exists for. The team lost `migrator` since the parent ran, and
      # forking an old session is not a way to get it back.
      now = %{"agents" => ["reviewer"], "mcp_servers" => ["jira", "slack"]}

      assert Fork.narrow(now, recorded) == %{
               "agents" => ["reviewer"],
               "mcp_servers" => ["jira"]
             }
    end

    test "is nil on either side meaning no restriction, and not an empty set" do
      # A local session and an unnarrowed grant both record nothing, and nothing is not
      # the same as a session allowed nothing at all.
      assert Fork.narrow(nil, %{"agents" => ["reviewer"]}) == %{"agents" => ["reviewer"]}
      assert Fork.narrow(%{"agents" => ["reviewer"]}, nil) == %{"agents" => ["reviewer"]}
      assert is_nil(Fork.narrow(nil, nil))

      # An empty list is a real answer and stays one.
      assert Fork.narrow(%{"agents" => ["reviewer"]}, %{"agents" => []}) == %{"agents" => []}
    end

    test "keeps a kind only one side mentions, from whichever side mentions it" do
      # Deny wins per kind, and a kind nobody has narrowed is not narrowed by silence.
      assert Fork.narrow(%{"agents" => ["a"]}, %{"skills" => ["s"]}) ==
               %{"agents" => ["a"], "skills" => ["s"]}
    end
  end

  describe "the workspace" do
    test "comes from the nearest archive at or before the fork point", context do
      {parent, child} = contexts(context)
      write_history(parent, 6)

      # Archives are written at intervals, so a fork at 5 lands between two of them.
      {:ok, _} = Storage.put_workspace(parent.store, parent.session_id, parent.data_key, 2, "at-two")
      {:ok, _} = Storage.put_workspace(parent.store, parent.session_id, parent.data_key, 6, "at-six")

      assert {:ok, result} = Fork.copy(parent, child, seq: 5)
      assert result.workspace == {2, "tar"}

      # And it opens under the *child's* key, in the child's prefix. Sealed bytes copied
      # across unchanged would be bytes nothing could open.
      assert {:ok, "at-two"} = Storage.get_workspace(child.store, child.session_id, child.data_key, 2)
    end

    test "is absent rather than invented when the parent has none before the point", context do
      {parent, child} = contexts(context)
      write_history(parent, 6)
      {:ok, _} = Storage.put_workspace(parent.store, parent.session_id, parent.data_key, 6, "at-six")

      assert {:ok, result} = Fork.copy(parent, child, seq: 3)
      assert is_nil(result.workspace)
      assert Storage.workspace_archives(child.store, child.session_id) == []
    end
  end

  describe "refusals" do
    test "a reason nobody defined", context do
      {parent, child} = contexts(context)
      write_history(parent, 3)

      assert {:error, {:bad_reason, "vibes", reasons}} =
               Fork.copy(parent, child, reason: "vibes")

      assert reasons == ~w(attempt branch import)
    end

    test "a seq the parent never reached", context do
      {parent, child} = contexts(context)
      write_history(parent, 3)

      assert {:error, {:no_such_seq, 0}} = Fork.copy(parent, child, seq: 0)
      assert {:error, {:bad_seq, -1}} = Fork.copy(parent, child, seq: -1)
    end

    test "a parent with no history", context do
      {parent, child} = contexts(context)

      assert {:error, :empty_parent} = Fork.copy(parent, child)
    end

    test "forking a session into itself", context do
      {parent, _child} = contexts(context)
      write_history(parent, 3)

      # Not a fork: it would append the session's own history to itself under its own key,
      # and there is nothing to recover to.
      assert {:error, :fork_into_self} = Fork.copy(parent, parent)
    end
  end
end
