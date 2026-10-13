defmodule Troupe.Tools.PatchTest do
  @moduledoc """
  A scratchpad document revised in place (issue #616): `patch` replaces an exact span of a
  document `show` put on the scratchpad, or adds to its end, so a revision sends the change
  and not the whole document again, and a document too long for one reply is written in
  parts. Offered wherever `show` is, on every call.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.LLM.{Message, ToolResult, ToolUse}
  alias Troupe.{Scratch, Tools}
  alias Troupe.Tools.{EditFile, Grep, Patch}

  @plan Enum.map_join(1..40, "", &"#{&1}. Step #{&1} of the migration, said at some length.\n")

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
            "patch" in Enum.map(request.tools, & &1.name)
          end)

        assert offered == [true, true, true], "#{agent} on #{model}: #{inspect(offered)}"

        Troupe.stop_session(session.id)
      end
    end

    test "replaces an exact span in place, a new version under the same name", context do
      %{session: session} =
        start(context,
          steps: [
            show("plan.md", "Migration plan", @plan, "markdown"),
            patch("Plan.md", "3. Step 3 of", "3. Step 3, in batches of a thousand rows, of"),
            {:text, "plan.md is revised."}
          ]
        )

      turn(session, "write the plan, then revise step 3")

      assert [first, second] = events_of_type(session.id, :scratch_updated)
      assert {first.data["version"], second.data["version"]} == {1, 2}

      revised =
        String.replace(@plan, "3. Step 3 of", "3. Step 3, in batches of a thousand rows, of")

      assert File.read!(Path.join(Scratch.dir(session.id), "plan.md")) == revised

      # The title and kind are the document's; the call is the patch's.
      assert second.data["title"] == "Migration plan"
      assert second.data["kind"] == "markdown"
      assert second.data["size"] == byte_size(revised)
      assert second.data["hash"] == Scratch.hash(revised)
      [patched] = completed(session.id, "patch")
      assert second.data["call_id"] == patched.data["call_id"]
      assert patched.data["content"] =~ "scratch:/plan.md"
      assert patched.data["content"] =~ "version 2"

      assert [%{name: "plan.md", version: 2}] = Scratch.list(session.id)
    end

    test "with no old_string adds to the end, on a line of its own", context do
      %{session: session} =
        start(context,
          steps: [
            show("plan.md", "Plan", "1. Copy."),
            patch("plan.md", nil, "2. Switch."),
            patch("plan.md", nil, "\n3. Drop.\n"),
            {:text, "done"}
          ]
        )

      turn(session, "go")

      assert File.read!(Path.join(Scratch.dir(session.id), "plan.md")) ==
               "1. Copy.\n2. Switch.\n3. Drop.\n"

      assert [%{version: 3}] = Scratch.list(session.id)
    end

    # The reproduction: a revision of a document was a `show` of all of it again, its words
    # sent once more on every later call. A patch sends the change.
    test "a revision sends the change, and the document's words only once", context do
      %{session: session, fake: fake} =
        start(context,
          steps: [
            show("plan.md", "Migration plan", @plan),
            {:text, "The plan is in plan.md."},
            patch("plan.md", "40. Step 40", "40. Count the rows, then step 40"),
            {:text, "plan.md is revised."},
            {:text, "carried on"}
          ]
        )

      turn(session, "write the plan")
      turn(session, "count the rows at the end")
      turn(session, "carry on")

      assert [%{version: 2}] = Scratch.list(session.id)
      last = fake |> Fake.requests() |> List.last()

      assert Enum.count(texts(last), &(&1 =~ "Step 17 of the migration")) == 1
      [revision] = for %ToolUse{name: "patch", input: input} <- blocks(last), do: input
      assert byte_size(Jason.encode!(revision)) * 20 < byte_size(@plan)
    end

    test "refuses what it cannot do in a sentence that says what to do, writing nothing",
         context do
      %{session: session} =
        start(context, steps: [show("plan.md", "Plan", "1. Copy.\n2. Copy.\n"), {:text, "done"}])

      turn(session, "go")
      ctx = %{ctx(session) | config: %Troupe.Config{scratch_max_bytes: 2_000}}

      for {args, words} <- [
            {%{"name" => "report.md", "new_string" => "x"}, "Show it first"},
            {%{"name" => "../plan.md", "new_string" => "x"}, "not a path"},
            {%{"name" => "plan.md", "old_string" => "3. Drop.", "new_string" => "x"},
             ~s|read_file(path: "scratch:/plan.md")|},
            {%{"name" => "plan.md", "old_string" => "Copy.", "new_string" => "x"},
             "appears 2 times"},
            {%{"name" => "plan.md", "new_string" => String.duplicate("x", 2_000)},
             "scratch_max_bytes"}
          ] do
        assert {:error, message} = Patch.run(args, ctx)
        assert message =~ words, "#{inspect(args)}: #{message}"
      end

      assert [%{version: 1}] = Scratch.list(session.id)
      assert File.read!(Path.join(Scratch.dir(session.id), "plan.md")) == "1. Copy.\n2. Copy.\n"
    end
  end

  # A long document sent as one call's arguments was cut at the reply's output cap. It goes
  # in parts: `show` the start, `patch` the rest on.
  describe "a document too long for one reply" do
    test "a show cut at the output cap is told to go in parts, and patch adds them", context do
      first = Enum.map_join(1..20, "", &"#{&1}. Step #{&1} of the migration.\n")
      rest = Enum.map_join(21..40, "", &"#{&1}. Step #{&1} of the migration.\n")

      cut = %{
        "__malformed_arguments__" => ~s|{"name": "plan.md", "title": "Plan", "content": "1. St|
      }

      %{session: session, fake: fake} =
        start(context,
          steps: [
            {:stop, :max_tokens, {:tools, [{"show", cut}]}},
            show("plan.md", "Plan", first),
            patch("plan.md", nil, rest),
            {:text, "The plan is in plan.md."}
          ]
        )

      turn(session, "write the whole plan")

      [refused | _] = completed(session.id, "show")
      refute refused.data["ok"]
      assert refused.data["content"] =~ "cut off mid-argument"
      assert refused.data["content"] =~ "patch"
      assert refused.data["content"] =~ "old_string"

      assert File.read!(Path.join(Scratch.dir(session.id), "plan.md")) == first <> rest
      assert [%{version: 2}] = Scratch.list(session.id)

      # The model was told so in the result it read next.
      [_cut, after_cut | _] = Fake.requests(fake)

      assert [%ToolResult{error?: true, content: said}] =
               after_cut.messages |> List.last() |> Map.fetch!(:content)

      assert said =~ "patch"
    end
  end

  describe "the words that point at it" do
    test "build's and plan's prompts name patch beside show", context do
      for agent <- ["build", "plan"] do
        %{session: session, fake: fake} = start(context, agent: agent, steps: [{:text, "hi"}])
        turn(session, "hello")
        [request] = Fake.requests(fake)
        assert prompt_text(request) =~ "`patch`", agent
        Troupe.stop_session(session.id)
      end
    end

    test "edit_file and grep given a scratchpad path name patch and read_file", context do
      %{session: session} = start(context)

      for {tool, args} <- [
            {EditFile, %{"path" => "scratch:/plan.md", "old_string" => "a", "new_string" => "b"}},
            {Grep, %{"pattern" => "step", "path" => "scratch:/plan.md"}}
          ] do
        assert %{ok?: false, content: said} = Tools.execute(tool, args, ctx(session))
        assert said =~ ~s|Read it with read_file(path: "scratch:/plan.md")|
        assert said =~ ~s|patch(name: "plan.md"|
        refute said =~ "edit_file"
      end
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp show(name, title, content, kind \\ nil) do
    args = %{"name" => name, "title" => title, "content" => content}
    {:tools, [{"show", if(kind, do: Map.put(args, "kind", kind), else: args)}]}
  end

  defp patch(name, old, new) do
    args = %{"name" => name, "new_string" => new}
    {:tools, [{"patch", if(old, do: Map.put(args, "old_string", old), else: args)}]}
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

  defp completed(session_id, name) do
    session_id
    |> events_of_type(:tool_call_completed)
    |> Enum.filter(&(&1.data["name"] == name))
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

  defp blocks(request), do: Enum.flat_map(request.messages, & &1.content)

  # Every text a request carries: its texts, its results and its calls' arguments.
  defp texts(request) do
    Enum.flat_map(blocks(request), fn
      %ToolResult{content: text} -> [text]
      %ToolUse{input: input} -> [Jason.encode!(input)]
      block -> [Message.text(%Message{role: :user, content: [block]})]
    end)
  end
end
