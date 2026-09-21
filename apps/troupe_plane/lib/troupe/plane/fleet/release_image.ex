defmodule Troupe.Plane.Fleet.ReleaseImage do
  @moduledoc """
  Profiles whose image is `release` move with the platform.

  A release rolls the plane, the operator, the A2A facade and the GUI, and until this it
  left every worker on whatever image its profile was last given — which is how a 0.2.17
  plane came to be talking to 0.2.1 workers with nobody having decided that it should. CI
  cannot fix it by editing profiles, because a service principal is refused admin on
  purpose, and patching the custom resources behind the plane's back would be a change the
  plane's own record and audit trail never saw.

  So a profile may give its image as `release`, and `Troupe.Plane.Provision` resolves the
  word to this plane's `TROUPE_WORKER_IMAGE` wherever a manifest is rendered. That makes
  every write after an upgrade carry the upgrade's image. This is the other half: a plane
  that has just been upgraded has written nothing yet, so as it starts it finds each such
  profile whose `WorkerProfile` carries a different image and writes it again — through
  `Provision.apply/2`, the function an administrator's edit ends in, so direct and GitOps
  mode each do what they always do, and after the same policy check.

  ## Every replica as it starts, not a singleton

  The cluster-unique actors live wherever they were first asked for, and during a rolling
  upgrade that is as likely to be an old replica as a new one — whose configuration names
  the release being replaced. Run from there, this would put back the image the upgrade is
  taking away. Each replica does it once as it starts instead, so the replica that started
  last, which is the one running the release, has the last word. Two replicas starting at
  the same moment may both write the same image, which is one write made twice and two
  rows in the trail saying the same thing.

  What it cannot stop is an old replica writing a profile for some other reason — the
  scaler, an administrator's edit — in the minute before it is replaced. That write renders
  the old release's image; the next write from a replica of the new one, or the next start,
  puts it right.

  Not the scaler's tick either, although it already passes over every profile. The scaler
  writes a profile only when the number of workers changes and asks the cluster nothing,
  which is right for a controller that runs every fifteen seconds; reading every profile's
  resource on every tick to catch a change that happens once per upgrade would not be.

  ## Not a person

  The audit row is `profile.put` with the image's move as its diff, the way an
  administrator's edit is recorded, and its actor is `system:release` — as the scaler is
  `system:scaler` and SCIM is `scim`. A change nobody made by hand is still a change
  somebody will one day need to account for.

  ## A cluster that will not answer yet

  A plane often starts before the API server will talk to it, and that must not be why it
  does not start. The pass runs after `init/1` has returned, a profile that could not be
  read or written is left for the next attempt, and the attempts back off to once every
  ten minutes and do not give up: an upgrade that never reached its workers is exactly the
  failure this exists to remove.
  """

  use GenServer

  alias Troupe.Plane.{Audit, Fleet, Provision}
  alias Troupe.Plane.Fleet.Profile
  alias Troupe.Protocol.Error

  require Logger

  @actor %{subject: "system:release", role: :platform_admin}

  # Where the attempts start, and where they stop growing: soon enough that a cluster
  # which was merely slow to answer costs half a minute, rare enough that one which is
  # down for an afternoon does not fill the log.
  @retry_ms 30_000
  @max_retry_ms 600_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  One pass over every profile that follows the release, and what became of each.

  Public so a test can drive it without a process, and so somebody with a shell on the
  plane can ask what it makes of things now. `:current` stands in for the question of what
  a profile's resource carries, which is how a test stands in for a cluster.
  """
  @spec follow(keyword()) :: [map()]
  def follow(opts \\ []) do
    following = Enum.filter(Fleet.list_profiles(), &Provision.follows_release?/1)

    case Provision.release_image() do
      nil -> unnamed(following)
      image -> Enum.map(following, &follow_profile(&1, image, opts))
    end
  end

  defp follow_profile(%Profile{} = profile, image, opts) do
    current = Keyword.get(opts, :current, &Provision.current_image/1)

    case current.(profile) do
      {:ok, ^image} -> %{profile: profile.name, state: :current, image: image}
      {:ok, carried} -> write(profile, carried, image)
      {:error, reason} -> failed(profile, image, reason)
    end
  end

  defp write(profile, carried, image) do
    with :ok <- Provision.check(profile),
         {:ok, provisioning} <- Provision.apply(profile, @actor) do
      {:ok, _} =
        Audit.record(@actor.subject, "profile.put", profile.name, %{
          "image" => %{"from" => carried, "to" => image}
        })

      Logger.info(
        "troupe plane: #{profile.name} follows the release from #{carried || "nothing"} to #{image}"
      )

      %{
        profile: profile.name,
        state: :written,
        from: carried,
        to: image,
        provisioning: provisioning
      }
    else
      {:error, %Error{data: %{policy_violations: violations}}} ->
        refused(profile, image, violations)

      {:error, reason} ->
        failed(profile, image, reason)
    end
  end

  # A release image outside the cluster policy is a cluster admin's decision, not a fault
  # to retry: admission would refuse the write, and asking again every few minutes would
  # not change its mind. The profile keeps what it runs, and its page in the console shows
  # the violation, because the verdict there is worked out from the same resolved image.
  defp refused(profile, image, violations) do
    Logger.warning(
      "troupe plane: #{profile.name} stays where it is; the release's #{image} is outside " <>
        "the cluster policy: #{Enum.join(violations, "; ")}"
    )

    %{profile: profile.name, state: :refused, violations: violations}
  end

  defp failed(profile, image, reason) do
    Logger.warning(
      "troupe plane: #{profile.name} does not carry the release's #{image} yet: #{inspect(reason)}"
    )

    %{profile: profile.name, state: :failed, reason: reason}
  end

  # Said rather than skipped quietly. These profiles keep running whatever they were last
  # given and nothing will write them until the plane is deployed with a worker image,
  # which somebody should read in the log rather than infer from a pod that never moves.
  defp unnamed([]), do: []

  defp unnamed(following) do
    Logger.warning(
      "troupe plane: #{Enum.map_join(following, ", ", & &1.name)} follow the release, but " <>
        "this plane was deployed without a worker image (TROUPE_WORKER_IMAGE); they keep " <>
        "the image they have"
    )

    Enum.map(following, &%{profile: &1.name, state: :unnamed})
  end

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe release image")
    send(self(), :follow)
    {:ok, %{opts: opts, retry_ms: Keyword.get(opts, :retry_ms, @retry_ms)}}
  end

  @impl GenServer
  def handle_info(:follow, state) do
    if settled?(attempt(state.opts)) do
      {:noreply, state}
    else
      Process.send_after(self(), :follow, state.retry_ms)
      {:noreply, %{state | retry_ms: min(state.retry_ms * 2, @max_retry_ms)}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A pass that raises — the database not there yet, most likely — is a pass that did not
  # happen, and is tried again like one that could not reach the cluster. It must not take
  # the process with it: restarted by its supervisor, it would try again at once, and a
  # plane whose database is down would be restarting this instead of waiting.
  defp attempt(opts) do
    follow(opts)
  rescue
    exception ->
      Logger.error("troupe plane: following the release failed: #{Exception.message(exception)}")
      :raised
  end

  defp settled?(:raised), do: false
  defp settled?(results), do: not Enum.any?(results, &(&1.state == :failed))
end
