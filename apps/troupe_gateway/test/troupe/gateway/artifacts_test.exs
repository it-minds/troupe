defmodule Troupe.Gateway.ArtifactsTest do
  @moduledoc """
  Publishing an artifact from a laptop (#62): through the daemon's sign-in, as `artifact.publish`
  on the plane, whether a client's "Publish…" sends it or a session's agent calls
  `publish_artifact`; signed out, refused with a sentence. Against `FakePlane`.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, FakePlane}
  alias Troupe.LLM.Fake
  alias Troupe.Protocol.{Client, Endpoint}
  alias Troupe.Session.Log

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_PROVIDER TROUPE_MODEL TROUPE_BASE_URL)

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-gw-artifacts-#{System.unique_integer([:positive])}")

    workspace = Path.join(base, "workspace")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))
    File.mkdir_p!(Path.join(workspace, ".git"))

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    plane = FakePlane.serve()

    on_exit(fn ->
      Process.exit(plane.server, :normal)
      Troupe.Artifacts.uninstall()

      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    {:ok, client} =
      Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false, owner: self())

    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    %{plane: plane, client: client, workspace: workspace}
  end

  defp link(ctx) do
    Client.call(ctx.client, "identity.link", %{
      "command_id" => Client.command_id(),
      "subject" => "ada@example.test",
      "plane_url" => ctx.plane.url,
      "plane_token" => "plane-token"
    })
  end

  defp publish(ctx, params) do
    Client.call(
      ctx.client,
      "artifact.publish",
      Map.merge(
        %{
          "command_id" => Client.command_id(),
          "title" => "Weekly",
          "kind" => "html",
          "visibility" => "organisation",
          "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<h1>Weekly</h1>")}]
        },
        params
      )
    )
  end

  test "signed out, a client's publish is refused with a sentence, and nothing reaches a plane",
       ctx do
    assert {:error, %{message: "unavailable", data: %{"reason" => reason}}} = publish(ctx, %{})
    assert reason =~ "not signed in to a Troupe plane"
    refute Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"artifact.publish", _}, &1))
  end

  test "signed in, a client's publish goes to the plane as the person, and its refusal comes back",
       ctx do
    assert {:ok, %{"linked" => true}} = link(ctx)

    assert {:ok, artifact} = publish(ctx, %{"session_id" => "20261025T120000-abcdef"})
    assert artifact["url"] == "https://artifacts.example.test/a/art-fakefakefakefake/"
    assert artifact["plane_url"] == ctx.plane.url

    {"artifact.publish", sent} =
      Enum.find(FakePlane.calls(ctx.plane.state), &match?({"artifact.publish", _}, &1))

    assert sent["title"] == "Weekly"
    assert sent["session_id"] == "20261025T120000-abcdef"
    refute Map.has_key?(sent, "command_id")
    assert [%{"path" => "index.html"}] = sent["files"]

    assert {:error, %{message: "invalid_params", data: %{"reason" => reason}}} =
             publish(ctx, %{"title" => ""})

    assert reason =~ "needs a title"
  end

  test "a version too large for one call goes by an upload handle, straight to the object store",
       ctx do
    assert {:ok, %{"linked" => true}} = link(ctx)
    big = :binary.copy("x", 3 * 1024 * 1024)

    on_exit(fn ->
      Troupe.ObjectStore.delete_prefix(Troupe.ObjectStore.from_env(), "artifact-uploads/")
    end)

    assert {:ok, _artifact} =
             publish(ctx, %{
               "id" => "art-fakefakefakefake",
               "note" => "bigger",
               "files" => [
                 %{"path" => "index.html", "bytes" => Base.encode64("<h1>Big</h1>")},
                 %{"path" => "data.bin", "bytes" => Base.encode64(big)}
               ]
             })

    calls = FakePlane.calls(ctx.plane.state)
    {"artifact.upload.begin", begun} = Enum.find(calls, &match?({"artifact.upload.begin", _}, &1))

    assert Enum.sort_by(begun["files"], & &1["path"]) == [
             %{"path" => "data.bin", "size" => byte_size(big)},
             %{"path" => "index.html", "size" => 12}
           ]

    {"artifact.publish", sent} = Enum.find(calls, &match?({"artifact.publish", _}, &1))
    refute Map.has_key?(sent, "files")
    assert "up-fake" <> _ = handle = sent["upload"]
    assert sent["note"] == "bigger"

    assert {:ok, ^big} =
             Troupe.ObjectStore.get(
               Troupe.ObjectStore.from_env(),
               "artifact-uploads/#{handle}/data.bin"
             )
  end

  test "the person's own artifacts are listed through the daemon, with the gallery", ctx do
    assert {:error, %{message: "unavailable"}} =
             Client.call(ctx.client, "artifact.list", %{"mine" => true})

    assert {:ok, %{"linked" => true}} = link(ctx)

    assert {:ok, %{"artifacts" => [%{"id" => "art-fakefakefakefake"}], "gallery_url" => gallery}} =
             Client.call(ctx.client, "artifact.list", %{"mine" => true})

    assert gallery =~ "#/artifacts"
    assert {"artifact.list", %{"mine" => true}} =
             Enum.find(FakePlane.calls(ctx.plane.state), &match?({"artifact.list", _}, &1))
  end

  # The desktop app's gallery and viewer, and the terminal's: one artifact with its versions, a
  # ticket to open it or one version on its host, one text file of a version, a view link and its revoking, a rollback and a pin, each the
  # plane's own method sent with the daemon's sign-in, its answer and its refusal as the
  # plane gave them.
  test "the viewer's methods are forwarded to the plane as the person, its refusals kept", ctx do
    forwarded = [
      {"artifact.get", %{"id" => "art-fakefakefakefake"}},
      {"artifact.open", %{"id" => "art-fakefakefakefake", "version" => 1}},
      {"artifact.read", %{"id" => "art-fakefakefakefake", "version" => 1, "path" => "index.md"}},
      {"artifact.share", %{"command_id" => Client.command_id(), "id" => "art-fakefakefakefake", "role" => "view"}},
      {"artifact.unshare", %{"command_id" => Client.command_id(), "id" => "art-fakefakefakefake", "share" => "sh-1"}},
      {"artifact.rollback", %{"command_id" => Client.command_id(), "id" => "art-fakefakefakefake", "version" => 1}},
      {"artifact.pin", %{"command_id" => Client.command_id(), "id" => "art-fakefakefakefake", "version" => nil}}
    ]

    for {method, params} <- forwarded do
      assert {:error, %{message: "unavailable", data: %{"reason" => reason}}} =
               Client.call(ctx.client, method, params)

      assert reason =~ "not signed in to a Troupe plane", method
    end

    refute Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"artifact." <> _, _}, &1))
    assert {:ok, %{"linked" => true}} = link(ctx)

    assert {:ok, %{"versions" => [%{"n" => 1}], "plane_url" => url}} =
             Client.call(ctx.client, "artifact.get", %{"id" => "art-fakefakefakefake"})

    assert url == ctx.plane.url

    assert {:ok, %{"url" => "https://artifacts.example.test/enter?ticket=" <> _, "expires_in" => 60}} =
             Client.call(ctx.client, "artifact.open", %{"id" => "art-fakefakefakefake", "version" => 1})

    assert {:ok, %{"url" => "https://artifacts.example.test/s/" <> _, "share" => %{"role" => "view"}}} =
             Client.call(ctx.client, "artifact.share", Enum.at(forwarded, 3) |> elem(1))

    assert {:ok, %{"text" => "# Weekly"}} = Client.call(ctx.client, "artifact.read", Enum.at(forwarded, 2) |> elem(1))

    for {method, params} <- Enum.drop(forwarded, 4) do
      assert {:ok, _answer} = Client.call(ctx.client, method, params), method
    end

    calls = FakePlane.calls(ctx.plane.state)

    for {method, params} <- forwarded do
      {^method, sent} = Enum.find(calls, &match?({^method, _}, &1))
      refute Map.has_key?(sent, "command_id")
      assert sent == Map.delete(params, "command_id"), method
    end

    # A refusal keeps its code: one the person may not see is not there.
    assert {:error, %{message: "not_found"}} =
             Client.call(ctx.client, "artifact.get", %{"id" => "art-somebody-elses"})

    assert {:error, %{message: "forbidden", data: %{"reason" => reason}}} =
             Client.call(ctx.client, "artifact.pin", %{
               "command_id" => Client.command_id(),
               "id" => "art-somebody-elses",
               "version" => 1
             })

    assert reason =~ "owner"
  end

  test "a session's agent publishes through the daemon, naming the session and itself", ctx do
    assert {:ok, %{"linked" => true}} = link(ctx)
    File.write!(Path.join(ctx.workspace, "report.md"), "# Findings")

    fake =
      start_supervised!(
        {Fake,
         [
           steps: [
             {:tools,
              [
                {"publish_artifact",
                 %{
                   "title" => "Findings",
                   "kind" => "markdown",
                   "visibility" => "profile:dev",
                   "files" => ["report.md"]
                 }}
              ]},
             {:text, "Published."}
           ]
         ]},
        id: {Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: ctx.workspace,
        fake: fake,
        config_overrides: [provider: "fake", auto_approve: true, model: "fake"]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "publish the findings")
    assert_receive {:troupe_event, _, %Troupe.Protocol.Event{type: "tool_call_completed"}}, 10_000

    {"artifact.publish", sent} =
      Enum.find(FakePlane.calls(ctx.plane.state), &match?({"artifact.publish", _}, &1))

    assert sent["session_id"] == session.id
    assert sent["agent"] =~ "agent:"
    assert [%{"path" => "report.md", "bytes" => bytes}] = sent["files"]
    assert Base.decode64!(bytes) == "# Findings"

    assert Enum.any?(Log.replay(session.id), fn
             %{
               type: "tool_call_completed",
               data: %{
                 "name" => "publish_artifact",
                 "artifact" => %{"id" => "art-fakefakefakefake"}
               }
             } ->
               true

             _ ->
               false
           end)
  end
end
