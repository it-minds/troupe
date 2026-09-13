defmodule Troupe.Plane.Admin.API.Argument do
  @moduledoc """
  One argument of one method, in enough detail to generate a schema from.

  `properties` is what makes an object argument worth having. `admin.team.update` takes
  `attrs`, and a caller told only "an object" sends `{"budget": 500}` to a field named
  `budget_micros` and is told nothing is wrong — because nothing was: the update changed
  no fields and said so. Naming the properties is what turns that into an error.
  """

  @enforce_keys [:name, :type, :description]
  defstruct [:name, :type, :description, :properties, :values, required: false]

  @type type :: :string | :integer | :boolean | :object | :array

  @type t :: %__MODULE__{
          name: String.t(),
          type: type(),
          description: String.t(),
          # For an `:object`: the properties it is known to take. `nil` means free-form,
          # which for a configuration bundle is the truth rather than a gap.
          properties: [t()] | nil,
          # For a string with a closed set of values.
          values: [String.t()] | nil,
          required: boolean()
        }
end
