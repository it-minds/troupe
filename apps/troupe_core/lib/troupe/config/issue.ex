defmodule Troupe.Config.Issue do
  @moduledoc """
  One thing wrong with a configuration: where it is (a file, and a line when one can be
  found, or an environment variable), which key, and what to do about it.

  `:error` refuses the whole load. `:refusal` refuses one provider or one MCP server and
  lets the rest load. `:warning` loads, and says what was ignored or is spelled the old
  way. `troupe config validate` exits non-zero on any of the three.
  """

  @enforce_keys [:level, :message]
  defstruct [:level, :source, :line, :key, :message]

  @type level :: :error | :refusal | :warning
  @type t :: %__MODULE__{
          level: level(),
          source: String.t() | nil,
          line: pos_integer() | nil,
          key: String.t() | nil,
          message: String.t()
        }

  @doc "The issue as one line: `source:line: message`."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{source: nil, message: message}), do: message
  def format(%__MODULE__{source: source, line: nil, message: message}), do: "#{source}: #{message}"
  def format(%__MODULE__{source: source, line: line, message: message}), do: "#{source}:#{line}: #{message}"

  @doc "The issue as JSON."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = issue) do
    %{
      "level" => Atom.to_string(issue.level),
      "source" => issue.source,
      "line" => issue.line,
      "key" => issue.key,
      "message" => issue.message
    }
  end
end
