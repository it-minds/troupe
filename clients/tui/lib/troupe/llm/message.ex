defmodule Troupe.LLM.Message do
  @moduledoc """
  Provider-neutral conversation messages. A message is a role plus a list of
  content blocks:

    * `%{type: :text, text: binary}`
    * `%{type: :tool_use, id: binary, name: binary, input: map}` (input keys are strings)
    * `%{type: :tool_result, tool_use_id: binary, content: binary, is_error: boolean}`
  """

  @type block ::
          %{:type => :text, :text => String.t(), optional(:volatile) => true}
          | %{type: :tool_use, id: String.t(), name: String.t(), input: map()}
          | %{type: :tool_result, tool_use_id: String.t(), content: String.t(), is_error: boolean()}

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

  @spec tool_uses([block()]) :: [block()]
  def tool_uses(blocks), do: Enum.filter(blocks, &match?(%{type: :tool_use}, &1))

  @spec text([block()]) :: String.t()
  def text(blocks) do
    blocks
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map_join("\n", & &1.text)
  end
end
