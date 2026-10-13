defmodule Troupe.Protocol.ProviderTypes do
  @moduledoc """
  The provider types, by name, and what choosing one asks of a person: the one list of
  them every party reads (#658).

  A person picks a provider in several places: `troupe setup` and `troupe config`, the
  terminal UI's settings, the desktop app's first run and its Models panel, and on a
  plane a profile's `llm.provider` and the provider its people's own machines are
  offered. The plane does not depend on the core, so the list is here, where both reach
  it: `Troupe.LLM.ProviderType` adds to each type what speaking to it takes (the adapter,
  where its model list comes from, what a call says about Troupe) and does not compile
  with a type this list lacks, `Troupe.Protocol.Organisation` enforces these names, the
  daemon hands `wire/0` to a client that draws a choice, and a test holds the
  WorkerProfile resource's enum to `names/0`.

  What a person is asked follows from three facts about a type:

    * `url`, where it is: `:own`, the vendor's own endpoint, which a gateway that speaks
      its API stands in for at a `base_url`; `:server`, a server of the person's, at
      `default_url` unless they say; `:required`, an address only the person knows, with
      no default (`url_example` shows its shape); `:none`, nowhere.
    * `key`: `:required`, or `:none` for a type asked with no key at all.
    * `key_var`: the variable that stands in for a key when none is given, sent only to
      the vendor's own endpoint; `nil` where none does.

  `named` is false for the one type only the session-wide `provider` may be (`fake`,
  scripted answers for a smoke test), which no screen offers.
  """

  @type url :: :own | :server | :required | :none
  @type key :: :required | :none

  @type t :: %{
          name: String.t(),
          label: String.t(),
          summary: String.t(),
          url: url(),
          default_url: String.t() | nil,
          url_example: String.t() | nil,
          key: key(),
          key_var: String.t() | nil,
          named: boolean()
        }

  @types [
    %{
      name: "anthropic",
      label: "Anthropic",
      summary: "Claude, at Anthropic's own endpoint, with a key from console.anthropic.com.",
      url: :own,
      default_url: "https://api.anthropic.com",
      url_example: nil,
      key: :required,
      key_var: "ANTHROPIC_API_KEY",
      named: true
    },
    %{
      name: "openai",
      label: "OpenAI",
      summary: "GPT, at OpenAI's own endpoint, with a key from platform.openai.com.",
      url: :own,
      default_url: "https://api.openai.com",
      url_example: nil,
      key: :required,
      key_var: "OPENAI_API_KEY",
      named: true
    },
    %{
      name: "ollama",
      label: "Ollama",
      summary:
        "Models you run yourself, on an Ollama server on this computer or your network. No key, and nothing leaves that server.",
      url: :server,
      default_url: "http://localhost:11434",
      url_example: nil,
      key: :none,
      key_var: nil,
      named: true
    },
    %{
      name: "openrouter",
      label: "OpenRouter",
      summary:
        "Many vendors' models behind one key from openrouter.ai, each priced as OpenRouter lists it.",
      url: :own,
      default_url: "https://openrouter.ai/api/v1",
      url_example: nil,
      key: :required,
      key_var: "OPENROUTER_API_KEY",
      named: true
    },
    %{
      name: "azure_openai",
      label: "Azure OpenAI",
      summary:
        "OpenAI's models in your own Azure resource, at its address, with its key. A model is a deployment's name.",
      url: :required,
      default_url: nil,
      url_example: "https://<resource>.openai.azure.com",
      key: :required,
      key_var: nil,
      named: true
    },
    %{
      name: "gemini",
      label: "Gemini",
      summary:
        "Google's Gemini models, through the Gemini API, with a key from aistudio.google.com.",
      url: :own,
      default_url: "https://generativelanguage.googleapis.com/v1beta/openai",
      url_example: nil,
      key: :required,
      key_var: "GEMINI_API_KEY",
      named: true
    },
    %{
      name: "fake",
      label: "The fake provider",
      summary:
        "Scripted replies from the file TROUPE_FAKE_SCRIPT names, not a model: nothing is sent anywhere.",
      url: :none,
      default_url: nil,
      url_example: nil,
      key: :none,
      key_var: nil,
      named: false
    }
  ]

  @by_name Map.new(@types, &{&1.name, &1})

  @doc "Every type, in the order a screen offers them and the reference lists them."
  @spec all() :: [t()]
  def all, do: @types

  @doc "Every type's name: what the session-wide `provider` may be."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@types, & &1.name)

  @doc "The names a named provider's `type` may be, and a screen offers: every type but `fake`."
  @spec named() :: [String.t()]
  def named, do: for(type <- @types, type.named, do: type.name)

  @doc "A type by name, or `nil` for a name that is no type."
  @spec fetch(String.t() | atom() | nil) :: t() | nil
  def fetch(name) when is_atom(name) and not is_nil(name), do: fetch(Atom.to_string(name))
  def fetch(name) when is_binary(name), do: Map.get(@by_name, name)
  def fetch(_name), do: nil

  @doc "Whether a type is asked with no key at all."
  @spec keyless?(String.t() | atom() | nil) :: boolean()
  def keyless?(name), do: match?(%{key: :none}, fetch(name))

  @doc "Whether a type has no address of its own, so a provider of it without one is refused."
  @spec needs_url?(String.t() | atom() | nil) :: boolean()
  def needs_url?(name), do: match?(%{url: :required}, fetch(name))

  # The two ways beside the types that an OpenAI-compatible server is reached at an
  # address of the person's: a gateway is the type of the API it speaks.
  @gateways [
    %{
      "id" => "gateway",
      "provider" => "openai",
      "label" => "An OpenAI-compatible gateway",
      "summary" =>
        "Anything speaking Chat Completions at a URL of yours: vLLM, LM Studio, a company gateway. Some want no key.",
      "url" => "required",
      "default_url" => nil,
      "url_example" => "https://llm-gw.example/v1",
      "key" => "optional",
      "key_var" => nil
    },
    %{
      "id" => "litellm",
      "provider" => "openai",
      "label" => "A LiteLLM proxy",
      "summary" => "A LiteLLM proxy at its URL. The one gateway that says what each model costs.",
      "url" => "required",
      "default_url" => nil,
      "url_example" => "https://llm-gw.example/v1",
      "key" => "optional",
      "key_var" => nil
    }
  ]

  @doc """
  The ways a first run may set a provider up, in the order a screen offers them: every
  type of `wire/0`, its `id` the type's name and its `provider` the same, then a gateway
  and a LiteLLM proxy, which are `openai` at an address of the person's. `key` may be
  `optional` here, for a gateway that wants none. What the daemon's `setup.get` carries
  as `kinds`.
  """
  @spec kinds() :: [map()]
  def kinds do
    types =
      for type <- wire() do
        {name, type} = Map.pop!(type, "name")
        Map.merge(type, %{"id" => name, "provider" => name})
      end

    types ++ @gateways
  end

  @doc """
  The types a screen offers, as a client reads them: every named type, its keys strings
  and its atoms words. What the daemon's `setup.get` and `config.get` carry.
  """
  @spec wire() :: [map()]
  def wire do
    for type <- @types, type.named do
      %{
        "name" => type.name,
        "label" => type.label,
        "summary" => type.summary,
        "url" => Atom.to_string(type.url),
        "default_url" => type.default_url,
        "url_example" => type.url_example,
        "key" => Atom.to_string(type.key),
        "key_var" => type.key_var
      }
    end
  end
end
