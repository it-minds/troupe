defmodule Troupe.Plane.Bundles do
  @moduledoc """
  Config bundles: versioned, immutable, and assigned to profiles by channel.

  A profile follows a *channel*, and a channel has versions. Publishing a new version
  pushes `config.updated` to every pod of every profile on that channel; the pods fetch
  it, check the hash, and apply it **to new sessions only**. A running session stays on
  the version recorded in its `session_created`, because a session whose agent
  definitions changed underneath it would be a different session halfway through.

  Retiring a version is how that promise ends. A session pinned to a retired version
  cannot be started again on it, and its next activation moves it to the channel's
  current version and says so with a durable `config_upgraded` event — which is the only
  way a session's configuration ever changes, and it is in the log.
  """

  import Ecto.Query

  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.{Fleet, Repo}
  alias Troupe.Plane.Fleet.Bundle

  require Logger

  @doc """
  Publish a new version of a channel.

  The version number is the channel's next, assigned here rather than by the caller: two
  admins publishing at once should produce two versions, not a conflict about what to
  call one of them.
  """
  @spec publish(String.t(), map(), keyword()) :: {:ok, Bundle.t()} | {:error, term()}
  def publish(channel, content, opts \\ []) do
    version = next_version(channel)

    %Bundle{}
    |> Bundle.changeset(%{
      channel: channel,
      version: version,
      hash: Bundle.hash(content),
      content: content,
      published_at: DateTime.utc_now(),
      published_by: Keyword.get(opts, :by, "system")
    })
    |> Repo.insert()
    |> case do
      {:ok, bundle} ->
        if Keyword.get(opts, :announce, true), do: announce(bundle)
        {:ok, bundle}

      error ->
        error
    end
  end

  defp next_version(channel) do
    Repo.one(from b in Bundle, where: b.channel == ^channel, select: coalesce(max(b.version), 0)) + 1
  end

  @doc "The version a new session on this channel gets, or `nil` if nothing is published."
  @spec current(String.t()) :: Bundle.t() | nil
  def current(channel) do
    Repo.one(
      from b in Bundle,
        where: b.channel == ^channel and is_nil(b.retired_at),
        order_by: [desc: b.version],
        limit: 1
    )
  end

  @doc "One version of a channel, retired or not."
  @spec get(String.t(), integer()) :: Bundle.t() | nil
  def get(channel, version), do: Repo.get_by(Bundle, channel: channel, version: version)

  @doc "Every version of a channel, newest first."
  @spec list(String.t()) :: [Bundle.t()]
  def list(channel) do
    Repo.all(from b in Bundle, where: b.channel == ^channel, order_by: [desc: b.version])
  end

  @doc """
  Retire a version, so nothing new starts on it.

  Sessions already running on it are untouched: retiring is about what may be *started*,
  and interrupting a running session to change its configuration is the thing versions
  exist to prevent.
  """
  @spec retire(String.t(), integer()) :: {:ok, Bundle.t()} | {:error, term()}
  def retire(channel, version) do
    case get(channel, version) do
      nil -> {:error, :not_found}
      bundle -> bundle |> Bundle.changeset(%{retired_at: DateTime.utc_now()}) |> Repo.update()
    end
  end

  @doc """
  What a session activating on `channel` should run, given what it is pinned to.

  `{:keep, version}` when the pinned version is still live, and `{:upgrade, from, to}`
  when it is not — which the worker turns into a durable `config_upgraded` event, so the
  model is told its configuration changed rather than quietly behaving differently.
  """
  @spec resolve(String.t(), integer() | nil) ::
          {:keep, Bundle.t()} | {:upgrade, integer() | nil, Bundle.t()} | {:error, :none_published}
  def resolve(channel, pinned) do
    case {pinned && get(channel, pinned), current(channel)} do
      {nil, nil} -> {:error, :none_published}
      {nil, current} -> {:upgrade, pinned, current}
      {%Bundle{retired_at: nil} = bundle, _current} -> {:keep, bundle}
      {%Bundle{version: from}, nil} -> nothing_left(channel, from)
      {%Bundle{version: from}, current} -> {:upgrade, from, current}
    end
  end

  defp nothing_left(channel, from) do
    Logger.warning("troupe plane: #{channel} v#{from} is retired and nothing has replaced it")
    {:error, :none_published}
  end

  @doc """
  Tell every pod on this channel that there is a new version.

  A notification rather than a request: a pod that is busy, restarting or briefly
  unreachable picks the change up on its next heartbeat comparison, and a publish that
  blocked on the slowest pod in the fleet would make publishing a risk.
  """
  @spec announce(Bundle.t()) :: :ok
  def announce(%Bundle{} = bundle) do
    params = %{
      "channel" => bundle.channel,
      "version" => bundle.version,
      "bundle_hash" => bundle.hash,
      "mcp_servers" => Map.get(bundle.content, "mcp_servers", [])
    }

    bundle.channel
    |> profiles_on()
    |> Enum.each(&Router.broadcast(&1, "config.updated", params))
  end

  @doc "Profiles following a channel, from the fleet's own record of what each one runs."
  @spec profiles_on(String.t()) :: [String.t()]
  def profiles_on(channel), do: Fleet.profiles_on_channel(channel)

  @doc """
  Which pods are reporting which bundle hash.

  The mismatch is the interesting part: a pod still reporting the previous hash ten
  seconds after a publish is a pod that has not applied it, and that surfaces as a
  condition rather than being discovered when a session behaves oddly.
  """
  @spec adoption(String.t(), String.t()) :: map()
  def adoption(profile, hash) do
    workers = Fleet.list_workers(profile)
    {current, stale} = Enum.split_with(workers, &(&1.bundle_hash == hash))

    %{
      profile: profile,
      expected: hash,
      pods: length(workers),
      current: Enum.map(current, & &1.pod_name),
      stale: Enum.map(stale, &%{pod: &1.pod_name, reported: &1.bundle_hash}),
      adopted?: stale == [] and workers != []
    }
  end
end
