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

    In `"client_credentials"` mode there is no Secret either: the pod gets a token as the
    profile's own identity, which the profile describes in its `mcpIdentities` (an
    `MCPIdentity` per server), by signing an assertion through the key manager (Decision
    747).
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

  defmodule MCPIdentity do
    @moduledoc """
    The identity a profile calls one bundle server as, with OAuth client credentials
    (Decision 747).

    The bundle marks a server `client_credentials`; the profile says who it is there: the
    client registered for it at the identity provider, the scope to ask for, where tokens
    come from (`token_url`, or the authorization server's metadata when absent), and the
    OpenBao transit key that signs the assertion together with the SHA-256 thumbprint of
    the certificate registered for that key, which goes in the assertion's `x5t#S256`
    header. `key_version` pins the transit key's version, so a rotation changes the key and
    the thumbprint in one write; absent is the key's latest.

    Nothing here is secret, so all of it may sit in git. The private key never leaves
    OpenBao: the pod sends the assertion's signing input to transit and gets the signature
    back.
    """

    @algorithms ~w(RS256 PS256)
    @base64url ~r/\A[A-Za-z0-9_-]{43}\z/
    @hex ~r/\A(?:[0-9A-Fa-f]{2}:?){31}[0-9A-Fa-f]{2}\z/

    defstruct [
      :server,
      :client_id,
      :scope,
      :token_url,
      :transit_key,
      :key_version,
      :thumbprint,
      algorithm: "RS256"
    ]

    @type t :: %__MODULE__{
            server: String.t() | nil,
            client_id: String.t() | nil,
            scope: String.t() | nil,
            token_url: String.t() | nil,
            transit_key: String.t() | nil,
            key_version: pos_integer() | nil,
            thumbprint: String.t() | nil,
            algorithm: String.t()
          }

    @doc """
    Parse one entry of `spec.mcpIdentities`, in the resource's spelling.

    Lenient, because the operator and the plane report a broken entry (`problems/1`) rather
    than fail on it. The thumbprint is kept as `x5t#S256` wants it, base64url without
    padding, and may be written as the 64 hex digits `openssl x509 -fingerprint -sha256`
    prints, colons and all.
    """
    @spec from_spec(map()) :: t()
    def from_spec(entry) when is_map(entry) do
      %__MODULE__{
        server: string(entry["server"]),
        client_id: string(entry["clientId"]),
        scope: string(entry["scope"]),
        token_url: string(entry["tokenUrl"]),
        transit_key: string(entry["transitKey"]),
        key_version: entry["keyVersion"],
        thumbprint: thumbprint(entry["certificateThumbprint"]),
        algorithm: string(entry["algorithm"]) || "RS256"
      }
    end

    def from_spec(_entry), do: %__MODULE__{}

    @doc "Back into the resource's spelling: what the operator hands a pod, and `from_spec/1` reads."
    @spec to_spec(t()) :: map()
    def to_spec(%__MODULE__{} = identity) do
      %{
        "server" => identity.server,
        "clientId" => identity.client_id,
        "scope" => identity.scope,
        "tokenUrl" => identity.token_url,
        "transitKey" => identity.transit_key,
        "keyVersion" => identity.key_version,
        "certificateThumbprint" => identity.thumbprint,
        "algorithm" => identity.algorithm
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end

    @doc """
    A certificate thumbprint as `x5t#S256` carries it, or the value as given when it is
    neither shape, so `problems/1` can say so.
    """
    @spec thumbprint(term()) :: String.t() | nil
    def thumbprint(value) when is_binary(value) do
      value = String.trim(value)

      if Regex.match?(@hex, value) do
        value
        |> String.replace(":", "")
        |> Base.decode16!(case: :mixed)
        |> Base.url_encode64(padding: false)
      else
        value
      end
    end

    def thumbprint(_value), do: nil

    @doc "What is wrong with an entry, one sentence each; none for one a pod can use."
    @spec problems(t()) :: [String.t()]
    def problems(%__MODULE__{} = identity) do
      name = identity.server || "?"

      [
        {is_nil(identity.server), "an entry of mcpIdentities names no server"},
        {is_nil(identity.client_id), "mcp server #{name}: the identity has no clientId"},
        {is_nil(identity.transit_key), "mcp server #{name}: the identity has no transitKey"},
        {not thumbprint?(identity.thumbprint),
         "mcp server #{name}: certificateThumbprint is not a SHA-256 thumbprint " <>
           "(43 base64url characters, or 64 hex digits)"},
        {identity.algorithm not in @algorithms,
         "mcp server #{name}: algorithm #{inspect(identity.algorithm)} is not RS256 or PS256"},
        {not version?(identity.key_version),
         "mcp server #{name}: keyVersion is not a version number"},
        {not secure?(identity.token_url), "mcp server #{name}: tokenUrl is not an https URL"}
      ]
      |> Enum.flat_map(fn {wrong?, sentence} -> if wrong?, do: [sentence], else: [] end)
    end

    @doc """
    Whether a signed assertion may be sent to this URL: `https`, or plain `http` to this
    machine's own loopback address, which is what a test's token endpoint is.
    """
    @spec secure?(String.t() | nil) :: boolean()
    def secure?(nil), do: true

    def secure?(url) when is_binary(url) do
      case URI.parse(url) do
        %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
        %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
        _other -> false
      end
    end

    def secure?(_url), do: false

    defp thumbprint?(value), do: is_binary(value) and Regex.match?(@base64url, value)

    defp version?(nil), do: true
    defp version?(version), do: is_integer(version) and version > 0

    defp string(value) when is_binary(value) and value != "", do: value
    defp string(_value), do: nil
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
    # Who the profile is at the servers its bundle calls with client credentials (Decision
    # 747). The owner's to write, in a repository or through `admin.profile.put`; unlike
    # `mcp_servers`, never a projection of the plane's.
    mcp_identities: [],
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
      mcp_identities: Enum.map(Map.get(spec, "mcpIdentities") || [], &MCPIdentity.from_spec/1),
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

  The LLM endpoint, the MCP servers and the token endpoints the profile's identities name
  are in here, not only the declared FQDNs: a profile that could name any endpoint could
  send a team's code anywhere, so policy has to see them as egress too. A token endpoint
  found in an authorization server's metadata is not known until a pod asks, and its host
  is declared in `egress.fqdns`.
  """
  @spec egress_destinations(t()) :: [String.t()]
  def egress_destinations(%__MODULE__{} = profile) do
    urls =
      [profile.llm_endpoint | Enum.map(profile.mcp_servers, & &1.url)] ++
        Enum.map(profile.mcp_identities, & &1.token_url)

    endpoints = Enum.map(urls, &host_of/1)

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

  @doc """
  What keeps the profile from calling its client-credentials servers as itself, one
  sentence each: a server the bundle marks `client_credentials` that the profile gives no
  identity, and an identity that is missing its client or its key or is otherwise broken.

  Reported, as a missing Secret is, rather than refused: the bundle and the profile are
  written by different people at different times, and either may be first. The operator
  says it in the `MCPIdentityMissing` condition and the plane beside the profile.
  """
  @spec identity_problems(t()) :: [String.t()]
  def identity_problems(%__MODULE__{} = profile) do
    named = MapSet.new(profile.mcp_identities, & &1.server)

    missing =
      for %MCPServer{credential_mode: "client_credentials", name: name} <- profile.mcp_servers,
          not MapSet.member?(named, name) do
        "mcp server #{name} is called with client credentials, and the profile gives it no " <>
          "identity in mcpIdentities"
      end

    missing ++ Enum.flat_map(profile.mcp_identities, &MCPIdentity.problems/1)
  end

  @doc "Secrets the profile references, which have to exist before it can run."
  @spec secret_names(t()) :: [String.t()]
  def secret_names(%__MODULE__{} = profile) do
    [profile.llm_secret_name | Enum.map(profile.mcp_servers, & &1.secret_name)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # -- finishing an upgrade (Decision 726) --------------------------------------
  #
  # A pod rolls `OnDelete`, and the two halves of replacing one belong to two writers. The
  # operator knows which pods run an older revision and says so in the status, which is
  # its own. The plane knows when a pod's drain has finished and says so in an annotation,
  # because its grant is on the resource and not on the status. Both are parsed here so
  # the two cannot come to spell them differently.

  @drained "troupe.dev/drained"

  @doc "The annotation the plane records finished drains in."
  @spec drained_annotation() :: String.t()
  def drained_annotation, do: @drained

  @doc """
  The pods the plane has finished draining, by name, with the revision each ran.

  A JSON object in `metadata.annotations["troupe.dev/drained"]`, such as
  `{"troupe-w-dev-1":"troupe-w-dev-7c9f"}`. Missing or unreadable is nothing drained.
  """
  @spec drained(map()) :: %{String.t() => String.t()}
  def drained(resource) do
    with json when is_binary(json) <- get_in(resource, ["metadata", "annotations", @drained]),
         {:ok, %{} = drained} <- Jason.decode(json) do
      for {pod, revision} <- drained, is_binary(revision), into: %{}, do: {pod, revision}
    else
      _unrecorded -> %{}
    end
  end

  @doc "The annotation's value for these finished drains."
  @spec encode_drained(%{String.t() => String.t()}) :: String.t()
  def encode_drained(drained), do: Jason.encode!(drained)

  @doc """
  The pods the operator reports on an older revision, as it wrote them in
  `status.podsBehind`: each one's name, uid and revision. A pod already being replaced is
  not among them.
  """
  @spec pods_behind(map()) :: [%{pod: String.t(), uid: String.t() | nil, revision: String.t() | nil}]
  def pods_behind(resource) do
    for %{"pod" => pod} = entry <- get_in(resource, ["status", "podsBehind"]) || [], is_binary(pod) do
      %{pod: pod, uid: entry["uid"], revision: entry["revision"]}
    end
  end
end
