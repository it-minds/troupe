Code.require_file("../../support/fake_openai.exs", __DIR__)

defmodule Troupe.Agent.ScratchCompactionTest do
  @moduledoc """
  A compaction stops sending old scratchpad documents again (issue #616, Decision 878).

  Until a compaction, a `show` call's document stays in the conversation as the call's
  arguments, so the prefix never changes (Decisions 863, 867 and 870). A compaction changes
  it anyway: what it keeps, and what its summariser reads, has a pointer in each shown
  document's place, naming the document, its title, version and size, and the
  `read_file` call that reads it back from the scratchpad, where it stays.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Bench.Prefix
  alias Troupe.LLM.{Message, Text, ToolResult, ToolUse}
  alias Troupe.{Scratch, Tools}
  alias Troupe.Test.FakeOpenAI
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{Grep, ReadFile, WriteFile}

  @plan """
  # Migration plan

  1. Copy the notes table to PostgreSQL in batches of a thousand rows.
  2. Switch the reads to PostgreSQL behind a flag.
  3. Drop the SQLite file once a week has passed without a fallback.
  """

  @revised @plan <> "4. Count the rows on both sides before the switch.\n"

  @overflow {:error, {:http_status, 400, "prompt is too long: 250000 tokens > 200000 maximum"}}

  # Two short turns, then the plan, then a turn the provider refuses as too long: the
  # compaction keeps the plan's call in its tail.
  defp shown_then_overflow do
    [
      {:text, "first answer"},
      {:text, "second answer"},
      show("plan.md", "Migration plan", @plan),
      {:text, "The plan is in plan.md."},
      @overflow,
      {:text, "summary of the first turns"},
      {:text, "carried on"}
    ]
  end

  defp shown_then_compacted(context, opts \\ []) do
    %{session: session, fake: fake} =
      start_session(context, Keyword.put(opts, :steps, shown_then_overflow()))

    Troupe.subscribe(session.id)
    Enum.each(["first", "second", "write the plan", "carry on"], &turn(session.id, &1))

    assert [%{data: %{"reason" => "context_overflow"}}] = events_of_type(session.id, "compacted")
    %{session: session, fake: fake}
  end

  describe "what a compaction keeps" do
    test "has a pointer in place of a shown document, which stays on the scratchpad", context do
      %{session: session, fake: fake} = shown_then_compacted(context)
      [_, _, _, _, overflowed, _summariser, after_compaction] = Fake.requests(fake)

      # Until the compaction the document went whole, as the call's arguments.
      assert call_in(overflowed, "show").input["content"] == @plan

      pointer = call_in(after_compaction, "show").input["content"]
      assert pointer =~ "plan.md"
      assert pointer =~ ~s("Migration plan")
      assert pointer =~ "version 1"
      assert pointer =~ "#{byte_size(@plan)} bytes"
      assert pointer =~ ~s|read_file(path: "scratch:/plan.md")|
      refute Enum.any?(texts(after_compaction), &(&1 =~ "Switch the reads"))

      # The `compacted` event keeps what memory keeps, so a replay rebuilds the same.
      [compacted] = events_of_type(session.id, "compacted")

      assert [%{"input" => %{"content" => ^pointer, "name" => "plan.md"}}] =
               for(
                 %{"content" => blocks} <- compacted.data["conversation"],
                 %{"type" => "tool_use", "name" => "show"} = block <- blocks,
                 do: block
               )

      # The document is where it was.
      assert [%{name: "plan.md", version: 1, size: size}] = Scratch.list(session.id)
      assert size == byte_size(@plan)
      assert File.read!(Path.join(Scratch.dir(session.id), "plan.md")) == @plan
    end

    test "has the summariser read the pointer, not the document", context do
      steps = [
        show("plan.md", "Migration plan", @plan),
        {:text, "The plan is in plan.md."},
        {:text, "two"},
        {:text, "three"},
        @overflow,
        {:text, "summary: the plan is plan.md on the scratchpad"},
        {:text, "carried on"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(["write the plan", "two", "three", "carry on"], &turn(session.id, &1))

      assert [_] = events_of_type(session.id, "compacted")
      summariser = fake |> Fake.requests() |> Enum.find(&(&1.system =~ "compress a coding"))
      read = Enum.map_join(summariser.messages, "\n", &Message.text/1)

      assert read =~ "[called show "
      assert read =~ ~s|read_file(path: \\"scratch:/plan.md\\")|
      assert read =~ "version 1"
      refute read =~ "Switch the reads"

      # Whatever the summary kept of it, the document is named after it.
      [summary | _] = fake |> Fake.requests() |> List.last() |> Map.fetch!(:messages)
      assert Message.text(summary) =~ "summary: the plan is plan.md on the scratchpad"

      assert Message.text(summary) =~
               ~s|On this session's scratchpad, each read with read_file(path: "scratch:/<name>") | <>
                 ~s|and revised with patch:\n| <>
                 ~s|- plan.md ("Migration plan", version 1, #{byte_size(@plan)} bytes)|
    end

    test "has a pointer for each version a tail holds, and the read gives the latest", context do
      steps = [
        {:text, "first answer"},
        show("plan.md", "Migration plan", @plan),
        show("Plan.md", "Migration plan, revised", @revised),
        {:text, "The plan is in plan.md."},
        @overflow,
        {:text, "summary of the first turn"},
        {:text, "carried on"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(["first", "write and revise the plan", "carry on"], &turn(session.id, &1))

      assert [_] = events_of_type(session.id, "compacted")
      after_compaction = fake |> Fake.requests() |> List.last()

      assert [first, second] =
               for(
                 %ToolUse{name: "show"} = call <- blocks(after_compaction),
                 do: call.input["content"]
               )

      assert first =~ ~s|plan.md ("Migration plan", version 1, #{byte_size(@plan)} bytes)|

      assert second =~
               ~s|plan.md ("Migration plan, revised", version 2, #{byte_size(@revised)} bytes)|

      read_back(fake, session.id)
      assert [%ToolResult{error?: false, content: read}] = last_results(fake)
      assert read =~ "6\t4. Count the rows on both sides before the switch."
    end

    # A revision is a patch, which carries the change: a long one, a part of a document
    # written in parts, is left out as a show's words are; a short one is shorter than its
    # pointer and stays as it was.
    test "has a pointer for a long patch, and keeps a short one whole", context do
      rest = Enum.map_join(4..12, "", &"#{&1}. Count the rows of table #{&1} on both sides.\n")
      short = %{"name" => "plan.md", "old_string" => "3. Drop", "new_string" => "3. Remove"}

      steps = [
        {:text, "first answer"},
        show("plan.md", "Migration plan", @plan),
        {:tools, [{"patch", %{"name" => "plan.md", "new_string" => rest}}]},
        {:tools, [{"patch", short}]},
        {:text, "The plan is in plan.md."},
        @overflow,
        {:text, "summary of the first turn"},
        {:text, "carried on"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(["first", "write the plan in parts", "carry on"], &turn(session.id, &1))

      assert [_] = events_of_type(session.id, "compacted")
      after_compaction = fake |> Fake.requests() |> List.last()

      assert [long, ^short] =
               for(%ToolUse{name: "patch"} = call <- blocks(after_compaction), do: call.input)

      written = @plan <> rest

      assert long["new_string"] =~
               ~s|plan.md (version 2, #{byte_size(written)} bytes) left out since a compaction|

      assert long["new_string"] =~ ~s|read_file(path: "scratch:/plan.md")|
      refute Map.has_key?(long, "old_string")
      refute Enum.any?(texts(after_compaction), &(&1 =~ "Count the rows of table 7"))

      assert File.read!(Path.join(Scratch.dir(session.id), "plan.md")) ==
               String.replace(written, "3. Drop", "3. Remove")

      assert [%{name: "plan.md", version: 3}] = Scratch.list(session.id)
    end

    # As Decision 771 keeps whole a result the model has not answered: a call it sees changed
    # before it has read the result, it makes again.
    test "keeps a show call the model has not replied after until the next compaction", context do
      steps = [
        {:text, "one"},
        {:text, "two"},
        {:text, "three"},
        show("plan.md", "Migration plan", @plan),
        @overflow,
        {:text, "summary one"},
        {:text, "The plan is in plan.md."},
        @overflow,
        {:text, "summary two"},
        {:text, "carried on"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(~w(one two three) ++ ["write the plan", "carry on"], &turn(session.id, &1))

      assert [_, _] = events_of_type(session.id, "compacted")
      requests = Fake.requests(fake)
      assert length(requests) == 10
      [resent, _overflowed, _summariser, after_second] = Enum.drop(requests, 6)

      # The compaction in the middle of the turn came after the call, before its answer.
      assert call_in(resent, "show").input["content"] == @plan

      assert call_in(after_second, "show").input["content"] =~
               ~s|read_file(path: "scratch:/plan.md")|
    end

    test "leaves a refused show call as it was: there is nothing on the scratchpad", context do
      refused = %{"name" => "plan.md", "title" => "Plan", "kind" => "html", "content" => @plan}

      steps = [
        {:text, "first answer"},
        {:text, "second answer"},
        {:tools, [{"show", refused}]},
        {:text, "It could not be shown."},
        @overflow,
        {:text, "summary of the first turns"},
        {:text, "carried on"}
      ]

      %{session: session, fake: fake} = start_session(context, steps: steps)
      Troupe.subscribe(session.id)
      Enum.each(["first", "second", "write the plan", "carry on"], &turn(session.id, &1))

      assert [_] = events_of_type(session.id, "compacted")
      after_compaction = fake |> Fake.requests() |> List.last()
      assert call_in(after_compaction, "show").input["content"] == @plan
      assert Scratch.list(session.id) == []

      # An empty scratchpad is not listed.
      refute after_compaction.messages |> hd() |> Message.text() =~ "scratchpad"
    end

    # A pointer the agent cannot follow is a document lost.
    test "keeps the document where the agent has no read_file", context do
      {:ok, shower} =
        Definition.parse(
          "shower",
          "---\nmode: primary\ntools: [show, todo_read]\n---\nShow.",
          :project
        )

      definitions =
        Definitions.from_list(Definitions.all(Definitions.load(System.tmp_dir!())) ++ [shower])

      %{fake: fake} = shown_then_compacted(context, agent: "shower", definitions: definitions)
      after_compaction = fake |> Fake.requests() |> List.last()
      assert call_in(after_compaction, "show").input["content"] == @plan
      refute after_compaction.messages |> hd() |> Message.text() =~ "read_file"
    end
  end

  describe "the prefix" do
    test "changes at the compaction and nowhere else, a restart included", context do
      %{session: session, fake: fake} = shown_then_compacted(context)
      turn(session.id, "and then")
      restart(session.id)
      turn(session.id, "after a restart")

      requests = Fake.requests(fake)
      {before, [_overflowed, summariser | since]} = Enum.split(requests, 4)
      assert summariser.system =~ "compress a coding"

      # Each call before the compaction began with the one before it, the document whole;
      # each after it begins with the one before, the pointer in the document's place.
      for calls <- [before, since], [one, next] <- Enum.chunk_every(calls, 2, 1, :discard) do
        assert Enum.take(next.messages, length(one.messages)) == one.messages
      end

      assert Enum.all?(since, &(call_in(&1, "show").input["content"] =~ "scratch:/plan.md"))
    end
  end

  # Decision 867: on a model that binds its thinking, the tail a compaction keeps goes
  # without the blocks made in front of what the summary replaced. Against the stand-in as
  # Claude Sonnet 5.5, asked for the refusal an enforced account gets.
  describe "on a model that binds its thinking" do
    test "the tail goes with the pointer and without its thinking, and nothing is refused",
         context do
      # Long enough that the call after it crosses the threshold; the stand-in counts four
      # bytes a token, and the first call's prompt is about 4,000.
      long = @plan <> String.duplicate("A line of the plan that takes up room.\n", 200)

      # The step is the number of answers the conversation has: two from the first turns,
      # then the plan, a read, and the answer. The compaction keeps three answers, so the
      # read is asked again after it, never the plan.
      steps = [
        {:text, "first answer"},
        {:text, "second answer"},
        {:tools,
         [{"show", %{"name" => "plan.md", "title" => "Migration plan", "content" => long}}]},
        {:tools, [{"read_file", %{"path" => "notes.txt"}}]},
        {:text, "The plan is in plan.md."}
      ]

      write_file(context, "notes.txt", "a note\n")

      stand_in =
        FakeOpenAI.start(scripts: [{"write the plan", steps}], first_token_ms: 0, done_ms: 0)

      on_exit(fn -> FakeOpenAI.stop(stand_in) end)

      overrides = [
        provider: "anthropic",
        base_url: stand_in.url,
        api_key: "test-key",
        model: "claude-sonnet-5-5",
        thinking_binding: "error",
        context_window: 6_000,
        compact_at: 0.85
      ]

      %{session: session} = start_session(context, config_overrides: overrides)
      sid = session.id
      Troupe.subscribe(sid)
      Enum.each(["first", "second", "write the plan"], &bound_turn(sid, &1))

      assert [compacted] = events_of_type(sid, "compacted")
      kept = compacted.data["conversation"]

      refute Enum.any?(kept, fn message ->
               Enum.any?(message["content"], &(&1["type"] == "reasoning"))
             end)

      assert [pointer] =
               for(
                 %{"content" => blocks} <- kept,
                 %{"type" => "tool_use", "name" => "show"} = block <- blocks,
                 do: block["input"]["content"]
               )

      assert pointer =~ ~s|read_file(path: "scratch:/plan.md")|

      requests = FakeOpenAI.requests(stand_in)
      refused = Enum.filter(requests, &(&1.status != 200))
      assert refused == [], "refused: #{inspect(Enum.map(refused, & &1.mismatch))}"
      assert %{"thinking_resent" => 0} = Prefix.count(Troupe.events(sid))
    end
  end

  describe "reading a document back" do
    test "read_file reads scratch:/<name> after a compaction left it out", context do
      %{session: session, fake: fake} = shown_then_compacted(context)
      read_back(fake, session.id)

      assert [%ToolResult{error?: false, content: read}] = last_results(fake)
      assert read =~ "1\t# Migration plan"
      assert read =~ "4\t2. Switch the reads to PostgreSQL behind a flag."
    end

    test "read_file refuses a name the scratchpad does not have, and a path out of it", context do
      %{session: session} = start_session(context)

      for path <- ["scratch:/report.md", "scratch:/../events.jsonl", "scratch:/"] do
        assert {:error, why} = ReadFile.run(%{"path" => path}, ctx(session))
        assert why =~ "#{path} is not a document on this session's scratchpad"
      end
    end

    test "another file tool given a scratchpad path says read_file reads it", context do
      %{session: session} = start_session(context)

      for {tool, args} <- [
            {Grep, %{"pattern" => "step", "path" => "scratch:/plan.md"}},
            {WriteFile, %{"path" => "scratch:/plan.md", "content" => "x"}}
          ] do
        assert %{ok?: false, content: said} = Tools.execute(tool, args, ctx(session))
        assert said =~ ~s|Read it with read_file(path: "scratch:/plan.md")|
      end
    end
  end

  # The agent reads the plan back: the model's next call, after a turn's input.
  defp read_back(fake, session_id) do
    Fake.push(fake, [
      {:tools, [{"read_file", %{"path" => "scratch:/plan.md"}}]},
      {:text, "Read it back."}
    ])

    turn(session_id, "what does the plan say now?")
  end

  defp show(name, title, content),
    do: {:tools, [{"show", %{"name" => name, "title" => title, "content" => content}}]}

  defp turn(session_id, text) do
    Troupe.send_input(session_id, text)
    await_state(session_id, [:idle], 10_000)
  end

  defp bound_turn(session_id, text) do
    Troupe.send_input(session_id, text)
    await_event(session_id, :turn_ended, 15_000)
  end

  defp restart(session_id) do
    agent = Registry.agent_pid(session_id, ["root"])
    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 2_000
    await_event(session_id, :agent_restarted)
    await_state(session_id, [:idle])
  end

  defp ctx(session) do
    %Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: session.workspace,
      call_id: "call-#{System.unique_integer([:positive])}",
      agent_pid: self(),
      config: %Troupe.Config{}
    }
  end

  # The results of the last request's last message: what the model was last handed.
  defp last_results(fake) do
    %Message{content: blocks} =
      fake |> Fake.requests() |> List.last() |> Map.fetch!(:messages) |> List.last()

    blocks
  end

  defp blocks(request), do: Enum.flat_map(request.messages, & &1.content)

  defp call_in(request, name), do: Enum.find(blocks(request), &match?(%ToolUse{name: ^name}, &1))

  # Every text a request carries: its texts, its results and its calls' arguments.
  defp texts(request) do
    Enum.flat_map(blocks(request), fn
      %ToolResult{content: text} -> [text]
      %Text{text: text} -> [text]
      %ToolUse{input: input} -> [Jason.encode!(input)]
      _other -> []
    end)
  end
end
