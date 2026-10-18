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
  alias Troupe.PlaneMemory
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
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

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
        {Troupe.LLM.Fake, [steps: [{:text, "hi"}]]},
        id: {Troupe.LLM.Fake, System.unique_integer([:positive])}
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
end
