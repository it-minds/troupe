defmodule Troupe.Plane.Bundles do
  @moduledoc """
  Config bundles: versioned, immutable, and assigned to profiles by channel.

  A profile follows a *channel*, and a channel has versions. Publishing a new version
  pushes `config.updated` to every pod of every profile on that channel; the pods fetch
  it by hash over `bundle.fetch`, check the hash, and apply it **to new sessions only**.
  A running session stays on the version recorded in its `session_created`, because a
  session whose agent definitions changed underneath it would be a different session
  halfway through.

  Retiring a version is how that promise ends. A session pinned to a retired version
  cannot be started again on it, and its next activation moves it to the channel's
  current version and says so with a durable `config_upgraded` event — which is the only
  way a session's configuration ever changes, and it is in the log.

  ## What a bundle is checked against

  The document's own rules live in `Troupe.Protocol.Bundle`, where the worker re-checks
  what it fetched with the same code. The one rule only the plane can apply is the
  cluster's: an MCP server's host must be one `TroupePolicy` lets a pod reach, because a
  server the pod cannot resolve is a bundle that looks published and does nothing.

  ## The bundle is where MCP servers are declared

  The `WorkerProfile` has an `mcpServers` field, and the plane is its writer: on every
  publish and retire the profiles on the channel are rewritten from what the channel now
  publishes, so the operator sees the hosts for egress and the Secret each server's
  token lives in. The Secret is `troupe-mcp-<server>`, key `token`, in the worker
  namespace, by convention rather than by configuration, so an admin reading a bundle
  knows which Secret to create without asking.
  """

  import Ecto.Query

  alias Troupe.Plane.{ClusterPolicy, Fleet, Provision, Repo}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Fleet.Bundle
  alias Troupe.Plane.Identity.Entitlement
  alias Troupe.Protocol.Bundle, as: Document

  require Logger

  # The agents `troupe_core` ships in `priv/agents/`. A bundle may replace one only by
  # saying so; the names are listed here rather than read from core because the plane
  # does not depend on core, and a bundle that shadowed `build` by accident would be a
  # bundle nobody meant to publish.
  @builtin_agents ~w(build plan general explore)
  @builtin_primaries ~w(build plan)

  @type projection :: %{String.t() => map()}

  @doc "The agent names a bundle may not replace without `override: true`."
  @spec builtin_agents() :: [String.t()]
  def builtin_agents, do: @builtin_agents

  @doc "The primaries a session may start as when the bundle defines none of its own."
  @spec builtin_primaries() :: [String.t()]
  def builtin_primaries, do: @builtin_primaries

  @doc """
  Check a document the way publishing will.

  The errors are sentences, one per thing wrong, so an admin fixes them in one pass;
  the egress check asks the cluster policy through `Troupe.Plane.ClusterPolicy`.
  """
  @spec validate(map()) :: {:ok, Document.t()} | {:error, {:invalid_bundle, [String.t()]}}
  def validate(content) do
    options = [egress_allowed?: &ClusterPolicy.egress_allowed?/1, builtin_agents: @builtin_agents]

    case Document.validate(content, options) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, messages} -> {:error, {:invalid_bundle, messages}}
    end
  end

  @doc """
  Publish a new version of a channel.

  The version number is the channel's next, assigned here rather than by the caller: two
  admins publishing at once should produce two versions, not a conflict about what to
  call one of them. Options: `:by`, the publisher; `:announce`, whether to tell the pods
  (default true); `:project`, whether to rewrite the profiles' `mcpServers` (default
  true).
  """
  @spec publish(String.t(), map(), keyword()) :: {:ok, Bundle.t()} | {:error, term()}
  def publish(channel, content, opts \\ []) do
    with {:ok, parsed} <- validate(content) do
      version = next_version(channel)

      %Bundle{}
      |> Bundle.changeset(%{
        channel: channel,
        version: version,
        hash: Bundle.hash(content),
        content: content,
        summary: Document.summary(parsed),
        published_at: DateTime.utc_now(),
        published_by: Keyword.get(opts, :by, "system")
      })
      |> Repo.insert()
      |> case do
        {:ok, bundle} -> {:ok, published(bundle, channel, opts)}
        error -> error
      end
    end
  end

  defp next_version(channel) do
    Repo.one(from(b in Bundle, where: b.channel == ^channel, select: coalesce(max(b.version), 0))) +
      1
  end

  defp actor(opts), do: %{subject: Keyword.get(opts, :by, "system")}

  # A row that was written is a version that exists: the pods on the channel are told,
  # and the profiles follow, unless the caller asked for either to be left alone.
  defp published(bundle, channel, opts) do
    if Keyword.get(opts, :announce, true), do: announce(bundle)
    reprojected(bundle, channel, opts)
  end

  # After a publish or a retire, the profiles' `mcpServers` say what the channel now
  # publishes — unless the caller asked for the projection to be left alone.
  defp reprojected(bundle, channel, opts) do
    if Keyword.get(opts, :project, true), do: project_mcp_servers(channel, actor(opts))
    bundle
  end

  @doc "The version a new session on this channel gets, or `nil` if nothing is published."
  @spec current(String.t()) :: Bundle.t() | nil
  def current(channel) do
    Repo.one(
      from(b in Bundle,
        where: b.channel == ^channel and is_nil(b.retired_at),
        order_by: [desc: b.version],
        limit: 1
      )
    )
  end

  @doc "One version of a channel, retired or not."
  @spec get(String.t(), integer() | String.t()) :: Bundle.t() | nil
  def get(channel, version), do: Repo.get_by(Bundle, channel: channel, version: version)

  @doc """
  The bundle with this hash, which is how a worker asks for one.

  The same document published on two channels has one hash and two rows; `:channel`
  says which to prefer, so the answer's channel and version are the asking pod's own
  when they can be. Either row's content is the right content.
  """
  @spec by_hash(String.t(), keyword()) :: Bundle.t() | nil
  def by_hash(hash, opts \\ []) do
    preferred = Keyword.get(opts, :channel)
    rows = Repo.all(from(b in Bundle, where: b.hash == ^hash, order_by: [desc: b.published_at]))

    Enum.find(rows, &(&1.channel == preferred)) || List.first(rows)
  end

  @doc "Every version of a channel, newest first."
  @spec list(String.t()) :: [Bundle.t()]
  def list(channel) do
    Repo.all(from(b in Bundle, where: b.channel == ^channel, order_by: [desc: b.version]))
  end

  @doc """
  Retire a version, so nothing new starts on it.

  Sessions already running on it are untouched: retiring is about what may be *started*,
  and interrupting a running session to change its configuration is the thing versions
  exist to prevent. The profiles' `mcpServers` are recomputed from whatever is current
  afterwards, which may be nothing.
  """
  @spec retire(String.t(), integer(), keyword()) :: {:ok, Bundle.t()} | {:error, term()}
  def retire(channel, version, opts \\ []) do
    case get(channel, version) do
      nil ->
        {:error, :not_found}

      bundle ->
        changeset = Bundle.changeset(bundle, %{retired_at: DateTime.utc_now()})

        with {:ok, retired} <- Repo.update(changeset) do
          {:ok, reprojected(retired, channel, opts)}
        end
    end
  end

  @doc """
  What a session activating on `channel` should run, given what it is pinned to.

  `{:keep, version}` when the pinned version is still live, and `{:upgrade, from, to}`
  when it is not — which the worker turns into a durable `config_upgraded` event, so the
  model is told its configuration changed rather than quietly behaving differently.
  """
  @spec resolve(String.t(), integer() | nil) ::
          {:keep, Bundle.t()}
          | {:upgrade, integer() | nil, Bundle.t()}
          | {:error, :none_published}
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

  The push names the version and its hash; the pod fetches the document over
  `bundle.fetch` and verifies it against the hash before applying it. `mcp_servers`
  still rides along for one release, so a worker from before `bundle.fetch` keeps
  applying the one thing it ever read from a bundle; it goes when no such worker can be
  running.
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

  A pod reporting a *newer* version of the same channel than the one asked about is not
  behind. That is what a pod looks like after the newest version was retired: it keeps
  every version it has materialised and serves the current one from its own directory,
  so it is listed as `ahead` and counts as adopted.
  """
  @spec adoption(String.t(), String.t()) :: map()
  def adoption(profile, hash) do
    workers = Fleet.list_workers(profile)
    expected = by_hash(hash)
    {current, others} = Enum.split_with(workers, &(&1.bundle_hash == hash))
    {ahead, stale} = Enum.split_with(others, &ahead?(&1.bundle_hash, expected))

    %{
      profile: profile,
      expected: hash,
      pods: length(workers),
      current: Enum.map(current, & &1.pod_name),
      ahead: Enum.map(ahead, & &1.pod_name),
      stale: Enum.map(stale, &%{pod: &1.pod_name, reported: &1.bundle_hash}),
      adopted?: stale == [] and workers != []
    }
  end

  defp ahead?(reported, %Bundle{} = expected) when is_binary(reported) do
    case by_hash(reported, channel: expected.channel) do
      %Bundle{channel: channel, version: version} ->
        channel == expected.channel and version > expected.version

      nil ->
        false
    end
  end

  defp ahead?(_reported, _expected), do: false

  # -- what a bundle carries --------------------------------------------------

  @doc """
  A published bundle, parsed.

  The document was checked at publish, so this is a decode rather than a judgement; the
  egress rule is not re-applied, because a policy that tightened since should stop the
  next publish, not make an existing version unreadable. `nil` for a row this code
  cannot read, which is a row an older plane wrote with a malformed server entry.
  """
  @spec contents(Bundle.t()) :: Document.t() | nil
  def contents(%Bundle{content: content}) do
    case Document.validate(content) do
      {:ok, parsed} -> parsed
      {:error, _messages} -> nil
    end
  end

  @doc """
  The primaries a session on this bundle may start as.

  The bundle's own primaries first, then the built-in ones it does not replace: a
  bundle that adds `reviewer` has not taken `build` away, because built-ins sit below
  the bundle in the definition search order.
  """
  @spec primaries(Document.t() | nil) :: [String.t()]
  def primaries(nil), do: @builtin_primaries

  def primaries(%{agents: agents}) do
    own = for %{name: name, parsed: %{mode: :primary}} <- agents, do: name
    own ++ (@builtin_primaries -- own)
  end

  @doc """
  What a session created on `channel` will have, for a client choosing.

  The current version's number and hash, the primaries it may start as, its skills with
  their descriptions, and the names of its MCP servers. A channel with nothing published
  offers the built-ins and nothing else.

  The second argument is the entitlement rows of the grant the caller is using, and
  narrowing happens here so that every caller gets the narrower answer for free: the
  profile listing shows a person what *they* may use, and `agent_for/2` refuses an agent
  their team may not run before a pod or a budget is touched. `[]` — the shape every
  grant has until somebody opens the editor — narrows nothing.

  The bundle is untouched. There are no derived bundles and no per-team hashes; the hash
  a session pins is the same hash for every team.
  """
  @spec offering(String.t() | nil, [map()]) :: map()
  def offering(channel, entitlements \\ [])

  def offering(nil, entitlements), do: offering_of(nil, nil, entitlements)

  def offering(channel, entitlements) do
    case current(channel) do
      nil -> offering_of(channel, nil, entitlements)
      bundle -> offering_of(channel, bundle, entitlements)
    end
  end

  defp offering_of(channel, nil, entitlements) do
    %{
      channel: channel,
      bundle_version: nil,
      bundle_hash: nil,
      agents: narrow(@builtin_primaries, entitlements, "agent"),
      skills: [],
      mcp_servers: [],
      acp_agents: []
    }
  end

  defp offering_of(channel, bundle, entitlements) do
    parsed = contents(bundle)
    skills = for skill <- skills_of(parsed), do: %{name: skill.name, description: skill.description}

    %{
      channel: channel,
      bundle_version: bundle.version,
      bundle_hash: bundle.hash,
      agents: narrow(primaries(parsed), entitlements, "agent"),
      skills: narrow_by(skills, & &1.name, entitlements, "skill"),
      mcp_servers: narrow(for(server <- servers_of(parsed), do: server.name), entitlements, "mcp_server"),
      acp_agents: narrow(for(agent <- acp_agents_of(parsed), do: agent.name), entitlements, "acp_agent")
    }
  end

  defp narrow(names, entitlements, kind) do
    Entitlement.resolve(names, Entitlement.of_kind(entitlements, kind))
  end

  defp narrow_by(items, name_of, entitlements, kind) do
    kept = items |> Enum.map(name_of) |> narrow(entitlements, kind) |> MapSet.new()
    Enum.filter(items, &MapSet.member?(kept, name_of.(&1)))
  end

  @doc """
  The entitlement set as `session_created` and `session.activate` carry it.

  Names rather than rows: what the log has to answer, years later, is *what was this
  session allowed to see* — and a reader of that answer should not have to know what the
  bundle said that day, nor re-run the allow-and-deny rules to find out.
  """
  @spec entitlement_set(map()) :: map()
  def entitlement_set(%{agents: agents, skills: skills, mcp_servers: servers} = offering) do
    %{
      "agents" => agents,
      "skills" => Enum.map(skills, & &1.name),
      "mcp_servers" => servers,
      "acp_agents" => Map.get(offering, :acp_agents, [])
    }
  end

  defp skills_of(nil), do: []
  defp skills_of(%{skills: skills}), do: skills

  defp servers_of(nil), do: []
  defp servers_of(%{mcp_servers: servers}), do: servers

  # `Map.get`, because a schema-0 bundle has no such key and a plane upgraded under one
  # keeps working — which is the same reason every other accessor here is forgiving.
  defp acp_agents_of(nil), do: []
  defp acp_agents_of(parsed), do: Map.get(parsed, :acp_agents, [])

  @doc """
  A bundle in the shape a panel renders: each agent with its mode, description and
  skills; each skill with its files; each MCP server with the Secret an admin must
  create for it.
  """
  @spec describe(Bundle.t()) :: map() | nil
  def describe(%Bundle{} = bundle) do
    case contents(bundle) do
      nil ->
        nil

      parsed ->
        %{
          schema: parsed.schema,
          agents:
            Enum.map(parsed.agents, fn agent ->
              %{
                name: agent.name,
                mode: agent.parsed.mode,
                description: agent.parsed.description,
                skills: agent.parsed.skills
              }
            end),
          skills:
            Enum.map(parsed.skills, fn skill ->
              %{
                name: skill.name,
                description: skill.description,
                files: skill.files |> Map.keys() |> Enum.sort()
              }
            end),
          mcp_servers:
            Enum.map(parsed.mcp_servers, fn server ->
              %{
                name: server.name,
                url: server.url,
                credential_ref: server.credential_ref,
                header: server.header,
                permission: server.permission,
                tools: server.tools,
                secret: server.credential_ref && secret_name(server.name)
              }
            end)
        }
    end
  end

  # -- the profiles' mcpServers -----------------------------------------------

  @doc """
  Rewrite `mcpServers` on every profile following `channel` from what it now publishes.

  The plane is the only writer of that field, and it is a projection of the current
  bundle rather than a second place to declare a server: the operator reads it for
  egress and for the Secret to inject, and a profile whose list disagreed with its
  bundle would be a profile whose pods could not reach what their sessions were told
  they had. Each profile's row is updated and re-provisioned through the same path
  `profile.put` uses; a cluster that cannot be reached leaves the resource stale until
  the next write, which is reported rather than failing the publish.
  """
  @spec project_mcp_servers(String.t(), map()) :: projection()
  def project_mcp_servers(channel, actor) do
    servers = channel |> current() |> mcp_servers_spec()

    for name <- profiles_on(channel), profile = Fleet.get_profile(name), into: %{} do
      {name, project_profile(profile, servers, actor)}
    end
  end

  defp project_profile(profile, servers, actor) do
    spec = Map.put(profile.spec || %{}, "mcpServers", servers)

    with {:ok, updated} <- Fleet.put_profile(%{name: profile.name, spec: spec}),
         {:ok, state} <- Provision.apply(updated, actor) do
      state
    else
      {:error, reason} ->
        Logger.warning("troupe plane: #{profile.name}'s mcpServers are stale: #{inspect(reason)}")
        %{state: :not_applied, reason: inspect(reason)}
    end
  end

  # The spec entries the operator reads (`Troupe.WorkerProfile.MCPServer`). A server
  # with no credential has no `secretRef` and no `credentialRef` — it is still listed,
  # because egress is decided from this list too.
  defp mcp_servers_spec(nil), do: []

  defp mcp_servers_spec(%Bundle{} = bundle) do
    case contents(bundle) do
      nil ->
        []

      parsed ->
        parsed
        |> Document.mcp_server_configs()
        |> Enum.map(fn server ->
          %{"name" => server["name"], "url" => server["url"]}
          |> put_unless_nil("header", server["header"])
          |> put_unless_nil("timeoutMs", server["timeout_ms"])
          |> put_credential(server["name"], server["credential_mode"], server["credential_ref"])
        end)
    end
  end

  defp put_credential(entry, _name, _mode, nil), do: entry

  # A person-mode server has no Secret and no environment variable: its value is in the
  # key manager under the person, and neither the plane nor the operator can read it. So
  # the projection carries the *slot* and says which mode it is, and the operator has
  # nothing to mount. Writing a `secretRef` here for a server nobody configured a Secret
  # for is how a pod would fail to start over a credential it was never meant to hold.
  defp put_credential(entry, _name, "person", slot) do
    entry
    |> Map.put("credentialMode", "person")
    |> Map.put("credentialSlot", slot)
  end

  defp put_credential(entry, name, _profile_mode, ref) do
    entry
    |> Map.put("credentialRef", ref)
    |> Map.put("secretRef", %{"name" => secret_name(name), "key" => "token"})
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  @doc "The Secret a server's token lives in, in the worker namespace."
  @spec secret_name(String.t()) :: String.t()
  def secret_name(server), do: "troupe-mcp-" <> server
end
