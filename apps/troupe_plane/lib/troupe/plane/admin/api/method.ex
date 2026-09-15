defmodule Troupe.Plane.Admin.API.Method do
  @moduledoc "One admin method: what it is called, what it does, and what it costs."

  alias Troupe.Plane.Admin.API.Argument

  @enforce_keys [:name, :function, :summary]
  defstruct [:name, :function, :summary, :confirm, arguments: [], risk: :read]

  @type t :: %__MODULE__{
          name: String.t(),
          function: atom(),
          summary: String.t(),
          arguments: [Argument.t()],
          risk: :read | :write | :destructive,
          confirm: String.t() | nil
        }

  @doc "The argument names, in the order the context takes them."
  @spec argument_names(t()) :: [String.t()]
  def argument_names(%__MODULE__{arguments: arguments}), do: Enum.map(arguments, & &1.name)

  @doc "The ones a caller must send. Declared here and, since this, enforced."
  @spec required_names(t()) :: [String.t()]
  def required_names(%__MODULE__{arguments: arguments}) do
    arguments |> Enum.filter(& &1.required) |> Enum.map(& &1.name)
  end
end
