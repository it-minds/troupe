defmodule Troupe.Worker.BundleWinsTest do
  @moduledoc """
  A session the plane activates on this pod runs its bundle's agents and skills, not the
  working copy's of the same names, unless the profile allows the repository's (Decision
  826).

  Driven the way a pod is: `session.activate` with a bundle pin, the bundle fetched and
  materialised by the pod's registry, and a working copy that carries a `.troupe/agents/
  build.md` of its own, which is what a clone of an onboarded repository has.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Troupe.Agent.Definitions
  alias Troupe.Protocol.Bundle
  alias Troupe.Worker.Bundles
  alias Troupe.Worker.Plane.Commands

  @moduletag timeout: 60_000

  @document %{
    "schema" => 1,
    "agents" => [
      %{"name" => "build", "definition" => "---\nmode: primary\n---\nYou are the bundle's build."}
    ],
    "skills" => [
      %{
        "name" => "review-checklist",
        "description" => "The bundle's checklist",
        "files" => %{"SKILL.md" => "---\nname: review-checklist\n---\nThe bundle's."}
      }
    ],
    "mcp_servers" => []
  }

  setup context do
    context = requires_tier(context)
    hash = Bundle.hash(@document)
    fetched = %{"content" => @document, "hash" => hash, "channel" => "stable", "version" => 3}

    start_supervised!(
      {Bundles, state_dir: context.state_dir, mcp: nil, fetch: fn _params -> {:ok, fetched} end}
    )

    Application.put_env(:troupe_worker, :session_defaults, activation(context))
    on_exit(fn -> Application.delete_env(:troupe_worker, :session_defaults) end)
    on_exit(fn -> quieten(context.session_id) end)

    write(
      context.workspace,
      ".troupe/agents/build.md",
      "---\nmode: primary\n---\nThe repository's."
    )

    write(
      context.workspace,
      ".troupe/skills/review-checklist/SKILL.md",
      "---\nname: review-checklist\ndescription: The repository's checklist\n---\nMine."
    )

    Map.put(context, :hash, hash)
  end

  test "the bundle's build runs, and the repository's is listed as skipped", context do
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push(context))

    {:ok, definitions} = Troupe.definitions(context.session_id)
    build = Definitions.fetch!(definitions, "build")
    assert build.source == :bundle
    assert build.prompt == "You are the bundle's build."

    [skipped] = Enum.filter(Troupe.events(context.session_id), &(&1.type == "files_skipped"))

    assert Enum.map(skipped.data["files"], &{&1["kind"], &1["name"]}) ==
             [{"agent", "build"}, {"skill", "review-checklist"}]

    assert hd(skipped.data["files"])["reason"] =~ "on a pod the bundle's beats a repository's"
  end

  test "a profile that allows the repository's gets the repository's", context do
    push = Map.put(push(context), "repository_overrides_bundle", true)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    {:ok, definitions} = Troupe.definitions(context.session_id)
    assert Definitions.fetch!(definitions, "build").source == :project
    refute Enum.any?(Troupe.events(context.session_id), &(&1.type == "files_skipped"))
  end

  test "anything but true is the bundle winning", context do
    push = Map.put(push(context), "repository_overrides_bundle", "true")
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", push)

    {:ok, definitions} = Troupe.definitions(context.session_id)
    assert Definitions.fetch!(definitions, "build").source == :bundle
  end

  # The built-ins beat the working copy on a pod as the bundle does, and a channel with
  # nothing published pins the session to nothing rather than to a laptop's order.
  test "with nothing published, the built-in build runs; with the setting on, the repository's",
       context do
    nothing = Map.drop(push(context), ["bundle_version", "bundle_hash"])
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", nothing)

    {:ok, definitions} = Troupe.definitions(context.session_id)
    assert Definitions.fetch!(definitions, "build").source == :builtin

    [skipped] = Enum.filter(Troupe.events(context.session_id), &(&1.type == "files_skipped"))
    assert [%{"name" => "build", "reason" => reason}] = skipped.data["files"]
    assert reason =~ "an agent Troupe ships"

    # Asleep and woken again under a profile that has turned the setting on.
    assert {:ok, _} = Sessions.dormant(context.session_id)
    allowed = Map.put(nothing, "repository_overrides_bundle", true)
    assert {:ok, %{"activated" => true}} = Commands.handle("session.activate", allowed)

    {:ok, definitions} = Troupe.definitions(context.session_id)
    assert Definitions.fetch!(definitions, "build").source == :project
  end

  defp push(context) do
    %{
      "session_id" => context.session_id,
      "team" => context.team,
      "epoch" => 1,
      "bundle_version" => 3,
      "bundle_hash" => context.hash,
      "channel" => "stable"
    }
  end

  defp write(dir, relative, text) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp quieten(session_id) do
    Troupe.cancel(session_id)
    Troupe.stop_session(session_id)
  catch
    :exit, _ -> :ok
  end
end
