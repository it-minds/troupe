defmodule Troupe.CoreTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.LLM.Fake

  # Done item 2
  test "single-branch loop: read_file, edit_file, finish changes the file and rests done_unread" do
    ws = tmp_workspace(%{"lib/a.ex" => "defmodule A do\n  def x, do: 1\nend\n"})

    script = [
      {:tool, "read_file", %{"path" => "lib/a.ex"}},
      {:tool, "edit_file",
       %{"path" => "lib/a.ex", "old_string" => "do: 1", "new_string" => "do: 42"}},
      {:finish, "changed x to 42"}
    ]

    {sid, fake, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, path} = Troupe.dispatch(sid, "code", "make x return 42")
    assert path == "code-1"

    await_state(path, :done_unread)

    assert File.read!(Path.join(ws, "lib/a.ex")) =~ "do: 42"
    assert window(sid, path).state == :done_unread
    assert window(sid, path).summary == "changed x to 42"
    assert Fake.call_count(fake) == 3

    types = sid |> Troupe.events() |> Enum.filter(&(&1.agent_path == path)) |> Enum.map(& &1.type)

    assert [
             :branch_spawned,
             :input,
             :assistant_message,
             :tool_call_started,
             :tool_call_completed,
             :assistant_message,
             :tool_call_started,
             :tool_call_completed,
             :assistant_message,
             :tool_call_started,
             :tool_call_completed,
             :finished,
             :branch_state
           ] = types

    names = sid |> events_of(path, :tool_call_started) |> Enum.map(& &1.data.name)
    assert names == ["read_file", "edit_file", "finish"]
  end

  # Done item 3
  test "three 500ms tool calls in one turn complete in under 1s" do
    ws = tmp_workspace()

    script = [
      {:tools,
       [
         {"shell", %{"command" => "sleep 0.5; echo a"}},
         {"shell", %{"command" => "sleep 0.5; echo b"}},
         {"shell", %{"command" => "sleep 0.5; echo c"}}
       ]},
      {:finish, "done"}
    ]

    {sid, fake, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    t0 = System.monotonic_time(:millisecond)
    {:ok, path} = Troupe.dispatch(sid, "code", "sleep in parallel")
    await_state(path, :done_unread)
    elapsed = System.monotonic_time(:millisecond) - t0
    assert elapsed < 1_000, "took #{elapsed}ms"

    [_, second | _] = Fake.requests(fake)
    results = second.messages |> List.last() |> Map.get(:content)
    assert Enum.map(results, & &1.tool_use_id) == ["call_1", "call_2", "call_3"]
    assert Enum.map(results, &String.trim(&1.content)) == ["a", "b", "c"]
  end

  # Done item 5
  test "a tool that raises yields an error tool_result and the agent pid is unchanged" do
    ws = tmp_workspace()
    # read_file with a non-binary path makes the tool raise inside Workspace.resolve
    script = [{:tool, "read_file", %{"path" => 123}}, {:finish, "ok"}]
    {sid, fake, _} = start_session!(workspace: ws, script: script)
    {:ok, path} = Troupe.dispatch(sid, "code", "x")
    await_event(path, :assistant_message)
    pid = eventually(fn -> Troupe.agent_pid(sid, path) end)
    await_state(path, :done_unread)
    assert Troupe.agent_pid(sid, path) == pid or Troupe.agent_pid(sid, path) == nil

    [completed] = events_of(sid, path, :tool_call_completed) |> Enum.take(1)
    assert completed.data.ok == false
    assert completed.data.content =~ "crashed"
    [_, second | _] = Fake.requests(fake)
    [%{type: :tool_result, is_error: true}] = second.messages |> List.last() |> Map.get(:content)
  end

  # Done item 8
  test "budget: max_turns 2 stops with :budget_exhausted after exactly 2 Fake calls" do
    ws = tmp_workspace(%{"f.txt" => "x"})
    script = List.duplicate({:tool, "read_file", %{"path" => "f.txt"}}, 10)
    {sid, fake, _} = start_session!(workspace: ws, script: script)
    {:ok, path} = Troupe.dispatch(sid, "code", %{prompt: "loop", budget: %{max_turns: 2}})
    await_state(path, :done_unread)
    assert window(sid, path).reason == :budget_exhausted
    assert Fake.call_count(fake) == 2
  end

  # Done item 10
  test "approvals: ask tool blocks until allow; deny produces a readable denial; needs_input carries agent_path" do
    ws = tmp_workspace()

    script = [
      {:tool, "write_file", %{"path" => "a.txt", "content" => "hello"}},
      {:tool, "write_file", %{"path" => "b.txt", "content" => "world"}},
      {:finish, "done"}
    ]

    {sid, fake, _} = start_session!(workspace: ws, script: script)
    {:ok, path} = Troupe.dispatch(sid, "code", "write files")

    assert_receive {:troupe_event,
                    %{type: :branch_state, agent_path: ^path, data: %{state: :needs_input}}},
                   5_000

    req = await_event(path, :approval_requested)
    assert req.data.name == "write_file"
    assert req.data.preview =~ "+hello"
    refute File.exists?(Path.join(ws, "a.txt"))
    assert window(sid, path).state == :needs_input

    :ok = Troupe.approve(sid, req.data.call_id, :allow)
    await_state(path, :running)
    eventually(fn -> File.exists?(Path.join(ws, "a.txt")) end)

    req2 = await_event(path, :approval_requested)
    :ok = Troupe.approve(sid, req2.data.call_id, :deny)
    await_state(path, :done_unread)
    refute File.exists?(Path.join(ws, "b.txt"))

    [_, _, third | _] = Fake.requests(fake)

    [%{type: :tool_result, is_error: true, content: content}] =
      third.messages |> List.last() |> Map.get(:content)

    assert content =~ "denied"
  end

  test "allow-for-session skips later approvals for the same tool" do
    ws = tmp_workspace()

    script = [
      {:tool, "write_file", %{"path" => "a.txt", "content" => "1"}},
      {:tool, "write_file", %{"path" => "b.txt", "content" => "2"}},
      {:finish, "done"}
    ]

    {sid, _fake, _} = start_session!(workspace: ws, script: script)
    {:ok, path} = Troupe.dispatch(sid, "code", "write")
    req = await_event(path, :approval_requested)
    :ok = Troupe.approve(sid, req.data.call_id, :allow_session)
    await_state(path, :done_unread)
    assert length(events_of(sid, path, :approval_requested)) == 1
    assert File.exists?(Path.join(ws, "b.txt"))
  end

  # Done item 12
  test "edit_file on a CRLF file keeps CRLF" do
    ws = tmp_workspace(%{"win.txt" => "line one\r\nline two\r\nline three\r\n"})

    script = [
      {:tool, "edit_file",
       %{"path" => "win.txt", "old_string" => "line two", "new_string" => "LINE 2"}},
      {:finish, "ok"}
    ]

    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: true)
    {:ok, path} = Troupe.dispatch(sid, "code", "edit")
    await_state(path, :done_unread)
    assert File.read!(Path.join(ws, "win.txt")) == "line one\r\nLINE 2\r\nline three\r\n"
  end

  test "free text without a leading slash is rejected with a hint" do
    {sid, _, _} = start_session!()
    assert {:error, msg} = Troupe.dispatch(sid, "fix the tests", "")
    assert msg =~ "/code"
    assert msg =~ "/plan"
  end

  test "continue: input to a done_unread branch returns it to running and the next request has the prior conversation" do
    ws = tmp_workspace()
    script = [{:finish, "first done"}, {:finish, "second done"}]
    {sid, fake, _} = start_session!(workspace: ws, script: script)
    {:ok, path} = Troupe.dispatch(sid, "code", "first task")
    await_state(path, :done_unread)
    eventually(fn -> Troupe.agent_pid(sid, path) == nil end)

    :ok = Troupe.send_input(sid, path, "follow up")
    await_state(path, :running)
    await_state(path, :done_unread)

    [_, second] = Fake.requests(fake)

    texts =
      second.messages
      |> Enum.flat_map(& &1.content)
      |> Enum.filter(&match?(%{type: :text}, &1))
      |> Enum.map(& &1.text)

    assert "first task" in texts
    assert "follow up" in texts

    assert Enum.any?(
             second.messages |> Enum.flat_map(& &1.content),
             &match?(%{type: :tool_use, name: "finish"}, &1)
           )
  end
