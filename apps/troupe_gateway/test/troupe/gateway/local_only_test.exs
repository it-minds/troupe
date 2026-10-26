defmodule Troupe.Gateway.LocalOnlyTest do
  @moduledoc """
  The daemon honours a client's Local only: a client that says `client_info.local_only` on
  `initialize`, or `client.mode` later, gets no plane call made for the sessions it runs. An
  agent's `remember` with `level: "me"` there is refused with a sentence naming Local only
  and offering the repository, an offer for steering is refused, the memory poll's report
  leaves the session out, the session says once in `instructions_loaded` that it reads what
  this machine holds, and while every client attached is in Local only the daemon's polls
  ask the plane nothing. A client that is not in Local only, on the same daemon, writes as
  before.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config.Org
  alias Troupe.Gateway.{Daemon, FakePlane, LocalOnly}
  alias Troupe.LLM.Fake
  alias Troupe.PlaneMemory
  alias Troupe.Protocol.{Client, Endpoint}

  @documents [
    %{
      "scope" => "organisation",
      "name" => nil,
      "version" => 2,
      "hash" => "sha256:o",
      "text" => "Deploy on Tuesdays."
    }
  ]

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_PROVIDER TROUPE_MODEL TROUPE_BASE_URL)

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-gw-local-only-#{System.unique_integer([:positive])}")

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
    Enum.each([Org.cache_path(), Org.keys_path(), PlaneMemory.cache_path()], &File.rm/1)

    plane = FakePlane.serve()

    on_exit(fn ->
      Process.exit(plane.server, :normal)
      Enum.each([Org.cache_path(), Org.keys_path(), PlaneMemory.cache_path()], &File.rm/1)

      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}

    start_supervised!(
      {Daemon,
       endpoint: endpoint,
       idle_shutdown_ms: :timer.hours(1),
       memory: [poll_ms: 150],
       policy: [poll_ms: 150]}
    )

    plain = connect(endpoint, %{"name" => "troupe", "version" => "1"})
    local = connect(endpoint, %{"name" => "troupe-gui", "version" => "1", "local_only" => true})

    _fingerprint = FakePlane.sign(plane.state)
    FakePlane.memory_with(plane.state, @documents)
    FakePlane.keep_own(plane.state)

    assert {:ok, %{"linked" => true}} =
             Client.call(plain, "identity.link", %{
               "command_id" => Client.command_id(),
               "subject" => "ada@example.test",
               "plane_url" => plane.url,
               "plane_token" => "plane-token"
             })

    assert eventually(fn ->
             match?({:ok, %{"documents" => @documents}}, PlaneMemory.read_cache())
           end)

    %{plane: plane, endpoint: endpoint, plain: plain, local: local, workspace: workspace}
  end

  test "a Local-only client's session refuses remember level me, naming Local only; another client's still writes",
       ctx do
    remembering = [
      {:tools, [{"remember", %{"level" => "me", "claim" => "Prefers tabs."}}]},
      {:text, "ok"}
    ]

    %{session: kept} = session(ctx, remembering ++ [{:text, "again"}])
    %{session: sent} = session(ctx, remembering)

    turn(ctx.local, kept.id, "remember that I like tabs")
    turn(ctx.plain, sent.id, "remember that I like tabs")

    refused = completed(kept.id)
    assert refused =~ "Local only"
    assert refused =~ "level repository"
    assert completed(sent.id) =~ "person's own memory on the plane, version 1"

    # One entry reached the plane, from the session that is not under Local only, naming it
    # and its agent; nothing of the other did.
    puts = for {"me.memory.put", params} <- FakePlane.calls(ctx.plane.state), do: params
    assert [%{"append" => "Prefers tabs.", "session" => session_id, "agent" => agent}] = puts
    assert session_id == sent.id
    assert is_binary(agent) and agent != ""

    refute Enum.any?(FakePlane.calls(ctx.plane.state), fn {_method, params} ->
             inspect(params) =~ kept.id
           end)

    # Said once, at the first turn under Local only, and not at the next.
    turn(ctx.local, kept.id, "and again")

    assert [said] =
             for(
               event <- Troupe.events(kept.id),
               event.type == "instructions_loaded",
               line = event.data["local_only"],
               do: line
             )

    assert said =~ "Local only"

    refute Enum.any?(
             Troupe.events(sent.id),
             &(&1.type == "instructions_loaded" and &1.data["local_only"])
           )
  end

  test "the poll's report leaves a Local-only session out, an offer is refused, and its client's memory calls ask nothing",
       ctx do
    %{session: kept} = session(ctx, [{:text, "one"}])
    %{session: sent} = session(ctx, [{:text, "two"}])
    turn(ctx.local, kept.id, "hello")
    turn(ctx.plain, sent.id, "hello")

    sent_id = sent.id

    assert eventually(fn ->
             Enum.any?(FakePlane.calls(ctx.plane.state), fn
               {"me.memory", %{"sessions" => sessions}} ->
                 Enum.any?(sessions, &(&1["session_id"] == sent_id))

               _other ->
                 false
             end)
           end)

    refute Enum.any?(FakePlane.calls(ctx.plane.state), fn {_method, params} ->
             inspect(params) =~ kept.id
           end)

    assert {:error, %{message: "forbidden", data: %{"reason" => offer}}} =
             Client.call(ctx.plain, "remote.offer", %{
               "command_id" => Client.command_id(),
               "session_id" => kept.id
             })

    assert offer =~ "under Local only"

    assert {:error, %{message: "forbidden", data: %{"reason" => own}}} =
             Client.call(ctx.local, "me.memory", %{})

    assert own =~ "Local only"

    # Its history and a rollback are the plane's as much.
    for {method, params} <- [{"me.memory.history", %{}}, {"me.memory.rollback", %{"to" => 1, "version" => 2}}] do
      assert {:error, %{message: "forbidden", data: %{"reason" => why}}} =
               Client.call(ctx.local, method, Map.put(params, "command_id", Client.command_id()))

      assert why =~ "Local only", method
    end

    asked = length(FakePlane.calls(ctx.plane.state))
    assert {:ok, status} = Client.call(ctx.local, "me.memory.status", %{})
    assert status["reason"] =~ "Local only"
    assert status["documents"] != []
    # The poll may have asked meanwhile; the status itself asked nothing of `me.memory`.
    assert Enum.count(
             Enum.drop(FakePlane.calls(ctx.plane.state), asked),
             &match?({"me.memory", %{"sessions" => _}}, &1)
           ) <= 1
  end

  test "while every client attached is in Local only the polls ask nothing, and client.mode off asks again",
       ctx do
    Client.close(ctx.plain)
    assert eventually(fn -> LocalOnly.paused?() end)

    # A poll in flight as the client went may still land; after that, nothing for a while.
    Process.sleep(300)
    before = length(FakePlane.calls(ctx.plane.state))
    Process.sleep(600)
    assert length(FakePlane.calls(ctx.plane.state)) == before

    assert {:ok, %{"local_only" => false}} =
             Client.call(ctx.local, "client.mode", %{"local_only" => false})

    refute LocalOnly.paused?()

    assert eventually(fn ->
             FakePlane.calls(ctx.plane.state)
             |> Enum.drop(before)
             |> Enum.any?(&match?({"me.memory", _}, &1))
           end)
  end

  test "client.mode on puts the sessions the client has open under Local only, and off takes them out",
       ctx do
    %{session: session} = session(ctx, [{:text, "one"}])
    turn(ctx.plain, session.id, "hello")
    refute LocalOnly.session?(session.id)

    assert {:ok, %{"local_only" => false}} =
             Client.call(ctx.local, "client.mode", %{"local_only" => false})

    assert {:ok, _} =
             Client.call(ctx.local, "subscribe", %{
               "command_id" => Client.command_id(),
               "topic" => "session:" <> session.id
             })

    assert {:ok, %{"local_only" => true}} =
             Client.call(ctx.local, "client.mode", %{"local_only" => true})

    assert LocalOnly.session?(session.id)

    assert {:ok, %{"local_only" => false}} =
             Client.call(ctx.local, "client.mode", %{"local_only" => false})

    refute LocalOnly.session?(session.id)

    assert {:error, %{message: "invalid_params"}} =
             Client.call(ctx.local, "client.mode", %{"local_only" => "yes"})
  end

  test "a session stays under Local only after its client goes, and leaves it when another client gives it work",
       ctx do
    %{session: session} = session(ctx, [{:text, "one"}, {:text, "two"}])
    turn(ctx.local, session.id, "hello")
    assert LocalOnly.session?(session.id)

    Client.close(ctx.local)
    Process.sleep(100)
    assert LocalOnly.session?(session.id)

    turn(ctx.plain, session.id, "again")
    refute LocalOnly.session?(session.id)
  end

  test "a Local-only client is refused the invitations, which are the plane's", ctx do
    %{session: session} = session(ctx, [{:text, "one"}])

    for method <- ~w(session.invites session.read_sealed) do
      assert {:error, %{message: "forbidden", data: %{"reason" => reason}}} =
               Client.call(ctx.local, method, %{"session_id" => session.id})

      assert reason =~ "Local only"
    end
  end

  test "a Local-only client publishes and lists no artifact, and its session's agent publishes none",
       ctx do
    publish = %{
      "command_id" => Client.command_id(),
      "title" => "Weekly",
      "kind" => "html",
      "visibility" => "organisation",
      "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<h1>Weekly</h1>")}]
    }

    assert {:error, %{message: "forbidden", data: %{"reason" => reason}}} =
             Client.call(ctx.local, "artifact.publish", publish)

    assert reason =~ "Local only"

    assert {:error, %{message: "forbidden"}} = Client.call(ctx.local, "artifact.list", %{})

    # Nor the desktop app's gallery and viewer, which go to the plane through the daemon.
    for method <- ~w(artifact.get artifact.open artifact.share artifact.unshare artifact.rollback artifact.pin) do
      assert {:error, %{message: "forbidden", data: %{"reason" => why}}} =
               Client.call(ctx.local, method, %{"command_id" => Client.command_id(), "id" => "art-1"})

      assert why =~ "Local only", method
    end

    File.write!(Path.join(ctx.workspace, "report.md"), "# Weekly\n")

    tool = %{
      "title" => "Weekly",
      "kind" => "markdown",
      "visibility" => "organisation",
      "files" => ["report.md"]
    }

    %{session: kept} = session(ctx, [{:tools, [{"publish_artifact", tool}]}, {:text, "ok"}])
    turn(ctx.local, kept.id, "publish the report")

    assert completed(kept.id) =~ "under Local only"
    refute Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"artifact." <> _, _}, &1))
  end

  test "a Local-only client is refused a private session", ctx do
    assert {:error, %{message: "forbidden", data: %{"reason" => reason}}} =
             Client.call(ctx.local, "session.create", %{
               "command_id" => Client.command_id(),
               "workspace" => ctx.workspace,
               "private" => true
             })

    assert reason =~ "Local only"
  end

  # -- helpers ----------------------------------------------------------------

  defp connect(endpoint, client_info) do
    {:ok, client} =
      Troupe.Protocol.Daemon.connect(
        endpoint: endpoint,
        spawn: false,
        owner: self(),
        client_info: client_info
      )

    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end

  defp session(ctx, steps) do
    fake =
      start_supervised!({Fake, [steps: steps]}, id: {Fake, System.unique_integer([:positive])})

    {:ok, session} =
      Troupe.start_session(
        workspace: ctx.workspace,
        fake: fake,
        config_overrides: [provider: "fake", auto_approve: true, model: "fake"]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    %{session: session, fake: fake}
  end

  # A turn given by `client`, over the protocol, as a client gives one.
  defp turn(client, session_id, text) do
    :ok = Troupe.subscribe(session_id)

    assert {:ok, %{"accepted" => true}} =
             Client.call(client, "input.send", %{
               "command_id" => Client.command_id(),
               "session_id" => session_id,
               "text" => text
             })

    await_turn(session_id)
    Troupe.unsubscribe(session_id)
  end

  defp await_turn(session_id) do
    receive do
      {:troupe_event, ^session_id, %{type: "turn_ended"}} -> :ok
      {:troupe_event, ^session_id, _other} -> await_turn(session_id)
    after
      20_000 -> flunk("no turn_ended")
    end
  end

  defp completed(session_id) do
    session_id
    |> Troupe.events()
    |> Enum.filter(&(&1.type == "tool_call_completed"))
    |> Enum.map_join("\n", &inspect(&1.data))
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(50)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end
end
