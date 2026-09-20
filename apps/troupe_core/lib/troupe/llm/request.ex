defmodule Troupe.LLM.Request do
  @moduledoc """
  Everything a provider needs for one streamed completion.

  Built by the agent and handed to a task; the task is the only thing that ever sees
  a base URL or an API key.
  """

  alias Troupe.LLM.Message

  @enforce_keys [:model, :messages]
  defstruct [
    :model,
    :messages,
    system: nil,
    tools: [],
    max_tokens: 8192,
    temperature: nil,
    # How hard a reasoning model should think, verbatim from the model's `models:` entry
    # (Decision 658): an OpenAI-compatible provider takes the word, Anthropic a budget
    # made from it. `nil` asks for no reasoning and gets the plain output cap.
    reasoning_effort: nil,
    base_url: nil,
    api_key: nil,
    # How the key is presented: the provider's own scheme, or `Authorization: Bearer`
    # for a gateway that fronts a provider's API but not its authentication.
    auth: :api_key,
    # The adapter this request goes through, when the model named a provider other
    # than the session's. `nil` means the agent's own.
    provider: nil,
    timeout_ms: 300_000,
    max_retries: 4,
    # Who this call is for, as the gateway is to record it. Every request a worker makes
    # is tagged with the session owner as the end user, plus the team and the session, so
    # the gateway's spend records and the plane's ledger can be reconciled against each
    # other without either side guessing.
    #
    # The owner, not the caller: a collaborator's input is billed to the owner's team
    # budget, because the budget belongs to the session and a session has one owner.
    attribution: %{},
    extra: %{}
  ]

  @type tool_spec :: %{name: String.t(), description: String.t(), schema: map()}
  @type t :: %__MODULE__{
          model: String.t(),
          messages: [Message.t()],
          system: String.t() | nil,
          tools: [tool_spec()],
          max_tokens: pos_integer(),
          temperature: float() | nil,
          reasoning_effort: String.t() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          auth: :api_key | :bearer,
          provider: module() | nil,
          timeout_ms: pos_integer(),
          max_retries: non_neg_integer(),
          attribution: map(),
          extra: map()
        }
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
            gateway: %Gateway{}

  @type stop_reason :: :end_turn | :tool_use | :max_tokens | :stop_sequence | :refusal | :other
  @type t :: %__MODULE__{
          content: [Message.block()],
          stop_reason: stop_reason(),
          usage: Usage.t(),
          model: String.t() | nil,
          gateway: Gateway.t()
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
