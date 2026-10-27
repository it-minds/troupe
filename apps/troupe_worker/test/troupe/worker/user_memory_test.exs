defmodule Troupe.Worker.UserMemoryTest do
  @moduledoc """
  `remember` with `level: "me"` on a pod (#55's user level): the entry goes over the pod's
  control link as `session.memory.put`, with a real plane at the other end, and lands in
  the session owner's own memory under the day's heading. Whose memory is the plane's to
  read off the session, so the pod's call names only the session.
  """

  use Troupe.Worker.SessionCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{Fleet, Identity, Memory, Repo}
  alias Troupe.Plane.Sessions, as: PlaneSessions
  alias Troupe.Worker.Plane.Link
  alias Troupe.Worker.{PlaneHelper, UserMemory}

  @moduletag timeout: 120_000

  setup context do
    unless Process.whereis(Repo),
      do: flunk("no database for the plane; bring one up with `scripts/dev-up`")

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &verify/1})

    start_supervised!(
      {Link,
       host: "127.0.0.1",
       port: Listener.port(),
       token: "dev-token",
       disk_path: context.base,
       claims: %{
         "pod_name" => "troupe-w-dev-0",
         "capacity" => 4,
         "disk_total_bytes" => 1_000_000,
         "version" => "test"
       }}
    )

    eventually(fn -> Link.connected?() end)
    context
  end

  test "an entry from a session on this pod lands in its owner's own memory, and nobody else's",
       context do
    {:ok, ada} = Identity.upsert_user(%{subject: "ada@example.test", email: "ada@example.test"})
    {:ok, bo} = Identity.upsert_user(%{subject: "bo@example.test", email: "bo@example.test"})
    {:ok, _} = Memory.save_own(ada, "Call me Ada.", 0)

    {:ok, _} =
      PlaneSessions.create(%{
        id: context.session_id,
        owner_id: ada.id,
        owner_subject: ada.subject,
        profile: "dev",
        epoch: 1
      })

    [pod] = Fleet.list_workers("dev")
    {:ok, _} = PlaneSessions.place(context.session_id, pod)

    assert {:ok, %{"entry" => "Prefers small pull requests.", "topic" => "Notes", "version" => 2}} =
             UserMemory.append("Prefers small pull requests.", %{session_id: context.session_id})

    # Under the topic the agent named, as the plane keeps topics.
    assert {:ok, %{"topic" => "Reviews", "version" => 3}} =
             UserMemory.append("Mornings only.", %{session_id: context.session_id}, "Reviews")

    assert Memory.current(ada).text ==
             "Call me Ada.\n\n## Notes\n\n- Prefers small pull requests.\n\n## Reviews\n\n- Mornings only."

    assert Memory.current(bo) == nil

    # A session this pod does not hold is not one it can write for.
    assert {:error, reason} = UserMemory.append("Not mine.", %{session_id: "s-elsewhere"})
    assert reason =~ "refused"

    stop_supervised!(Link)
    PlaneHelper.stop_plane()
  end

  defp verify("dev-token") do
    {:ok,
     %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}
end
