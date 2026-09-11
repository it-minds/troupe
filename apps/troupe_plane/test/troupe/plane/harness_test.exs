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

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{Fleet, Harness, Identity, Sessions}

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

    test "a user with no grant on the profile cannot create" do
      team_with_grant("engineering", "dev", name: "engineering")
      stranger = person("nobody@example.test", [])

      assert {:error, error} = Harness.call("session.create", %{"profile" => "dev"}, context(stranger))
      assert error.message == "forbidden"
    end

    test "with no pod to put it on, nothing is left behind" do
      team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])

      assert {:error, error} = Harness.call("session.create", %{"profile" => "dev"}, context(user))
      assert error.message in ["capacity", "unavailable"]

      # The row went with the failure: a session that never started is not a session,
      # and leaving it would put a phantom in everybody's listing.
      assert {:ok, %{"sessions" => []}} = Harness.call("sessions.list", %{}, context(user))
    end

    test "a user in two teams that both grant the profile is asked which" do
      team_with_grant("engineering", "dev", name: "engineering")
      team_with_grant("research", "dev", name: "research")
      user = person("ada@example.test", ["engineering", "research"])

      assert {:error, error} = Harness.call("session.create", %{"profile" => "dev"}, context(user))
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
               Harness.call("session.open", %{"session_id" => session.id, "mode" => "read"}, context(user))

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
            Harness.call("session.open", %{"session_id" => session.id, "mode" => "activate"}, context(user))
          end,
          max_concurrency: 6,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Sessions.get(session.id).epoch == 2
      assert results |> Enum.map(fn {:ok, r} -> r["epoch"] end) |> Enum.uniq() == [2]
    end

    test "a read-only session cannot be activated", context do
      team = team_with_grant("engineering", "dev", name: "engineering")
      user = person("ada@example.test", ["engineering"])
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      session = session!("s-frozen", user, team, state: "read_only")

      assert {:error, error} =
               Harness.call("session.open", %{"session_id" => session.id, "mode" => "activate"}, context(user))

      assert error.message == "forbidden"

      # Reads still work, which is what read-only means.
      assert {:ok, %{"mode" => "read"}} =
               Harness.call("session.open", %{"session_id" => session.id, "mode" => "read"}, context(user))
    end
  end

  describe "pins" do
    test "an owner may pin and unpin; a viewer may not" do
      team = team_with_grant("engineering", "dev", name: "engineering")
      owner = person("ada@example.test", ["engineering"])
      watcher = person("grace@example.test", ["engineering"])
      session = session!("s-pinned", owner, team, visibility: "team")

      assert {:ok, pinned} = Harness.call("session.pin", %{"session_id" => session.id}, context(owner))
      assert pinned["pinned"]
      assert Sessions.get(session.id).pinned_by == "ada@example.test"

      assert {:error, error} = Harness.call("session.pin", %{"session_id" => session.id}, context(watcher))
      assert error.message == "forbidden"

      assert {:ok, unpinned} = Harness.call("session.unpin", %{"session_id" => session.id}, context(owner))
      refute unpinned["pinned"]
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp context(user), do: %{user: user, platform_admin?: false}

  defp session!(id, owner, team, opts) do
    {:ok, session} =
      Sessions.create(%{
        id: id <> "-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        owner_subject: owner.subject,
        team_id: team.id,
        profile: Keyword.get(opts, :profile, "dev"),
        visibility: Keyword.get(opts, :visibility, "private"),
        state: Keyword.get(opts, :state, "active"),
        epoch: 1
      })

    session
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
        "params" => %{"token" => token, "pod_name" => pod_name, "capacity" => 4, "disk_total_bytes" => 1_000_000}
      })

    :ok = :gen_tcp.send(socket, [request, ?\n])
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    %{"result" => result} = line |> String.split("\n", trim: true) |> List.first() |> Jason.decode!()

    pid =
      spawn_link(fn ->
        :inet.setopts(socket, active: true)
        serve(socket, test)
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(socket) end)

    %{worker_id: result["worker_id"], socket: socket}
  end

  defp serve(socket, test) do
    receive do
      {:tcp, ^socket, data} ->
        for line <- String.split(data, "\n", trim: true) do
          case Jason.decode(line) do
            {:ok, %{"id" => id, "method" => method, "params" => params}} ->
              send(test, {:pushed, method, params})
              answer = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"ok" => true}})
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
    {:ok, %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}
end
