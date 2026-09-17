defmodule Troupe.LLM.Message do
  @moduledoc """
  Provider-neutral conversation messages. A message is a role plus a list of
  content blocks:

    * `%{type: :text, text: binary}`
    * `%{type: :tool_use, id: binary, name: binary, input: map}` (input keys are strings)
    * `%{type: :tool_result, tool_use_id: binary, content: binary, is_error: boolean}`
    * `%{type: :reasoning, provider: atom, text: binary, signature: binary | nil, redacted: boolean}`

  A reasoning block is the model's own thinking, and unlike the others it is
  **opaque and provider-bound**: Anthropic signs it and rejects a turn whose
  thinking it cannot verify, DeepSeek rejects a thinking-mode turn that omits it.
  So it is stored, replayed and handed back verbatim to the provider that made
  it, and dropped for any other (`provider` is what says which). Nothing but the
  adapters reads it: `text/1` and `tool_uses/1` filter it out, so the UI and the
  summaries never see it.
  """

  @type block ::
          %{:type => :text, :text => String.t(), optional(:volatile) => true}
          | %{type: :tool_use, id: String.t(), name: String.t(), input: map()}
          | %{type: :tool_result, tool_use_id: String.t(), content: String.t(), is_error: boolean()}
          | %{
              type: :reasoning,
              provider: atom(),
              text: String.t(),
              signature: String.t() | nil,
              redacted: boolean()
            }

  @type t :: %{role: :user | :assistant, content: [block()]}

  @spec user(String.t() | [block()]) :: t()
  def user(text) when is_binary(text), do: %{role: :user, content: [text_block(text)]}
  def user(blocks) when is_list(blocks), do: %{role: :user, content: blocks}

  @spec assistant([block()]) :: t()
  def assistant(blocks) when is_list(blocks), do: %{role: :assistant, content: blocks}

  @spec text_block(String.t()) :: block()
  def text_block(text), do: %{type: :text, text: text}

  @doc """
  A text block that is rebuilt every turn and never stored: the task list, watch
  context — state the model needs now and that would be stale if replayed. The
  request builder puts it after the last cache breakpoint, where a block that
  differs from turn to turn costs its own tokens and invalidates nothing.
  """
  @spec volatile_block(String.t()) :: block()
  def volatile_block(text), do: %{type: :text, text: text, volatile: true}

  @spec volatile?(block()) :: boolean()
  def volatile?(%{volatile: true}), do: true
  def volatile?(_block), do: false

  @spec tool_use(String.t(), String.t(), map()) :: block()
  def tool_use(id, name, input) when is_map(input),
    do: %{type: :tool_use, id: id, name: name, input: input}

  @spec tool_result(String.t(), String.t(), boolean()) :: block()
  def tool_result(id, content, is_error \\ false),
    do: %{type: :tool_result, tool_use_id: id, content: content, is_error: is_error}

  @doc """
  A block of provider-bound thinking. `signature` is Anthropic's verification of
  it; `redacted` marks thinking the provider encrypted, whose `text` is its
  opaque payload rather than anything readable.
  """
  @spec reasoning(atom(), String.t(), keyword()) :: block()
  def reasoning(provider, text, opts \\ []) when is_atom(provider) and is_binary(text) do
    %{
      type: :reasoning,
      provider: provider,
      text: text,
      signature: Keyword.get(opts, :signature),
      redacted: Keyword.get(opts, :redacted, false)
    }
  end

  @doc "Reasoning blocks this provider itself produced; another provider's are not replayable."
  @spec reasoning_of([block()], atom()) :: [block()]
  def reasoning_of(blocks, provider) when is_atom(provider),
    do: Enum.filter(blocks, &match?(%{type: :reasoning, provider: ^provider}, &1))

  @doc "Every block that is not reasoning, in order."
  @spec without_reasoning([block()]) :: [block()]
  def without_reasoning(blocks), do: Enum.reject(blocks, &match?(%{type: :reasoning}, &1))

  @spec tool_uses([block()]) :: [block()]
  def tool_uses(blocks), do: Enum.filter(blocks, &match?(%{type: :tool_use}, &1))

  @spec text([block()]) :: String.t()
  def text(blocks) do
    blocks
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map_join("\n", & &1.text)
  end
end
