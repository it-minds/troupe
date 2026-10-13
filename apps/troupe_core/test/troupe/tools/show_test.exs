defmodule Troupe.Tools.ShowTest do
  @moduledoc """
  The session's scratchpad (issue #472, Decision 870): `show` writes a named document a
  person reads beside the chat, replaces it under the same name, and logs each write as
  `scratch_updated`; the listing is a fold over the log; the documents are the session's
  own, beside its log, so an erasure takes them and the checkout never holds them.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Bench.LiveScenarios
  alias Troupe.{Paths, Scratch}
  alias Troupe.Tools.Show

  @plan "# Migration plan\n\n1. Copy the table.\n2. Switch the reads.\n"

  describe "the tool" do
    test "is offered on every call of an agent with every tool and of plan, on any model",
         context do
      for {agent, model} <- [
            {"build", "fake-model"},
            {"build", "claude-sonnet-5-5"},
            {"plan", "fake-model"}
          ] do
        %{session: session, fake: fake} =
          start(context,
            agent: agent,
            steps: [
              {:tools, [{"list_files", %{"path" => "."}}]},
              {:text, "listed"},
              {:text, "again"}
            ],
            config_overrides: [model: model]
          )

        turn(session, "look")
        turn(session, "and again")

        offered =
          Enum.map(Fake.requests(fake), fn request ->
            "show" in Enum.map(request.tools, & &1.name)
          end)

        assert offered == [true, true, true], "#{agent} on #{model}: #{inspect(offered)}"

        Troupe.stop_session(session.id)
      end
    end

    # A document the person asks for, or an answer past about 80 lines; every other answer
    # goes in the reply (issue #616).
    test "its words, build's and plan's say when: a document asked for, or a long answer",
         context do
      assert Show.description() =~ "only when they ask for one"
      assert Show.description() =~ "about 80 lines"
      assert Show.description() =~ "otherwise answer in the reply"

      for agent <- ["build", "plan"] do
        %{session: session, fake: fake} = start(context, agent: agent, steps: [{:text, "hi"}])
        turn(session, "hello")
        [request] = Fake.requests(fake)
        assert prompt_text(request) =~ ~r/asks? for a document/, agent
        assert prompt_text(request) =~ "about 80 lines", agent
        assert prompt_text(request) =~ "`patch` revises it", agent
        Troupe.stop_session(session.id)
      end
    end

    test "writes the document, logs it, and the same name again replaces it", context do
      %{session: session} =
        start(context,
          steps: [
            {:tools, [{"show", show_args("plan.md", "Migration plan", "first draft")}]},
            {:tools, [{"show", show_args("Plan.md", "Migration plan", @plan)}]},
            {:text, "The plan is in plan.md."}
          ]
        )

      turn(session, "write a migration plan")

      assert [first, second] = events_of_type(session.id, :scratch_updated)
      assert first.data["version"] == 1
      assert second.data["version"] == 2
      assert second.data["name"] == "plan.md"
      assert second.data["path"] == "scratch:/plan.md"
      assert second.data["kind"] == "markdown"
      assert second.data["title"] == "Migration plan"
      assert second.data["size"] == byte_size(@plan)
      assert second.data["hash"] == Scratch.hash(@plan)
      assert is_binary(second.data["call_id"])

      # The words are in the call, as any answer's are, and never in the event.
      refute Map.has_key?(second.data, "content")

      # Beside the log, not in the checkout.
      assert File.read!(Path.join(session_dir(context, session.id), "scratch/plan.md")) == @plan
      refute File.exists?(Path.join(context.workspace, "scratch"))

      assert [%{name: "plan.md", version: 2, size: size, hash: hash, updated_at: at}] =
               Scratch.list(session.id)

      assert size == byte_size(@plan)
      assert hash == Scratch.hash(@plan)
      assert is_binary(at)

      assert [completed | _] =
               session.id
               |> events_of_type(:tool_call_completed)
               |> Enum.filter(&(&1.data["name"] == "show"))

      assert completed.data["ok"]
      assert completed.data["content"] =~ "scratch:/plan.md"
    end

    test "lists the documents in the order each was first shown, the latest of each", context do
      %{session: session} =
        start(context,
          steps: [
            {:tools, [{"show", show_args("plan.md", "Plan", "one")}]},
            {:tools, [{"show", show_args("table.csv", "Table", "a,b\n1,2\n", "csv")}]},
            {:tools, [{"show", show_args("plan.md", "Plan, revised", "two")}]},
            {:text, "done"}
          ]
        )

      turn(session, "go")

      assert [
               %{name: "plan.md", title: "Plan, revised", version: 2},
               %{name: "table.csv", kind: "csv", version: 1}
             ] =
               Scratch.list(session.id)
    end

    test "refuses a path, .., a control character and an unknown kind, writing nothing",
         context do
      %{session: session} = start(context)
      ctx = ctx(session)

      for {name, words} <- [
            {"notes/plan.md", "not a path"},
            {"..\\plan.md", "not a path"},
            {"..plan.md", "\"..\""},
            {"plan\n.md", "control character"},
            {"", "at most 64"},
            {"nul.md", "device"}
          ] do
        assert {:error, message} = Show.run(show_args(name, "Plan", "x"), ctx)
        assert message =~ words, "#{inspect(name)}: #{message}"
      end

      assert {:error, message} = Show.run(show_args("page.html", "Page", "<p>", "html"), ctx)
      assert message =~ "markdown, mermaid, json, csv or text"

      assert events_of_type(session.id, :scratch_updated) == []
      refute File.exists?(Path.join(session_dir(context, session.id), "scratch/page.html"))
    end

    test "refuses past either cap with a sentence that says what to do", context do
      %{session: session} =
        start(context,
          config_overrides: [scratch_max_bytes: 10, scratch_max_documents: 1],
          steps: [
            {:tools, [{"show", show_args("plan.md", "Plan", "eleven byte")}]},
            {:tools, [{"show", show_args("plan.md", "Plan", "ten bytes!")}]},
            {:tools, [{"show", show_args("other.md", "Other", "x")}]},
            # Replacing the one it holds is not a second document.
            {:tools, [{"show", show_args("plan.md", "Plan", "again")}]},
            {:text, "done"}
          ]
        )

      turn(session, "go")

      assert [too_long, ok, too_many, replaced] =
               session.id
               |> events_of_type(:tool_call_completed)
               |> Enum.filter(&(&1.data["name"] == "show"))

      refute too_long.data["ok"]
      assert too_long.data["content"] =~ "scratch_max_bytes"
      assert too_long.data["content"] =~ "shorter"
      assert ok.data["ok"]
      refute too_many.data["ok"]
      assert too_many.data["content"] =~ "scratch_max_documents"
      assert too_many.data["content"] =~ "under its name"
      assert replaced.data["ok"]

      assert [%{name: "plan.md", version: 2}] = Scratch.list(session.id)
    end
  end

  describe "the session's rules" do
    test "a dormant session still lists its documents, and erasing it takes them", context do
      %{session: session} =
        start(context,
          steps: [{:tools, [{"show", show_args("plan.md", "Plan", @plan)}]}, {:text, "done"}]
        )

      turn(session, "go")
      dir = Path.join(session_dir(context, session.id), "scratch")
      assert File.exists?(Path.join(dir, "plan.md"))

      :ok = Troupe.stop_session(session.id)
      assert [%{name: "plan.md", version: 1}] = Scratch.list(session.id)
      assert Scratch.dir(session.id) == dir

      :ok = Troupe.erase_session(session.id)
      refute File.exists?(dir)
    end

    test "a private session's documents are its own directory's, as its log is", context do
      %{session: session} =
        start(context,
          kind: :private,
          steps: [{:tools, [{"show", show_args("plan.md", "Plan", @plan)}]}, {:text, "done"}]
        )

      turn(session, "go")

      # On this device, beside the log the sealer seals, and nowhere a worker or the
      # checkout would see it; the one event it adds holds no word of it.
      assert Scratch.dir(session.id) == Path.join(session_dir(context, session.id), "scratch")
      refute File.exists?(Path.join(context.workspace, "scratch"))
      assert [event] = events_of_type(session.id, :scratch_updated)
      assert Map.keys(event.data) -- ~w(name path kind title size hash version call_id) == []

      :ok = Troupe.erase_session(session.id)
      refute File.exists?(Path.join(session_dir(context, session.id), "scratch"))
    end

    test "a fork carries the documents its history shows", context do
      %{session: session} =
        start(context,
          steps: [{:tools, [{"show", show_args("plan.md", "Plan", @plan)}]}, {:text, "done"}]
        )

      turn(session, "go")

      {:ok, fork} =
        Troupe.fork_session(session.id,
          config_overrides: [provider: "fake", state_dir: context.state_dir]
        )

      on_exit(fn -> Troupe.stop_session(fork.id) end)

      assert [%{name: "plan.md", hash: hash}] = Scratch.list(fork.id)
      assert Scratch.hash(File.read!(Path.join(Scratch.dir(fork.id), "plan.md"))) == hash
    end
  end

  describe "the live bench" do
    test "runs the plan without the scratchpad on build as it was, show denied and unnamed",
         context do
      assert {:ok, [%{name: "scratchpad"}, %{name: "scratchpad_without"}]} =
               LiveScenarios.select(nil, ~w(scratchpad scratchpad_without))

      write_file(context, ".troupe/agents/build.md", LiveScenarios.build_without_show())
      %{session: session, fake: fake} = start(context, steps: [{:text, "a plan"}])
      turn(session, "plan it")

      assert [request] = Fake.requests(fake)
      refute "show" in Enum.map(request.tools, & &1.name)
      refute "patch" in Enum.map(request.tools, & &1.name)
      assert prompt_text(request) =~ "Answer the user in plain prose"
      refute prompt_text(request) =~ "`show`"
      refute prompt_text(request) =~ "`patch`"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp show_args(name, title, content, kind \\ nil) do
    %{"name" => name, "title" => title, "content" => content}
    |> then(fn args -> if kind, do: Map.put(args, "kind", kind), else: args end)
  end

  defp start(context, opts \\ []) do
    %{session: session} = started = start_session(context, opts)
    Troupe.subscribe(session.id)
    started
  end

  defp turn(session, text) do
    Troupe.send_input(session.id, text)
    await_event(session.id, :turn_ended, 10_000)
  end

  # A call made straight to the tool, as the agent makes one.
  defp ctx(session) do
    %Troupe.Tool.Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: session.workspace,
      call_id: "call-#{System.unique_integer([:positive])}",
      agent_pid: self(),
      config: %Troupe.Config{}
    }
  end

  defp session_dir(context, session_id) do
    Paths.session_dir(
      Troupe.Workspace.new!(context.workspace).root_real,
      session_id,
      context.state_dir
    )
  end
end
