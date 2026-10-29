defmodule Troupe.LLM.Request do
  @moduledoc """
  Everything a provider needs for one streamed completion.

  Built by the agent and handed to a task; the task is the only thing that ever sees
  a base URL or an API key.
  """

  alias Troupe.LLM.{Message, ProviderType}

  @enforce_keys [:model, :messages]
  defstruct [
    :model,
    :messages,
    system: nil,
    # The end of the system prompt that changes from one turn to the next — the task list,
    # held as the turn began (Decision 792) — kept apart so a provider's prompt cache can
    # stop in front of it (Decision 770). `system_text/1` is the two as one prompt, which
    # is what a provider without cache marks is sent.
    system_tail: nil,
    # Whether the provider is asked to cache the prompt for the next call. An agent's own
    # calls are, since each sends the one before's prompt again with a little more; a
    # one-off such as a compaction summary is not, since writing a cache costs more than
    # plain input and nothing would read it back.
    cache: false,
    tools: [],
    max_tokens: 8192,
    # The organisation's enforced `max_tokens`, when it enforces one: the most the call
    # may ask for whatever else wants room in it. An adapter that raises the output cap to
    # hold the thinking an effort asks for raises it no further, and shortens the thinking
    # to fit instead (issue #644). `nil` where nothing is enforced.
    ceiling: nil,
    temperature: nil,
    # How hard a reasoning model should think, verbatim from the model's `models:` entry
    # (Decision 658): an OpenAI-compatible provider takes the word, Anthropic a budget or
    # an effort level made from it. `nil` asks for no reasoning and gets the plain output
    # cap.
    reasoning_effort: nil,
    # The form the model takes thinking in, `:adaptive` or `:budget`, when the provider's
    # own model list says (Decision 780). `nil` leaves it to the adapter, which goes by the
    # model's name.
    thinking: nil,
    # `"drop_block"` when the config's `thinking_binding` asks Anthropic to drop a kept
    # thinking block whose conversation changed rather than refuse the call (issue #465,
    # Decision 815), `"error"` when it asks for the refusal (issue #591, Decision 863).
    # Only the Anthropic adapter reads it.
    thinking_binding: nil,
    base_url: nil,
    # `{:refused, why}` when the provider may not be used — a `{env:VAR}` its key or URL
    # reads is not set — which the adapter answers with that error and no request.
    api_key: nil,
    # How the key is presented: the provider's own scheme, or `Authorization: Bearer`
    # for a gateway that fronts a provider's API but not its authentication.
    auth: :api_key,
    # The adapter this request goes through, when the model named a provider other
    # than the session's. `nil` means the agent's own.
    provider: nil,
    # The provider type it goes to (`Troupe.LLM.ProviderType`): what an adapter that
    # speaks to several types does differently for this one
    # (`Troupe.LLM.Providers.Compatible`). `nil` is `openai`.
    type: nil,
    # Azure OpenAI's `api-version`, when the provider names one.
    api_version: nil,
    timeout_ms: 300_000,
    # How long the provider may take to send the first byte of its answer. Shorter than
    # `timeout_ms`, which a reply that has begun may spend thinking: a call that has not
    # begun at all is an address, a key or a proxy, not a model, and is said so sooner.
    first_byte_ms: 60_000,
    max_retries: 4,
    # Who this call is for, as the gateway is to record it. Every request a worker makes
    # is tagged with the session owner as the end user, plus the team and the session, so
    # the gateway's spend records and the plane's ledger can be reconciled against each
    # other without either side guessing.
    #
    # The owner, not the caller: a collaborator's input is billed to the owner's team
    # budget, because the budget belongs to the session and a session has one owner.
    attribution: %{},
    # What the call says about Troupe itself (Decision 787, `Troupe.LLM.Identify`): whether
    # it says anything, and which client the session is, a word from
    # `Identify.clients/0`.
    identify: true,
    client: nil,
    extra: %{}
  ]

  @type tool_spec :: %{name: String.t(), description: String.t(), schema: map()}
  @type t :: %__MODULE__{
          model: String.t(),
          messages: [Message.t()],
          system: String.t() | nil,
          system_tail: String.t() | nil,
          cache: boolean(),
          tools: [tool_spec()],
          max_tokens: pos_integer(),
          ceiling: pos_integer() | nil,
          temperature: float() | nil,
          reasoning_effort: String.t() | nil,
          thinking: :adaptive | :budget | nil,
          thinking_binding: String.t() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | {:refused, String.t()} | nil,
          auth: :api_key | :bearer,
          provider: module() | nil,
          type: atom() | nil,
          api_version: String.t() | nil,
          timeout_ms: pos_integer(),
          first_byte_ms: pos_integer(),
          max_retries: non_neg_integer(),
          attribution: map(),
          identify: boolean(),
          client: String.t() | nil,
          extra: map()
        }

  @doc "The output cap the call asks for: `max_tokens`, held to `ceiling` where there is one."
  @spec output_cap(t()) :: pos_integer()
  def output_cap(%__MODULE__{max_tokens: max, ceiling: nil}), do: max
  def output_cap(%__MODULE__{max_tokens: max, ceiling: ceiling}), do: min(max, ceiling)

  @doc """
  Where the call goes, as a sentence or a log line names it: the host of `base_url`, or of
  the provider type's own endpoint when none is set, or the type's name where it has no
  endpoint (`fake`). Never the key, never the path.
  """
  @spec host(t()) :: String.t()
  def host(%__MODULE__{base_url: base_url, type: type}) do
    url =
      case base_url do
        url when is_binary(url) and url != "" -> url
        _none -> ProviderType.default_base_url(type)
      end

    case url && URI.parse(url).host do
      host when is_binary(host) and host != "" -> host
      _none -> to_string(type || "the provider")
    end
  end

  @doc "The whole system prompt as one text: `system`, then `system_tail` after a blank line."
  @spec system_text(t()) :: String.t() | nil
  def system_text(%__MODULE__{system: system, system_tail: tail}) do
    case Enum.reject([system, tail], &(&1 in [nil, ""])) do
      [] -> system
      parts -> Enum.join(parts, "\n\n")
    end
  end
