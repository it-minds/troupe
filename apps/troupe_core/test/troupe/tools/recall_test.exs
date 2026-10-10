defmodule Troupe.Tools.RecallTest do
  @moduledoc """
  The `recall` tool (Decision 838): the repository's facts a prompt does not carry, asked
  for by words, kind or path, each with its status and where it came from; and the brief's
  line naming it, which an agent without the tool is not shown.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Memory.Facts
  alias Troupe.Tools.Recall

  test "recall answers matching facts with their status and evidence", context do
    ws = context.workspace
    File.write!(Path.join(ws, "mix.exs"), "defmodule M do\nend\n")

    {:ok, gate} =
      Facts.put(
        ws,
        %{kind: "command", claim: "`mix check` is the gate.", anchors: ["mix.exs"]},
        %{
          session: "s-1",
          seq: 12,
          by: "librarian",
          exit_status: 0
        }
      )

    {:ok, _} =
      Facts.put(ws, %{kind: "layout", claim: "lib/ holds the code\nand nothing else"}, %{})

    File.write!(Path.join(ws, "mix.exs"), "defmodule M do\n  # changed\nend\n")

    assert {:ok, text} = Recall.run(%{"query" => "gate"}, ctx(context))
    assert text =~ "1 fact matches, of 2 kept:"

    assert text =~
             "- [command, may no longer be true: a file it rests on changed since] `mix check` is the gate.\n" <>
               "  rests on mix.exs; checked #{Date.utc_today()} by librarian (session s-1, seq 12, exit 0); " <>
               "id #{gate["id"]}"

    assert {:ok, layout} = Recall.run(%{"kind" => "layout"}, ctx(context))
    assert layout =~ "- [layout, unanchored] lib/ holds the code\n  and nothing else\n  checked "

    assert {:ok, "No fact matches. 2 facts are kept." <> _} =
             Recall.run(%{"query" => "zebra"}, ctx(context))

    assert {:error, "unknown kind todo" <> _} = Recall.run(%{"kind" => "todo"}, ctx(context))
  end

  test "recall with nothing kept, and with the brief off", context do
    assert {:ok, "Nothing is kept about this repository yet." <> _} =
             Recall.run(%{}, ctx(context))

    off = %{ctx(context) | config: %Troupe.Config{memory: false}}
    assert {:ok, "The project brief is off in this workspace" <> _} = Recall.run(%{}, off)
  end

  test "the brief names recall to an agent that has it, and not to one that does not", context do
    ws = context.workspace
    {:ok, _} = Facts.put(ws, %{kind: "command", claim: "`make` builds it."}, %{})
    {:ok, _} = Facts.put(ws, %{kind: "overview", claim: "A sample project."}, %{})

    write_file(context, ".troupe/agents/narrow.md", """
    ---
    description: Reads, and nothing else.
    mode: primary
    tools:
      - read_file
      - finish
    ---
    You read.
    """)

    line = "1 more fact about this repository (1 overview) is kept out of this prompt"

    for {agent, named?} <- [{"build", true}, {"plan", true}, {"narrow", false}] do
      %{session: session, fake: fake} =
        start_session(context, agent: agent, steps: [{:text, "ok"}])

      :ok = Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "hello")
      await_event(session.id, :turn_ended)

      request = fake |> Fake.requests() |> List.first()
      assert request.system =~ "- `make` builds it.", agent
      assert request.system =~ line == named?, agent
      assert Enum.any?(request.tools, &(&1.name == "recall")) == named?, agent
    end
  end

  defp ctx(context) do
    %Troupe.Tool.Ctx{
      session_id: "s-1",
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    }
  end
end
