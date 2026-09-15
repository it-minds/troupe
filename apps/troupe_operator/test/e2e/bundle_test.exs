defmodule Troupe.E2E.BundleTest do
  @moduledoc """
  A pod fetches its configuration by hash, materialises it once, and a running session
  keeps the version it started on.

  The unit tests prove the plane publishes and the worker unpacks. What only a cluster
  decides is the join: a real pod, told by a real plane over the control channel, writing
  to a real volume — and the *pinning*, which is a promise about a session that outlives
  a publish and cannot be observed in a process that does both.

  Content-addressing is the other half. A bundle is named by the hash of its content, so
  publishing the same document again is the same bundle: the pod must not fetch it twice
  and must not unpack it twice. That is asserted against the directory on the pod's disk,
  not against what the plane believes it sent.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}

  @moduletag :e2e
  @moduletag timeout: 600_000

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Plane.ready!()
  end

  test "a running session keeps its version while the next one moves", context do
    first = Plane.publish!(context.channel, bundle("the first wording"))
    await_bundle(context.profile, first["hash"])

    running = Plane.call!("session.create", %{"profile" => context.profile})
    on_exit(fn -> Plane.call("session.erase", %{"session_id" => running["session_id"]}) end)

    pinned = Plane.call!("session.get", %{"session_id" => running["session_id"]})["bundle_version"]
    assert pinned == first["version"]

    # Published while it runs. This is the case the promise is about: a session whose
    # agent definitions changed underneath it halfway through would be a different
    # session halfway through.
    second = Plane.publish!(context.channel, bundle("the second wording"))
    refute second["hash"] == first["hash"]
    await_bundle(context.profile, second["hash"])

    still = Plane.call!("session.get", %{"session_id" => running["session_id"]})
    assert still["bundle_version"] == pinned, "a running session moved to a new bundle"

    moved = Plane.call!("session.create", %{"profile" => context.profile})
    on_exit(fn -> Plane.call("session.erase", %{"session_id" => moved["session_id"]}) end)

    assert Plane.call!("session.get", %{"session_id" => moved["session_id"]})["bundle_version"] ==
             second["version"]
  end

  test "the same content published twice is materialised once", context do
    content = bundle("published twice, unpacked once")

    first = Plane.publish!(context.channel, content)
    await_bundle(context.profile, first["hash"])

    dir = materialised!(context.profile, first["hash"])
    stamp = World.exec(World.worker_namespace(context.profile), pod(context.profile), ["stat", "-c", "%Y %i", dir])

    # A new *version* of the same *content*. The plane records the publish, the pod is
    # told, and there is nothing for it to do: it already has that hash.
    second = Plane.publish!(context.channel, content)
    assert second["hash"] == first["hash"]
    refute second["version"] == first["version"]

    await_bundle(context.profile, second["hash"])

    # Same directory, same inode, same modification time. Re-unpacking would change the
    # last two, and re-unpacking over a directory a running session is reading from is
    # the failure this is really about.
    assert World.exec(World.worker_namespace(context.profile), pod(context.profile), ["stat", "-c", "%Y %i", dir]) == stamp

    # And exactly one directory for that hash, which is the claim in its plainest form.
    {listing, 0} =
      World.exec(World.worker_namespace(context.profile), pod(context.profile), [
        "sh",
        "-c",
        "ls -1d #{dir} | wc -l"
      ])

    assert String.trim(listing) == "1"
  end

  # -- helpers ----------------------------------------------------------------

  # What the pod says it is carrying, reported to the plane on its heartbeat. Read from
  # the plane because that is where a pod's own claim about itself arrives; the directory
  # below is the independent witness that it did the work.
  defp await_bundle(profile, hash) do
    World.eventually(
      fn ->
        Enum.any?(pods_of(profile), &(&1["bundle_hash"] == hash))
      end,
      timeout: 180_000,
      what: "a pod of #{profile} to carry #{hash}"
    )
  end

  defp materialised!(profile, hash) do
    namespace = World.worker_namespace(profile)
    dir = "/var/lib/troupe/bundles/" <> String.replace(hash, ":", "-")

    World.eventually(
      fn -> match?({_, 0}, World.exec(namespace, pod(profile), ["test", "-f", dir <> "/bundle.json"])) end,
      timeout: 120_000,
      what: "#{dir}/bundle.json on the pod"
    )

    dir
  end

  defp pods_of(profile) do
    Plane.call!("admin.profiles.list")
    |> Enum.find(%{}, &(&1["name"] == profile))
    |> Map.get("pods", [])
  end

  defp pod(profile) do
    World.pod(World.worker_namespace(profile), "app.kubernetes.io/name=troupe-worker")
  end

  # Distinct content, so distinct hash. The prompt is the only thing that varies, which
  # keeps the difference in one place a reader can see.
  defp bundle(prompt) do
    %{
      "version" => 1,
      "agents" => [%{"name" => "build", "description" => "The development agent", "prompt" => prompt}]
    }
  end
end
