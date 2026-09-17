defmodule Troupe.Tool.Context do
  @moduledoc "Execution context handed to every tool run."

  @type t :: %__MODULE__{
          session_id: String.t(),
          agent_path: String.t(),
          call_id: String.t(),
          workspace: String.t(),
          isolation: :shared | :worktree,
          definition: Troupe.Agents.Definition.t() | nil,
          definitions: %{optional(String.t()) => Troupe.Agents.Definition.t()},
          depth: non_neg_integer(),
          config: Troupe.Config.t() | nil
        }

  defstruct session_id: "",
            agent_path: "",
            call_id: "",
            workspace: ".",
            isolation: :shared,
            definition: nil,
            definitions: %{},
            depth: 0,
            config: nil

  @doc """
  The per-tool output limits in force. A context built without a config (tests,
  a tool called directly) gets the defaults rather than no bound at all.
  """
  @spec limits(t()) :: %{
          file_lines: pos_integer(),
          command_head: pos_integer(),
          command_tail: pos_integer(),
          list_items: pos_integer(),
          max_chars: pos_integer()
        }
  def limits(%__MODULE__{config: %Troupe.Config{limits: limits}}), do: limits
  def limits(%__MODULE__{}), do: %Troupe.Config{}.limits
end
