defmodule Troupe.DelegationGateTest do
  @moduledoc """
  A delegation a person asked to see first, in the TUI's approval box (root Decision 850,
  TUI Decision 157): the agent, its definition, the tools, the budget, the depth and the
  brief's five parts, and the five answers: `y` runs it, `e` edits a part in the box, `s`
  sends it to another subagent, `n` denies it with a word back, `a` lets that agent run
  unasked for the session. Driven against the daemon this VM embeds, as a person would.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.UI.TUI.Model

  @asks %{"delegation" => %{"ask" => ["general"]}}

  defp brief(goal) do
    %{
      "agent" => "general",
      "goal" => goal,
      "context" => "none",
      "constraints" => "none",
      "deliverable" => "a summary",
      "do_not" => "none"
    }
  end

  defp gated(scripts) do
    ws = tmp_workspace()
    {sid, _, _} = start_session!(workspace: ws, config: @asks, scripts: scripts)
    {pid, session} = start_tui(sid)

    type(pid, "delegate it")
    press(pid, "enter")
    await_event("build-1", :approval_requested, 10_000)
    press(pid, "1")
    eventually(fn -> screen_text(pid, session) =~ "DELEGATE to general" end)
    {sid, pid, session}
  end

  # The child's first message is its brief, the parts under their names.
  defp child_brief(sid) do
    eventually(fn -> child_inputs(sid) != [] end, 10_000)
    sid |> child_inputs() |> hd()
  end

  defp child_inputs(sid) do
    for %{type: :input, agent_path: "build-1/" <> _, data: data} <- Client.events(sid),
        do: to_string(data[:text] || data[:content] || "")
  end

  test "the box shows the whole delegation; e edits constraints in place, then y runs it" do
    {sid, pid, session} =
      gated(%{
        "root" => [
          {:tools, [{"delegate", brief("Write notes.md")}]},
          {:text_and_tools, "root done", []}
        ],
        "general" => [{:finish, "wrote it"}]
      })

    text = screen_text(pid, session)
    assert text =~ "Goal: Write notes.md"
    assert text =~ "Constraints: none"
    assert text =~ "depth 1 of 3"
    assert text =~ "/agents general opens its definition: builtin"
    assert text =~ "write_file ask"

    press(pid, "e")
    eventually(fn -> screen_text(pid, session) =~ "edit which part?" end)
    press(pid, "3")
    eventually(fn -> screen_text(pid, session) =~ "editing Constraints" end)

    # The part is in the box as it stands, to be changed there.
    for _ <- 1..4, do: press(pid, "backspace")
    type(pid, "notes.md only")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "Constraints (edited): notes.md only" end)

    press(pid, "y")
    await_event("build-1", :approval_answered, 10_000)
    assert child_brief(sid) =~ "Constraints: notes.md only"
    await_state("build-1", :idle, 10_000)
  end

  test "a: the second delegation is let through for the session, and the third does not ask" do
    {sid, pid, session} =
      gated(%{
        "root" => [
          {:tools, [{"delegate", brief("one")}]},
          {:tools, [{"delegate", brief("two")}]},
          {:tools, [{"delegate", brief("three")}]},
          {:text_and_tools, "root done", []}
        ],
        "general" => [{:finish, "one done"}, {:finish, "two done"}, {:finish, "three done"}]
      })

    press(pid, "y")
    await_event("build-1", :approval_requested, 10_000)
    eventually(fn -> screen_text(pid, session) =~ "Goal: two" end)
    press(pid, "a")
    await_state("build-1", :idle, 20_000)

    assert length(events_of(sid, "build-1", :approval_requested)) == 2
    eventually(fn -> length(child_inputs(sid)) == 3 end, 10_000)
  end

  test "n asks for a word back and sends it with the denial; s sends the brief elsewhere" do
    {sid, pid, session} =
      gated(%{
        "root" => [
          {:tools, [{"delegate", brief("Look first")}]},
          {:tools, [{"delegate", brief("Then write")}]},
          {:text_and_tools, "root done", []}
        ],
        "explore" => [{:finish, "looked"}]
      })

    press(pid, "n")
    eventually(fn -> screen_text(pid, session) =~ "deny: type a word back" end)
    type(pid, "ask explore first")
    press(pid, "enter")
    await_event("build-1", :approval_answered, 10_000)

    # The next delegation goes to explore instead.
    await_event("build-1", :approval_requested, 10_000)
    eventually(fn -> screen_text(pid, session) =~ "Goal: Then write" end)
    press(pid, "s")
    eventually(fn -> screen_text(pid, session) =~ "a digit sends the brief there" end)
    agents = screen_text(pid, session)
    assert agents =~ "explore"

    n =
      ~r/(\d)\. explore/
      |> Regex.run(agents, capture: :all_but_first)
      |> hd()

    press(pid, n)
    eventually(fn -> screen_text(pid, session) =~ "DELEGATE to explore (switched from general)" end)
    press(pid, "y")
    await_state("build-1", :idle, 20_000)

    denied =
      for %{type: :tool_call_completed, agent_path: "build-1", data: data} <- Client.events(sid),
          inspect(data) =~ "ask explore first",
          do: data

    assert denied != []
    assert child_brief(sid) =~ "Goal: Then write"
  end

  # Headless mode has nobody to ask: it denies the gate as any request, and its lines say
  # why it asked and that --auto-approve would not have answered it.
  test "headless denies a delegation that asks first, and says what made it ask" do
    ws = tmp_workspace()

    {sid, _, _} =
      start_session!(
        workspace: ws,
        config: @asks,
        scripts: %{
          "root" => [
            {:tools, [{"delegate", brief("Write notes.md")}]},
            {:text_and_tools, "It was not mine to send.", []}
          ]
        }
      )

    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, _pid} =
      Troupe.UI.Headless.Printer.start_link(
        session_id: sid,
        target: "root",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    say!(sid, "delegate it")
    assert_receive {:rest, 3}, 15_000
    {_, out} = StringIO.contents(io)
    assert out =~ "delegation to general asks first (delegation.ask"
    assert out =~ "--auto-approve does not answer it"
    assert out =~ "The person denied this delegation to general."
    assert out =~ "exit 3: an approval was refused, with nobody to ask: delegations that ask first"
  end

  describe "the box itself" do
    @item %{
      kind: :approval,
      call_id: "c1",
      agent_path: "root",
      name: "delegate",
      preview: nil,
      delegation: %{
        "agent" => "general",
        "definition" => %{"name" => "general", "layer" => "builtin", "path" => "/agents/general.md"},
        "brief" => %{
          "goal" => "g",
          "context" => "c\nmore",
          "constraints" => "k",
          "deliverable" => "d",
          "do_not" => "n"
        },
        "tools" => [
          %{"name" => "read_file", "permission" => "auto"},
          %{"name" => "shell", "permission" => "ask"}
        ],
        "budget_share" => 0.5,
        "depth" => 1,
        "max_depth" => 3,
        "agents" => [
          %{"name" => "explore", "description" => "reads"},
          %{"name" => "general", "description" => "edits"}
        ]
      }
    }

    test "the answer carries the switch and the edits, and nothing when there are none" do
      fresh = Model.gate_draft(nil, @item)
      assert Model.gate_answer(fresh, @item) == %{}

      draft = %{fresh | agent: "explore", edits: %{"constraints" => "read only"}}

      assert Model.gate_answer(draft, @item) == %{
               "agent" => "explore",
               "brief" => %{"constraints" => "read only"}
             }

      assert Model.gate_part(draft, @item, "constraints") == "read only"
      assert Model.gate_part(draft, @item, "goal") == "g"

      # A draft for another call is a fresh one.
      assert Model.gate_draft(draft, %{@item | call_id: "c2"}).edits == %{}
    end
  end
end
