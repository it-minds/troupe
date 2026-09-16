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
    # bounded: whatever the burst queued is collapsed and drained within 3 s
    t0 = System.monotonic_time(:millisecond)

    eventually(
      fn -> match?({:message_queue_len, n} when n < 50, Process.info(pid, :message_queue_len)) end,
      3_000,
      20
    )

    drain_ms = System.monotonic_time(:millisecond) - t0
    assert drain_ms < 3_000, "mailbox peaked at #{max_queue} and took #{drain_ms}ms to drain"

    assert Process.alive?(pid)
  end
end

defmodule Troupe.TUIActivityTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  test "a working window shows what it is doing: thinking, then the running tool, then waiting for you" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [
        {:delay, 1_500, {:tool, "shell", %{"command" => "sleep 1.5; echo hi"}}},
        {:tool, "write_file", %{"path" => "a", "content" => "b"}},
        {:finish, "ok"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "do something slow")

    eventually(fn -> screen_text(pid, session) =~ ~r/thinking \(00:0\d\)/ end)

    req = await_event("code-1", :approval_requested, 10_000)
    :ok = Troupe.approve(sid, req.data.call_id, :allow)

    assert_receive {:troupe_event,
                    %{type: :tool_call_started, agent_path: "code-1", data: %{name: "shell"}}},
                   5_000

    eventually(fn -> screen_text(pid, session) =~ "running shell sleep 1.5; echo hi (00:0" end)
    await_state("code-1", :needs_input, 10_000)
    eventually(fn -> screen_text(pid, session) =~ "waiting for you" end)
  end
end

defmodule Troupe.TUIMouseTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.Event.Mouse

  test "clicking a tile activates that window; the status line says which key answers a waiting window" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [{:delay, 60_000, {:finish, "never"}}],
      "code-2" => [{:tool, "write_file", %{"path" => "a", "content" => "b"}}, {:finish, "x"}]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "one")
    {:ok, "code-2"} = Troupe.dispatch(sid, "code", "two")
    await_state("code-2", :needs_input)
    eventually(fn -> user_state(pid).model.windows["code-2"].pending != [] end)

    assert screen_text(pid, session) =~ "press 2 (or Enter, or click the window) to answer"

    # two tiles across a 220-wide screen: x=5 is the first, x=150 the second
    :ok = ExRatatui.Runtime.inject_event(pid, %Mouse{kind: "down", button: "left", x: 150, y: 3})
    assert user_state(pid).focus == {:window, "code-2"}
    assert screen_text(pid, session) =~ "APPROVAL: write_file"

    :ok = ExRatatui.Runtime.inject_event(pid, %Mouse{kind: "down", button: "left", x: 5, y: 3})
    assert user_state(pid).focus == {:window, "code-1"}

    # a click below the strip changes nothing
    :ok = ExRatatui.Runtime.inject_event(pid, %Mouse{kind: "down", button: "left", x: 5, y: 39})
    assert user_state(pid).focus == {:window, "code-1"}

    # Enter on the empty command line jumps to the window that needs input
    press(pid, "esc")
    press(pid, "enter")
    assert user_state(pid).focus == {:window, "code-2"}
  end
end