end

defmodule Troupe.CompactionTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.LLM.Fake

  test "context past the configured fraction of the window is compacted into a summary and the agent continues" do
    ws = tmp_workspace(%{"big.txt" => String.duplicate("lorem ipsum dolor sit amet ", 40)})
    script = List.duplicate({:tool, "read_file", %{"path" => "big.txt"}}, 6) ++ [{:finish, "done"}]

    {sid, fake, _} =
      start_session!(
        workspace: ws,
        script: script,
        config: %{default_window: 1_500, compaction: %{fraction: 0.5, keep_last_turns: 1}}
      )

    {:ok, path} = Troupe.dispatch(sid, "code", "read it a few times")
    await_state(path, :done_unread, 15_000)

    compactions = events_of(sid, path, :compaction)
    assert compactions != []
    assert hd(compactions).data.summary =~ "Summary"
    assert Enum.any?(Fake.requests(fake), &(&1.purpose == :compaction))

    after_compaction = fake |> Fake.requests() |> Enum.filter(&(&1.purpose == :turn)) |> List.last()
    first_text = after_compaction.messages |> hd() |> Map.get(:content) |> Troupe.LLM.Message.text()
    assert first_text =~ "Summary of the earlier conversation"

    assert Enum.all?(Enum.chunk_every(after_compaction.messages, 2, 1, :discard), fn [a, b] ->
             a.role != b.role
           end)

    assert window(sid, path).summary == "done"
  end
end
