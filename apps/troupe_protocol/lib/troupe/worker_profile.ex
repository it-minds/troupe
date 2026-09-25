defmodule Troupe.WorkerProfile do
  @moduledoc """
  A `WorkerProfile`, parsed.

  One pool of workers: which image, how many, how big, what they may reach, and which
  teams' volumes they mount. The plane writes these; the operator reads them and never
  writes their `spec`.

  `teams` is the one field worth understanding. It is a *projection* of the plane's
  grants — the plane derives it and rewrites it whenever a grant changes — so it is not
  a second source of truth about who may use a profile. It is how the operator learns
  which volumes to bind into the namespace.
  """

  defmodule Team do
    @moduledoc "One team's volume, as a profile sees it."

    @enforce_keys [:name]
    defstruct [:name, :claim_name, :storage_class, :size, mode: :ro]

    @type t :: %__MODULE__{
            name: String.t(),
            claim_name: String.t() | nil,
            storage_class: String.t() | nil,
            size: String.t() | nil,
            mode: :ro | :rw
          }
  end

  defmodule MCPServer do
    @moduledoc """
    One MCP server a profile's sessions may use.

    `credential_mode` says whose credential goes out with a call, and the two modes use
    different fields.

    In `"profile"` mode — the default, and what every profile did before there was a
    mode — `credential_ref` is the name of the environment variable the pod finds the
    server's token in. The bundle names it; the plane copies it into the spec; the
    operator writes a `secretKeyRef` under that name and tells the worker the same name
    in `TROUPE_MCP_SERVERS`, so the three agree without any of them holding the value.

    In `"person"` mode there is no Secret and no environment variable. `credential_slot`
    names a slot under the session's owner in the key manager, which the pod reads with a
    credential scoped to that person and neither the plane nor the operator can reach.
    There is nothing here for the operator to mount.
    """

    @enforce_keys [:name, :url]
    defstruct [
      :name,
      :url,
      :secret_name,
      :secret_key,
      :credential_ref,
      :credential_slot,
      :header,
      :timeout_ms,
      credential_mode: "profile"
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            url: String.t(),
            secret_name: String.t() | nil,
            credential_mode: String.t(),
            credential_slot: String.t() | nil,
            secret_key: String.t() | nil,
            credential_ref: String.t() | nil,
            header: String.t() | nil,
            timeout_ms: pos_integer() | nil
          }

    @doc """
    The environment variable the server's credential arrives in.

    The declared `credentialRef` when there is one, else `TROUPE_MCP_<NAME>_TOKEN` with
    the name upper-cased and anything that is not a letter or digit folded to an
    underscore, so `jira-cloud` becomes `TROUPE_MCP_JIRA_CLOUD_TOKEN`. A fixed default
    means a profile written by hand, without a bundle, still gets a name the worker can
    be told.
    """
    @spec credential_env(t()) :: String.t()
    def credential_env(%__MODULE__{credential_ref: ref}) when is_binary(ref) and ref != "",
      do: ref

    def credential_env(%__MODULE__{name: name}) do
      "TROUPE_MCP_" <> String.upcase(String.replace(name, ~r/[^A-Za-z0-9]+/, "_")) <> "_TOKEN"
    end
  end

  @enforce_keys [:name, :image]
  defstruct [
    :name,
    :image,
    :uid,
    :generation,
    :llm_endpoint,
    :llm_provider,
    :llm_model,
    :llm_small_model,
    :llm_secret_name,
    :llm_secret_key,
    # Each pod's own disk. `nil` for either means the operator's default: 20Gi, on the
    # cluster's default storage class.
    :storage_size,
    :storage_class,
    # Dollars per million tokens by model, in the resource's own camelCase, for models a
    # gateway serves without saying what a streamed call cost (Decision 689). A pod gets
    # them as `TROUPE_MODEL_PRICES`.
    llm_prices: %{},
    replicas: 1,
    sessions_per_pod: 4,
    resources: %{},
    mcp_servers: [],
    egress_fqdns: [],
    git_hosts: [],
    config_bundle_channel: "stable",
    org_mount: false,
    teams: []
  ]

  @type t :: %__MODULE__{}

  @doc "Parse a `WorkerProfile` resource."
  @spec from_resource(map()) :: t()
  def from_resource(resource) do
    spec = Map.get(resource, "spec", %{})

    %__MODULE__{
      name: get_in(resource, ["metadata", "name"]),
      uid: get_in(resource, ["metadata", "uid"]),
      generation: get_in(resource, ["metadata", "generation"]),
      image: image(Map.get(spec, "image", %{})),
      replicas: Map.get(spec, "replicas", 1),
      sessions_per_pod: Map.get(spec, "sessionsPerPod", 4),
      resources: Map.get(spec, "resources", %{}),
      storage_size: get_in(spec, ["storage", "size"]),
      storage_class: get_in(spec, ["storage", "storageClassName"]),
      llm_endpoint: get_in(spec, ["llm", "endpoint"]),
      llm_provider: get_in(spec, ["llm", "provider"]) || "openai",
      llm_model: get_in(spec, ["llm", "model"]),
      llm_small_model: get_in(spec, ["llm", "smallModel"]),
      llm_prices: get_in(spec, ["llm", "prices"]) || %{},
      llm_secret_name: get_in(spec, ["llm", "secretRef", "name"]),
      llm_secret_key: get_in(spec, ["llm", "secretRef", "key"]) || "api-key",
      mcp_servers: Enum.map(Map.get(spec, "mcpServers", []), &mcp_server/1),
      egress_fqdns: get_in(spec, ["egress", "fqdns"]) || [],
      git_hosts: get_in(spec, ["egress", "gitHosts"]) || [],
      config_bundle_channel: Map.get(spec, "configBundleChannel", "stable"),
      org_mount: Map.get(spec, "orgMount", false),
      teams: Enum.map(Map.get(spec, "teams", []), &team/1)
    }
  end

  # A digest wins over a tag when both are given: a digest is what actually pins an
  # image, and honouring the tag instead would silently un-pin it.
  defp image(%{"repository" => repository} = spec) do
    cond do
      digest = Map.get(spec, "digest") -> "#{repository}@#{digest}"
      tag = Map.get(spec, "tag") -> "#{repository}:#{tag}"
      true -> repository
    end
  end

  defp image(_spec), do: ""

  defp team(entry) do
    %Team{
      name: Map.fetch!(entry, "name"),
      claim_name: Map.get(entry, "claimName"),
      storage_class: Map.get(entry, "storageClassName"),
      size: Map.get(entry, "size"),
      mode: if(Map.get(entry, "mode") == "rw", do: :rw, else: :ro)
    }
  end

  defp mcp_server(entry) do
    %MCPServer{
      name: Map.fetch!(entry, "name"),
      url: Map.fetch!(entry, "url"),
      secret_name: get_in(entry, ["secretRef", "name"]),
      secret_key: get_in(entry, ["secretRef", "key"]) || "token",
      credential_ref: Map.get(entry, "credentialRef"),
      credential_mode: Map.get(entry, "credentialMode") || "profile",
      credential_slot: Map.get(entry, "credentialSlot"),
      header: Map.get(entry, "header"),
      timeout_ms: Map.get(entry, "timeoutMs")
    }
  end

  @doc """
  Every host outside the cluster a profile's workers may reach.

  The LLM endpoint and the MCP servers are in here, not only the declared FQDNs: a
  profile that could name any endpoint could send a team's code anywhere, so policy has
  to see them as egress too.
  """
  @spec egress_destinations(t()) :: [String.t()]
  def egress_destinations(%__MODULE__{} = profile) do
    endpoints =
      Enum.map([profile.llm_endpoint | Enum.map(profile.mcp_servers, & &1.url)], &host_of/1)

    (endpoints ++ profile.egress_fqdns ++ profile.git_hosts)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  @doc "The host part of a URL, or the string itself when it is already a host."
  @spec host_of(String.t() | nil) :: String.t() | nil
  def host_of(nil), do: nil

  def host_of(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) -> host
      _ -> value
    end
  end

  @doc "Secrets the profile references, which have to exist before it can run."
  @spec secret_names(t()) :: [String.t()]
  def secret_names(%__MODULE__{} = profile) do
    [profile.llm_secret_name | Enum.map(profile.mcp_servers, & &1.secret_name)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
