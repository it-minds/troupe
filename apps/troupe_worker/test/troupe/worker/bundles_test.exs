defmodule Troupe.Worker.BundlesTest do
  @moduledoc """
  Fetch, verify, materialise, remember.

  The plane is a function here: what these tests ask is what the worker does with a
  document once it has one, and the one thing that must never happen — a document
  whose hash is not the announced hash reaching disk — is a property of this module
  alone.
  """

  use ExUnit.Case, async: false

  alias Troupe.Protocol.Bundle
  alias Troupe.Worker.Bundles

  @document %{
    "schema" => 1,
    "agents" => [
      %{
        "name" => "reviewer",
        "definition" => "---\nmode: primary\nskills: [review-checklist]\n---\nYou review."
      }
    ],
    "skills" => [
      %{
        "name" => "review-checklist",
        "description" => "How we review",
        "files" => %{"SKILL.md" => "---\nname: review-checklist\n---\nCheck things."}
      }
    ],
    "mcp_servers" => [
      %{"name" => "jira", "url" => "https://mcp.jira.example/mcp", "tools" => ["get_issue"]}
    ]
  }

  setup do
    unique = System.unique_integer([:positive])
    state_dir = Path.join(System.tmp_dir!(), "troupe-bundles-#{unique}")
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(state_dir) end)

    %{state_dir: state_dir, hash: Bundle.hash(@document)}
  end

  test "an announcement is fetched, verified and written under the state directory", context do
    test = self()

    bundles =
      start(context,
        fetch: fn params ->
          send(test, {:fetched, params})
          {:ok, fetched(@document, context.hash, 3)}
        end
      )

    assert {:ok, applied} = Bundles.announce(bundles, announcement(context))
    assert_received {:fetched, %{"hash" => hash}}
    assert hash == context.hash

    assert applied.hash == context.hash
    assert applied.version == 3
    assert String.starts_with?(applied.dir, Path.join(context.state_dir, "bundles"))

    assert File.read!(Path.join(applied.dir, "agents/reviewer.md")) =~ "You review."
    manifest = Path.join(applied.dir, "skills/review-checklist/SKILL.md")
    assert File.read!(manifest) =~ "Check things."
    assert Jason.decode!(File.read!(Path.join(applied.dir, "bundle.json"))) == @document

    assert %{hash: ^hash, version: 3, channel: "stable"} = Bundles.current(bundles)
    assert Bundles.current_hash() == hash
    assert {:ok, dir} = Bundles.dir_for(bundles, 3)
    assert dir == applied.dir
    assert Bundles.dir_for(bundles, 2) == :error

    # Announced again, nothing is fetched again: the directory is named by hash.
    assert {:ok, _} = Bundles.announce(bundles, announcement(context))
    refute_received {:fetched, _}
  end

  test "a document whose hash is not the announced hash never reaches disk", context do
    tampered = put_in(@document, ["agents"], [])
    bundles = start(context, fetch: fn _ -> {:ok, fetched(tampered, context.hash, 3)} end)

    assert {:error, {:hash_mismatch, expected, actual}} =
             Bundles.announce(bundles, announcement(context))

    assert expected == context.hash
    assert actual == Bundle.hash(tampered)

    assert Bundles.current(bundles) == nil
    assert Bundles.current_hash() == nil
    assert materialised(context) == []
  end

  test "a document that does not validate is refused", context do
    broken = Map.put(@document, "skills", [%{"name" => "no-manifest", "files" => %{}}])
    hash = Bundle.hash(broken)
    bundles = start(context, fetch: fn _ -> {:ok, fetched(broken, hash, 4)} end)
    announced = %{"channel" => "stable", "version" => 4, "bundle_hash" => hash}

    assert {:error, {:invalid_bundle, [message]}} = Bundles.announce(bundles, announced)
    assert message =~ "SKILL.md"
    assert Bundles.current(bundles) == nil
  end

  test "when the fetch fails, inline servers are applied and nothing becomes current", context do
    bundles = start(context, fetch: fn _ -> {:error, :disconnected} end)

    params = Map.put(announcement(context), "mcp_servers", @document["mcp_servers"])
    assert {:fallback, applied} = Bundles.announce(bundles, params)
    assert applied.reason == {:fetch_failed, :disconnected}
    assert Bundles.current(bundles) == nil

    # And without the inline copy there is nothing to fall back to.
    assert {:error, {:fetch_failed, :disconnected}} =
             Bundles.announce(bundles, announcement(context))
  end

  test "a version this pod never saw is fetched for a session, not made current", context do
    # An earlier version with no skill and an agent that does not list one; a version
    # whose agent named a skill it lacked would rightly be refused.
    older =
      @document
      |> Map.put("skills", [])
      |> Map.put("agents", [%{"name" => "reviewer", "definition" => "You review."}])

    older_hash = Bundle.hash(older)

    bundles =
      start(context,
        fetch: fn
          %{"hash" => ^older_hash} -> {:ok, fetched(older, older_hash, 2)}
          _ -> {:ok, fetched(@document, context.hash, 3)}
        end
      )

    assert {:ok, _} = Bundles.announce(bundles, announcement(context))
    pin = %{version: 2, hash: older_hash, channel: "stable"}
    assert {:ok, dir} = Bundles.ensure(bundles, pin)
    assert File.dir?(Path.join(dir, "agents"))
    assert {:ok, ^dir} = Bundles.dir_for(bundles, 2)

    assert Bundles.current(bundles).hash == context.hash
  end

  test "the index survives a restart", context do
    fetch = fn _ -> {:ok, fetched(@document, context.hash, 3)} end
    {id, bundles} = start_named(context, fetch: fetch)
    assert {:ok, _} = Bundles.announce(bundles, announcement(context))
    :ok = stop_supervised(id)
    assert Bundles.current_hash() == nil

    {_id, again} = start_named(context, fetch: fn _ -> {:error, :nothing_should_be_fetched} end)
    assert %{version: 3} = Bundles.current(again)
    assert Bundles.current_hash() == context.hash
    assert {:ok, _} = Bundles.dir_for(again, 3)
  end

  test "current/0 is nil when no registry is running" do
    assert Bundles.current() == nil
    assert Bundles.current_hash() == nil
  end

  defp start(context, opts) do
    {_id, pid} = start_named(context, opts)
    pid
  end

  defp start_named(context, opts) do
    id = {Bundles, System.unique_integer([:positive])}

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Bundles, [name: nil, state_dir: context.state_dir, mcp: nil] ++ opts},
          id: id,
          restart: :temporary
        )
      )

    {id, pid}
  end

  defp announcement(context) do
    %{"channel" => "stable", "version" => 3, "bundle_hash" => context.hash}
  end

  # What the plane answers `bundle.fetch` with.
  defp fetched(content, hash, version) do
    %{"content" => content, "hash" => hash, "channel" => "stable", "version" => version}
  end

  defp materialised(context) do
    context.state_dir |> Path.join("bundles/*") |> Path.wildcard() |> Enum.filter(&File.dir?/1)
  end
end
