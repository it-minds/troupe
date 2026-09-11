defmodule Troupe.LLM.Message do
  @moduledoc """
  Provider-neutral conversation messages. A message is a role plus a list of
  content blocks:

    * `%{type: :text, text: binary}`
    * `%{type: :tool_use, id: binary, name: binary, input: map}` (input keys are strings)
    * `%{type: :tool_result, tool_use_id: binary, content: binary, is_error: boolean}`
  """

  @type block ::
          %{type: :text, text: String.t()}
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