defmodule Troupe.TUICompletionTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  test "Tab completes command names and worktree paths for /merge and /discard, cycling on repeat" do
    ws = tmp_workspace() |> git_init!()

    scripts = %{
      "worktree-1" => [
        {:tool, "write_file", %{"path" => "a.txt", "content" => "a"}},
        {:finish, "a"}
      ],
      "worktree-2" => [
        {:tool, "write_file", %{"path" => "b.txt", "content" => "b"}},
        {:finish, "b"}
      ],
      "worktree-3" => [{:delay, 60_000, {:finish, "never"}}],
      "code-1" => [{:finish, "plain"}]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, _session} = start_tui(sid)
    for _ <- 1..3, do: {:ok, _} = Troupe.dispatch(sid, "worktree", "w")
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "c")
    for p <- ["worktree-1", "worktree-2", "code-1"], do: await_state(p, :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    # an ambiguous prefix (`workflow` and `worktree` are both agents) completes
    # to the first match; one more character makes it unambiguous
    type(pid, "wor")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "workflow "
    press(pid, "esc")

    type(pid, "workt")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "worktree "
    press(pid, "esc")

    # only finished worktree branches are offered; the running one and the shared one are not
    type(pid, "merge ")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "merge worktree-1"
    press(pid, "tab")
    assert user_state(pid).cmd_text == "merge worktree-2"
    press(pid, "tab")
    assert user_state(pid).cmd_text == "merge worktree-1"
    press(pid, "enter")
    eventually(fn -> File.exists?(Path.join(ws, "a.txt")) end)

    # a merged worktree drops out of the candidates
    eventually(fn ->
      get_in(user_state(pid).model.windows, ["worktree-1", :worktree, :merged]) == true
    end)

    type(pid, "discard ")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "discard worktree-2"
    press(pid, "esc")

    # cancel completes every window still on the strip, running or resting
    type(pid, "cancel w")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "cancel worktree-1"
    press(pid, "tab")
    assert user_state(pid).cmd_text == "cancel worktree-2"
    press(pid, "tab")
    assert user_state(pid).cmd_text == "cancel worktree-3"
    press(pid, "esc")

    # @file completion still works
    type(pid, "code look at @REA")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "code look at @README.md"
  end
end

defmodule Troupe.TUIWorktreeCompletionTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.UI.TUI.Model

  test "/worktree <Tab> completes the user's checked-out worktrees by path or branch" do
    ws = tmp_workspace() |> git_init!()
    run_git!(ws, ["worktree", "add", "feature/design", "-b", "design"])
    run_git!(ws, ["worktree", "add", "feature/api", "-b", "api"])
    {sid, _, _} = start_session!(workspace: ws)
    {pid, _} = start_tui(sid)

    type(pid, "worktree fe")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "worktree feature/api "
    press(pid, "backspace")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "worktree feature/design "
    press(pid, "esc")

    type(pid, "worktree des")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "worktree design "
    type(pid, "add docs")
    assert user_state(pid).cmd_text == "worktree design add docs"
  end

  # Decision 42
  test "/worktree <Tab> offers a Troupe-managed worktree as <name>:" do
    ws = tmp_workspace() |> git_init!()
    scripts = %{"worktree-1" => [{:finish, "ok"}]}
    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, _} = start_tui(sid)

    {:ok, "worktree-1"} = Troupe.dispatch(sid, "worktree", "feat-auth: start it")
    await_state("worktree-1", :done_unread, 15_000)

    type(pid, "worktree feat")
    press(pid, "tab")
    assert user_state(pid).cmd_text == "worktree feat-auth: "
    type(pid, "carry on")
    assert user_state(pid).cmd_text == "worktree feat-auth: carry on"
  end

  # Decision 57
  test "/cancel <n> stops the branch on tile n and takes its window off the strip" do
    ws = tmp_workspace()
    fallback = fn _ -> {:delay, 20_000, {:finish, "never"}} end
    {sid, _, _} = start_session!(workspace: ws, fallback: fallback)
    {pid, session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "keep this one")
    {:ok, "code-2"} = Troupe.dispatch(sid, "code", "cancel this one")
    eventually(fn -> map_size(user_state(pid).model.windows) == 2 end)

    type(pid, "/cancel 2")
    press(pid, "enter")
    await_event("code-2", :window_dismissed)
    eventually(fn -> map_size(user_state(pid).model.windows) == 1 end)

    text = screen_text(pid, session)
    assert text =~ "1 code-1 · running"
    refute text =~ "code-2"

    # a path still works, and so does the number of a window that is already resting
    type(pid, "/cancel code-1")
    press(pid, "enter")
    await_event("code-1", :window_dismissed)
    eventually(fn -> map_size(user_state(pid).model.windows) == 0 end)
  end

  test "a multi-line tool argument renders on one row instead of aborting the frame" do
    ws = tmp_workspace()
    question = "Which of these?\n\n1. the first one\n2. the second one"
    scripts = %{"code-1" => [{:tool, "ask_user", %{"question" => question}}, {:finish, "ok"}]}
    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "ask me something")
    await_state("code-1", :needs_input)

    text = screen_text(pid, session)
    assert text =~ "ask_user Which of these? 1. the first one 2. the second one"

    press(pid, "1")
    text = screen_text(pid, session)
    assert text =~ "QUESTION: Which of these? 1. the first one 2. the second one"
  end

  test "bracketed paste inserts into the command line, a window input, and a settings field" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [
        {:tool, "ask_user", %{"question" => "What do you want?"}},
        {:finish, "ok"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, _session} = start_tui(sid)

    # Command line: paste a full command and run it.
    paste(pid, "/settings")
    assert user_state(pid).cmd_text == "/settings"
    press(pid, "enter")

    # Settings field: move to a non-bool field (watch debounce, an int), edit it and paste.
    to_setting(pid, "watch.debounce_ms")
    press(pid, "enter")
    assert is_binary(user_state(pid).settings.editing)
    before_editing = user_state(pid).settings.editing
    paste(pid, "42")
    assert user_state(pid).settings.editing == before_editing <> "42"
    press(pid, "esc")
    press(pid, "esc")

    # Active window: paste into its input box while an agent needs input.
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "ask me something")
    await_state("code-1", :needs_input)
    press(pid, "1")

    paste(pid, "a multi-\nline answer")
    assert user_state(pid).win_text == "a multi-\nline answer"
    press(pid, "enter")
    await_state("code-1", :done_unread)

    [answered] = events_of(sid, "code-1", :question_answered)
    assert answered.data.text == "a multi-\nline answer"
  end

  test "a question with options renders a numbered menu and a digit answers it" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [
        {:tool, "ask_user",
         %{
           "question" => "Which database?",
           "options" => [
             %{"label" => "postgres", "description" => "what production runs"},
             "sqlite"
           ]
         }},
        {:finish, "ok"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "ask me")
    await_state("code-1", :needs_input)

    press(pid, "1")
    text = screen_text(pid, session)
    assert text =~ "QUESTION: Which database?"
    assert text =~ "1. postgres"
    assert text =~ "what production runs"
    assert text =~ "2. sqlite"
    assert text =~ "press a digit to choose"

    # The digit is the answer: nothing lands in the input box.
    press(pid, "2")
    assert user_state(pid).win_text == ""
    await_state("code-1", :done_unread)

    [answered] = events_of(sid, "code-1", :question_answered)
    assert answered.data.text == "sqlite"

    [asked] = events_of(sid, "code-1", :question_asked)
    assert Enum.map(asked.data.options, & &1.label) == ["postgres", "sqlite"]
    refute asked.data.multiple
  end

  test "a multiple-choice question ticks with digits and sends the ticked set on Enter" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [
        {:tool, "ask_user",
         %{
           "question" => "Which targets?",
           "options" => ["linux", "macos", "windows"],
           "multiple" => true
         }},
        {:finish, "ok"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "ask me")
    await_state("code-1", :needs_input)

    press(pid, "1")
    assert screen_text(pid, session) =~ "Enter sends the ticked options"

    # Tick two, then untick and re-tick one to show a digit toggles.
    press(pid, "1")
    press(pid, "3")
    assert user_state(pid).answer.selected == ["linux", "windows"]
    press(pid, "3")
    assert user_state(pid).answer.selected == ["linux"]
    press(pid, "2")
    assert user_state(pid).answer.selected == ["linux", "macos"]

    text = screen_text(pid, session)
    assert text =~ "[x] linux"
    assert text =~ "[x] macos"
    assert text =~ "[ ] windows"

    press(pid, "enter")
    await_state("code-1", :done_unread)

    [answered] = events_of(sid, "code-1", :question_answered)
    assert answered.data.text == "linux, macos"
    assert user_state(pid).answer == nil
  end

  # An option list is a shortcut, not a cage: the reader may always type instead.
  test "a free-text answer still works when options are offered" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [
        {:tool, "ask_user", %{"question" => "Which database?", "options" => ["postgres"]}},
        {:finish, "ok"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, _session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "ask me")
    await_state("code-1", :needs_input)

    press(pid, "1")
    # A letter starts free text; from then on digits are ordinary characters.
    type(pid, "mysql8")
    assert user_state(pid).win_text == "mysql8"
    press(pid, "enter")
    await_state("code-1", :done_unread)

    [answered] = events_of(sid, "code-1", :question_answered)
    assert answered.data.text == "mysql8"
  end

  test "a modified Enter or Ctrl-J inserts a newline; a multiline window input sends whole" do
    ws = tmp_workspace()
    scripts = %{"code-1" => [{:tool, "ask_user", %{"question" => "Tell me?"}}, {:finish, "ok"}]}
    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)

    # Command line: every newline key inserts one, and the marker appears.
    press(pid, "enter", ["shift"])
    press(pid, "enter", ["alt"])
    press(pid, "j", ["ctrl"])
    press(pid, "w")
    assert user_state(pid).cmd_text == "\n\n\nw"
    assert user_state(pid).focus == :command
    assert screen_text(pid, session) =~ "pasted 1 line"
    press(pid, "esc")

    # Window input: type, split with alt-enter, marker shows, Enter sends the whole text.
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "ask me something")
    await_state("code-1", :needs_input)
    press(pid, "1")
    type(pid, "answer")
    press(pid, "enter", ["alt"])
    type(pid, "two")
    press(pid, "j", ["ctrl"])
    type(pid, "three")
    assert user_state(pid).win_text == "answer\ntwo\nthree"
    assert screen_text(pid, session) =~ "pasted 3 lines"

    press(pid, "enter")
    await_state("code-1", :done_unread)
    [answered] = events_of(sid, "code-1", :question_answered)
    assert answered.data.text == "answer\ntwo\nthree"
  end

  # A delegated subagent runs on a share of its parent's budget, so it is the agent
  # that hits the budget question first. The side panel used to have no clause for
  # it and raised inside render/2, which the renderer turns into a dropped frame —
  # the screen froze on stale content while the app kept eating keys — and y/n/a
  # only matched approvals, so nothing could answer it either.
  test "a subagent's budget question renders in the pane and side panel, and n answers it" do
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [
        {:tool, "delegate", %{"agent" => "explore", "prompt" => "look"}},
        {:finish, "done"}
      ],
      "code-1/explore-1" => [
        {:tool, "list_files", %{"path" => "."}},
        {:finish, "looked"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", %{prompt: "go", budget: %{max_turns: 1}})
    await_event("code-1/explore-1", :budget_ask_started, 15_000)

    eventually(fn -> user_state(pid).model.windows["code-1"].pending != [] end)

    assert [%{kind: :budget, agent_path: "code-1/explore-1"}] =
             user_state(pid).model.windows["code-1"].pending

    press(pid, "1")
    text = screen_text(pid, session)
    assert text =~ "[code-1/explore-1] BUDGET EXHAUSTED"
    assert text =~ "budget exhausted (y / n / a)", "the side panel renders instead of raising"
    assert text =~ "y/n/a"

    # ←→ views the subagent, so its request is the one y/n/a answers.
    press(pid, "right")
    assert user_state(pid).pane.agent == "code-1/explore-1"
    press(pid, "n")

    answered = await_event("code-1/explore-1", :budget_ask_answered, 15_000)
    assert answered.data.decision == :deny
    assert user_state(pid).win_text == "", "n answered the question instead of being typed"

    # The root spent the same budget, so it asks in its turn; n rests the branch.
    await_event("code-1", :budget_ask_started, 15_000)
    eventually(fn -> Enum.any?(user_state(pid).model.windows["code-1"].pending) end)
    press(pid, "left")
    press(pid, "n")
    await_state("code-1", :done_unread, 15_000)
  end

  # `y` and `a` on a budget question used to resume the turn without logging
  # `branch_state`, and `budget_ask_answered` only clears the pending item — so the
  # window kept blinking "waiting for you" with nothing outstanding. A subagent made
  # it permanent: its `finished` carries no `branch_state` either, so nothing after
  # it ever cleared the flag.
  test "allowing a subagent's budget question stops the window needing input" do
    ws =
      tmp_workspace(%{
        # Its own definition caps the turns, so the child runs out of budget while the
        # root has plenty and never asks a question of its own.
        ".troupe/agents/tiny.md" => """
        ---
        description: One turn and out.
        mode: subagent
        tools: [list_files, finish]
        max_turns: 1
        ---
        You look once.
        """
      })

    scripts = %{
      "code-1" => [
        {:tool, "delegate", %{"agent" => "tiny", "prompt" => "look"}},
        {:finish, "done"}
      ],
      "code-1/tiny-1" => [
        {:tool, "list_files", %{"path" => "."}},
        {:finish, "looked"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, _session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "go")
    await_event("code-1/tiny-1", :budget_ask_started, 15_000)

    eventually(fn -> user_state(pid).model.windows["code-1"].state == :needs_input end, 15_000)

    press(pid, "1")
    press(pid, "right")
    assert user_state(pid).pane.agent == "code-1/tiny-1"
    press(pid, "y")

    answered = await_event("code-1/tiny-1", :budget_ask_answered, 15_000)
    assert answered.data.decision == :allow

    eventually(fn -> user_state(pid).model.windows["code-1"].pending == [] end, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state != :needs_input end, 15_000)

    # The ledger reads the same log, so it has to be told too — and the window
    # derives `:running` from an empty `pending` before the agent gets to log it,
    # so this waits for the event rather than for the frame that cleared the flag.
    eventually(
      fn ->
        match?(
          %{data: %{state: :running}},
          sid |> events_of("code-1/tiny-1", :branch_state) |> List.last()
        )
      end,
      15_000
    )

    await_state("code-1", :done_unread, 15_000)
  end

  # A request whose agent is gone can never be answered: Approvals drops its entry
  # when the pid dies without logging anything, so the item stayed in `pending`
  # forever and the `pending != []` guard then blocked every later `:running`.
  test "a request left behind by a dead subagent does not pin the window" do
    events =
      [
        {"code-1", :branch_spawned, %{name: "code", isolation: :shared}},
        {"code-1", :delegation_started, %{child_path: "code-1/general-1", agent: "general"}},
        {"code-1/general-1", :question_asked, %{call_id: "q1", question: "Which directory?"}},
        {"code-1/general-1", :branch_state, %{state: :needs_input}}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{path, type, data}, seq} ->
        %Troupe.Event{
          session_id: "S",
          seq: seq,
          ts: seq,
          agent_path: path,
          type: type,
          data: data
        }
      end)

    waiting = Model.rebuild("S", "/ws", events)
    assert [%{call_id: "q1"}] = waiting.windows["code-1"].pending
    assert waiting.windows["code-1"].state == :needs_input

    for ending <- [
          {"code-1", :delegation_completed, %{child_path: "code-1/general-1", ok: false}},
          {"code-1/general-1", :cancelled, %{}}
        ] do
      {path, type, data} = ending

      settled =
        Model.apply(waiting, %Troupe.Event{
          session_id: "S",
          seq: 5,
          ts: 5,
          agent_path: path,
          type: type,
          data: data
        })

      assert settled.windows["code-1"].pending == [], inspect(type)
      assert settled.windows["code-1"].state == :running, inspect(type)
    end
  end

  # `branch_state` is window-scoped but each agent emits it from its own calls, so
  # the root answering used to flip the window back to running while a subagent was
  # still waiting: no badge, no attention count, and Enter no longer went there.
  test "the window keeps needing input while a subagent waits, after the root is answered" do
    ws = tmp_workspace()

    scripts = %{
      # Both in one turn, so the root and its subagent wait on the user at once.
      "code-1" => [
        {:tools,
         [
           {"delegate", %{"agent" => "general", "prompt" => "look"}},
           {"ask_user", %{"question" => "Which database?"}}
         ]},
        {:finish, "done"}
      ],
      "code-1/general-1" => [
        {:tool, "ask_user", %{"question" => "Which directory?"}},
        {:finish, "looked"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)

    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "go")

    eventually(fn -> length(user_state(pid).model.windows["code-1"].pending) == 2 end, 15_000)

    # Answer the root's question; the subagent's is still outstanding.
    press(pid, "1")
    type(pid, "postgres")
    press(pid, "enter")

    eventually(fn -> length(user_state(pid).model.windows["code-1"].pending) == 1 end, 15_000)
    assert user_state(pid).model.windows["code-1"].state == :needs_input
    assert screen_text(pid, session) =~ "[code-1/general-1] QUESTION: Which directory?"

    # Now answer the subagent's; only then does the window stop needing input.
    press(pid, "right")
    type(pid, "lib")
    press(pid, "enter")

    eventually(fn -> user_state(pid).model.windows["code-1"].pending == [] end, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state != :needs_input end, 15_000)

    assert [%{data: %{text: "postgres"}}] = events_of(sid, "code-1", :question_answered)
    assert [%{data: %{text: "lib"}}] = events_of(sid, "code-1/general-1", :question_answered)
  end
end
