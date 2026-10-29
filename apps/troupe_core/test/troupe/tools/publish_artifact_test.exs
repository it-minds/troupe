defmodule Troupe.Tools.PublishArtifactTest do
  @moduledoc """
  `publish_artifact` (#62): a page, a document or a file from the workspace published on the
  plane for the session's person, through whatever the host installed (`Troupe.Artifacts`);
  confined to the workspace; offered only where there is somewhere for it to go; refused,
  naming the file, where the person is signed out; asked about by default; and on the call's
  own event, what it published.

  Whom it is for is the person's to say: a call that names no `visibility` asks whatever
  `auto_approve` says, with the publication for the gate to show, and runs for the audience
  and owner the person answers; an allow that names nobody is refused and the request waits
  on. `async: false`, as it installs the host's function in the application environment.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Session.{Approvals, Log}
  alias Troupe.Tools.PublishArtifact

  setup do
    on_exit(&Troupe.Artifacts.uninstall/0)
    :ok
  end

  defp published(params) do
    %{
      "id" => params["id"] || "art-abcdefghijklmnop",
      "version" => if(params["id"], do: 2, else: 1),
      "title" => params["title"],
      "kind" => params["kind"],
      "visibility" => params["visibility"],
      "url" => "https://artifacts.example.test/a/art-abcdefghijklmnop/"
    }
  end

  test "sends the files with their paths below the directory they share, read as they are now",
       context do
    test = self()

    Troupe.Artifacts.install(fn params, ctx ->
      send(test, {:published, params, ctx.session_id})
      {:ok, published(params)}
    end)

    File.mkdir_p!(Path.join(context.workspace, "out/report/assets"))
    File.write!(Path.join(context.workspace, "out/report/index.html"), "<h1>Weekly</h1>")
    File.write!(Path.join(context.workspace, "out/report/assets/site.css"), "h1 {}")

    %{session: session} = start_session(context, steps: [])

    assert {:ok, said, %{fields: %{"artifact" => fields}}} =
             PublishArtifact.run(
               %{
                 "title" => "Weekly",
                 "kind" => "html",
                 "visibility" => "profile:dev",
                 "files" => ["out/report/index.html", "out/report/assets/site.css"]
               },
               ctx(session, context)
             )

    assert_received {:published, params, id} when id == session.id
    assert params["title"] == "Weekly"
    assert params["visibility"] == "profile:dev"

    assert Enum.map(params["files"], &{&1["path"], Base.decode64!(&1["bytes"])}) == [
             {"index.html", "<h1>Weekly</h1>"},
             {"assets/site.css", "h1 {}"}
           ]

    assert said =~ "version 1"
    assert said =~ "profile dev's people"
    assert said =~ "https://artifacts.example.test/a/art-abcdefghijklmnop/"
    assert fields["id"] == "art-abcdefghijklmnop"
    assert fields["url"] =~ "artifacts.example.test"
  end

  test "republishes one by its id, and a single file keeps only its name", context do
    test = self()

    Troupe.Artifacts.install(fn params, _ctx ->
      send(test, {:published, params})
      {:ok, published(params)}
    end)

    File.mkdir_p!(Path.join(context.workspace, "docs"))
    File.write!(Path.join(context.workspace, "docs/notes.md"), "# Notes")
    %{session: session} = start_session(context, steps: [])

    assert {:ok, said, _} =
             PublishArtifact.run(
               %{
                 "title" => "Notes",
                 "kind" => "markdown",
                 "visibility" => "organisation",
                 "files" => ["docs/notes.md"],
                 "id" => "art-abcdefghijklmnop",
                 "note" => "the figures for October"
               },
               ctx(session, context)
             )

    assert_received {:published,
                     %{
                       "id" => "art-abcdefghijklmnop",
                       "note" => "the figures for October",
                       "files" => [%{"path" => "notes.md"}]
                     }}

    # The tool says what `id` and `note` are for: a new version, of one's own or an edit link's.
    assert PublishArtifact.schema()["properties"]["note"]
    assert PublishArtifact.description() =~ "edit link"

    assert said =~ "version 2"
    assert said =~ "the whole organisation"
  end

  test "publishes nothing from outside the workspace, nor what is not a file", context do
    Troupe.Artifacts.install(fn _params, _ctx -> flunk("nothing should be sent") end)
    %{session: session} = start_session(context, steps: [])
    ctx = ctx(session, context)

    outside =
      Path.join(
        System.tmp_dir!(),
        "troupe-artifact-outside-#{System.unique_integer([:positive])}.html"
      )

    File.write!(outside, "secret")
    on_exit(fn -> File.rm(outside) end)

    for files <- [[outside], ["../" <> Path.basename(outside)], ["no-such.html"], ["."]] do
      assert {:error, why} =
               PublishArtifact.run(
                 %{
                   "title" => "x",
                   "kind" => "html",
                   "visibility" => "organisation",
                   "files" => files
                 },
                 ctx
               )

      assert why =~ "not published", inspect(files)
    end

    assert {:error, {:invalid_args, _}} =
             PublishArtifact.run(
               %{
                 "title" => "x",
                 "kind" => "pdf",
                 "visibility" => "organisation",
                 "files" => ["a"]
               },
               ctx
             )
  end

  test "signed out, it is refused with a sentence naming the file in the workspace", context do
    Troupe.Artifacts.install(fn _params, _ctx -> {:error, :signed_out} end)
    File.write!(Path.join(context.workspace, "report.html"), "<p>x</p>")
    %{session: session} = start_session(context, steps: [])

    assert {:error, why} =
             PublishArtifact.run(
               %{
                 "title" => "R",
                 "kind" => "html",
                 "visibility" => "organisation",
                 "files" => ["report.html"]
               },
               ctx(session, context)
             )

    assert why =~ "not signed in to a Troupe plane"
    assert why =~ "in the workspace at report.html"
  end

  test "is offered only where the host installed somewhere for it to go, and asks first",
       context do
    refute Enum.any?(Troupe.Tools.all(), &(Troupe.Tool.name(&1) == "publish_artifact"))
    Troupe.Artifacts.install(fn params, _ctx -> {:ok, published(params)} end)
    assert Enum.any?(Troupe.Tools.all(), &(Troupe.Tool.name(&1) == "publish_artifact"))
    assert PublishArtifact.default_permission() == :ask
    Troupe.Artifacts.uninstall()
    refute Enum.any?(Troupe.Tools.all(), &(Troupe.Tool.name(&1) == "publish_artifact"))
    _ = context
  end

  test "a session's agent calls it, and its event keeps what was published", context do
    Troupe.Artifacts.install(fn params, _ctx -> {:ok, published(params)} end)
    File.write!(Path.join(context.workspace, "index.html"), "<h1>Hi</h1>")

    %{session: session} =
      start_session(context,
        steps: [
          {:tools,
           [
             {"publish_artifact",
              %{
                "title" => "Hi",
                "kind" => "html",
                "visibility" => "organisation",
                "files" => ["index.html"]
              }}
           ]},
          {:text_and_tools, "Published.", [{"finish", finished("published")}]}
        ]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "publish the page")
    assert_receive {:troupe_event, _, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    # An audience the person named in the prompt is asked about as any `ask` tool's call,
    # which the session's `auto_approve` answers.
    assert events_of_type(session.id, "approval_requested") == []

    assert Enum.any?(Log.replay(session.id), fn
             %{
               type: "tool_call_completed",
               data: %{"name" => "publish_artifact", "artifact" => artifact}
             } ->
               artifact["id"] == "art-abcdefghijklmnop" and artifact["version"] == 1

             _ ->
               false
           end)
  end

  test "run with nobody asked, it says nothing of who it is for and it is the person's alone",
       context do
    test = self()

    Troupe.Artifacts.install(fn params, _ctx ->
      send(test, {:published, params})
      {:ok, published(params)}
    end)

    File.write!(Path.join(context.workspace, "notes.md"), "# Notes")
    %{session: session} = start_session(context, steps: [])
    args = %{"title" => "Notes", "kind" => "markdown", "files" => ["notes.md"]}

    # Only a call nobody was asked about reaches `run/2` without a visibility: the gate
    # lays the person's choice over one that said nothing. Such a call is the safest thing.
    assert {:ok, said, _} = PublishArtifact.run(args, ctx(session, context))
    assert_received {:published, %{"visibility" => "private"}}
    assert said =~ "the person alone"
    refute said =~ "as the person chose"

    # A new version that says nothing keeps who it was for, which the plane knows.
    assert {:ok, _, _} =
             PublishArtifact.run(
               Map.put(args, "id", "art-abcdefghijklmnop"),
               ctx(session, context)
             )

    assert_received {:published, again}
    refute Map.has_key?(again, "visibility")

    # Whose an artifact is does not change with a version: a republish sends no owner, and
    # the gate shows none to choose; a new one sends what was said.
    assert {:ok, _, _} =
             PublishArtifact.run(
               Map.merge(args, %{
                 "id" => "art-abcdefghijklmnop",
                 "owner" => "me",
                 "visibility" => "team:core"
               }),
               ctx(session, context)
             )

    assert_received {:published, republished}
    refute Map.has_key?(republished, "owner")

    assert PublishArtifact.publication(
             Map.merge(args, %{"id" => "art-abcdefghijklmnop", "owner" => "me"})
           )["owner"] == nil

    assert PublishArtifact.publication(Map.put(args, "owner", "me"))["owner"] == "me"

    assert {:ok, _, _} =
             PublishArtifact.run(
               Map.merge(args, %{"owner" => "me", "visibility" => "team:core"}),
               ctx(session, context)
             )

    assert_received {:published, %{"owner" => "me", "visibility" => "team:core"}}

    assert {:ok, said, _} =
             PublishArtifact.run(Map.put(args, "visibility", "team:core"), ctx(session, context))

    assert said =~ "team core's members"

    schema = PublishArtifact.schema()
    refute "visibility" in schema["required"]
    assert schema["properties"]["visibility"]["description"] =~ "team:<name>"
    assert schema["properties"]["owner"]["enum"] == ["me", "team"]
    assert PublishArtifact.description() =~ "leave it out and they choose at the approval"
    assert PublishArtifact.description() =~ "`owner`"
  end

  describe "whom it is for is the person's to say" do
    defp publishing(context, args, opts \\ []) do
      test = self()

      Troupe.Artifacts.install(fn params, _ctx ->
        send(test, {:published, params})
        {:ok, published(params)}
      end)

      File.write!(Path.join(context.workspace, "report.md"), "# Findings")

      start_session(
        context,
        Keyword.merge(
          [
            steps: [
              {:tools,
               [
                 {"publish_artifact",
                  Map.merge(
                    %{"title" => "Findings", "kind" => "markdown", "files" => ["report.md"]},
                    args
                  )}
               ]},
              {:text, "Done."}
            ]
          ],
          opts
        )
      )
    end

    defp asked(session) do
      :ok = Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "publish the findings")
      await_event(session.id, "approval_requested", 10_000)
    end

    defp completed(session_id) do
      await_event(session_id, "tool_call_completed", 10_000)

      session_id
      |> events_of_type("tool_call_completed")
      |> Enum.find(&(&1.data["name"] == "publish_artifact"))
    end

    test "a call naming no visibility must ask, past auto_approve, with the publication",
         context do
      refute PublishArtifact.must_ask?(%{"title" => "x", "visibility" => "organisation"})
      assert PublishArtifact.must_ask?(%{"title" => "x"})
      assert PublishArtifact.must_ask?(%{"title" => "x", "visibility" => ""})

      # `SessionCase` starts every session with `auto_approve` on; it does not answer this.
      %{session: session} =
        publishing(context, %{"id" => "art-abcdefghijklmnop", "note" => "October"})

      request = asked(session)

      assert request.data["tool"] == "publish_artifact"

      assert request.data["publication"] == %{
               "title" => "Findings",
               "kind" => "markdown",
               "files" => 1,
               "visibility" => nil,
               "owner" => nil,
               "id" => "art-abcdefghijklmnop",
               "note" => "October"
             }

      assert [%{publication: %{"visibility" => nil}}] = Approvals.pending(session.id)
      refute_received {:published, _}

      # A republish keeps its owner: one answered at the gate is dropped, not sent.
      call_id = request.data["call_id"]

      assert :ok =
               Troupe.approve(session.id, call_id, :allow, nil, %{
                 "visibility" => "team:core",
                 "owner" => "me"
               })

      result = completed(session.id)
      assert result.data["content"] =~ "for team core's members, as the person chose"

      assert_received {:published,
                       %{"visibility" => "team:core", "id" => "art-abcdefghijklmnop"} = params}

      refute Map.has_key?(params, "owner")

      assert [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["visibility"] == "team:core"
      refute Map.has_key?(decided.data, "owner")
      assert decided.data["edited"] == ["visibility"]
    end

    test "an allow naming nobody is refused and waits on; the person's audience and owner run it",
         context do
      %{session: session} = publishing(context, %{})
      call_id = asked(session).data["call_id"]

      assert {:error,
              "say whom it is for: visibility is private, organisation, team:<name> or profile:<name>"} =
               Troupe.approve(session.id, call_id, :allow)

      assert {:error, why} =
               Troupe.approve(session.id, call_id, :allow, nil, %{"visibility" => "everyone"})

      assert why =~
               "visibility is private, organisation, team:<name> or profile:<name>, not \"everyone\""

      assert {:error, why} =
               Troupe.approve(session.id, call_id, :allow, nil, %{"visibility" => "team:"})

      assert why =~ "not \"team:\""

      assert {:error, "owner is me or team, not \"them\""} =
               Troupe.approve(session.id, call_id, :allow, nil, %{
                 "visibility" => "private",
                 "owner" => "them"
               })

      assert {:error, "a publication's answer takes visibility, owner and reason, not agent"} =
               Troupe.approve(session.id, call_id, :allow, nil, %{"agent" => "explore"})

      assert {:error, "a word back goes with a denial"} =
               Troupe.approve(session.id, call_id, :allow, nil, %{
                 "visibility" => "private",
                 "reason" => "no"
               })

      assert [%{call_id: ^call_id}] = Approvals.pending(session.id)
      assert events_of_type(session.id, "approval_decided") == []

      assert :ok =
               Troupe.approve(session.id, call_id, :allow, nil, %{
                 "visibility" => "team:core",
                 "owner" => "team"
               })

      result = completed(session.id)
      assert result.data["ok"]
      assert result.data["content"] =~ "for team core's members, as the person chose"
      assert result.data["artifact"]["visibility"] == "team:core"
      assert_received {:published, %{"visibility" => "team:core", "owner" => "team"}}

      assert [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["decision"] == "allow"
      assert decided.data["visibility"] == "team:core"
      assert decided.data["owner"] == "team"
      assert decided.data["edited"] == ["visibility", "owner"]
    end

    test "allow_session on a call that named nobody is this call's allow, and nothing standing",
         context do
      %{session: session} = publishing(context, %{})
      call_id = asked(session).data["call_id"]

      assert {:error, "say whom it is for: " <> _} =
               Troupe.approve(session.id, call_id, :allow_session)

      assert :ok =
               Troupe.approve(session.id, call_id, :allow_session, nil, %{
                 "visibility" => "private"
               })

      result = completed(session.id)

      assert result.data["content"] =~
               "for the person alone, until they share a link to it, as the person chose"

      assert_received {:published, %{"visibility" => "private"} = params}
      refute Map.has_key?(params, "owner")

      assert [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["decision"] == "allow"
      assert decided.data["edited"] == ["visibility"]
    end

    test "an audience the model proposed is kept unless the person changes it", context do
      %{session: session} =
        publishing(context, %{"visibility" => "organisation"},
          config_overrides: [auto_approve: false]
        )

      request = asked(session)
      assert %{"visibility" => "organisation", "owner" => nil} = request.data["publication"]

      assert :ok =
               Troupe.approve(session.id, request.data["call_id"], :allow, nil, %{"owner" => "me"})

      result = completed(session.id)
      assert result.data["content"] =~ "for the whole organisation, as the person chose"
      assert_received {:published, %{"visibility" => "organisation", "owner" => "me"}}

      assert [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["visibility"] == "organisation"
      assert decided.data["owner"] == "me"
      assert decided.data["edited"] == ["owner"]
    end

    test "a plain allow keeps the model's proposal, and the answer does not say the person chose",
         context do
      %{session: session} =
        publishing(context, %{"visibility" => "profile:dev"},
          config_overrides: [auto_approve: false]
        )

      assert :ok = Troupe.approve(session.id, asked(session).data["call_id"], :allow)

      result = completed(session.id)
      assert result.data["content"] =~ "for profile dev's people, at"
      refute result.data["content"] =~ "as the person chose"

      assert [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["visibility"] == "profile:dev"
      assert decided.data["edited"] == []
    end

    test "a denial carries the person's word back to the model", context do
      %{session: session} = publishing(context, %{})
      call_id = asked(session).data["call_id"]

      assert :ok =
               Troupe.approve(session.id, call_id, :deny, nil, %{
                 "reason" => "not until legal has read it"
               })

      result = completed(session.id)
      refute result.data["ok"]
      assert result.data["content"] =~ "denied by the user, who said: not until legal has read it"
      refute_received {:published, _}

      assert [decided] = events_of_type(session.id, "approval_decided")
      assert decided.data["decision"] == "deny"
      assert decided.data["reason"] == "not until legal has read it"
      refute Map.has_key?(decided.data, "visibility")
    end

    test "a publication's keys on another tool's request are refused naming the tool", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "x"}}]}, {:text, "done"}]
        )

      :ok = Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "go")
      call_id = await_event(session.id, "approval_requested", 10_000).data["call_id"]

      assert {:error,
              "visibility, owner and reason answer a publication, and this asks about needs_approval"} =
               Troupe.approve(session.id, call_id, :allow, nil, %{"visibility" => "private"})

      assert [%{call_id: ^call_id}] = Approvals.pending(session.id)
      assert :ok = Troupe.approve(session.id, call_id, :allow)
      await_event(session.id, "tool_call_completed", 10_000)
    end
  end

  defp ctx(session, context) do
    %Troupe.Tool.Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    }
  end
end
