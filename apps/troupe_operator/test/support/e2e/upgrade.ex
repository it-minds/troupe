defmodule Troupe.E2E.Upgrade do
  @moduledoc """
  The two halves of the upgrade check, and what they hand each other.

  `scripts/kind-upgrade-check` installs the release before this one from the registry,
  runs `test/upgrade/seed_test.exs` against it, upgrades to the chart and images under
  test, and runs `test/upgrade/check_test.exs`. The seed writes what it made to a file
  (`TROUPE_UPGRADE_STATE`), and the check reads it: the ids, the versions and the key the
  old release gave out, so the check can ask the new one for the same things.

  Everything goes through the protocol, as `Troupe.E2E.Plane` does: a seeded thing the new
  release lost or misreads is a thing a client would find lost or misread.
  """

  alias Troupe.E2E.{Plane, World}
  alias Troupe.Protocol.Client

  @doc "Where the seed writes what it made and the check reads it."
  @spec state_path() :: String.t()
  def state_path do
    System.get_env("TROUPE_UPGRADE_STATE") ||
      Path.expand("../../../../../.e2e/upgrade/seed.json", __DIR__)
  end

  @doc "Write the seed's record."
  @spec write!(map()) :: :ok
  def write!(state) do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(state, pretty: true))
  end

  @doc "Read the seed's record, or say plainly that there is none."
  @spec read!() :: map()
  def read! do
    path = state_path()

    case File.read(path) do
      {:ok, body} ->
        Jason.decode!(body)

      {:error, reason} ->
        raise "no seed at #{path} (#{inspect(reason)}): the check runs after " <>
                "test/upgrade/seed_test.exs, as scripts/kind-upgrade-check runs them"
    end
  end

  @doc "The release the seed ran against, as the script was told it (`TROUPE_UPGRADE_FROM`)."
  @spec from() :: String.t() | nil
  def from, do: presence(System.get_env("TROUPE_UPGRADE_FROM"))

  @doc "The commit the images under test were built from (`TROUPE_UPGRADE_EXPECT_COMMIT`)."
  @spec expected_commit() :: String.t() | nil
  def expected_commit, do: presence(System.get_env("TROUPE_UPGRADE_EXPECT_COMMIT"))

  @doc "What `/.well-known/troupe` says the plane is: its `plane.build`."
  @spec build() :: map()
  def build do
    %{status: 200, body: body} =
      Req.get!(World.plane_url() <> "/.well-known/troupe", retry: false)

    get_in(body, ["plane", "build"]) || %{}
  end

  @doc "The plane's signing key, as a client pins it at sign-in."
  @spec signing_key() :: map()
  def signing_key do
    %{status: 200, body: body} =
      Req.get!(World.plane_url() <> "/.well-known/troupe-signing-key", retry: false)

    body
  end

  @doc """
  A worker profile's conditions, `%{"Ready" => "True", ...}`, as the operator wrote them.
  """
  @spec conditions(String.t()) :: %{String.t() => String.t()}
  def conditions(profile) do
    path = ~s|jsonpath={range .status.conditions[*]}{.type}={.status}{"\\n"}{end}|

    case World.kubectl(["get", "workerprofile", profile, "-n", World.namespace(), "-o", path],
           stderr: false
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [type, status] = String.split(line, "=", parts: 2)
          {type, status}
        end)

      _missing ->
        %{}
    end
  end

  @doc "The images a profile's worker pods run, one per pod."
  @spec pod_images(String.t()) :: [String.t()]
  def pod_images(profile) do
    path = ~s|jsonpath={range .items[*]}{.spec.containers[0].image}{"\\n"}{end}|
    selector = "app.kubernetes.io/name=troupe-worker"

    case World.kubectl(
           ["get", "pods", "-n", World.worker_namespace(profile), "-l", selector, "-o", path],
           stderr: false
         ) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _none -> []
    end
  end

  @doc """
  One environment variable of each worker pod of a profile, as the operator set it: one
  entry per pod, `""` for a pod without it.
  """
  @spec pod_env(String.t(), String.t()) :: [String.t()]
  def pod_env(profile, name) do
    path =
      ~s|jsonpath={range .items[*]}{.metadata.name}={.spec.containers[0].env[?(@.name=="#{name}")].value}{"\\n"}{end}|

    selector = "app.kubernetes.io/name=troupe-worker"

    case World.kubectl(
           ["get", "pods", "-n", World.worker_namespace(profile), "-l", selector, "-o", path],
           stderr: false
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.split("=", parts: 2) |> List.last() end)

      _none ->
        []
    end
  end

  @doc """
  Wait until a pod of the profile is one the plane will place a session on: enrolled,
  healthy, not draining and with room. Readiness is Kubernetes' word and enrolment the
  plane's, and a session opened in between is told every pod is full.
  """
  @spec placeable!(String.t(), keyword()) :: :ok
  def placeable!(profile, opts \\ []) do
    World.eventually(fn -> placeable?(profile) end,
      timeout: Keyword.get(opts, :timeout, 600_000),
      every: 5_000,
      what: "a pod of #{profile} the plane will place a session on",
      explain: fn -> inspect(Plane.call("admin.profiles.list")) end
    )
  end

  defp placeable?(profile) do
    case Plane.call("admin.profiles.list") do
      {:ok, profiles} ->
        Enum.any?(List.wrap(profiles), fn listed ->
          listed["name"] == profile and Enum.any?(listed["pods"] || [], &room?/1)
        end)

      {:error, _} ->
        false
    end
  end

  defp room?(worker) do
    worker["healthy"] and not worker["draining"] and
      (worker["active_sessions"] || 0) < (worker["capacity"] || 0)
  end

  @doc """
  Attach to the pod an answer from `session.create` or `session.open` names, and read the
  session's log so far. Answers the client and the events.
  """
  @spec attach!(map(), String.t()) :: {pid(), [Troupe.Protocol.Event.t()]}
  def attach!(answer, session_id) do
    client = Plane.attach!(answer)
    {client, Plane.history!(client, session_id)}
  end

  @doc """
  Send a line to a session the client is subscribed to and wait for the turn to end.

  Answers every event the turn wrote. A model error, a turn the harness stopped or no end
  within the time fails with what the session said.
  """
  @spec turn!(pid(), String.t(), String.t(), timeout()) :: [Troupe.Protocol.Event.t()]
  def turn!(client, session_id, text, timeout \\ 180_000) do
    params = %{"command_id" => Client.command_id(), "session_id" => session_id, "text" => text}

    case Client.call(client, "input.send", params) do
      {:ok, %{"accepted" => true}} -> :ok
      other -> raise "input.send to #{session_id} was not accepted: #{inspect(other)}"
    end

    deadline = System.monotonic_time(:millisecond) + timeout
    await_turn([], session_id, deadline)
  end

  defp await_turn(events, session_id, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:troupe_event, _topic, ^session_id, %{type: "turn_ended"} = event} ->
        Enum.reverse([event | events])

      {:troupe_event, _topic, ^session_id, %{type: type} = event}
      when type in ["llm_error", "agent_done", "cancelled"] ->
        raise "the turn in #{session_id} ended with #{type}: #{inspect(event.data)}\n" <>
                "the turn so far: #{inspect(Enum.map(Enum.reverse(events), & &1.type))}"

      {:troupe_event, _topic, ^session_id, event} ->
        await_turn([event | events], session_id, deadline)
    after
      left ->
        raise "no turn_ended in #{session_id}; the turn so far: " <>
                inspect(Enum.map(Enum.reverse(events), &{&1.type, &1.data}))
    end
  end

  @doc "A webhook trigger fired as a CI job fires one: its key and nothing else."
  @spec fire!(map(), map()) :: Req.Response.t()
  def fire!(%{"url" => url, "key" => key}, body) do
    Req.post!(World.plane_url() <> url,
      json: body,
      headers: [{"authorization", "Bearer " <> key}],
      retry: false,
      receive_timeout: 60_000
    )
  end

  @doc "Erase a session as the platform admin, whoever owns it."
  @spec erase(String.t() | nil) :: :ok
  def erase(nil), do: :ok

  def erase(id) do
    _ = Plane.call("admin.session.erase", %{"session_id" => id, "confirm" => id})
    :ok
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
