defmodule Troupe.E2E.CapacityTest do
  @moduledoc """
  A profile with nothing running has no workers, and the first session brings one up.

  Every part of this is arithmetic in the plane's own suite and none of it is the claim.
  The claim is that the number the plane writes reaches a StatefulSet, that a pod is
  scheduled and enrols, that a session waits and then runs on a worker that did not exist
  a minute earlier — and that the plane can do all of it holding the permission it always
  had, which is `WorkerProfile` and nothing else.

  A profile of its own, deliberately. The suite's shared profile keeps a worker warm so
  that a test about something else never finds the fleet gone; this one is about the fleet
  going, so it owns a profile nobody else uses and takes it away afterwards.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}

  @moduletag :e2e
  @moduletag timeout: 1_200_000

  # The scaler ticks every fifteen seconds; a cold worker then has to be scheduled, bind
  # a volume and fetch a bundle. Generous, because what is under test is that it happens
  # at all rather than how fast — and a timeout tuned to a fast machine is a test that
  # fails on a loaded one and tells nobody anything.
  @cold_start 300_000

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    world = Plane.ready!()
    name = Plane.unique("e2e-cold")

    # The same image the running workers have, and the same channel, so nothing here
    # depends on a registry pull that the shared profile has already made.
    Plane.call!("admin.profile.put", %{
      "profile" =>
        Map.merge(Plane.profile_attrs(name, world.channel), %{
          "size_class" => "standard",
          "warm_workers" => 0
        })
    })

    {:ok, _} = Plane.grant(world.team, name)

    # The operator makes the namespace; what goes in it is somebody else's job on purpose,
    # and a profile created through the console arrives with an empty one. Waited for,
    # because the namespace is the operator's answer to the profile and the two are
    # separate events.
    namespace = World.worker_namespace(name)

    World.eventually(fn -> World.kubectl(["get", "ns", namespace]) |> elem(1) == 0 end,
      timeout: 120_000,
      every: 2_000,
      what: "the operator to make #{namespace}"
    )

    World.secrets!(namespace)

    on_exit(fn ->
      Plane.call("admin.team.revoke", %{
        "name" => world.team,
        "profile" => name,
        "confirm" => name
      })
      Plane.call("admin.profile.delete", %{"name" => name, "confirm" => name})
    end)

    Map.put(world, :cold, name)
  end

  describe "a profile nobody is using" do
    test "has no workers, and the first session brings one up and runs on it", context do
      # Nothing has ever run here, so the scaler takes it to zero after the grace period.
      # Waited for in two steps because they are two facts: the plane writes a number, and
      # Kubernetes acts on it. A pod that is still terminating when the desired count
      # reaches zero is the ordinary case, not a failure.
      World.eventually(fn -> replicas(context.cold) == 0 end,
        timeout: @cold_start,
        every: 5_000,
        what: "#{context.cold} to scale to zero"
      )

      World.eventually(
        fn -> World.pods(World.worker_namespace(context.cold), worker_selector()) == [] end,
        timeout: @cold_start,
        every: 5_000,
        what: "#{context.cold} to have no pods"
      )

      # A session on a cold profile. The honest answer is a session id and no endpoint:
      # there is nowhere to connect to yet, and inventing an address would be worse than
      # saying so.
      created = Plane.call!("session.create", %{"profile" => context.cold})
      session_id = created["session_id"]
      on_exit(fn -> Plane.call("session.erase", %{"session_id" => session_id}) end)

      assert is_binary(session_id)
      assert created["state"] == "pending", "expected a wait, got #{inspect(created)}"
      refute created["endpoint"]
      refute created["token"]

      # The wait is visible and bounded: the client is told how long to leave it, and the
      # session says what it is doing while it waits.
      assert created["retry_after_ms"] > 0
      assert Plane.call!("session.get", %{"session_id" => session_id})["state"] == "pending"

      # And the plane asked. Not "a pod appeared" — the *desired* number in the custom
      # resource is what the plane writes, and the StatefulSet is what acts on it.
      World.eventually(fn -> replicas(context.cold) >= 1 end,
        timeout: @cold_start,
        every: 5_000,
        what: "#{context.cold} to be scaled up"
      )

      # The whole way round: a worker scheduled, enrolled, and the session on it.
      World.eventually(
        fn ->
          case Plane.call("token.mint", %{"session_id" => session_id}) do
            {:ok, %{"endpoint" => endpoint}} -> is_binary(endpoint)
            _still_waiting -> false
          end
        end,
        timeout: @cold_start,
        every: 5_000,
        what: "#{session_id} to be placed on a worker"
      )

      placed = Plane.call!("token.mint", %{"session_id" => session_id})
      assert placed["endpoint"]
      assert placed["token"]

      session = Plane.call!("session.get", %{"session_id" => session_id})
      assert session["state"] == "active"

      # On a pod the API server agrees exists — and one that did not exist when this test
      # started. Two roads to one fact, which is the shape every claim in this suite has.
      pods = World.pods(World.worker_namespace(context.cold), worker_selector())
      assert pods != [], "the plane placed a session on a profile with no pods"
    end
  end

  describe "a ceiling somebody set" do
    test "refuses with the number they set, and nothing above it runs", context do
      # One session at a time, decided by a person. This is the only capacity refusal
      # there is now: a profile with no ceiling grows instead of refusing.
      put(context, %{"max_sessions" => 1})

      first = Plane.call!("session.create", %{"profile" => context.cold})
      on_exit(fn -> Plane.call("session.erase", %{"session_id" => first["session_id"]}) end)

      World.eventually(
        fn -> Plane.call!("session.get", %{"session_id" => first["session_id"]})["state"] == "active" end,
        timeout: @cold_start,
        every: 5_000,
        what: "the first session to be running"
      )

      assert {:error, error} = Plane.call("session.create", %{"profile" => context.cold})
      assert error["message"] == "capacity", inspect(error)

      # The refusal names the decision rather than the machine that noticed it. "Every
      # pod is full, ask your administrator to add replicas" is not something the person
      # in front of it can act on; a number somebody chose is.
      assert error["data"]["max_sessions"] == 1
      assert error["data"]["reason"] =~ "allows 1 session"

      # And nothing was left behind by the refusal.
      running =
        Plane.call!("admin.sessions.list", %{"filter" => %{"profile" => context.cold}})
        |> List.wrap()
        |> Enum.reject(&(&1["state"] == "erased"))

      assert length(running) == 1

      put(context, %{"max_sessions" => nil})
    end
  end

  describe "a size class the cluster policy refuses" do
    test "is refused, and the profile is not changed", context do
      # The development policy allows two CPUs and four gibibytes; `heavy` asks for four
      # and eight. A maximum belongs where the plane cannot write it, and the plane's own
      # check has to be the check admission would make — an approximation that disagreed
      # would be worse than none, because somebody would trust it.
      assert {:error, error} =
               Plane.call("admin.profile.put", %{
                 "profile" =>
                   Map.merge(Plane.profile_attrs(context.cold, context.channel), %{
                     "size_class" => "heavy"
                   })
               })

      assert error["message"] == "invalid_params"

      violations = error["data"]["policy_violations"]
      assert is_list(violations) and violations != [], inspect(error)
      assert Enum.all?(violations, &is_binary/1), inspect(violations)

      # Unchanged, because the refusal came before anything was written.
      assert current_class(context.cold) == "standard"
    end
  end

  describe "the plane's permission" do
    test "is still WorkerProfile and nothing else, after writing replicas", _context do
      # Writing `spec.replicas` is the permission the plane already had for `spec.teams`,
      # so this should be exactly what it was. Asserted rather than assumed: the whole
      # argument for letting the plane scale is that it widens nothing, and an argument
      # nobody checks is a comment.
      for {verb, resource} <- [
            {"create", "pods"},
            {"delete", "pods"},
            {"get", "secrets"},
            {"create", "secrets"},
            {"create", "namespaces"},
            {"delete", "namespaces"},
            {"create", "statefulsets"},
            {"patch", "statefulsets"}
          ] do
        assert can_i(verb, resource) == "no", "the plane may #{verb} #{resource}"
      end

      # And the two it does have, so this is a test of a boundary rather than of a
      # ServiceAccount that has been broken entirely.
      assert can_i("update", "workerprofiles.troupe.dev") == "yes"
      assert can_i("create", "teamvolumes.troupe.dev") == "yes"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp worker_selector, do: "app.kubernetes.io/name=troupe-worker"

  # Whole, never partial. `admin.profile.put` checks what it is given against the cluster
  # policy before writing, and a profile sent without its image is a profile the check has
  # to make up half of.
  defp put(context, changes) do
    Plane.call!("admin.profile.put", %{
      "profile" =>
        Plane.profile_attrs(context.cold, context.channel)
        |> Map.put("warm_workers", 0)
        |> Map.merge(changes)
    })
  end

  defp replicas(profile) do
    World.kubectl!([
      "get",
      "workerprofile",
      profile,
      "-n",
      World.namespace(),
      "-o",
      "jsonpath={.spec.replicas}"
    ])
    |> String.trim()
    |> case do
      "" -> nil
      number -> String.to_integer(number)
    end
  end

  defp current_class(profile) do
    Plane.call!("admin.profile.get", %{"name" => profile})["profile"]["size_class"]
  end

  # As the plane's ServiceAccount, with `--as`, which is what a cluster admin would type.
  # The *last* line, not the first. `kubectl` prints `Warning: resource 'namespaces' is
  # not namespace scoped` ahead of the answer when a cluster-scoped resource is asked
  # about with a namespace — and reading the first line turned that warning into "the
  # plane may create namespaces", which is a frightening sentence about nothing.
  defp can_i(verb, resource) do
    {output, _status} =
      World.kubectl([
        "auth",
        "can-i",
        verb,
        resource,
        "-n",
        World.namespace(),
        "--as",
        "system:serviceaccount:#{World.namespace()}:troupe-plane"
      ])

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "Warning:")))
    |> List.last()
  end
end
