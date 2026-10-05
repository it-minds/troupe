defmodule Troupe.LLM.Identify do
  @moduledoc """
  What Troupe says about itself on a model call, so that whoever runs the gateway can see
  which of their spend is Troupe's, from which client and on which version (Decision 787).

    * **`User-Agent: troupe/<version> (<client>; <os>/<arch>)`**, on every call to every
      endpoint. A gateway records it with each request (LiteLLM tags its spend with it),
      and it is the only convention the vendors' own APIs have.
    * **To a gateway** — an endpoint that is neither a vendor's own API nor OpenRouter —
      LiteLLM's `x-litellm-tags` (`troupe`, `troupe-<client>`, `troupe-<version>`) and
      `x-litellm-spend-logs-metadata`: the session's id, and its team, worker profile and
      agent where the plane attributes the session. A server that is not LiteLLM ignores
      both.
    * **To OpenRouter**, `HTTP-Referer` (the project's page) and `X-Title: Troupe`, which
      name the app there, and nothing of LiteLLM's.
    * **In an OpenAI-compatible body**, `troupe_client` and `troupe_version` beside the
      session's id in `metadata` (`metadata/1`).

  The client is a word from a fixed list, `clients/0`, never what a client called itself:
  the session's own (`Troupe.Config` `:client`), named by the connection that created or
  woke it, or `worker` on a pod.

  A local session names the software and nothing else: no person, no path, no repository
  (an agent's name may be a repository's own), no hostname, no email. The plane's
  attribution of a pod session (`Request.attribution`) goes out as it did before this,
  identify or not: it is an arrangement the operator made with their gateway.

  `identify: false` sends none of this, and the User-Agent is the HTTP client's own.
  """

  alias Troupe.LLM.{Endpoint, Request}

  @clients ~w(tui headless desktop acp worker other)
  @project_url "https://github.com/it-minds/troupe"

  @doc "Every word a client is named by."
  @spec clients() :: [String.t()]
  def clients, do: @clients

  @doc """
  The client a connection is, from the protocol it speaks and the name it gave in
  `initialize`: `troupe` is the terminal UI, `troupe-headless` its headless run,
  `troupe-gui` the desktop app, any ACP editor `acp`, and anything else `other`.
  """
  @spec client(atom(), map() | nil) :: String.t()
  def client(:acp, _client_info), do: "acp"

  def client(_protocol, %{} = client_info) do
    case client_info["name"] || client_info[:name] do
      "troupe" -> "tui"
      "troupe-headless" -> "headless"
      "troupe-gui" -> "desktop"
      _ -> "other"
    end
  end

  def client(_protocol, _client_info), do: "other"

  @doc "The User-Agent for a client: `troupe/0.8.3 (tui; windows/x86_64)`."
  @spec user_agent(String.t() | nil) :: String.t()
  def user_agent(client), do: "troupe/#{version()} (#{word(client)}; #{platform()})"

  @doc "LiteLLM's tags for a client, as `x-litellm-tags` carries them."
  @spec tags(String.t() | nil) :: String.t()
  def tags(client),
    do: Enum.join(["troupe", "troupe-" <> word(client), "troupe-" <> version()], ",")

  @doc """
  The headers a request carries about Troupe, for an adapter whose vendor is `type`
  (`:openai`, `:anthropic`): none when the request says not to identify.
  """
  @spec headers(Request.t(), atom() | String.t()) :: [{String.t(), String.t()}]
  def headers(%Request{identify: false}, _type), do: []

  def headers(%Request{} = request, type) do
    [{"user-agent", user_agent(request.client)} | endpoint_headers(request, type)]
  end

  defp endpoint_headers(%Request{base_url: url} = request, type) do
    cond do
      openrouter?(url) -> [{"http-referer", @project_url}, {"x-title", "Troupe"}]
      Endpoint.vendor_api?(type, url) -> []
      true -> [{"x-litellm-tags", tags(request.client)} | spend_metadata(request)]
    end
  end

  # The session's id always; what the plane knows of it only where the plane attributes it.
  defp spend_metadata(%Request{attribution: attribution}) do
    keys =
      if attributed?(attribution), do: [:session_id, :team, :profile, :agent], else: [:session_id]

    case strings(attribution, keys, "") do
      none when map_size(none) == 0 -> []
      metadata -> [{"x-litellm-spend-logs-metadata", Jason.encode!(metadata)}]
    end
  end

  # The keys whose values are text, named with a prefix; anything else is left out.
  defp strings(map, keys, prefix) do
    keys
    |> Enum.flat_map(fn key ->
      case string(Map.get(map, key)) do
        nil -> []
        value -> [{prefix <> to_string(key), value}]
      end
    end)
    |> Map.new()
  end

  @doc """
  `metadata` for an OpenAI-compatible body, or `nil`: a pod session's attribution as the
  plane set it, and a local session's id alone; with the client and the version beside
  either when the request identifies.
  """
  @spec metadata(Request.t()) :: map() | nil
  def metadata(%Request{attribution: attribution} = request) do
    sent =
      cond do
        attributed?(attribution) -> attribution
        request.identify -> Map.take(attribution, [:session_id])
        true -> %{}
      end

    sent =
      if request.identify,
        do: Map.merge(sent, %{client: word(request.client), version: version()}),
        else: sent

    case strings(sent, Map.keys(sent), "troupe_") do
      none when map_size(none) == 0 -> nil
      metadata -> metadata
    end
  end

  @doc "Whether the plane attributes the session: a worker set its owner or team."
  @spec attributed?(map()) :: boolean()
  def attributed?(attribution),
    do: string(attribution[:owner]) != nil or string(attribution[:team]) != nil

  @doc """
  What `troupe doctor` says goes out with a session's calls to a provider of `type` at
  `base_url`: the headers as they are sent, a session's id standing for itself.
  """
  @spec describe(boolean(), String.t() | nil, String.t() | atom(), String.t() | nil) :: String.t()
  def describe(false, _client, _type, _base_url), do: "off"

  def describe(true, client, type, base_url) do
    request = %Request{
      model: "",
      messages: [],
      base_url: base_url,
      client: client,
      attribution: %{session_id: "<session id>"}
    }

    request
    |> headers(type)
    |> Enum.map_join("; ", fn {name, value} -> "#{name}: #{value}" end)
  end

  @doc "The version every call names: the build's."
  @spec version() :: String.t()
  def version, do: Troupe.Version.version()

  @doc "`<os>/<arch>`, as the VM says: `windows/x86_64`, `macos/aarch64`, `linux/x86_64`."
  @spec platform() :: String.t()
  def platform, do: os() <> "/" <> arch()

  defp os do
    case :os.type() do
      {:win32, _} -> "windows"
      {:unix, :darwin} -> "macos"
      {_family, name} -> Atom.to_string(name)
    end
  end

  defp arch do
    case :erlang.system_info(:system_architecture) |> List.to_string() |> String.split("-") do
      [arch | _] when arch in ["aarch64", "arm64"] -> "aarch64"
      [arch | _] when arch in ["x86_64", "amd64"] -> "x86_64"
      [arch | _] -> arch
    end
  end

  defp openrouter?(url) when is_binary(url) do
    case URI.parse(String.trim(url)).host do
      host when is_binary(host) ->
        String.downcase(host) == "openrouter.ai" or String.ends_with?(host, ".openrouter.ai")

      _ ->
        false
    end
  end

  defp openrouter?(_url), do: false

  defp word(client) when client in @clients, do: client
  defp word(_client), do: "other"

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil
end
