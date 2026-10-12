defmodule Troupe.LLM.Endpoint do
  @moduledoc """
  Joining a configured base URL to a provider's path.

  Every OpenAI-compatible tool takes a base URL that already ends in `/v1` — that is
  what LiteLLM, vLLM and the OpenAI SDK all print in their own documentation — while
  the provider's path is conventionally written `/v1/chat/completions`. Joining those
  naively gives `/v1/v1/chat/completions`, which 404s.

  So the version segment is dropped from the base when it is already there. Both forms
  work, and a base URL with a path prefix of its own (a gateway mounted under
  `/proxy/openai`, say) is preserved.
  """

  alias Troupe.LLM.ProviderType

  @doc """
  Build a request URL from a base and a versioned path.

      iex> Troupe.LLM.Endpoint.build("https://api.openai.com", "/v1/chat/completions")
      "https://api.openai.com/v1/chat/completions"

      iex> Troupe.LLM.Endpoint.build("https://gateway.example/v1", "/v1/chat/completions")
      "https://gateway.example/v1/chat/completions"

      iex> Troupe.LLM.Endpoint.build("https://gateway.example/proxy/v1/", "/v1/messages")
      "https://gateway.example/proxy/v1/messages"
  """
  @spec build(String.t(), String.t()) :: String.t()
  def build(base, path) when is_binary(base) and is_binary(path) do
    base = String.trim_trailing(base, "/")
    ["", version, rest] = String.split(path, "/", parts: 3)

    if String.ends_with?(base, "/" <> version) do
      base <> "/" <> rest
    else
      base <> "/" <> version <> "/" <> rest
    end
  end

  @doc """
  A request URL for a provider of `type`: its `base_url`, or the type's own where none is
  set (`Troupe.LLM.ProviderType`), joined to a versioned path as `build/2` joins it. The
  Gemini API's OpenAI-compatible root carries its version in a path of its own
  (`/v1beta/openai`), so there the path goes after the root without its version.

      iex> Troupe.LLM.Endpoint.url(:ollama, nil, "/v1/chat/completions")
      "http://localhost:11434/v1/chat/completions"

      iex> Troupe.LLM.Endpoint.url(:gemini, nil, "/v1/models")
      "https://generativelanguage.googleapis.com/v1beta/openai/models"
  """
  @spec url(atom() | String.t(), String.t() | nil, String.t()) :: String.t()
  def url(type, base_url, path) do
    base = present(base_url) || ProviderType.default_base_url(type) || ""

    case ProviderType.atom(type) do
      :gemini ->
        ["", _version, rest] = String.split(path, "/", parts: 3)
        String.trim_trailing(base, "/") <> "/" <> rest

      _other ->
        build(base, path)
    end
  end

  defp present(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      url -> url
    end
  end

  defp present(_url), do: nil

  @doc """
  Whether a configured base URL is the vendor's own endpoint: none configured, or one on
  the same host over HTTPS. What decides whether a vendor's key variable
  (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`) may be
  sent there.

      iex> Troupe.LLM.Endpoint.vendor?(nil, "https://api.openai.com")
      true

      iex> Troupe.LLM.Endpoint.vendor?("https://api.openai.com/v1", "https://api.openai.com")
      true

      iex> Troupe.LLM.Endpoint.vendor?("https://llm-gw.example/v1", "https://api.openai.com")
      false
  """
  @spec vendor?(String.t() | nil, String.t()) :: boolean()
  def vendor?(nil, _vendor), do: true
  def vendor?("", _vendor), do: true

  def vendor?(base, vendor) when is_binary(base) do
    %URI{scheme: scheme, host: host} = URI.parse(String.trim(base))
    scheme == "https" and is_binary(host) and String.downcase(host) == URI.parse(vendor).host
  end

  @doc """
  The variable holding a vendor's own key, when a provider of that type at `base_url` may
  be sent it — that is, when `base_url` is the vendor's own endpoint — and `nil` for a
  gateway or any other provider, which is sent no key it was not given. A type with no
  vendor's variable (`ollama`, `azure_openai`) has none anywhere.

      iex> Troupe.LLM.Endpoint.vendor_key_var(:anthropic, nil)
      "ANTHROPIC_API_KEY"

      iex> Troupe.LLM.Endpoint.vendor_key_var("openai", "https://llm-gw.example/v1")
      nil

      iex> Troupe.LLM.Endpoint.vendor_key_var(:openrouter, "https://openrouter.ai/api/v1")
      "OPENROUTER_API_KEY"
  """
  @spec vendor_key_var(atom() | String.t(), String.t() | nil) :: String.t() | nil
  def vendor_key_var(type, base_url) do
    case ProviderType.fetch(type) do
      %ProviderType{key_var: var, vendor_url: vendor} when is_binary(var) ->
        if vendor?(base_url, vendor), do: var

      _none ->
        nil
    end
  end

  @doc """
  Whether a provider of this type at `base_url` is the vendor's own API rather than a
  gateway or a server of somebody else's; `false` for a type no vendor has.

      iex> Troupe.LLM.Endpoint.vendor_api?(:anthropic, nil)
      true

      iex> Troupe.LLM.Endpoint.vendor_api?(:openai, "https://llm-gw.example/v1")
      false
  """
  @spec vendor_api?(atom() | String.t(), String.t() | nil) :: boolean()
  def vendor_api?(type, base_url), do: vendor_key_var(type, base_url) != nil
end
