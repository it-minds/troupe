defmodule Troupe.Keyring.Memory do
  @moduledoc """
  A credential store in this VM, for tests: what `Troupe.Keyring.OS` would keep, kept
  in `:persistent_term` so that it outlives the process that wrote it, as the real one
  does. `entries/0` says what is there.
  """

  @behaviour Troupe.Keyring

  @impl true
  def get(entry) do
    case :persistent_term.get({__MODULE__, entry}, nil) do
      nil -> :none
      value -> {:ok, value}
    end
  end

  @impl true
  def put(entry, value) do
    :persistent_term.put({__MODULE__, entry}, value)
    :ok
  end

  @impl true
  def delete(entry) do
    :persistent_term.erase({__MODULE__, entry})
    :ok
  end

  @doc "Every entry this store holds, by full name."
  @spec entries() :: %{String.t() => String.t()}
  def entries do
    for {{__MODULE__, entry}, value} <- :persistent_term.get(), into: %{}, do: {entry, value}
  end
end
