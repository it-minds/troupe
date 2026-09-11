defmodule Troupe.Todo do
  @moduledoc """
  One task-list item, and the rules the list obeys.

  Each agent owns its own list. The invariant — at most one `in_progress` item — is
  enforced here and violating it returns an error tool result, so the model is told
  what it did wrong rather than silently getting a list that says it is doing three
  things at once.
  """

  @enforce_keys [:id, :content, :status]
  defstruct [:id, :content, :status]

  @type status :: :pending | :in_progress | :completed | :cancelled
  @type t :: %__MODULE__{id: String.t(), content: String.t(), status: status()}

  @statuses ~w(pending in_progress completed cancelled)

  @doc """
  Validate and build a whole list from raw tool arguments.

  `todo_write` replaces the list wholesale, so validation is a property of the list,
  not of an individual write.
  """
  @spec parse_list(term()) :: {:ok, [t()]} | {:error, term()}
  def parse_list(items) when is_list(items) do
    with {:ok, todos} <- parse_items(items, []),
         :ok <- check_single_in_progress(todos),
         :ok <- check_unique_ids(todos) do
      {:ok, todos}
    end
  end

  def parse_list(other),
    do: {:error, {:invalid_args, "items must be a list, got #{inspect(other)}"}}

  defp parse_items([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_items([item | rest], acc) do
    case parse_item(item) do
      {:ok, todo} -> parse_items(rest, [todo | acc])
      {:error, _} = error -> error
    end
  end

  defp parse_item(%{"content" => content} = item) when is_binary(content) do
    status = Map.get(item, "status", "pending")

    if status in @statuses do
      id = item |> Map.get("id") |> normalize_id(content)
      {:ok, %__MODULE__{id: id, content: content, status: String.to_existing_atom(status)}}
    else
      {:error,
       {:invalid_args,
        "status must be one of #{Enum.join(@statuses, ", ")}, got #{inspect(status)}"}}
    end
  end

  defp parse_item(other) do
    {:error, {:invalid_args, "each item needs a string `content`, got #{inspect(other)}"}}
  end

  defp normalize_id(id, _content) when is_binary(id) and id != "", do: id
  defp normalize_id(id, _content) when is_integer(id), do: Integer.to_string(id)

  defp normalize_id(_, content) do
    # A model that omits ids still gets a stable list across rewrites, because the
    # id is derived from the item's own text.
    :sha256 |> :crypto.hash(content) |> Base.url_encode64(padding: false) |> binary_part(0, 8)
  end

  defp check_single_in_progress(todos) do
    case Enum.count(todos, &(&1.status == :in_progress)) do
      n when n <= 1 ->
        :ok

      n ->
        {:error,
         {:invalid_args,
          "#{n} items are in_progress; exactly one item may be in progress at a time. " <>
            "Complete the current item before starting the next."}}
    end
  end

  defp check_unique_ids(todos) do
    ids = Enum.map(todos, & &1.id)

    if length(Enum.uniq(ids)) == length(ids) do
      :ok
    else
      {:error, {:invalid_args, "todo ids must be unique"}}
    end
  end

  @doc "Render the list for the model, compact and stable."
  @spec render([t()]) :: String.t()
  def render([]), do: "(the task list is empty)"

  def render(todos) do
    Enum.map_join(todos, "\n", fn todo ->
      "#{marker(todo.status)} [#{todo.id}] #{todo.content}"
    end)
  end

  defp marker(:pending), do: "[ ]"
  defp marker(:in_progress), do: "[~]"
  defp marker(:completed), do: "[x]"
  defp marker(:cancelled), do: "[-]"

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = todo) do
    %{"id" => todo.id, "content" => todo.content, "status" => Atom.to_string(todo.status)}
  end

  @spec from_json(map()) :: t()
  def from_json(%{"id" => id, "content" => content, "status" => status}) do
    %__MODULE__{id: id, content: content, status: String.to_existing_atom(status)}
  end
end

defmodule Troupe.Todo.Edit do
  @moduledoc """
  A change to the task list made from the TUI rather than by the model.

  Delivered as a `:tui_todo_edit` input. The agent applies it to its own list
  and mentions it in the next request context, so the model sees that the user
  cancelled or added something.
  """

  @enforce_keys [:action]
  defstruct [:action, :id, :content]

  @type action :: :cancel | :add | :complete
  @type t :: %__MODULE__{action: action(), id: String.t() | nil, content: String.t() | nil}

  @spec cancel(String.t()) :: t()
  def cancel(id), do: %__MODULE__{action: :cancel, id: id}

  @spec add(String.t()) :: t()
  def add(content), do: %__MODULE__{action: :add, content: content}

  @spec complete(String.t()) :: t()
  def complete(id), do: %__MODULE__{action: :complete, id: id}

  @doc """
  Apply an edit, returning the new list and a sentence describing what changed.

  The sentence goes into the conversation as a user message: the model has to know
  the list moved under it, or its next `todo_write` would undo the user's edit.
  """
  @spec apply(t(), [Troupe.Todo.t()]) :: {[Troupe.Todo.t()], String.t()}
  def apply(%__MODULE__{action: :cancel, id: id}, todos) do
    {set_status(todos, id, :cancelled), "The user cancelled task #{id}."}
  end

  def apply(%__MODULE__{action: :complete, id: id}, todos) do
    {set_status(todos, id, :completed), "The user marked task #{id} completed."}
  end

  def apply(%__MODULE__{action: :add, content: content}, todos) do
    {:ok, [todo]} = Troupe.Todo.parse_list([%{"content" => content, "status" => "pending"}])
    {todos ++ [todo], "The user added task #{todo.id}: #{content}"}
  end

  defp set_status(todos, id, status) do
    Enum.map(todos, fn
      %Troupe.Todo{id: ^id} = todo -> %{todo | status: status}
      todo -> todo
    end)
  end
end
