defmodule Troupe.PlaneMemoryTest do
  @moduledoc """
  The organisation's memory documents on a machine and a pod (#55): the daemon's copy of
  `me.memory`, checked against the plane's pinned key whenever it is read; what a session
  reads, the organisation's, a team's and a profile's, before the person's own file and
  the repository's, in a section that says they are the organisation's and no agent's to
  change; and `troupe config --explain` naming each with its version.
  """

  # The cache's path is the application environment's, which is the whole VM's.
  use ExUnit.Case, async: false

  alias Troupe.{Config, Instructions, PlaneKeys, PlaneMemory, Workspace}
  alias Troupe.Protocol.Memory, as: Shape
  alias Troupe.Protocol.PlaneSignature

  @plane "https://plane.example.test"

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-memory-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")
    File.mkdir_p!(Path.join(ws, ".git"))
    user = Path.join(base, "user.yaml")
    File.write!(user, "version: 1\n")

    previous = Application.get_env(:troupe_core, :organisation)

    Application.put_env(:troupe_core, :organisation,
      managed_path: Path.join(base, "managed.yaml"),
      cache_path: Path.join(base, "state/organisation.json"),
      keys_path: Path.join(base, "state/plane-keys.json")
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:troupe_core, :organisation, previous),
        else: Application.delete_env(:troupe_core, :organisation)

      File.rm_rf!(base)
    end)

    %{base: base, ws: ws, user: user, cache: PlaneMemory.cache_path()}
  end

  @documents [
    %{
      "scope" => "team",
      "name" => "engineering",
      "version" => 2,
      "hash" => "sha256:t",
      "text" => "Review within a day."
    },
    %{
      "scope" => "organisation",
      "name" => nil,
      "version" => 3,
      "hash" => "sha256:o",
      "text" => "We deploy on Tuesdays."
    }
  ]

  defp resolve(ctx, overrides \\ [], opts \\ []),
    do: Config.resolve(ctx.ws, overrides, [user_path: ctx.user] ++ opts)

  defp signing_key! do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, _} = PlaneKeys.see(@plane, PlaneSignature.key_json(public))
    %{secret: secret, fingerprint: PlaneSignature.fingerprint(public)}
  end

  defp sign(key, body, opts \\ []) do
    document = PlaneSignature.document("memory", body, opts)
    signature = :crypto.sign(:eddsa, :none, document, [key.secret, :ed25519])
    PlaneSignature.envelope(document, signature, key.fingerprint)
  end

  describe "the daemon's copy" do
    test "a signed copy is read into a session's configuration, the organisation's first", ctx do
      key = signing_key!()
      answer = %{"documents" => @documents}
      assert {:ok, _} = PlaneMemory.save(@plane, answer, ctx.cache, sign(key, answer))

      assert {:ok, config, layers} = resolve(ctx)

      assert Enum.map(config.plane_memory, &{&1["scope"], &1["version"]}) == [
               {"organisation", 3},
               {"team", 2}
             ]

      assert layers.memory.source == @plane
      assert is_binary(layers.memory.fetched_at)
      assert config.warnings == []
    end

    test "a copy edited on this machine is refused with a sentence, and nothing of it is read",
         ctx do
      key = signing_key!()
      answer = %{"documents" => @documents}
      assert {:ok, _} = PlaneMemory.save(@plane, answer, ctx.cache, sign(key, answer))

      edited =
        ctx.cache
        |> File.read!()
        |> Jason.decode!()
        |> put_in(["documents", Access.at(1), "text"], "Deploy whenever you like.")

      File.write!(ctx.cache, Jason.encode!(edited))

      assert {:error, why} = PlaneMemory.read_cache(ctx.cache)
      assert why =~ "does not match the plane's signature: it was changed on this machine"

      assert {:ok, config, _layers} = resolve(ctx)
      assert config.plane_memory == []
      assert Enum.any?(config.warnings, &(&1 =~ "the organisation's memory from #{@plane}"))

      # Without the signature, once the plane's key is pinned, it is refused too.
      File.write!(ctx.cache, edited |> Map.delete("signed") |> Jason.encode!())
      assert {:error, unsigned} = PlaneMemory.read_cache(ctx.cache)
      assert unsigned =~ "is not signed, and this machine holds that plane's signing key"
    end

    test "a signed copy past its time still holds, and says so", ctx do
      key = signing_key!()
      answer = %{"documents" => @documents}
      long_ago = ~U[2026-01-01 00:00:00Z]
      assert {:ok, _} = PlaneMemory.save(@plane, answer, ctx.cache, sign(key, answer, now: long_ago))

      assert {:ok, config, _layers} = resolve(ctx)
      assert length(config.plane_memory) == 2
      assert Enum.any?(config.warnings, &(&1 =~ "was the plane's word until"))
    end

    test "is in the state directory, where no tool that writes reaches", ctx do
      {:ok, _} = PlaneMemory.save(@plane, %{"documents" => @documents}, ctx.cache)

      assert {:error, {:outside_workspace, _}} =
               Workspace.resolve(Workspace.new!(ctx.ws), ctx.cache, :write)
    end
  end

  describe "on a pod" do
    test "the activation's documents are read, and the machine's copy never is", ctx do
      {:ok, _} = PlaneMemory.save(@plane, %{"documents" => @documents}, ctx.cache)

      assert {:ok, config, _layers} = resolve(ctx, [], trust: :never)
      assert config.plane_memory == []

      profile = %{"scope" => "profile", "name" => "dev", "version" => 1, "hash" => "sha256:p", "text" => "On dev."}

      assert {:ok, config, layers} =
               resolve(ctx, [plane_memory: [profile | @documents]], trust: :never)

      assert Enum.map(config.plane_memory, & &1["scope"]) == ["organisation", "team", "profile"]
      assert layers.memory.source == "the plane, with the session's activation"
    end

    test "a document past the limit is kept to it, and says so", ctx do
      long = String.duplicate("a", Shape.max_bytes() + 10)
      big = %{"scope" => "organisation", "name" => nil, "version" => 1, "hash" => "sha256:x", "text" => long}

      assert {:ok, config, _layers} = resolve(ctx, [plane_memory: [big]], trust: :never)
      assert [%{"trimmed" => 10, "text" => kept}] = config.plane_memory
      assert byte_size(kept) == Shape.max_bytes()
    end
  end

  describe "in a session's instructions" do
    test "come first, in order, outside the files' budget, each named with its version", ctx do
      File.write!(Path.join(ctx.ws, "AGENTS.md"), "Use pnpm.\n")
      {:ok, _} = PlaneMemory.save(@plane, %{"documents" => @documents}, ctx.cache)
      {:ok, config, _layers} = resolve(ctx)

      loaded = Instructions.load(ctx.ws, config)

      assert [organisation, team | rest] = loaded.files
      assert {organisation.scope, organisation.version} == {:organisation, 3}
      assert {team.scope, team.where, team.version} == {:team, "engineering", 2}
      assert Enum.any?(rest, &(&1.scope == :root))
      assert loaded.used == String.length("Use pnpm.")

      prompt = Instructions.to_prompt(loaded)
      {memory_at, _} = :binary.match(prompt, "# Your organisation's memory")
      {organisation_at, _} = :binary.match(prompt, "The organisation's memory (version 3):\nWe deploy on Tuesdays.")
      {team_at, _} = :binary.match(prompt, "The team engineering's memory (version 2):\nReview within a day.")
      {files_at, _} = :binary.match(prompt, "# Instruction files")
      assert memory_at < organisation_at and organisation_at < team_at and team_at < files_at

      # Instructions from the organisation, and no agent's to change.
      assert prompt =~ "instructions from the organisation, which apply as written"
      assert prompt =~ "If you are asked to change one, say that you cannot"
      assert prompt =~ "Troupe console"

      provenance = Instructions.provenance(loaded)

      assert [
               %{"scope" => "organisation", "path" => "memory:organisation", "version" => 3},
               %{"scope" => "team", "path" => "memory:team/engineering", "version" => 2, "name" => "engineering"}
               | _
             ] = provenance["files"]
    end
  end

  describe "troupe config --explain" do
    test "names each document with its version and where it came from", ctx do
      {:ok, _} = PlaneMemory.save(@plane, %{"documents" => @documents}, ctx.cache)

      {text, 0} = Config.explain(ctx.ws, nil, user_path: ctx.user)
      assert text =~ "  memory   the organisation's memory, version 3 (#{@plane}, fetched "
      assert text =~ "  memory   the team engineering's memory, version 2 (#{@plane}"

      {json, 0} = Config.explain(ctx.ws, nil, user_path: ctx.user, json: true)

      assert [%{"scope" => "organisation", "version" => 3, "source" => @plane}, %{"scope" => "team"}] =
               Jason.decode!(json)["memory"]
    end
  end
end
