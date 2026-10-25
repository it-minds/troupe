defmodule Troupe.Tools.PublishArtifactTest do
  @moduledoc """
  `publish_artifact` (#62): a page, a document or a file from the workspace published on the
  plane for the session's person, through whatever the host installed (`Troupe.Artifacts`);
  confined to the workspace; offered only where there is somewhere for it to go; refused,
  naming the file, where the person is signed out; asked about by default; and on the call's
  own event, what it published. `async: false`, as it installs the host's function in the
  application environment.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Session.Log
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
                 "id" => "art-abcdefghijklmnop"
               },
               ctx(session, context)
             )

    assert_received {:published,
                     %{"id" => "art-abcdefghijklmnop", "files" => [%{"path" => "notes.md"}]}}

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
