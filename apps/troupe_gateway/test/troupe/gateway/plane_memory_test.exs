defmodule Troupe.Gateway.PlaneMemoryTest do
  @moduledoc """
  The daemon's copy of the organisation's memory (#55): fetched from the plane's
  `me.memory` when a client hands the daemon a plane token, kept as the plane signed it,
  and read by every session started after it, whose `context.get` names each document
  with its version, before the person's own file and the repository's. A plane that does
  not answer, or one from before memory, leaves the copy as it was.
  """

  # The copy is the machine's, in one place for the whole VM.
  use ExUnit.Case, async: false

  alias Troupe.Config.Org
  alias Troupe.Gateway.{Daemon, FakePlane}
  alias Troupe.LLM.Fake
  alias Troupe.{PlaneKeys, PlaneMemory}
  alias Troupe.Protocol.{Client, Endpoint}

  @documents [
    %{"scope" => "organisation", "name" => nil, "version" => 2, "hash" => "sha256:o", "text" => "Deploy on Tuesdays."},
    %{"scope" => "team", "name" => "design", "version" => 5, "hash" => "sha256:t", "text" => "Use the design tokens."}
  ]

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_PROVIDER TROUPE_MODEL TROUPE_BASE_URL)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-memory-#{System.unique_integer([:positive])}")
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
    # The poll a few times a second, so a test sees a save without waiting five minutes.
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1), memory: [poll_ms: 150]})

    {:ok, client} =
      Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false, owner: self())

    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    %{plane: plane, client: client, base: base, workspace: workspace}
  end

  defp link(ctx) do
    Client.call(ctx.client, "identity.link", %{
      "command_id" => Client.command_id(),
      "subject" => "ada@example.test",
      "plane_url" => ctx.plane.url,
      "plane_token" => "plane-token"
    })
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

  test "a link with a token keeps the plane's signed memory, and a session after it reads it first",
       ctx do
    fingerprint = FakePlane.sign(ctx.plane.state)
    FakePlane.memory_with(ctx.plane.state, @documents)
    File.write!(Path.join(ctx.workspace, "AGENTS.md"), "Run mix check.\n")

    assert {:ok, %{"linked" => true}} = link(ctx)

    assert {:ok, cached} =
             eventually(fn -> match?({:ok, _}, PlaneMemory.read_cache()) && PlaneMemory.read_cache() end)

    assert cached["plane_url"] == ctx.plane.url
    assert cached["documents"] == @documents
    assert cached["signed"]["fingerprint"] == fingerprint

    fake =
      start_supervised!(
        {Fake, [steps: [{:text, "hi"}]]},
        id: {Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: ctx.workspace,
        fake: fake,
        config_overrides: [provider: "fake", auto_approve: true, model: "fake"]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)

    assert {:ok, answer} = Client.call(ctx.client, "context.get", %{"session_id" => session.id})

    assert [
             %{"scope" => "organisation", "path" => "memory:organisation", "version" => 2},
             %{"scope" => "team", "name" => "design", "version" => 5},
             %{"scope" => "root"} | _
           ] = Enum.reject(answer["files"], &(&1["scope"] == "user"))
  end

  test "a plane with no me.memory leaves the copy as it was", ctx do
    {:ok, _} = PlaneMemory.save(ctx.plane.url, %{"documents" => @documents})

    assert {:ok, %{"linked" => true}} = link(ctx)

    assert eventually(fn -> Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"me.memory", _}, &1)) end)
    # The refresh answers before it is recorded, so give it the moment it takes to finish.
    Process.sleep(200)

    assert {:ok, %{"documents" => @documents}} = PlaneMemory.read_cache()
  end

  # Slice 2: a save on the plane reaches a session already running here, through the
  # daemon's signed poll of `me.memory`; every client hears which documents changed, and
  # the session's next turn reads the new version and says so.
  test "a save on the plane reaches a running session here at its next turn, and every client hears of it",
       ctx do
    _fingerprint = FakePlane.sign(ctx.plane.state)
    FakePlane.memory_with(ctx.plane.state, @documents)
    assert {:ok, %{"linked" => true}} = link(ctx)
    assert eventually(fn -> match?({:ok, %{"documents" => @documents}}, PlaneMemory.read_cache()) end)
    assert_receive {:troupe_notification, "config.changed", %{"scope" => "memory"}}, 5_000

    %{session: session, fake: fake} = session(ctx, [{:text, "one"}, {:text, "two"}])
    turn(session.id, "hello")
    [first] = Fake.requests(fake)
    assert first.system =~ "Deploy on Tuesdays."

    saved = [
      %{"scope" => "organisation", "name" => nil, "version" => 3, "hash" => "sha256:o3", "text" => "Deploy on Thursdays."},
      %{"scope" => "team", "name" => "design", "version" => 5, "hash" => "sha256:t", "text" => "Use the design tokens."}
    ]
    FakePlane.memory_with(ctx.plane.state, saved)

    assert_receive {:troupe_notification, "config.changed",
                    %{"scope" => "memory", "keys" => ["memory:organisation"], "path" => path}},
                   5_000

    assert path =~ "memory.json"

    turn(session.id, "again")
    [_first, second] = Fake.requests(fake)
    assert second.system =~ "Deploy on Thursdays."
    refute second.system =~ "Tuesdays"

    assert [%{data: %{"changes" => [%{"scope" => "organisation", "from" => 2, "to" => 3}]}}] =
             session.id |> Troupe.events() |> Enum.filter(&(&1.type == "memory_changed"))

    # What the session's instructions view lists is what its turns now read.
    assert {:ok, answer} = Client.call(ctx.client, "context.get", %{"session_id" => session.id})
    assert [%{"path" => "memory:organisation", "version" => 3} | _] = answer["files"]
  end

  # The poll tells the plane what each session here read at its last turn, by
  # version and hash and never the text, and `me.memory.status` says where this machine
  # stands for its person's own debugging.
  test "the poll says what each session read at its last turn, and me.memory.status where this machine stands",
       ctx do
    _fingerprint = FakePlane.sign(ctx.plane.state)
    FakePlane.memory_with(ctx.plane.state, @documents)
    assert {:ok, %{"linked" => true}} = link(ctx)
    assert eventually(fn -> match?({:ok, %{"documents" => @documents}}, PlaneMemory.read_cache()) end)

    %{session: session} = session(ctx, [{:text, "one"}])
    turn(session.id, "hello")
    id = session.id

    read = [
      %{"scope" => "organisation", "name" => nil, "version" => 2, "hash" => "sha256:o"},
      %{"scope" => "team", "name" => "design", "version" => 5, "hash" => "sha256:t"}
    ]

    assert eventually(fn ->
             Enum.any?(FakePlane.calls(ctx.plane.state), fn
               {"me.memory", %{"sessions" => sessions}} ->
                 Enum.any?(sessions, &match?(%{"session_id" => ^id, "documents" => ^read, "turn_at" => _}, &1))

               _other ->
                 false
             end)
           end)

    refute Enum.any?(FakePlane.calls(ctx.plane.state), fn {_method, params} -> inspect(params) =~ "Tuesdays" end)

    assert {:ok, status} = Client.call(ctx.client, "me.memory.status", %{})
    assert status["plane_url"] == ctx.plane.url
    assert status["documents"] == read
    assert status["in_force"] == read
    assert status["current"] == true
    assert [%{"session_id" => ^id, "current" => true}] = Enum.filter(status["sessions"], &(&1["session_id"] == id))

    # A save on the plane: the status asks it (the poll may have been first), names what is
    # in force, and the session is behind until its next turn.
    FakePlane.memory_with(ctx.plane.state, [%{hd(@documents) | "version" => 3, "hash" => "sha256:o3"}])
    assert {:ok, status} = Client.call(ctx.client, "me.memory.status", %{})
    assert [%{"version" => 3}] = status["in_force"]
    assert status["documents"] |> Enum.map(& &1["version"]) |> Enum.member?(3) or status["current"] == false
    assert [%{"current" => false}] = Enum.filter(status["sessions"], &(&1["session_id"] == id))
  end

  test "config.memory keeps what troupe config pull fetched, says what changed, and gives it to the sessions here",
       ctx do
    %{session: session, fake: fake} = session(ctx, [{:text, "one"}, {:text, "two"}])
    turn(session.id, "hello")

    assert {:ok, kept} =
             Client.call(ctx.client, "config.memory", %{
               "command_id" => Client.command_id(),
               "plane_url" => ctx.plane.url,
               "document" => %{"documents" => @documents}
             })

    assert kept["plane_url"] == ctx.plane.url
    assert kept["path"] =~ "memory.json"

    assert kept["documents"] == [
             %{"scope" => "organisation", "name" => nil, "version" => 2},
             %{"scope" => "team", "name" => "design", "version" => 5}
           ]

    assert Enum.map(kept["changed"], &{&1["scope"], &1["from"], &1["to"]}) == [{"organisation", nil, 2}, {"team", nil, 5}]

    assert_receive {:troupe_notification, "config.changed",
                    %{"scope" => "memory", "keys" => ["memory:organisation", "memory:team/design"]}},
                   2_000

    turn(session.id, "again")
    [_first, second] = Fake.requests(fake)
    assert second.system =~ "Deploy on Tuesdays."
    assert second.system =~ "Use the design tokens."

    # The same answer again changes nothing and says nothing.
    assert {:ok, %{"changed" => []}} =
             Client.call(ctx.client, "config.memory", %{
               "command_id" => Client.command_id(),
               "plane_url" => ctx.plane.url,
               "document" => %{"documents" => @documents}
             })

    refute_receive {:troupe_notification, "config.changed", %{"scope" => "memory"}}, 300
  end

  test "signing out of the plane drops its memory, keeps the key it pinned, and the sessions here read none from their next turn",
       ctx do
    fingerprint = FakePlane.sign(ctx.plane.state)
    FakePlane.memory_with(ctx.plane.state, @documents)
    assert {:ok, %{"linked" => true}} = link(ctx)
    assert eventually(fn -> match?({:ok, _}, PlaneMemory.read_cache()) end)

    %{session: session, fake: fake} = session(ctx, [{:text, "one"}, {:text, "two"}])
    turn(session.id, "hello")

    # Signing out of another plane leaves this one's copy.
    assert {:ok, _} = Client.call(ctx.client, "identity.sign_out", %{"plane_url" => "https://other.example.test"})
    assert File.exists?(PlaneMemory.cache_path())

    assert {:ok, _} = Client.call(ctx.client, "identity.sign_out", %{"plane_url" => ctx.plane.url, "subject" => "ada@example.test"})
    refute File.exists?(PlaneMemory.cache_path())
    assert %{"fingerprint" => ^fingerprint} = PlaneKeys.pinned(ctx.plane.url)

    assert_receive {:troupe_notification, "config.changed",
                    %{"scope" => "memory", "keys" => ["memory:organisation", "memory:team/design"]}},
                   2_000

    turn(session.id, "again")
    [_first, second] = Fake.requests(fake)
    refute second.system =~ "Deploy on Tuesdays."

    assert [%{data: %{"changes" => [%{"to" => nil}, %{"to" => nil}]}}] =
             session.id |> Troupe.events() |> Enum.filter(&(&1.type == "memory_changed"))
  end

  # A session given its documents (a pod's, from its activation) lists those in its
  # instructions view, not this machine's copy: what the desktop app's view reads.
  test "context.get names the documents the session was given, not the machine's copy", ctx do
    {:ok, _} = PlaneMemory.save(ctx.plane.url, %{"documents" => @documents})
    profile = %{"scope" => "profile", "name" => "fixing", "version" => 1, "hash" => "sha256:p", "text" => "Fix one issue."}

    %{session: session} = session(ctx, [{:text, "one"}], plane_memory: [profile])

    assert {:ok, answer} = Client.call(ctx.client, "context.get", %{"session_id" => session.id})

    assert [%{"scope" => "profile", "path" => "memory:profile/fixing", "version" => 1}] =
             Enum.filter(answer["files"], &(&1["scope"] in ["organisation", "team", "profile"]))
  end

  # #55's user level: the person's own document, saved through the daemon's `me.memory.put`
  # as them, and an agent's `remember` with `level: "me"` adding to it; both reach the
  # sessions running here at their next turn, since the daemon asks `me.memory` again at once.
  describe "the person's own memory" do
    test "me.memory and me.memory.put read and save it as the person, and a running session reads it next turn",
         ctx do
      _fingerprint = FakePlane.sign(ctx.plane.state)
      FakePlane.memory_with(ctx.plane.state, @documents)
      FakePlane.keep_own(ctx.plane.state)
      assert {:ok, %{"linked" => true}} = link(ctx)
      assert eventually(fn -> match?({:ok, _}, PlaneMemory.read_cache()) end)

      assert {:ok, %{"version" => 0, "text" => "", "plane_url" => url}} = Client.call(ctx.client, "me.memory", %{})
      assert url == ctx.plane.url

      %{session: session, fake: fake} = session(ctx, [{:text, "one"}, {:text, "two"}])
      turn(session.id, "hello")

      assert {:ok, %{"user" => %{"version" => 1}}} =
               Client.call(ctx.client, "me.memory.put", %{
                 "command_id" => Client.command_id(),
                 "text" => "I write British English.",
                 "version" => 0
               })

      assert {:ok, %{"documents" => documents}} = PlaneMemory.read_cache()
      assert List.last(documents)["scope"] == "user"

      turn(session.id, "again")
      [_first, second] = Fake.requests(fake)
      assert second.system =~ "# The person's own memory"
      assert second.system =~ "I write British English."

      # A save from a machine that had not seen version 1 is told so.
      assert {:error, %{message: "conflict", data: %{"version" => 1}}} =
               Client.call(ctx.client, "me.memory.put", %{"command_id" => Client.command_id(), "text" => "x", "version" => 0})
    end

    test "remember with level me lands in the person's document and a second session reads it at its next turn",
         ctx do
      _fingerprint = FakePlane.sign(ctx.plane.state)
      FakePlane.memory_with(ctx.plane.state, @documents)
      FakePlane.keep_own(ctx.plane.state)
      assert {:ok, %{"linked" => true}} = link(ctx)
      assert eventually(fn -> match?({:ok, _}, PlaneMemory.read_cache()) end)

      %{session: other, fake: other_fake} = session(ctx, [{:text, "one"}, {:text, "two"}])
      turn(other.id, "hello")

      %{session: writer} =
        session(ctx, [
          {:tools, [{"remember", %{"level" => "me", "claim" => "Prefers small pull requests."}}]},
          {:text, "Noted."}
        ])

      turn(writer.id, "remember that I like small pull requests")

      assert FakePlane.own(ctx.plane.state)["text"] =~ ~r/## \d{4}-\d{2}-\d{2}\n\n- Prefers small pull requests\./

      assert Enum.any?(Troupe.events(writer.id), fn event ->
               event.type == "tool_call_completed" and inspect(event.data) =~ "person's own memory on the plane, version 1"
             end)

      turn(other.id, "again")
      [_first, second] = Fake.requests(other_fake)
      assert second.system =~ "- Prefers small pull requests."

      assert [%{data: %{"changes" => [%{"scope" => "user", "from" => nil, "to" => 1}]}}] =
               other.id |> Troupe.events() |> Enum.filter(&(&1.type == "memory_changed"))
    end

    test "signed out, the daemon says so and remember offers the repository", ctx do
      assert {:error, %{message: "unavailable", data: %{"reason" => reason}}} =
               Client.call(ctx.client, "me.memory", %{})

      assert reason =~ "not signed in to a Troupe plane"

      %{session: writer} =
        session(ctx, [{:tools, [{"remember", %{"level" => "me", "claim" => "Likes tabs."}}]}, {:text, "ok"}])

      turn(writer.id, "remember that I like tabs")

      assert Enum.any?(Troupe.events(writer.id), fn event ->
               event.type == "tool_call_completed" and inspect(event.data) =~ "level repository"
             end)
    end
  end

  defp session(ctx, steps, overrides \\ []) do
    fake =
      start_supervised!(
        {Fake, [steps: steps]},
        id: {Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: ctx.workspace,
        fake: fake,
        config_overrides:
          [provider: "fake", auto_approve: true, model: "fake", system_prompt: "per_turn"] ++ overrides
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    %{session: session, fake: fake}
  end

  defp turn(session_id, text) do
    :ok = Troupe.subscribe(session_id)
    Troupe.send_input(session_id, text)
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
end
