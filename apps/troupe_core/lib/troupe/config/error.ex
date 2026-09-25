defmodule Troupe.Config.Error do
  @moduledoc """
  A configuration Troupe refuses to load: a file that is not YAML, a value of the wrong
  type, an unknown enum value, both spellings of one setting, a file for a newer Troupe.
  Every issue names the file, the key and the fix.
  """

  alias Troupe.Config.Issue

  defexception issues: []

  @type t :: %__MODULE__{issues: [Issue.t()]}

  @impl Exception
  def message(%__MODULE__{issues: [issue]}), do: "the configuration did not load: " <> Issue.format(issue)

  def message(%__MODULE__{issues: issues}) do
    "the configuration did not load:\n" <> Enum.map_join(issues, "\n", &("  " <> Issue.format(&1)))
  end
end
