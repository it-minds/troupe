defmodule Troupe.LLM.ProviderType do
  @moduledoc """
  Every provider type a config may name, in one table: the adapter that speaks to it,
  where it is when no `base_url` says, the variable that stands in for a key and where
  that variable may be sent, what its model list is read from, what a call says about
  Troupe there, and, for a person, what it does about the key, the config keys, thinking
  and caching.

  Everything that has to know a type reads it from here: the config schema's two enums
  (`provider` and `providers.<name>.type`), the loader, the key rules
  (`Troupe.LLM.Endpoint`), what a call says about Troupe (`Troupe.LLM.Identify`), the
  model catalogue (`Troupe.LLM.Catalog.Store`), and the adapters. `ollama`,
  `openrouter`, `azure_openai` and `gemini` speak OpenAI's Chat Completions shape and go
  through `Troupe.LLM.Providers.OpenAI`; what each does differently on the wire is
  `Troupe.LLM.Providers.Compatible`. `reference/0` is the table in
  `docs/user/configuration.md`, written by `mix troupe.config.schema`.

  The types themselves, their names and what choosing one asks of a person (its label,
  where it is, whether it takes a key and which variable stands in for one) are
  `Troupe.Protocol.ProviderTypes`, the list the plane and the clients read too; this
  module adds what speaking to each takes, and does not compile with a type that list
  lacks or one it does not have.

  A type nobody implements is not a type: a file that names one is refused, naming the
  file, the key and these. Bedrock and Vertex are not here: each signs its requests with
  its cloud's own credentials (SigV4, a Google service account) rather than taking a key.
  """

  alias Troupe.Protocol.ProviderTypes

  @enforce_keys [:name]
  defstruct [
    :name,
    :adapter,
    # What a person choosing it reads, and what choosing it asks
    # (`Troupe.Protocol.ProviderTypes`).
    :label,
    :summary,
    :url,
    :url_example,
    :key,
    # Where it is when the config gives no `base_url`; `nil` where there is no such place
    # and the config must say (`azure_openai`), or no place at all (`fake`).
    :base_url,
    # The variable a key is read from when the config gives none, and the vendor's own
    # endpoint, the only place it is sent (`Troupe.LLM.Endpoint.vendor?/2`).
    :key_var,
    :vendor_url,
    # Where its model list comes from (`Troupe.LLM.Catalog.Store`), `nil` for none.
    :listing,
    # What a call says about Troupe beyond the User-Agent: `:gateway` sends LiteLLM's
    # tags wherever the endpoint is not the vendor's own, `:openrouter` OpenRouter's app
    # headers, `:plain` nothing more.
    identify: :plain,
    # Asked with no key at all, as a local server is.
    keyless: false,
    # Without a `base_url` the provider is refused.
    needs_base_url: false,
    # A named provider may be of this type; `fake` is the session-wide provider's alone.
    named: true,
    # For the reference: what a person reads in each column.
    endpoint: "",
    auth: "",
    keys: "",
    models: "",
    thinking: "",
    caching: ""
  ]

  @type t :: %__MODULE__{}

  # What speaking to each type takes, in `Troupe.Protocol.ProviderTypes`' order; the rest
  # of a row is that list's.
  @speaking [
    %{
      name: :anthropic,
      adapter: Troupe.LLM.Providers.Anthropic,
      vendor_url: "https://api.anthropic.com",
      listing: :anthropic,
      identify: :gateway,
      endpoint:
        "Anthropic's Messages API at `https://api.anthropic.com`, or a gateway that speaks it at its `base_url`.",
      auth:
        "`x-api-key`, or `Authorization: Bearer` with `auth: bearer`. Without a key, `ANTHROPIC_API_KEY`, " <>
          "sent only to Anthropic's own endpoint.",
      keys: "`base_url`, `api_key`, `auth`, `models`, `binds_thinking`",
      models:
        "`/v1/models`: each model's window, output cap and the thinking it takes; no prices.",
      thinking:
        "`reasoning_effort` becomes adaptive thinking or a budget, whichever the model takes; the output cap " <>
          "is raised to hold it, no further than an enforced `max_tokens`. Thinking is handed back.",
      caching:
        "Troupe marks the tools, the system prompt and the conversation for Anthropic's cache; what it read " <>
          "and wrote is reported."
    },
    %{
      name: :openai,
      adapter: Troupe.LLM.Providers.OpenAI,
      vendor_url: "https://api.openai.com",
      listing: :openai,
      identify: :gateway,
      endpoint:
        "OpenAI's Chat Completions at `https://api.openai.com`, or any server that speaks it (LiteLLM, vLLM, " <>
          "LM Studio) at its `base_url`.",
      auth:
        "`Authorization: Bearer`. Without a key, `OPENAI_API_KEY`, sent only to OpenAI's own endpoint; a " <>
          "server elsewhere is sent only a key of its own, and may need none.",
      keys: "`base_url`, `api_key`, `models`",
      models:
        "A LiteLLM gateway's `/model_group/info`, with windows and prices, else `/v1/models`; asked only " <>
          "with a `base_url`.",
      thinking:
        "`reasoning_effort` is sent as written, with the output cap as `max_completion_tokens`, which the " <>
          "reasoning spends from. Reasoning is handed back.",
      caching:
        "Whatever the server does by itself; Troupe sends no marks. What it read from its cache, and through " <>
          "LiteLLM what Anthropic wrote, is reported."
    },
    %{
      name: :ollama,
      adapter: Troupe.LLM.Providers.OpenAI,
      listing: :openai,
      endpoint:
        "Ollama's OpenAI-compatible endpoint, at `http://localhost:11434` unless `base_url` says.",
      auth:
        "None. A key that is set is sent as `Authorization: Bearer`, for a proxy in front of the server.",
      keys: "`base_url`, `api_key`, `models`",
      models:
        "The server's `/v1/models`, asked with no key: the models pulled there. Nothing is priced.",
      thinking:
        "`reasoning_effort` is sent as written, beside `max_tokens`; the reasoning a model streams is shown.",
      caching:
        "The server keeps a loaded model's last prompt in memory by itself; nothing is billed or reported."
    },
    %{
      name: :openrouter,
      adapter: Troupe.LLM.Providers.OpenAI,
      vendor_url: "https://openrouter.ai",
      listing: :openrouter,
      identify: :openrouter,
      endpoint:
        "OpenRouter's Chat Completions at `https://openrouter.ai/api/v1`. A model is OpenRouter's id after the " <>
          "provider's name: `openrouter/anthropic/claude-sonnet-4.5`.",
      auth:
        "`Authorization: Bearer`. Without a key, `OPENROUTER_API_KEY`, sent only to openrouter.ai. " <>
          "`HTTP-Referer` and `X-Title` name Troupe there, unless `identify: false`.",
      keys: "`base_url`, `api_key`, `models`",
      models: "`/models`: each model's window, output cap and prices, its cache rates included.",
      thinking:
        "`reasoning_effort` is sent as OpenRouter's `reasoning`: `effort`, or `max_tokens` for a number, beside " <>
          "`max_tokens`, which the reasoning spends from.",
      caching:
        "Whatever the model's own provider does by itself; Troupe sends no marks, so an Anthropic model there is " <>
          "not cached. What it read is reported."
    },
    %{
      name: :azure_openai,
      adapter: Troupe.LLM.Providers.OpenAI,
      listing: nil,
      endpoint:
        "Your Azure OpenAI resource, which `base_url` names: `https://<resource>.openai.azure.com`. A call goes to " <>
          "`/openai/deployments/<model>/chat/completions?api-version=<api_version>`, so a model's name, or its " <>
          "`id`, is the deployment's.",
      auth:
        "`api-key`, or `Authorization: Bearer` with `auth: bearer`, for a Microsoft Entra token. No variable " <>
          "stands in for a key.",
      keys:
        "`base_url` (required), `api_key`, `auth`, `api_version` (`2024-10-21` unless set), `models`",
      models:
        "None: Azure lists deployments only through its management API, so name them under `models:`.",
      thinking:
        "As `openai`: `reasoning_effort` as written, with `max_completion_tokens`. A reasoning model may need a " <>
          "later `api_version`.",
      caching: "Azure caches a long enough prompt by itself, and reports what it read."
    },
    %{
      name: :gemini,
      adapter: Troupe.LLM.Providers.OpenAI,
      vendor_url: "https://generativelanguage.googleapis.com",
      listing: :gemini,
      identify: :gateway,
      endpoint:
        "The Gemini API's OpenAI-compatible endpoint, `https://generativelanguage.googleapis.com/v1beta/openai`.",
      auth:
        "`Authorization: Bearer`. Without a key, `GEMINI_API_KEY`, sent only to Google's endpoint.",
      keys: "`base_url`, `api_key`, `models`",
      models: "`/models` on that endpoint: the ids, without windows or prices.",
      thinking:
        "`reasoning_effort` is sent as written, beside `max_tokens`, which the thinking spends from. The thought " <>
          "signature Gemini puts on a tool call is handed back with it.",
      caching:
        "Gemini caches a repeated prefix by itself on the models that do; what the endpoint says it read is counted."
    },
    %{
      name: :fake,
      adapter: Troupe.LLM.Providers.Fake,
      endpoint:
        "None: scripted answers, for a packaged binary's smoke test. The session-wide `provider` only.",
      auth: "None.",
      keys: "`fake_script`",
      models: "None.",
      thinking: "None.",
      caching: "None."
    }
  ]

  # A type the protocol's list has and this one does not, or the other way round, is a
  # build that would offer a person a type nothing speaks, or speak one nobody is offered.
  unless Enum.map(@speaking, &Atom.to_string(&1.name)) == ProviderTypes.names() do
    raise CompileError,
      description:
        "Troupe.LLM.ProviderType's types #{inspect(Enum.map(@speaking, & &1.name))} are not " <>
          "Troupe.Protocol.ProviderTypes' #{inspect(ProviderTypes.names())}, in that order"
  end

  @table Enum.map(@speaking, fn speaking ->
           type = ProviderTypes.fetch(speaking.name)

           Map.merge(speaking, %{
             label: type.label,
             summary: type.summary,
             url: type.url,
             url_example: type.url_example,
             key: type.key,
             base_url: type.default_url,
             key_var: type.key_var,
             keyless: type.key == :none,
             needs_base_url: type.url == :required,
             named: type.named
           })
         end)

  @by_name Map.new(@table, &{Atom.to_string(&1.name), &1})

  # Names people reach for that are another type's, for `troupe config migrate`: a
  # gateway's own name is the API it speaks, and two vendors' other spellings.
  @rewrites %{
    "litellm" => "openai",
    "vllm" => "openai",
    "lmstudio" => "openai",
    "openai-compatible" => "openai",
    "openai_compatible" => "openai",
    "google" => "gemini",
    "azure" => "azure_openai",
    "azure-openai" => "azure_openai"
  }

  @doc "Every type, in the reference's order."
  @spec all() :: [t()]
  def all, do: Enum.map(@table, &struct!(__MODULE__, &1))

  @doc "The session-wide `provider`'s names, `fake` among them."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@table, &Atom.to_string(&1.name))

  @doc "The names a named provider's `type` may be: every type but `fake`."
  @spec named() :: [String.t()]
  def named, do: for(type <- @table, Map.get(type, :named, true), do: Atom.to_string(type.name))

  @doc "The type a name or atom is, or `nil` for one nobody implements."
  @spec fetch(String.t() | atom() | nil) :: t() | nil
  def fetch(name) when is_atom(name) and not is_nil(name), do: fetch(Atom.to_string(name))

  def fetch(name) when is_binary(name) do
    case Map.fetch(@by_name, name) do
      {:ok, type} -> struct!(__MODULE__, type)
      :error -> nil
    end
  end

  def fetch(_name), do: nil

  @doc "The atom a type's name is, or `nil`: never an atom made from a name nobody implements."
  @spec atom(String.t() | atom() | nil) :: atom() | nil
  def atom(name) do
    case fetch(name) do
      %__MODULE__{name: atom} -> atom
      nil -> nil
    end
  end

  @doc "The adapter for a type."
  @spec adapter(String.t() | atom()) :: {:ok, module()} | {:error, {:unknown_provider, term()}}
  def adapter(name) do
    case fetch(name) do
      %__MODULE__{adapter: adapter} -> {:ok, adapter}
      nil -> {:error, {:unknown_provider, name}}
    end
  end

  @doc "Where a type is when no `base_url` says, or `nil`."
  @spec default_base_url(String.t() | atom() | nil) :: String.t() | nil
  def default_base_url(name) do
    case fetch(name) do
      %__MODULE__{base_url: url} -> url
      nil -> nil
    end
  end

  @doc "Whether a provider of this type may be asked with no key at all."
  @spec keyless?(String.t() | atom() | nil) :: boolean()
  def keyless?(name), do: match?(%__MODULE__{keyless: true}, fetch(name))

  @doc "Whether a provider of this type lists its models to a request that carries no key."
  @spec listed_without_key?(String.t() | atom() | nil) :: boolean()
  def listed_without_key?(name),
    do: match?(%__MODULE__{keyless: true, listing: listing} when listing != nil, fetch(name))

  @doc "Whether a provider of this type is refused without a `base_url`."
  @spec needs_base_url?(String.t() | atom() | nil) :: boolean()
  def needs_base_url?(name), do: match?(%__MODULE__{needs_base_url: true}, fetch(name))

  @doc """
  The type a name that is not one stands for, when there is one people mean by it:
  `litellm` is `openai`, `google` is `gemini`. What `troupe config migrate` rewrites.
  """
  @spec rewrite(term()) :: String.t() | nil
  def rewrite(name) when is_binary(name), do: Map.get(@rewrites, String.downcase(name))
  def rewrite(_name), do: nil

  @doc """
  The provider-type table as Markdown, one row a type: what `docs/user/configuration.md`
  carries between its generated markers.
  """
  @spec reference() :: String.t()
  def reference do
    "| Type | Endpoint | Key | Keys that apply | Model list | Thinking | Caching |\n" <>
      "|---|---|---|---|---|---|---|\n" <>
      Enum.map_join(all(), "", fn type ->
        "| `#{type.name}` | #{type.endpoint} | #{type.auth} | #{type.keys} | #{type.models} | " <>
          "#{type.thinking} | #{type.caching} |\n"
      end)
  end
end
