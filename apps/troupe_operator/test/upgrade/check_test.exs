defmodule Troupe.E2E.Upgrade.CheckTest do
  @moduledoc """
  What the previous release was left holding, asked of the release under test.

  The second half of the upgrade check (`scripts/kind-upgrade-check`): run after the CRDs
  were applied and the chart upgraded, with nothing done by hand in between. Each test
  asks for one thing `seed_test.exs` made, through the protocol, and fails where the new
  release lost it, misreads it or needs a person to make it work again.

  In the order they are written (`mix troupe.e2e` runs with `--seed=0`): the cheap
  questions to the plane first, then the ones that need a worker on the new release.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, Upgrade, World}
  alias Troupe.Protocol.PlaneSignature

  @moduletag :e2e
  @moduletag timeout: 1_200_000

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    %{seed: Upgrade.read!()}
  end

  test "the plane says it is the build under test", %{seed: seed} do
    build = Upgrade.build()

    case Upgrade.expected_commit() do
      nil ->
        assert build != seed["from"], "the plane still reports #{inspect(build)}"

      commit ->
        assert build["commit"] == commit,
               "the plane reports #{inspect(build)}; the images under test are #{commit}"
    end
  end

  test "the audit trail still verifies and still has what the seed wrote", %{seed: seed} do
    verified = Plane.call!("admin.audit.verify")
    assert verified["result"] == "ok", "the audit chain does not verify: #{inspect(verified)}"

    rows =
      "admin.audit.list"
      |> Plane.call!(%{"filter" => %{"limit" => 500}})
      |> List.wrap()
      |> Enum.map(&Map.take(&1, ["action", "subject_id"]))

    missing = Enum.reject(seed["audit"], &(Map.take(&1, ["action", "subject_id"]) in rows))
    assert missing == [], "audit rows the seed saw are gone: #{inspect(missing)}"
  end

  test "the team is there with its grant", %{seed: seed} do
    teams = "admin.teams.list" |> Plane.call!() |> List.wrap()
    team = Enum.find(teams, &(&1["name"] == seed["team"]))
    assert team, "no team #{seed["team"]}: #{inspect(teams)}"

    profiles = "admin.profiles.list" |> Plane.call!() |> List.wrap()
    assert Enum.any?(profiles, &(&1["name"] == seed["profile"])), "no profile #{seed["profile"]}"
  end

  test "the client-version policy is still served, signed by the key pinned before", %{seed: seed} do
    policy = seed["client_versions"]
    {:ok, key} = PlaneSignature.read_key(seed["signing_key"])
    answer = Plane.call!("me.client_versions")

    assert get_in(answer, [policy["component"], "recommended"]) == policy["recommended"],
           "the #{policy["component"]} policy changed across the upgrade: #{inspect(answer)}"

    assert {:ok, %{body: body}} = PlaneSignature.verify(answer["signed"], key, "client_versions"),
           "me.client_versions is not signed by the key a client pinned on the previous release"

    assert get_in(body, ["versions", policy["component"], "recommended"]) == policy["recommended"]
  end

  test "the profile is Ready on the new release, its pods replaced by themselves", %{seed: seed} do
    profile = seed["profile"]

    World.eventually(
      fn ->
        conditions = Upgrade.conditions(profile)
        images = Upgrade.pod_images(profile)

        conditions["Ready"] == "True" and conditions["UpgradePending"] != "True" and
          images != [] and Enum.all?(images, &(&1 not in seed["pod_images"]))
      end,
      timeout: 900_000,
      every: 5_000,
      what: "#{profile}'s pods to be replaced on the new release and the profile Ready",
      explain: fn ->
        "conditions #{inspect(Upgrade.conditions(profile))}, pods on " <>
          "#{inspect(Upgrade.pod_images(profile))}, before the upgrade #{inspect(seed["pod_images"])}"
      end
    )

    assert World.worker_image(profile) != seed["worker_image"],
           "the profile follows the release and still names #{seed["worker_image"]}"
  end

  test "the dormant session wakes on the new release and answers a turn", %{seed: seed} do
    session = seed["session"]
    id = session["id"]

    before = Plane.call!("session.get", %{"session_id" => id})
    assert before["state"] == "dormant", inspect(before)
    assert before["head_hash"] == session["head_hash"], "the index lost the session's head"

    Upgrade.placeable!(seed["profile"])
    opened = Plane.call!("session.open", %{"session_id" => id, "mode" => "activate"})
    {client, history} = Upgrade.attach!(opened, id)

    assert Enum.any?(history, &(&1.type == "user_input" and &1.data["text"] == session["said"])),
           "the log read back on the new release does not have the turn the previous one ran"

    assert Enum.any?(history, &(&1.prev_hash == session["head_hash"])),
           "nothing in the restored log continues from #{session["head_hash"]}"

    turn = Upgrade.turn!(client, id, "Upgrade check: a turn on the new release.")
    assert Enum.any?(turn, &(&1.type == "llm_response"))

    now = Plane.call!("session.get", %{"session_id" => id})
    assert now["epoch"] > session["epoch"], "the session woke on the epoch it slept on"
  end

  test "the organisation's memory reaches a new session", %{seed: seed} do
    memory = seed["memory"]
    document = Plane.call!("admin.memory.get", %{"scope" => "organisation"})
    assert document["version"] == memory["version"]
    assert document["text"] == memory["text"]

    Upgrade.placeable!(seed["profile"])
    created = Plane.call!("session.create", %{"profile" => seed["profile"]})
    id = created["session_id"]
    on_exit(fn -> Upgrade.erase(id) end)

    {client, history} = Upgrade.attach!(created, id)
    turn = Upgrade.turn!(client, id, "Upgrade check: what does the organisation say?")

    files =
      (history ++ turn)
      |> Enum.filter(&(&1.type == "instructions_loaded"))
      |> Enum.flat_map(&(&1.data["files"] || []))

    read = Enum.find(files, &(&1["path"] == "memory:organisation"))
    assert read, "the turn read no organisation memory: #{inspect(files)}"
    assert read["version"] in [nil, memory["version"]], inspect(read)
  end

  test "the trigger fires on the key the previous release gave out", %{seed: seed} do
    Upgrade.placeable!(seed["profile"])
    fired = Upgrade.fire!(seed["trigger"], %{"issue" => "UPG-2"})
    assert fired.status == 202, "the trigger's key no longer fires it: #{inspect(fired.body)}"

    id = fired.body["session_id"]
    assert is_binary(id), inspect(fired.body)
    on_exit(fn -> Upgrade.erase(id) end)

    World.eventually(
      fn ->
        case Plane.call("admin.sessions.list", %{}) do
          {:ok, sessions} -> Enum.any?(List.wrap(sessions), &(&1["id"] == id))
          _other -> false
        end
      end,
      timeout: 120_000,
      every: 5_000,
      what: "the trigger's session to appear in the fleet"
    )
  end
end
