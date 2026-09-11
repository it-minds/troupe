defmodule Troupe.TUITest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.LLM.Fake
  alias Troupe.Session.Log

  # Done item 27
  test "snapshots: window strip states, activated pane with transcript and todo list, approval with diff, ask_user question" do
    ws = tmp_workspace(%{"a.txt" => "old\n"})

    scripts = %{
      "code-1" => [{:delay, 60_000, {:finish, "never"}}],
      "code-2" => [
        {:tool, "write_file", %{"path" => "a.txt", "content" => "new\n"}},
        {:finish, "x"}
      ],
      "code-3" => [
        {:tool, "todo_write",
         %{
           "items" => [
             %{"id" => "1", "content" => "read the code", "status" => "completed"},
             %{"id" => "2", "content" => "write the fix", "status" => "in_progress"}
           ]
         }},
        {:finish, "all done here"}
      ],
      "code-4" => [{:delay, 60_000, {:finish, "never"}}],
      "code-5" => [
        {:tool, "ask_user", %{"question" => "Which database should we target?"}},
        {:finish, "ok"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "long task")
    {:ok, "code-2"} = Troupe.dispatch(sid, "code", "write a file")
    {:ok, "code-3"} = Troupe.dispatch(sid, "code", "plan then finish")
    {:ok, "code-4"} = Troupe.dispatch(sid, "code", "doomed")
    {:ok, "code-5"} = Troupe.dispatch(sid, "code", "ask me something")
    await_state("code-2", :needs_input)
    await_state("code-3", :done_unread)
    await_state("code-5", :needs_input)
    Log.append(sid, "code-4", :branch_failed, %{message: "boom"})
    await_state("code-4", :failed_unread)
    eventually(fn -> user_state(pid).model.windows["code-4"].state == :failed_unread end)

    text = screen_text(pid, session)
    assert text =~ "1 code-1 · running"
    assert text =~ "2 code-2 · needs_input"
    assert text =~ "3 code-3 · done_unread ●"
    assert text =~ "4 code-4 · failed_unread ●"
    assert text =~ "2 need input, 1 done, 1 failed"
    assert text =~ "> long task"
    assert text =~ "/▏"

    # activated pane with transcript and todo list
    press(pid, "3")
    text = screen_text(pid, session)
    assert text =~ "code-3 (code) — Esc back"
    assert text =~ "> plan then finish"
    assert text =~ "✓ todo_write"
    assert text =~ "finished (finished): all done here"
    assert text =~ "[x] read the code"
    assert text =~ "[>] write the fix"
    refute text =~ "3 code-3 · done_unread ●", "badge cleared on activation"

    # approval prompt with diff
    press(pid, "esc")
    press(pid, "2")
    text = screen_text(pid, session)
    assert text =~ "APPROVAL: write_file"
    assert text =~ "-old"
    assert text =~ "+new"

    # ask_user question
    press(pid, "esc")
    press(pid, "5")
    text = screen_text(pid, session)
    assert text =~ "QUESTION: Which database should we target?"
    type(pid, "postgres")
    press(pid, "enter")
    await_state("code-5", :done_unread)
    [answered] = events_of(sid, "code-5", :question_answered)
    assert answered.data.text == "postgres"
  end

  # Done item 28
  test "focus: an approval in window 2 while window 1 is activated does not move focus; Esc 2 y Esc returns to the command line" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [{:delay, 60_000, {:finish, "never"}}],
      "code-2" => [
        {:tool, "write_file", %{"path" => "b.txt", "content" => "x"}},
        {:finish, "written"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "long")
    eventually(fn -> user_state(pid).model.windows["code-1"] end)
    press(pid, "1")
    assert user_state(pid).focus == {:window, "code-1"}

    {:ok, "code-2"} = Troupe.dispatch(sid, "code", "needs approval")
    await_state("code-2", :needs_input)
    eventually(fn -> user_state(pid).model.windows["code-2"].pending != [] end)
    assert user_state(pid).focus == {:window, "code-1"}
    assert screen_text(pid, session) =~ "code-1 (code) — Esc back"

    press(pid, "esc")
    assert user_state(pid).focus == :command
    press(pid, "2")
    assert user_state(pid).focus == {:window, "code-2"}
    press(pid, "y")
    await_state("code-2", :running)
    press(pid, "esc")
    assert user_state(pid).focus == :command
    assert user_state(pid).model.windows["code-1"].state == :running
    assert user_state(pid).model.windows["code-1"].agents["code-1"].transcript == [{:user, "long"}]
    await_state("code-2", :done_unread)
    assert File.exists?(Path.join(ws, "b.txt"))
  end

  # Done item 29
  test "killing the TUI mid-stream leaves branches running; it restarts and redraws from the log" do
    ws = tmp_workspace()

    fallback = fn req ->
      if length(req.messages) < 7,
        do: {:delay, 150, {:tool, "shell", %{"command" => "echo step"}}},
        else: {:finish, "ok"}
    end

    {sid, fake, _} = start_session!(workspace: ws, fallback: fallback, auto_approve: true)
    {session, opts} = tui_opts(sid)
    name = Troupe.UI.TUI.Server.via(sid)

    start_supervised!(%{
      id: :tui,
      start: {ExRatatui.Server, :start_link, [Keyword.put(opts, :name, name)]},
      restart: :permanent
    })

    pid = GenServer.whereis(name)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "one")
    {:ok, "code-2"} = Troupe.dispatch(sid, "code", "two")
    eventually(fn -> Fake.call_count(fake) >= 2 end)
    eventually(fn -> map_size(user_state(pid).model.windows) == 2 end)

    count_before = Fake.call_count(fake)
    Process.exit(pid, :kill)

    new_pid =
      eventually(fn ->
        p = GenServer.whereis(name)
        if p && p != pid, do: p
      end)

    # branches never noticed
    eventually(fn -> Fake.call_count(fake) > count_before end)
    assert Troupe.agent_pid(sid, "code-1") && Troupe.agent_pid(sid, "code-2")
    assert Enum.all?(Troupe.windows(sid), &(&1.state == :running))

    text = screen_text(new_pid, session)
    assert text =~ "1 code-1 · running"
    assert text =~ "2 code-2 · running"
    assert text =~ "> one"
    assert text =~ "shell echo step"

    await_state("code-1", :done_unread, 15_000)
    await_state("code-2", :done_unread, 15_000)
  end

  # Done item 30
  test "backpressure: 10k deltas across four branches while the TUI renders slowly do not slow a branch; mailbox stays bounded" do
    ws = tmp_workspace()

    fallback = fn req ->
      if length(req.messages) < 9,
        do: {:tool, "shell", %{"command" => "true"}},
        else: {:finish, "ok"}
    end

    {sid, _fake, _} = start_session!(workspace: ws, fallback: fallback, auto_approve: true)
    {pid, _session} = start_tui(sid, slow_render_ms: 40)

    paths = for i <- 1..4, do: "flood-#{i}"

    for p <- paths,
        do:
          Log.append(sid, p, :branch_spawned, %{
            branch_id: p,
            name: "code",
            prompt: "flood",
            isolation: :shared,
            source: :user,
            budget: %{}
          })

    measure = fn ->
      t0 = System.monotonic_time(:millisecond)
      {:ok, path} = Troupe.dispatch(sid, "code", "work")
      await_state(path, :done_unread, 20_000)
      System.monotonic_time(:millisecond) - t0
    end

    baseline = measure.()

    me = self()

    flooder =
      spawn_link(fn ->
        for i <- 1..10_000 do
          Troupe.Events.notify(sid, Enum.at(paths, rem(i, 4)), :llm_delta, %{
            text: "delta #{i} ",
            purpose: :thinking
          })
        end

        send(me, :flood_done)
      end)

    sampler =
      spawn_link(fn ->
        Enum.reduce(1..40, 0, fn _, max ->
          {:message_queue_len, n} = Process.info(pid, :message_queue_len) || {:message_queue_len, 0}
          Process.sleep(25)
          Kernel.max(max, n)
        end)
        |> then(&send(me, {:max_queue, &1}))
      end)

    flooded = measure.()
    assert_receive :flood_done, 20_000
    assert_receive {:max_queue, max_queue}, 20_000
    Process.exit(flooder, :normal)
    Process.exit(sampler, :normal)

    assert flooded < baseline * 3 + 1_500, "baseline #{baseline}ms, flooded #{flooded}ms"
    assert max_queue < 8_000, "TUI mailbox peaked at #{max_queue}"

    eventually(
      fn -> match?({:message_queue_len, n} when n < 50, Process.info(pid, :message_queue_len)) end,
      15_000
    )

    assert Process.alive?(pid)
  end
end
