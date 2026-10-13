defmodule Troupe.Tools.DelegateContractTest do
  @moduledoc """
  A delegation has a contract both ways (#554, Decision 847): a brief in five parts, refused
  before any child starts when one is missing, and a `finish` in parts, with what changed
  filled in by Troupe and the full diff only when `read_branch` is asked for it.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.Writes
  alias Troupe.LLM.Message
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{Delegate, Finish, ReadBranch}

  @brief %{
    "goal" => "Say where the retry logic lives.",
    "context" => "It was moved out of lib/client.ex last week.",
    "constraints" => "Read only.",
    "deliverable" => "The file and the function, with line numbers.",
    "do_not" => "Do not suggest changes."
  }

  describe "the brief" do
    test "a brief with no goal is refused, naming it, and no child starts", context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "explore", "task" => "find the retry logic"}}]},
              {:text, "root done"}
            ],
            "explore" => [{:tools, [{"finish", finished("lib/retry.ex")}]}]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate it")
      await_event(session.id, "turn_ended", 20_000)

      assert events_of_type(session.id, "delegation_started") == []

      [refused] =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.filter(&(&1.data["name"] == "delegate"))

      refute refused.data["ok"]
      assert refused.data["content"] =~ "goal"
      # The old single field is named as gone, so a model retries in parts.
      assert refused.data["content"] =~ "`task` field is gone"
    end

    test "the refusal names every missing part and nothing else" do
      args = Map.delete(@brief, "deliverable")
      assert {:error, sentence} = Delegate.brief(args)
      assert sentence =~ "the brief has no deliverable."
      refute sentence =~ "task"

      assert {:error, sentence} = Delegate.brief(Map.drop(@brief, ["goal", "do_not"]))
      assert sentence =~ "the brief has no goal and do_not."

      # A blank part is a missing one.
      assert {:error, sentence} = Delegate.brief(Map.put(@brief, "constraints", "  \n"))
      assert sentence =~ "no constraints."
    end

    test "a list of lines is a part, one line each" do
      assert {:ok, brief} = Delegate.brief(Map.put(@brief, "context", ["lib/a.ex", "lib/b.ex"]))
      assert brief["context"] == "- lib/a.ex\n- lib/b.ex"
    end

    test "the child's first message is the parts under their names", context do
      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", Map.put(@brief, "agent", "explore")}]},
              {:text, "root done"}
            ],
            "explore" => [{:tools, [{"finish", finished("lib/retry.ex:12, Retry.run/2")}]}]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate it")
      await_event(session.id, "turn_ended", 20_000)

      [request | _] = Fake.requests_for(fake, "explore")
      first = request.messages |> List.first() |> Message.text()

      assert first == """
             Goal: Say where the retry logic lives.

             Context: It was moved out of lib/client.ex last week.

             Constraints: Read only.

             Deliverable: The file and the function, with line numbers.

             Do not: Do not suggest changes.\
             """

      [started] = events_of_type(session.id, "delegation_started")
      assert started.data["brief"] == @brief
      assert started.data["task"] == first
    end
  end

  describe "the finish" do
    test "one missing a part is refused, naming it, and the child sends it again whole",
         context do
      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", Map.put(@brief, "agent", "general")}]},
              {:text, "root done"}
            ],
            "general" => [
              {:tools, [{"finish", %{"summary" => "lib/retry.ex"}}]},
              {:tools, [{"finish", finished("lib/retry.ex", %{"unverified" => "the tests"})}]}
            ]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate it")
      await_event(session.id, "turn_ended", 20_000)

      [refused, accepted] =
        session.id
        |> events_of_type("tool_call_completed")
        |> Enum.filter(&(&1.data["name"] == "finish"))

      refute refused.data["ok"]
      assert refused.data["content"] =~ "it has no ran, passed, unverified and needs."
      assert accepted.data["ok"]

      result = delegate_result(session.id)
      assert result.data["ok"]

      assert result.data["content"] == """
             lib/retry.ex

             changed: nothing
             ran: none
             passed: none
             unverified: the tests
             needs: none\
             """
    end

    test "says what its file tools changed as a stat and where to read the diff, never the diff",
         context do
      write_file(context, "lib/a.ex", "one\ntwo\nthree\n")

      %{session: session} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", Map.put(@brief, "agent", "general")}]},
              {:text, "root done"}
            ],
            "general" => [
              {:tools,
               [
                 {"edit_file",
                  %{
                    "path" => "lib/a.ex",
                    "old_string" => "one\ntwo\n",
                    "new_string" => "one\n2\n"
                  }},
                 {"write_file", %{"path" => "lib/b.ex", "content" => "new\nfile\n"}}
               ]},
              {:tools, [{"shell", %{"command" => "echo ok"}}]},
              {:tools,
               [
                 {"finish",
                  finished("two is 2 now, and lib/b.ex is new", %{
                    "ran" => "echo ok",
                    "passed" => "echo printed ok",
                    "changed" => "nothing else"
                  })}
               ]}
            ]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "delegate it")
      await_event(session.id, "turn_ended", 20_000)

      [started] = events_of_type(session.id, "delegation_started")
      child = Enum.join(started.data["child_path"], "/")
      content = delegate_result(session.id).data["content"]

      assert content == """
             two is 2 now, and lib/b.ex is new

             changed: 2 files, +3 -1; the full diff: read_branch(child: "#{child}", diff: true)
               lib/a.ex +1 -1
               lib/b.ex +2 -0 (written whole)
               not counted: what its 1 command changed
               it says: nothing else
             ran: echo ok
             passed: echo printed ok
             unverified: none
             needs: none\
             """

      refute content =~ "+new"
      refute content =~ "-two"

      [done] = Enum.filter(events_of_type(session.id, "agent_done"), &(&1.agent != ["root"]))
      assert done.data["summary"] == content
      report = done.data["report"]
      assert report["unverified"] == "none"

      assert %{
               "files" => [
                 %{"path" => "lib/a.ex", "added" => 1, "removed" => 1},
                 %{"path" => "lib/b.ex", "added" => 2, "removed" => 0, "whole" => true}
               ],
               "commands" => 1,
               "said" => "nothing else"
             } = report["changed"]

      # The diff is read only when it is asked for.
      ctx = ctx(session, context)
      assert {:ok, read} = ReadBranch.run(%{"child" => child}, ctx)
      assert read =~ "Goal: Say where the retry logic lives."
      assert read =~ "two is 2 now"
      refute read =~ "\ndiff:\n"
      refute read =~ "-two"

      assert {:ok, read} = ReadBranch.run(%{"child" => child, "diff" => true}, ctx)

      assert read =~ """
             diff:
             2 files, +3 -1, from its write_file and edit_file calls in the order they ran. \
             What its 1 command changed is not in it.

             --- lib/a.ex
             +++ lib/a.ex
             @@ edit_file @@
              one
             -two
             +2

             --- lib/b.ex
             +++ lib/b.ex
             @@ write_file: the whole file as written @@
             +new
             +file\
             """

      # Its last part alone names a child of the reader's own.
      assert {:ok, ^read} =
               ReadBranch.run(
                 %{"child" => List.last(started.data["child_path"]), "diff" => true},
                 ctx
               )
    end

    test "a child that has not finished, or is not there, is said to be so", context do
      %{session: session} = start_session(context, steps: [])
      ctx = ctx(session, context)

      assert {:error, message} = ReadBranch.run(%{"child" => "explore#9"}, ctx)
      assert message =~ ~s(no subagent "explore#9")
      assert message =~ "no subagents"
    end

    test "a branch's diff is its whole tree's, and only when asked", context do
      %{session: parent} = start_session(context, steps: [])

      %{session: branch} =
        start_session(context,
          parent: parent.id,
          steps: [
            {:tools, [{"write_file", %{"path" => "notes.md", "content" => "a\n"}}]},
            {:tools, [{"finish", finished("wrote notes.md")}]}
          ]
        )

      :ok = Troupe.subscribe(branch.id)
      Troupe.send_input(branch.id, "write the notes")
      assert_receive {:troupe_event, _, %Event{type: "agent_done", agent: ["root"]}}, 20_000

      ctx = ctx(parent, context)
      assert {:ok, text} = ReadBranch.run(%{"session_id" => branch.id}, ctx)
      assert text =~ ~s[read_branch(session_id: "#{branch.id}", diff: true)]
      refute text =~ "+a"

      assert {:ok, text} = ReadBranch.run(%{"session_id" => branch.id, "diff" => true}, ctx)
      assert text =~ "--- notes.md\n+++ notes.md\n@@ write_file: the whole file as written @@\n+a"
    end
  end

  describe "rendering" do
    test "a part of several lines goes under its name" do
      assert Finish.labelled({"ran", "mix test\nmix credo"}) == "ran:\nmix test\nmix credo"
      assert Finish.labelled({"ran", "mix test"}) == "ran: mix test"
    end

    test "a summary alone, as a finish from before the parts gave, is the report" do
      assert Finish.replayed(%{"summary" => "old"}) == %{"summary" => "old"}
      assert Finish.render(%{"summary" => "old"}) == "old"
    end

    test "a stat names twenty files and counts the rest" do
      events =
        Enum.flat_map(1..22, fn n ->
          id = "c#{n}"

          [
            %Event{
              type: "tool_call_started",
              agent: ["root", "general#1"],
              data: %{
                "call_id" => id,
                "name" => "write_file",
                "args" => %{"path" => "f#{n}", "content" => "x"}
              }
            },
            %Event{
              type: "tool_call_completed",
              agent: ["root", "general#1"],
              data: %{"call_id" => id, "ok" => true}
            }
          ]
        end)

      described = events |> Writes.changed(["root", "general#1"], "s") |> Writes.describe()
      assert described =~ "22 files, +22 -0"
      assert described =~ "f20 +1 -0"
      refute described =~ "f21 +1"
      assert described =~ "and 2 more"
    end

    # D125: a command whose approval was refused never ran, so it changed nothing and is
    # not one whose changes went uncounted.
    test "a refused command is not counted as one that ran" do
      agent = ["root", "general#1"]

      call = fn id ->
        [
          %Event{
            type: "tool_call_started",
            agent: agent,
            data: %{"call_id" => id, "name" => "shell", "args" => %{"command" => "rm -rf x"}}
          },
          %Event{
            type: "approval_requested",
            agent: agent,
            data: %{"call_id" => id, "tool" => "shell"}
          }
        ]
      end

      refused =
        call.("c1") ++
          [
            %Event{
              type: "approval_decided",
              agent: agent,
              data: %{"call_id" => "c1", "tool" => "shell", "decision" => "deny"}
            },
            %Event{
              type: "tool_call_completed",
              agent: agent,
              data: %{"call_id" => "c1", "ok" => false}
            }
          ]

      assert {[], 0} = Writes.of(refused, agent)
      described = refused |> Writes.changed(agent, "s") |> Writes.describe()
      assert described == "nothing"

      allowed =
        call.("c2") ++
          [
            %Event{
              type: "approval_decided",
              agent: agent,
              data: %{"call_id" => "c2", "tool" => "shell", "decision" => "allow"}
            },
            %Event{
              type: "tool_call_completed",
              agent: agent,
              data: %{"call_id" => "c2", "ok" => true}
            }
          ]

      assert {[], 1} = Writes.of(refused ++ allowed, agent)
      assert Writes.describe(Writes.changed(refused ++ allowed, agent, "s")) =~
               "what its 1 command changed"
    end
  end

  defp delegate_result(session_id) do
    session_id
    |> events_of_type("tool_call_completed")
    |> Enum.find(&(&1.data["name"] == "delegate"))
  end

  defp ctx(session, context) do
    %Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    }
  end
end
