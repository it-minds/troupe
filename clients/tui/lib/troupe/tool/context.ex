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
end
