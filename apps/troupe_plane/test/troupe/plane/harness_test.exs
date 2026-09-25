defmodule Troupe.Plane.HarnessTest do
  @moduledoc """
  What a person's client may ask the plane, and what it may not learn.

  The done item is about exactness: a user sees exactly their granted profiles and
  exactly the sessions they own, are on the ACL of, or can see through their team — and
  a user in no granted team sees nothing and cannot create. "Exactly" is the whole
  assertion, so every test here sets up sessions the caller must *not* see alongside the
  ones they must.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, Bundles, FakePod, Fleet, Harness, Identity, Principals, Sessions, TeamBudget}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Protocol.SessionId

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &verify/1})

    %{port: Listener.port()}
  end

  describe "me" do
    test "shows the teams and profiles a user actually has" do
      team = team_with_grant("engineering", "dev", name: "engineering")
      _other = team_with_grant("design", "ux", name: "design")
      user = person("ada@example.test", ["engineering"])

      assert {:ok, me} = Harness.call("me", %{}, context(user))
      assert me["subject"] == "ada@example.test"
      assert Enum.map(me["teams"], & &1["name"]) == [team.name]
      assert me["profiles"] == ["dev"]
    end

    test "a user in no enabled team sees nothing" do
      team_with_grant("engineering", "dev", name: "engineering")
      stranger = person("nobody@example.test", [])

      assert {:ok, me} = Harness.call("me", %{}, context(stranger))
      assert me["teams"] == []
      assert me["profiles"] == []

      assert {:ok, %{"profiles" => []}} = Harness.call("profiles.list", %{}, context(stranger))
      assert {:ok, %{"sessions" => []}} = Harness.call("sessions.list", %{}, context(stranger))
    end
  end

  describe "profiles.list" do
    test "lists granted profiles with the pods behind them" do
      team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])

      {:ok, _} = enrol_worker("dev", "troupe-w-dev-0", capacity: 4)
      {:ok, _} = enrol_worker("ux", "troupe-w-ux-0", capacity: 4)

      assert {:ok, %{"profiles" => [profile]}} = Harness.call("profiles.list", %{}, context(user))
      assert profile["name"] == "dev"
      assert profile["capacity"] == 4
      assert [pod] = profile["pods"]
      assert pod["pod"] == "troupe-w-dev-0"

      # The ux pods exist and are not this user's business.
      refute Enum.any?(profile["pods"], &(&1["pod"] == "troupe-w-ux-0"))
    end

    test "a draining pod is listed and counts for nothing: it is out of its Service" do
      team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])

      {:ok, _} = enrol_worker("dev", "troupe-w-dev-0", capacity: 4)
      {:ok, draining} = enrol_worker("dev", "troupe-w-dev-1", capacity: 4)
      {:ok, _} = Fleet.drain(draining)

      assert {:ok, %{"profiles" => [profile]}} = Harness.call("profiles.list", %{}, context(user))
      assert length(profile["pods"]) == 2
      assert profile["capacity"] == 4
      assert profile["healthy_pods"] == 1
      assert Enum.find(profile["pods"], &(&1["pod"] == "troupe-w-dev-1"))["draining"] == true
    end

    test "says what a session on each profile will have" do
      team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])
      {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable"})

      # Nothing published: the built-ins, and nothing else.
      assert {:ok, %{"profiles" => [bare]}} = Harness.call("profiles.list", %{}, context(user))
      assert bare["channel"] == "stable"
      assert bare["bundle_version"] == nil
      assert bare["agents"] == ["build", "plan"]
      assert bare["skills"] == []
      assert bare["mcp_servers"] == []

      {:ok, bundle} =
        Bundles.publish(
          "stable",
          %{
            "schema" => 1,
            "agents" => [
              %{
                "name" => "reviewer",
                "definition" => "---\nmode: primary\nskills: [review]\n---\nReview."
              },
              %{"name" => "helper", "definition" => "You help."}
            ],
            "skills" => [
              %{
                "name" => "review",
                "description" => "How we review",
                "files" => %{
                  "SKILL.md" => "---\nname: review\ndescription: How we review\n---\nCheck."
                }
              }
            ],
            "mcp_servers" => [%{"name" => "jira", "url" => "https://mcp.jira.example/mcp"}]
          },
          announce: false
        )

      assert {:ok, %{"profiles" => [profile]}} = Harness.call("profiles.list", %{}, context(user))
      assert profile["bundle_version"] == bundle.version
      assert profile["bundle_hash"] == bundle.hash
      # The bundle's primary, then the built-ins it does not replace; the subagent is
      # not something a session starts as.
      assert profile["agents"] == ["reviewer", "build", "plan"]
      assert profile["skills"] == [%{"name" => "review", "description" => "How we review"}]
      assert profile["mcp_servers"] == ["jira"]
    end
  end

  describe "sessions.list" do
    test "exactly the ones owned, shared by ACL, or visible through a team" do
      team = team_with_grant("engineering", "dev", name: "engineering")
      ada = person("ada@example.test", ["engineering"])
      grace = person("grace@example.test", ["engineering"])
      stranger = person("nobody@example.test", [])

      mine = session!("s-mine", ada, team, visibility: "private")
      shared = session!("s-shared", grace, team, visibility: "private")
      team_wide = session!("s-team", grace, team, visibility: "team")
      hidden = session!("s-hidden", grace, team, visibility: "private")

      {:ok, _} = Sessions.grant_access(shared.id, ada.subject, "collaborator", grace.subject)

      assert {:ok, %{"sessions" => sessions}} = Harness.call("sessions.list", %{}, context(ada))
      ids = sessions |> Enum.map(& &1["id"]) |> Enum.sort()

      assert ids == Enum.sort([mine.id, shared.id, team_wide.id])
      refute hidden.id in ids

      # And the role each one carries, which is what a client renders from.
      by_id = Map.new(sessions, &{&1["id"], &1})
      assert by_id[mine.id]["your_role"] == "owner"
      assert by_id[shared.id]["your_role"] == "collaborator"
      assert by_id[team_wide.id]["your_role"] == "viewer"

      assert {:ok, %{"sessions" => []}} = Harness.call("sessions.list", %{}, context(stranger))
    end

    test "a session nobody may see is not found rather than forbidden" do
      team = team_with_grant("engineering", "dev", name: "engineering")
      owner = person("grace@example.test", ["engineering"])
      stranger = person("nobody@example.test", [])
      session = session!("s-secret", owner, team, visibility: "private")

      assert {:error, error} =
               Harness.call("session.get", %{"session_id" => session.id}, context(stranger))

      # Whether a session exists is itself something a person who cannot see it should
      # not learn.
      assert error.message == "not_found"
    end
  end

  describe "session.create" do
    test "places the session, pushes it to the pod, and hands back a token", context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])

      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      assert {:ok, result} =
               Harness.call("session.create", %{"profile" => "dev"}, context(user))

      assert result["role"] == "owner"
      assert result["epoch"] == 1
      assert result["pod"] == "troupe-w-dev-0"
      assert is_binary(result["token"])

      # The pod was actually told, with the session's identity and its epoch.
      assert_receive {:pushed, "session.activate", params}, 5_000
      assert params["session_id"] == result["session_id"]
      assert params["team"] == team.name
      assert params["epoch"] == 1
      assert params["owner_subject"] == "ada@example.test"

      session = Sessions.get(result["session_id"])
      assert session.state == "active"
      assert session.worker_id == pod.worker_id
    end

    test "the pod is given a pin it can redeem, not just a version number", context do
      team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])
      {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable"})

      {:ok, bundle} =
        Bundles.publish(
          "stable",
          %{"schema" => 1, "agents" => [%{"name" => "reviewer", "definition" => "Review."}]},
          announce: false
        )

      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      assert {:ok, _result} =
               Harness.call("session.create", %{"profile" => "dev"}, context(user))

      assert_receive {:pushed, "session.activate", params}, 5_000

      # A version number is not a pin. A pod asks the plane for a bundle by hash, or by
      # channel *and* version, so a create that sent only the version handed the pod
      # something it could not redeem — and a pod that cannot get its bundle refuses the
      # session. This is exactly what waking a session already sends.
      assert params["bundle_version"] == bundle.version
      assert params["bundle_hash"] == bundle.hash
      assert params["channel"] == "stable"

      # And the round trip answers. Asserting the keys alone would still pass if the two
      # sides disagreed about what a pin looks like, which is the mistake being fixed.
      asked = %{
        "hash" => params["bundle_hash"],
        "channel" => params["channel"],
        "version" => params["bundle_version"]
      }

      assert %{"result" => fetched} =
               pod_asks(context.port, "dev-token", "troupe-w-dev-1", "bundle.fetch", asked)

      assert fetched["hash"] == bundle.hash
      assert fetched["version"] == bundle.version
      assert fetched["channel"] == "stable"
    end

    test "an id the caller brings has the shape the plane's own have, or nothing is placed",
         context do
      team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      # The pod makes a directory of the id: a path, a pattern or a separator in its
      # place is refused before a row exists or a pod hears of it.
      for bad <- ["../escape", "a/b", "*", "", "20260923T101112-q3Vx_A/..", 42] do
        params = %{"profile" => "dev", "session_id" => bad}

        assert {:error, error} = Harness.call("session.create", params, context(user)),
               "#{inspect(bad)} was accepted"

        assert error.message == "invalid_params"
        assert error.data.field == "session_id"
      end

      refute_received {:pushed, "session.activate", _params}
      assert {:ok, %{"sessions" => []}} = Harness.call("sessions.list", %{}, context(user))

      # One of the right shape becomes the session's id, and none at all gets one made.
      brought = SessionId.generate()
      params = %{"profile" => "dev", "session_id" => brought}
      assert {:ok, %{"session_id" => ^brought}} = Harness.call("session.create", params, context(user))

      assert {:ok, %{"session_id" => generated}} =
               Harness.call("session.create", %{"profile" => "dev"}, context(user))

      assert SessionId.valid?(generated)
    end

    test "a user with no grant on the profile cannot create" do
      team_with_grant("engineering", "dev", name: "engineering")
      stranger = person("nobody@example.test", [])

      assert {:error, error} =
               Harness.call("session.create", %{"profile" => "dev"}, context(stranger))

      assert error.message == "forbidden"
    end

    test "with no pod to put it on, nothing is left behind" do
      team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])

      assert {:error, error} =
               Harness.call("session.create", %{"profile" => "dev"}, context(user))

      # Not `capacity`: the plane has no record of this profile at all, so it cannot know
      # a ceiling and cannot ask for a worker. "Every pod is full" would send somebody to
      # look for pods that were never there.
      assert error.message == "unavailable"
      assert error.data.component == "profile"

      # The row went with the failure: a session that never started is not a session,
      # and leaving it would put a phantom in everybody's listing.
      assert {:ok, %{"sessions" => []}} = Harness.call("sessions.list", %{}, context(user))
    end

    test "a user in two teams that both grant the profile is asked which" do
      team_with_grant("engineering", "dev", name: "engineering")
      team_with_grant("research", "dev", name: "research")
      user = person("ada@example.test", ["engineering", "research"])

      assert {:error, error} =
               Harness.call("session.create", %{"profile" => "dev"}, context(user))

      assert error.message == "invalid_params"
      assert Enum.sort(error.data.teams) == ["engineering", "research"]
    end
  end

  describe "session.open" do
    test "read mode never activates the session", context do
      team = team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      session = session!("s-asleep", user, team, state: "dormant")

      assert {:ok, result} =
               Harness.call(
                 "session.open",
                 %{"session_id" => session.id, "mode" => "read"},
                 context(user)
               )

      assert result["mode"] == "read"
      assert is_binary(result["token"])

      # Still asleep, still epoch 1. A session that woke up because somebody looked at
      # it would never stay dormant.
      assert Sessions.get(session.id).state == "dormant"
      assert Sessions.get(session.id).epoch == 1
      refute_receive {:pushed, "session.activate", _}, 500
    end

    test "activate bumps the epoch exactly once, however many ask", context do
      team = team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      session = session!("s-waking", user, team, state: "dormant")

      results =
        1..6
        |> Task.async_stream(
          fn _ ->
            Harness.call(
              "session.open",
              %{"session_id" => session.id, "mode" => "activate"},
              context(user)
            )
          end,
          max_concurrency: 6,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Sessions.get(session.id).epoch == 2
      assert results |> Enum.map(fn {:ok, r} -> r["epoch"] end) |> Enum.uniq() == [2]
    end

    test "a pod that cannot put the tree back parks the session read-only, and the next open says so",
         context do
      team = team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])

      gone = %{
        "code" => -32_005,
        "message" => "not_found",
        "data" => %{"reason" => "workspace_gone", "detail" => "/var/lib/troupe/erased"}
      }

      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0", refuse: %{"session.activate" => gone})
      session = session!("s-erased", user, team, state: "dormant")

      assert {:error, error} =
               Harness.call("session.open", %{"session_id" => session.id, "mode" => "activate"}, context(user))

      assert error.message == "forbidden"
      assert error.data.reason =~ "workspace is gone"
      assert_receive {:pushed, "session.activate", _}, 5_000

      parked = Sessions.get(session.id)
      assert parked.state == "read_only"
      assert is_nil(parked.worker_id)

      # The next open is refused before any pod is asked.
      assert {:error, %{message: "forbidden"}} =
               Harness.call("session.open", %{"session_id" => session.id, "mode" => "activate"}, context(user))

      refute_receive {:pushed, "session.activate", _}, 200
    end

    test "a read-only session cannot be activated", context do
      team = team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      session = session!("s-frozen", user, team, state: "read_only")

      assert {:error, error} =
               Harness.call(
                 "session.open",
                 %{"session_id" => session.id, "mode" => "activate"},
                 context(user)
               )

      assert error.message == "forbidden"

      # Reads still work, which is what read-only means.
      assert {:ok, %{"mode" => "read"}} =
               Harness.call(
                 "session.open",
                 %{"session_id" => session.id, "mode" => "read"},
                 context(user)
               )
    end
  end

  describe "pins" do
    test "an owner may pin and unpin; a viewer may not" do
      team = team_with_grant("engineering", "dev", name: "engineering")
      owner = person("ada@example.test", ["engineering"])
      watcher = person("grace@example.test", ["engineering"])
      session = session!("s-pinned", owner, team, visibility: "team")

      assert {:ok, pinned} =
               Harness.call("session.pin", %{"session_id" => session.id}, context(owner))

      assert pinned["pinned"]
      assert Sessions.get(session.id).pinned_by == "ada@example.test"

      assert {:error, error} =
               Harness.call("session.pin", %{"session_id" => session.id}, context(watcher))

      assert error.message == "forbidden"

      assert {:ok, unpinned} =
               Harness.call("session.unpin", %{"session_id" => session.id}, context(owner))

      refute unpinned["pinned"]
    end
  end

  describe "session.archive" do
    # The fake pod answers the push and reports nothing, which is also what a pod whose
    # tree had already stopped does; the plane gives the row back itself. A real pod's own
    # report of its dormancy, ahead of its answer, is `plane_link_test.exs` in the worker.
    test "the owner's puts a running session to sleep on its pod, gives back what it held, and is audited",
         context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 1_000_000)
      owner = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      params = %{"profile" => "dev", "terms" => %{"budget_micros" => 1_000_000}}
      assert {:ok, %{"session_id" => id}} = Harness.call("session.create", params, context(owner))
      assert_receive {:pushed, "session.activate", _}, 5_000
      assert TeamBudget.inspect_state(team).reserved_micros == 1_000_000

      assert {:ok, archived} =
               Harness.call("session.archive", %{"session_id" => id}, context(owner))

      assert_receive {:pushed, "session.dormant", %{"session_id" => ^id}}, 5_000
      assert archived["id"] == id
      assert archived["state"] == "dormant"
      assert Sessions.get(id).worker_id == nil
      assert TeamBudget.inspect_state(team).reserved_micros == 0

      assert [event] = Audit.list(kind: "session", subject_id: id)
      assert event.action == "session.archive"
      assert event.actor == owner.subject
      assert event.detail["pod"] == "troupe-w-dev-0"
    end

    test "is the owner's: a collaborator is refused and a stranger is not told it exists",
         context do
      team = team_with_grant("engineering", "dev", name: "engineering")
      owner = person("ada@example.test", ["engineering"])
      watcher = person("grace@example.test", ["engineering"])
      stranger = person("eve@example.test", [])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      session = session!("s-running", owner, team, visibility: "team")

      assert {:error, error} =
               Harness.call("session.archive", %{"session_id" => session.id}, context(watcher))

      assert error.message == "forbidden"

      assert {:error, error} =
               Harness.call("session.archive", %{"session_id" => session.id}, context(stranger))

      assert error.message == "not_found"

      refute_receive {:pushed, "session.dormant", _}, 200
      assert Sessions.get(session.id).state == "active"
      assert Audit.list(kind: "session", subject_id: session.id) == []
    end

    test "a session asleep already is answered as it is; one not on a pod yet is refused",
         context do
      team = team_with_grant("engineering", "dev", name: "engineering")
      owner = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      asleep = session!("s-asleep", owner, team, state: "dormant")

      assert {:ok, %{"state" => "dormant"}} =
               Harness.call("session.archive", %{"session_id" => asleep.id}, context(owner))

      waiting = session!("s-waiting", owner, team, state: "pending")

      assert {:error, error} =
               Harness.call("session.archive", %{"session_id" => waiting.id}, context(owner))

      assert error.message == "conflict"
      assert Sessions.get(waiting.id).state == "pending"

      refute_receive {:pushed, "session.dormant", _}, 200
      assert Audit.list(kind: "session", subject_id: asleep.id) == []
      assert Audit.list(kind: "session", subject_id: waiting.id) == []
    end

    test "a pod that does not put it to sleep leaves it running, and nothing is audited",
         context do
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      owner = person("ada@example.test", ["engineering"])

      FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0",
        refuse: %{"session.dormant" => %{"code" => -32_603, "message" => "internal_error"}}
      )

      assert {:ok, %{"session_id" => id}} =
               Harness.call("session.create", %{"profile" => "dev"}, context(owner))

      assert {:error, error} =
               Harness.call("session.archive", %{"session_id" => id}, context(owner))

      assert error.message == "unavailable"
      assert_receive {:pushed, "session.dormant", %{"session_id" => ^id}}, 5_000

      session = Sessions.get(id)
      assert session.state == "active"
      assert session.worker_id
      assert Audit.list(kind: "session", subject_id: id) == []
    end
  end

  describe "session.erase" do
    test "erasing a running session gives its pod slot back", context do
      team_with_grant("engineering", "dev", name: "engineering")
      owner = person("ada@example.test", ["engineering"])
      %{worker_id: pod} = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      [erased, _kept] =
        for _n <- 1..2 do
          assert {:ok, %{"session_id" => id}} =
                   Harness.call("session.create", %{"profile" => "dev"}, context(owner))

          id
        end

      assert placement("dev").capacities[pod] == 2

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => erased}, context(owner))

      assert_receive {:pushed, "session.erase", %{"session_id" => ^erased}}, 5_000

      # The row was made read-only first, which cleared the `worker_id` the release gives
      # the slot back by.
      assert placement("dev").capacities[pod] == 1
    end
  end

  describe "session.create carries the first turn" do
    test "prompt, terms and origin reach the pod; the row keeps all but the prompt", context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      params = %{
        "profile" => "dev",
        "prompt" => "update every dependency with a patch release",
        "terms" => %{"max_turns" => 25, "wall_clock_seconds" => 3600, "approvals" => "deny"},
        "origin" => %{"kind" => "trigger", "trigger" => "nightly-deps", "run" => "r-1"}
      }

      assert {:ok, result} = Harness.call("session.create", params, context(user))

      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["prompt"] == "update every dependency with a patch release"

      assert pushed["terms"] == %{
               "max_turns" => 25,
               "wall_clock_seconds" => 3600,
               "approvals" => "deny"
             }

      assert pushed["origin"] == %{
               "kind" => "trigger",
               "trigger" => "nightly-deps",
               "run" => "r-1"
             }

      assert pushed["team"] == team.name

      session = Sessions.get(result["session_id"])

      assert session.terms == %{
               "max_turns" => 25,
               "wall_clock_seconds" => 3600,
               "approvals" => "deny"
             }

      assert session.origin == %{"kind" => "trigger", "trigger" => "nightly-deps", "run" => "r-1"}

      # The prompt is session content. It went to the pod and is nowhere in this row.
      refute session |> Map.from_struct() |> inspect() =~ "patch release"

      # And the listing says what started it.
      assert {:ok, listed} =
               Harness.call("session.get", %{"session_id" => session.id}, context(user))

      assert listed["origin"]["kind"] == "trigger"
      assert listed["terms"]["approvals"] == "deny"
      assert listed["status"] == "idle"
    end

    test "with nothing said, the defaults are a person waiting on approvals", context do
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      assert {:ok, result} = Harness.call("session.create", %{"profile" => "dev"}, context(user))

      assert_receive {:pushed, "session.activate", pushed}, 5_000
      refute Map.has_key?(pushed, "prompt")
      assert pushed["terms"] == %{"approvals" => "wait"}
      assert pushed["origin"] == %{"kind" => "user"}

      session = Sessions.get(result["session_id"])
      assert session.origin == %{"kind" => "user"}
    end

    test "a bad term is refused before anything is placed", context do
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      for terms <- [
            %{"approvals" => "auto"},
            %{"max_turns" => 0},
            %{"max_turns" => 501},
            %{"wall_clock_seconds" => 5},
            %{"budget" => 1},
            "cheap"
          ] do
        assert {:error, error} =
                 Harness.call(
                   "session.create",
                   %{"profile" => "dev", "terms" => terms},
                   context(user)
                 )

        assert error.message == "invalid_params", "#{inspect(terms)} was accepted"
      end

      assert {:error, error} =
               Harness.call(
                 "session.create",
                 %{"profile" => "dev", "origin" => %{"kind" => "robot"}},
                 context(user)
               )

      assert error.message == "invalid_params"

      too_long = String.duplicate("x", 65_537)

      assert {:error, error} =
               Harness.call(
                 "session.create",
                 %{"profile" => "dev", "prompt" => too_long},
                 context(user)
               )

      assert error.message == "payload_too_large"

      refute_receive {:pushed, "session.activate", _}, 200
      assert {:ok, %{"sessions" => []}} = Harness.call("sessions.list", %{}, context(user))
    end

    test "a budget slice is trimmed to what the team has left", context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 1_000_000)
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      params = %{"profile" => "dev", "terms" => %{"budget_micros" => 5_000_000}}
      assert {:ok, result} = Harness.call("session.create", params, context(user))

      assert Sessions.get(result["session_id"]).terms["budget_micros"] == 1_000_000
      assert TeamBudget.inspect_state(team).reserved_micros == 1_000_000

      # Nothing left: the next one is refused, and refused before it is placed.
      assert {:error, error} = Harness.call("session.create", params, context(user))
      assert error.message == "budget_exhausted"
    end
  end

  describe "session.fork" do
    test "is a create with a lineage: its own row, its own budget, the parent's team", context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      parent = sealed_parent(user, team, 40)

      assert {:ok, result} =
               Harness.call(
                 "session.fork",
                 %{"session_id" => parent.id, "seq" => 12, "reason" => "branch"},
                 context(user)
               )

      child = Sessions.get(result["session_id"])
      refute child.id == parent.id

      # The three columns that make it a fork, and nothing else about it is special: its
      # own id, its own epoch, its own key path, placed like anything else.
      assert child.parent_session_id == parent.id
      assert child.parent_seq == 12
      assert child.fork_reason == "branch"
      assert child.team_id == team.id
      assert child.profile == parent.profile
      assert child.epoch == 1
      assert child.last_seq == 0
    end

    test "tells the pod what to copy, and the pod is the only thing that reads a log",
         context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      parent = sealed_parent(user, team, 40)

      assert {:ok, _} =
               Harness.call(
                 "session.fork",
                 %{"session_id" => parent.id, "seq" => 12},
                 context(user)
               )

      assert_receive {:pushed, "session.activate", pushed}, 5_000

      assert pushed["fork"] == %{
               "parent" => parent.id,
               "parent_team" => team.name,
               "seq" => 12,
               "reason" => "attempt"
             }

      # The instruction names a session and a number. There is no event in it, and there
      # could not be: the plane has never held a key.
      refute pushed |> inspect() =~ "user_input"
    end

    test "at no seq is the parent's last seal, written down rather than left to drift",
         context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      parent = sealed_parent(user, team, 40)

      assert {:ok, result} =
               Harness.call("session.fork", %{"session_id" => parent.id}, context(user))

      assert Sessions.get(result["session_id"]).parent_seq == 40

      # And the parent going on talking does not move it. "Forked at the head" would have.
      {:ok, _} = Sessions.seal(parent.id, %{last_seq: 55})
      assert Sessions.get(result["session_id"]).parent_seq == 40
    end

    test "refuses a point the parent has not sealed", context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      parent = sealed_parent(user, team, 40)

      assert {:error, error} =
               Harness.call(
                 "session.fork",
                 %{"session_id" => parent.id, "seq" => 41},
                 context(user)
               )

      assert error.data.sealed_through == 40
    end

    test "needs control of the parent, not a view of it", context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      ada = person("ada@example.test", ["engineering"])
      bea = person("bea@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      parent = sealed_parent(ada, team, 40, visibility: "team")

      # bea can read every word of it through the team, and that is not enough. A fork is
      # a copy she would own, under her own key, outliving the original's erasure.
      assert {:ok, _} = Harness.call("session.get", %{"session_id" => parent.id}, context(bea))

      assert {:error, error} =
               Harness.call("session.fork", %{"session_id" => parent.id}, context(bea))

      assert error.message == "forbidden"
      assert error.data.reason =~ "control"

      # Let her in properly and it goes through.
      {:ok, _} =
        Harness.call(
          "session.grant",
          %{"session_id" => parent.id, "subject" => bea.subject, "role" => "collaborator"},
          context(ada)
        )

      assert {:ok, _} = Harness.call("session.fork", %{"session_id" => parent.id}, context(bea))
    end

    test "refuses a reason nobody defined, and a session nobody may see", context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      ada = person("ada@example.test", ["engineering"])
      stranger = person("nobody@example.test", [])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      parent = sealed_parent(ada, team, 40)

      assert {:error, bad} =
               Harness.call(
                 "session.fork",
                 %{"session_id" => parent.id, "reason" => "vibes"},
                 context(ada)
               )

      assert bad.message == "invalid_params"

      # Not-found rather than forbidden: whether a session exists is itself something
      # somebody who cannot see it should not learn.
      assert {:error, hidden} =
               Harness.call("session.fork", %{"session_id" => parent.id}, context(stranger))

      assert hidden.message == "not_found"
    end

    test "a lineage is not a client's to claim", context do
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      ada = person("ada@example.test", ["engineering"])
      mallory = person("mal@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      parent = sealed_parent(ada, Identity.get_team("engineering"), 40)

      # A create carrying a `fork` block of its own would be a create that walked off with
      # somebody else's history. The block is stripped at the door, so this is a plain
      # create and the row says so.
      assert {:ok, result} =
               Harness.call(
                 "session.create",
                 %{
                   "profile" => "dev",
                   "fork" => %{"parent" => parent.id, "seq" => 40, "reason" => "attempt"}
                 },
                 context(mallory)
               )

      child = Sessions.get(result["session_id"])
      assert is_nil(child.parent_session_id)
      assert is_nil(child.parent_seq)
      assert is_nil(child.fork_reason)

      assert_receive {:pushed, "session.activate", pushed}, 5_000
      refute Map.has_key?(pushed, "fork")
    end

    test "a private session forks as an import, from the device that holds its key",
         context do
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      {:ok, private} =
        Sessions.create(%{
          id: "private-" <> to_string(System.unique_integer([:positive])),
          owner_id: user.id,
          owner_subject: user.subject,
          kind: "private",
          visibility: "private",
          state: "active",
          epoch: 1,
          last_seq: 9
        })

      assert {:error, error} =
               Harness.call(
                 "session.fork",
                 %{"session_id" => private.id, "reason" => "branch"},
                 context(user)
               )

      assert error.data.reason =~ "import"

      # And an import with no profile is refused rather than guessed at: a private session
      # has none to inherit, because it was never placed anywhere.
      assert {:error, no_profile} =
               Harness.call(
                 "session.fork",
                 %{"session_id" => private.id, "reason" => "import", "team" => "engineering"},
                 context(user)
               )

      assert no_profile.data.reason =~ "profile"

      # As an import it is a real create, and the pod is told nothing: a private session's
      # key is under a path no pod role covers, so no pod could read the parent. The row
      # carries the lineage and the copy belongs to the machine that holds the key.
      assert {:ok, result} =
               Harness.call(
                 "session.fork",
                 %{
                   "session_id" => private.id,
                   "reason" => "import",
                   "team" => "engineering",
                   "profile" => "dev"
                 },
                 context(user)
               )

      child = Sessions.get(result["session_id"])
      assert child.parent_session_id == private.id
      assert child.fork_reason == "import"
      assert child.kind == "team"
      assert child.visibility == "team"

      assert_receive {:pushed, "session.activate", pushed}, 5_000
      refute Map.has_key?(pushed, "fork")
    end
  end

  describe "a share and the pod holding the session" do
    test "the pod is told, by id, with no secret in what crosses the wire", context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      user = person("ada@example.test", ["engineering"])
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      {:ok, created} =
        Harness.call("session.create", %{"profile" => "dev"}, context(user))

      session_id = created["session_id"]
      assert_receive {:pushed, "session.activate", _activated}, 5_000

      assert {:ok, share} =
               Harness.call(
                 "session.share",
                 %{"session_id" => session_id, "role" => "observe"},
                 context(user)
               )

      # The pod appends the durable event; this is the instruction that asks it to. It
      # names the share and never the secret — a log outlives the session, and a working
      # credential in one is a credential nobody can revoke by revoking the share.
      assert_receive {:pushed, "share.changed", minted}, 5_000
      assert minted["type"] == "share_created"
      assert minted["session_id"] == session_id
      assert minted["share"]["id"] == share["id"]
      assert minted["share"]["role"] == "observe"
      refute minted |> inspect() =~ share["secret"]

      assert {:ok, _revoked} =
               Harness.call(
                 "session.share.revoke",
                 %{"session_id" => session_id, "share" => share["id"]},
                 context(user)
               )

      assert_receive {:pushed, "share.changed", ended}, 5_000
      assert ended["type"] == "share_revoked"
      assert ended["share"]["id"] == share["id"]

      assert pod.worker_id
      assert team.name == "engineering"
    end
  end

  describe "sessions.list filters" do
    test "by status, origin, trigger and what still needs a review" do
      team = team_with_grant("engineering", "dev", name: "engineering")
      ada = person("ada@example.test", ["engineering"])

      mine = session!("s-mine", ada, team, [])

      nightly =
        session!("s-nightly", ada, team,
          origin: %{"kind" => "trigger", "trigger" => "nightly"},
          status: "done"
        )

      triage =
        session!("s-triage", ada, team,
          origin: %{"kind" => "trigger", "trigger" => "triage"},
          status: "waiting"
        )

      {:ok, _} = Sessions.review(triage.id, ada.subject)

      list = fn params ->
        {:ok, %{"sessions" => sessions}} = Harness.call("sessions.list", params, context(ada))
        sessions |> Enum.map(& &1["id"]) |> Enum.sort()
      end

      assert list.(%{"origin" => "trigger"}) == Enum.sort([nightly.id, triage.id])
      assert list.(%{"origin" => "user"}) == [mine.id]
      assert list.(%{"trigger" => "nightly"}) == [nightly.id]
      assert list.(%{"status" => "waiting"}) == [triage.id]
      assert list.(%{"status" => ["done", "waiting"]}) == Enum.sort([nightly.id, triage.id])
      assert list.(%{"needs_review" => true}) == [nightly.id]
    end
  end

  describe "session.grant" do
    test "an owner lets somebody in, and the pod holding the session is told", context do
      _team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      ada = person("ada@example.test", ["engineering"])
      grace = person("grace@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      {:ok, created} = Harness.call("session.create", %{"profile" => "dev"}, context(ada))
      assert_receive {:pushed, "session.activate", _}, 5_000
      session = Sessions.get(created["session_id"])

      assert {:error, error} =
               Harness.call("session.get", %{"session_id" => session.id}, context(grace))

      assert error.message == "not_found"

      params = %{"session_id" => session.id, "subject" => grace.subject, "role" => "collaborator"}
      assert {:ok, granted} = Harness.call("session.grant", params, context(ada))
      assert granted["role"] == "collaborator"
      assert granted["pushed"]

      assert_receive {:pushed, "acl.changed", %{"changes" => [change]}}, 5_000

      assert change == %{
               "session_id" => session.id,
               "subject" => grace.subject,
               "role" => "collaborator"
             }

      assert {:ok, seen} =
               Harness.call("session.get", %{"session_id" => session.id}, context(grace))

      assert seen["your_role"] == "collaborator"

      # A collaborator is not an owner, and may not pass the session on.
      params = %{"session_id" => session.id, "subject" => "nobody@example.test"}
      assert {:error, error} = Harness.call("session.grant", params, context(grace))
      assert error.message == "forbidden"
    end

    test "a team admin may let somebody in to a private session of their team" do
      team = team_with_grant("engineering", "dev", name: "engineering")
      owner = person("svc-like@example.test", ["engineering"])
      lead = person("lead@example.test", ["engineering"])
      reviewer = person("grace@example.test", ["engineering"])
      {:ok, _} = Identity.add_team_admin(team, lead.subject, "root@example.test")

      session = session!("s-private", owner, team, state: "dormant")

      params = %{"session_id" => session.id, "subject" => reviewer.subject, "role" => "viewer"}
      assert {:ok, granted} = Harness.call("session.grant", params, context(lead))
      refute granted["pushed"]
      assert Sessions.role_for(reviewer, session) == :observe
    end
  end

  describe "session.review" do
    test "records who looked, and audits it" do
      team = team_with_grant("engineering", "dev", name: "engineering")
      ada = person("ada@example.test", ["engineering"])

      session =
        session!("s-run", ada, team, origin: %{"kind" => "trigger", "trigger" => "nightly"})

      assert {:ok, reviewed} =
               Harness.call("session.review", %{"session_id" => session.id}, context(ada))

      assert reviewed["reviewed_by"] == ada.subject
      assert reviewed["reviewed_at"]

      assert {:ok, %{"sessions" => []}} =
               Harness.call("sessions.list", %{"needs_review" => true}, context(ada))

      assert [event] = Audit.list(kind: "session", subject_id: session.id)
      assert event.action == "session.review"
      assert event.actor == ada.subject
    end
  end

  describe "a service principal" do
    test "creates on its profile as itself, and is forbidden everywhere else", context do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      {:ok, _} = Identity.grant(team, "ux")

      {:ok, principal, _secret} =
        principal!(team, %{name: "nightly", profiles: ["dev"]})

      robot = Identity.get_user(principal.subject)
      assert robot.kind == "service"

      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      assert {:ok, me} = Harness.call("me", %{}, context(robot))
      assert me["kind"] == "service"
      assert Enum.map(me["teams"], & &1["name"]) == ["engineering"]
      assert me["profiles"] == ["dev"]

      assert {:ok, created} =
               Harness.call(
                 "session.create",
                 %{"profile" => "dev", "prompt" => "go"},
                 context(robot)
               )

      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["owner_subject"] == "svc:engineering/nightly"
      assert Sessions.get(created["session_id"]).owner_subject == "svc:engineering/nightly"

      # The team is granted ux; the principal is not.
      assert {:error, error} =
               Harness.call("session.create", %{"profile" => "ux"}, context(robot))

      assert error.message == "forbidden"

      # And it sees its own sessions, like anybody.
      assert {:ok, %{"sessions" => [own]}} = Harness.call("sessions.list", %{}, context(robot))
      assert own["your_role"] == "owner"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp context(user), do: %{user: user, platform_admin?: false}

  defp session!(id, owner, team, opts) do
    {:ok, session} =
      Sessions.create(
        %{
          id: id <> "-#{System.unique_integer([:positive])}",
          owner_id: owner.id,
          owner_subject: owner.subject,
          team_id: team.id,
          profile: Keyword.get(opts, :profile, "dev"),
          visibility: Keyword.get(opts, :visibility, "private"),
          state: Keyword.get(opts, :state, "active"),
          epoch: 1
        }
        |> Map.merge(Map.new(Keyword.take(opts, [:origin, :status, :done_reason])))
      )

    session
  end

  # A parent with a history the plane can see: a row that has sealed through `seq`. The
  # events themselves are in object storage under a key the plane does not have, which is
  # exactly the situation `session.fork` has to work in.
  defp sealed_parent(user, team, seq, opts \\ []) do
    session = session!("parent", user, team, Keyword.put_new(opts, :visibility, "private"))
    {:ok, sealed} = Sessions.seal(session.id, %{last_seq: seq, head_hash: "sha256:whatever"})
    sealed
  end

  defp enrol_worker(profile, pod_name, opts) do
    Fleet.enrol(%{
      profile: profile,
      namespace: "troupe-w-#{profile}",
      pod_name: pod_name,
      ordinal: pod_name |> String.split("-") |> List.last() |> String.to_integer(),
      endpoint: "https://0.#{profile}.workers.example.test",
      capacity: Keyword.get(opts, :capacity, 4),
      disk_total_bytes: 1_000_000
    })
  end

  # What the placement actor holds, without the reload `Placement.inspect_state/1` does
  # first, which would hide a slot that was never given back.
  defp placement(profile) do
    :sys.get_state(:global.whereis_name({Troupe.Plane.Placement, profile}))
  end

  # A worker that enrols for real over the control channel and forwards every push to
  # the test process, so the assertions are about what actually crossed the wire.
  defp fake_pod(port, token, pod_name) do
    test = self()
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "enrol",
        "params" => %{
          "token" => token,
          "pod_name" => pod_name,
          "capacity" => 4,
          "disk_total_bytes" => 1_000_000
        }
      })

    :ok = :gen_tcp.send(socket, [request, ?\n])
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)

    %{"result" => result} =
      line |> String.split("\n", trim: true) |> List.first() |> Jason.decode!()

    pid =
      spawn_link(fn ->
        :inet.setopts(socket, active: true)
        serve(socket, test)
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(socket) end)

    %{worker_id: result["worker_id"], socket: socket}
  end

  # A pod that asks the plane something and waits for the answer, rather than one that
  # only receives. Everything the plane pushes goes through `fake_pod`; this is the other
  # direction, which is how a pod gets its bundle.
  defp pod_asks(port, token, pod_name, method, params) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    enrol =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "enrol",
        "params" => %{
          "token" => token,
          "pod_name" => pod_name,
          "capacity" => 4,
          "disk_total_bytes" => 1_000_000
        }
      })

    :ok = :gen_tcp.send(socket, [enrol, ?\n])
    {:ok, enrolled} = :gen_tcp.recv(socket, 0, 5_000)

    ask = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    :ok = :gen_tcp.send(socket, [ask, ?\n])
    answer = await_answer(socket, 1, enrolled)
    :gen_tcp.close(socket)

    answer
  end

  # The plane starts pushing the moment a pod enrols - `jwks.updated` is on its way
  # before the ask is even written - so the next frame down the socket is not
  # necessarily the answer to it. Read until the frame carrying this id arrives;
  # anything else on the way is the other direction and none of this function's
  # business. Taking whatever arrived first made this a race, and it lost in
  # `bundle.fetch`, which had nothing to do with it.
  # An *answer*, which is not the same thing as a frame carrying this id. JSON-RPC ids
  # are per direction: the plane numbers its own requests from one too, and it pushes
  # `session.index` at a pod the moment it enrols — so matching on the id alone matched
  # the plane's question and read it as the reply to ours. A response has no `method`.
  defp await_answer(socket, id, buffer) do
    {frames, rest} = split_frames(buffer)

    case Enum.find(frames, &response?(&1, id)) do
      nil ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        await_answer(socket, id, rest <> data)

      answer ->
        answer
    end
  end

  defp response?(%{"id" => id, "method" => _asking}, id), do: false
  defp response?(%{"id" => id}, id), do: true
  defp response?(_frame, _id), do: false

  # Newline-delimited JSON, and a read can end mid-frame; the trailing fragment goes
  # back on the buffer rather than through `Jason.decode!/1`.
  defp split_frames(buffer) do
    {complete, [rest]} = buffer |> String.split("\n") |> Enum.split(-1)
    {Enum.map(complete, &Jason.decode!/1), rest}
  end

  defp serve(socket, test) do
    receive do
      {:tcp, ^socket, data} ->
        for line <- String.split(data, "\n", trim: true) do
          case Jason.decode(line) do
            {:ok, %{"id" => id, "method" => method, "params" => params}} ->
              send(test, {:pushed, method, params})

              answer =
                Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"ok" => true}})

              :gen_tcp.send(socket, [answer, ?\n])

            {:ok, %{"method" => method, "params" => params}} ->
              send(test, {:pushed, method, params})

            _ ->
              :ok
          end
        end

        serve(socket, test)

      {:tcp_closed, ^socket} ->
        :ok
    end
  end

  defp verify("dev-token") do
    {:ok,
     %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}
end
