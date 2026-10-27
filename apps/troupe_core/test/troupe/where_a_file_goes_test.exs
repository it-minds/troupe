defmodule Troupe.WhereAFileGoesTest do
  @moduledoc """
  Where a file the person asks for goes (issue #765): the harness's own word, first in the
  root's instructions and listed as `harness` in `instructions_loaded`, names the order (where
  the organisation keeps files, else an artifact, else the workspace) and what is open in this
  session; a tool that stores files is one its server's config marks, never one guessed from
  its name; and a file written with `deliverable: true` is said with `file_ready`.

  The model is the fake, so what it does is scripted: each branch shows the prompt saying
  what is open, and the scripted call to the way it names going through, the event with it.

  `async: false`: these install the host's functions (`Troupe.Artifacts`,
  `Troupe.LocalOnly`) and the pod's MCP tools in the application environment.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Instructions.Harness
  alias Troupe.Session.Questions

  setup do
    on_exit(fn ->
      Troupe.Artifacts.uninstall()
      Application.delete_env(:troupe_core, :local_only)
      Application.delete_env(:troupe_core, :remote_tools)
    end)
  end

  # A pod's MCP tool, as discovery builds one from a server marked `stores: files` (or not).
  defp remote_tool(server, tool, files?) do
    test = self()

    %Troupe.MCP.Tool{
      name: "mcp.#{server}.#{tool}",
      remote_name: tool,
      server: server,
      description: "Upload a document.\n\nProvided by the #{server} MCP server.",
      schema: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}},
      default_permission: :auto,
      files: files?,
      run: fn args, _ctx ->
        send(test, {:called, "mcp.#{server}.#{tool}", args})
        {:ok, "stored"}
      end
    }
  end

  defp published(params),
    do: %{"id" => "art-abcdefghijklmnop", "version" => 1, "title" => params["title"], "url" => "https://artifacts.example.test/a/x/"}

  defp harness_of(session_id) do
    [event | _] = events_of_type(session_id, :instructions_loaded)
    hd(event.data["files"])
  end

  defp run(context, steps, input) do
    %{session: session, fake: fake} = start_session(context, steps: steps)
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, input)
    await_event(session.id, :agent_done, 10_000)
    %{session: session, prompt: prompt_text(hd(Fake.requests(fake)))}
  end

  test "a tool that stores files is named first, and the agent's call to it goes through", context do
    Application.put_env(:troupe_core, :remote_tools, [
      remote_tool("docs", "upload", true),
      remote_tool("tracker", "upload", false)
    ])

    %{session: session, prompt: prompt} =
      run(
        context,
        [
          {:tools, [{"mcp.docs.upload", %{"name" => "q3.md"}}]},
          {:text_and_tools, "Stored.", [{"finish", finished("stored")}]}
        ],
        "write the Q3 report"
      )

    assert prompt =~ Harness.paragraph()
    assert prompt =~ "- where the organisation keeps files: `mcp.docs.upload`\n"
    # Nothing is read from a tool's name: the tracker's upload is not where files are kept.
    refute prompt =~ "`mcp.tracker.upload`"
    assert prompt =~ "- an artifact: not from here, no plane publishes one"
    assert_received {:called, "mcp.docs.upload", %{"name" => "q3.md"}}

    assert %{
             "scope" => "harness",
             "path" => "harness",
             "status" => "whole",
             "open" => %{
               "file_tools" => ["mcp.docs.upload"],
               "artifact" => %{"state" => "none"},
               "where" => "local"
             }
           } = harness_of(session.id)

    assert events_of_type(session.id, :question_asked) == []
  end

  test "with no such tool and the person signed in, the artifact is the way open", context do
    Troupe.Artifacts.install(fn params, _ctx -> {:ok, published(params)} end, ready: fn _ -> true end)
    File.write!(Path.join(context.workspace, "report.md"), "# Q3\n")

    %{session: session, prompt: prompt} =
      run(
        context,
        [
          {:tools,
           [
             {"publish_artifact",
              %{"title" => "Q3", "kind" => "markdown", "visibility" => "organisation", "files" => ["report.md"]}}
           ]},
          {:text_and_tools, "Published.", [{"finish", finished("published")}]}
        ],
        "publish the Q3 report"
      )

    assert prompt =~ "- where the organisation keeps files: no tool here does that"
    assert prompt =~ "- an artifact: `publish_artifact`"

    assert Enum.any?(events_of_type(session.id, :tool_call_completed), fn e ->
             e.data["name"] == "publish_artifact" and e.data["artifact"]["id"] == "art-abcdefghijklmnop"
           end)
  end

  test "signed out, the artifact is said to be closed and why", context do
    Troupe.Artifacts.install(fn _params, _ctx -> {:error, :signed_out} end, ready: fn _ -> false end)
    %{prompt: prompt} = run(context, [{:text_and_tools, "Done.", [{"finish", finished("done")}]}], "hi")
    assert prompt =~ "- an artifact: not from here, the person is not signed in to a plane here"
  end

  test "under Local only, the workspace is the way, and a deliverable is said with file_ready",
       context do
    Troupe.Artifacts.install(fn _params, _ctx -> flunk("nothing is published") end, ready: fn _ -> true end)
    Troupe.LocalOnly.install(fn _session -> true end)

    %{session: session, prompt: prompt} =
      run(
        context,
        [
          {:tools,
           [{"write_file", %{"path" => "out/report.md", "content" => "# Q3\n", "deliverable" => true}}]},
          {:text_and_tools, "It is in out/report.md.", [{"finish", finished("written")}]}
        ],
        "write the Q3 report"
      )

    assert prompt =~ "- an artifact: not from here, this session is under Local only"

    assert %{"state" => "closed", "why" => "this session is under Local only"} =
             harness_of(session.id)["open"]["artifact"]

    assert prompt =~
             "- the workspace, always: this session runs on the person's machine, so the file is already there"

    assert [%{agent: ["root"], data: data}] = events_of_type(session.id, :file_ready)
    assert data["path"] == "out/report.md"
    assert data["size"] == 5
    assert data["hash"] == "sha256:" <> Base.encode16(:crypto.hash(:sha256, "# Q3\n"), case: :lower)
    assert data["local_path"] == Path.join([Path.expand(context.workspace), "out", "report.md"])
  end

  test "a file written without deliverable is no file_ready", context do
    %{session: session} =
      run(
        context,
        [
          {:tools, [{"write_file", %{"path" => "notes.md", "content" => "x"}}]},
          {:text_and_tools, "Done.", [{"finish", finished("done")}]}
        ],
        "take a note"
      )

    assert events_of_type(session.id, :file_ready) == []
  end

  test "the person naming the way decides it: no question", context do
    Troupe.Artifacts.install(fn params, _ctx -> {:ok, published(params)} end, ready: fn _ -> true end)
    Application.put_env(:troupe_core, :remote_tools, [remote_tool("sharepoint", "upload", true)])

    %{session: session, prompt: prompt} =
      run(
        context,
        [
          {:tools, [{"mcp.sharepoint.upload", %{"name" => "q3.docx"}}]},
          {:text_and_tools, "Saved to SharePoint.", [{"finish", finished("saved")}]}
        ],
        "write the Q3 report and save it to SharePoint"
      )

    assert prompt =~ "What the person says, or an instruction after this one, decides outright."
    assert_received {:called, "mcp.sharepoint.upload", _}
    assert events_of_type(session.id, :question_asked) == []
  end

  test "with two ways open and none named, one question names them, and the answer is the way",
       context do
    Troupe.Artifacts.install(fn params, _ctx -> {:ok, published(params)} end, ready: fn _ -> true end)
    Application.put_env(:troupe_core, :remote_tools, [remote_tool("docs", "upload", true)])

    %{session: session, fake: fake} =
      start_session(context,
        steps: [
          {:tools,
           [
             {"ask_user",
              %{
                "question" => "Where should the report go?",
                "options" => [%{"label" => "Your documents (mcp.docs.upload)"}, %{"label" => "An artifact"}]
              }}
           ]},
          {:tools, [{"mcp.docs.upload", %{"name" => "q3.md"}}]},
          {:text_and_tools, "Stored.", [{"finish", finished("stored")}]}
        ]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "write the Q3 report")
    asked = await_event(session.id, :question_asked, 10_000)
    Questions.answer(session.id, asked.data["call_id"], "Your documents (mcp.docs.upload)")
    await_event(session.id, :agent_done, 10_000)

    prompt = prompt_text(hd(Fake.requests(fake)))
    assert prompt =~ "- where the organisation keeps files: `mcp.docs.upload`"
    assert prompt =~ "- an artifact: `publish_artifact`"
    assert prompt =~ "ask one question with `ask_user`, the open ways as its options in this order"

    assert [%{data: %{"options" => [_, _]}}] = events_of_type(session.id, :question_asked)
    assert_received {:called, "mcp.docs.upload", _}
  end

  test "on a pod the workspace line says the client saves it, and the paragraph stays short" do
    open = %{file_tools: [], artifact: :none, where: :pod}

    assert Harness.text(open) =~
             "- the workspace, always: this session runs on a server, and their client saves the file from there"

    assert Harness.paragraph() |> String.split() |> length() <= 120
  end

  # A stdio server answers `initialize` a moment after the session starts, so on the first
  # turn its tools are not offered yet: the line says it is starting rather than that no
  # tool stores files, and the turn is not held up for it.
  test "a store's server still starting is said to be, and the turn does not wait for it", context do
    # As `config.yaml`'s `mcp:` reads `stores: files`: a server that never answers
    # `initialize`, so it is starting for the whole turn.
    server = %{
      command: "sleep",
      args: ["30"],
      env: %{},
      cd: nil,
      url: nil,
      permission: :ask,
      timeout_ms: 30_000,
      stores: :files
    }

    %{session: session, fake: fake} =
      start_session(context,
        config_overrides: [mcp: %{"docs" => server}],
        steps: [{:text_and_tools, "Done.", [{"finish", finished("done")}]}]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "write the Q3 report")
    await_event(session.id, :agent_done, 10_000)

    assert prompt_text(hd(Fake.requests(fake))) =~
             "- where the organisation keeps files: not yet; the docs server is starting, its tools join at the next turn"

    assert %{"starting" => ["docs"], "file_tools" => []} = harness_of(session.id)["open"]

    assert Harness.text(%{file_tools: ["mcp.a.save"], starting: ["b", "c"], artifact: :none, where: :local}) =~
             "`mcp.a.save`; the b, c servers are still starting"
  end

  test "a person's offered tool marked files, and a held one, store files; nothing else does" do
    offered = %{name: "client.wiki.save", files: true}
    held = %Troupe.Agent.Hold.Tool{name: "mcp.docs.save", description: "", schema: %{}, files: true}
    plain = %{name: "client.wiki.search", files: false}

    assert Harness.file_tools([offered, plain, Troupe.Tools.WriteFile, held]) ==
             ["client.wiki.save", "mcp.docs.save"]
  end
end