end

defmodule Troupe.LLM.Delta do
  @moduledoc """
  One incremental chunk of a streamed response.

  `:text` carries assistant prose as it arrives; `:reasoning` carries the model's
  thinking the same way, under its own kind so a client can fold it rather than read it
  as the answer. `:tool_use_start` announces a tool call so a UI can render it before its
  arguments finish streaming, and `:tool_input` carries that argument JSON in pieces.
  """
  @enforce_keys [:kind]
  defstruct [:kind, :text, :id, :name, :fragment]

  @type kind :: :text | :reasoning | :tool_use_start | :tool_input
  @type t :: %__MODULE__{
          kind: kind(),
          text: String.t() | nil,
          id: String.t() | nil,
          name: String.t() | nil,
          fragment: String.t() | nil
        }

  @spec text(String.t()) :: t()
  def text(chunk), do: %__MODULE__{kind: :text, text: chunk}

  @spec reasoning(String.t()) :: t()
  def reasoning(chunk), do: %__MODULE__{kind: :reasoning, text: chunk}

  @doc """
  The delta as the JSON a subscriber receives.

  Absent fields are dropped rather than sent as `null`: a delta is the highest-volume
  thing on the wire, and a client that has to distinguish "missing" from "null" for no
  reason is a client that will get it wrong.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = delta) do
    %{"kind" => Atom.to_string(delta.kind)}
    |> put_present("text", delta.text)
    |> put_present("id", delta.id)
    |> put_present("name", delta.name)
    |> put_present("fragment", delta.fragment)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end

defmodule Troupe.LLM.Response do
  @moduledoc """
  A provider's final answer for one request.

  `gateway` is what the gateway in front of the provider said about the call it just
  billed: its own identifier for the request, and what it cost. Both come from response
  headers rather than from the body, because that is where every OpenAI-compatible
  gateway puts them and because a body shape differs per provider while a header does
  not. Neither is invented here: a gateway that says nothing leaves an empty
  `Troupe.LLM.Gateway`, and the accounting records the tokens with no cost rather than a
  cost we made up, which would reconcile against itself.
  """

  alias Troupe.LLM.{Gateway, Message, Usage}

  @enforce_keys [:content]
  defstruct content: [],
            stop_reason: :end_turn,
            usage: %Usage{},
            model: nil,
            gateway: %Gateway{},
            # What became of the thinking the request handed back (issue #465, Decision
            # 815): refused as bound to another conversation and the call sent again
            # without it (Decision 805), or how many blocks Anthropic's thinking-binding
            # beta dropped. And, when the API's response header said, the kind of edit
            # it saw and where it begins, in its own words (issue #591, Decision 863).
            thinking_resent: false,
            thinking_dropped: 0,
            prefix_mismatch: nil

  @type stop_reason :: :end_turn | :tool_use | :max_tokens | :stop_sequence | :refusal | :other
  @type t :: %__MODULE__{
          content: [Message.block()],
          stop_reason: stop_reason(),
          usage: Usage.t(),
          model: String.t() | nil,
          gateway: Gateway.t(),
          thinking_resent: boolean(),
          thinking_dropped: non_neg_integer(),
          prefix_mismatch: String.t() | nil
        }

  @doc "The response as an assistant message to append to the conversation."
  @spec to_message(t()) :: Message.t()
  def to_message(%__MODULE__{content: content}), do: Message.assistant(content)

  @doc "The tool calls the model asked for, in the order it asked."
  @spec tool_uses(t()) :: [Troupe.LLM.ToolUse.t()]
  def tool_uses(%__MODULE__{content: content}) do
    Enum.filter(content, &match?(%Troupe.LLM.ToolUse{}, &1))
  end
end
