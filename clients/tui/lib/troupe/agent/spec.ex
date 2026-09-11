defmodule Troupe.Agent.Spec do
  @moduledoc "Everything an `Agent.Node` needs to start; immutable, passed down in child specs."

  alias Troupe.Agent.Budget

  @type t :: %__MODULE__{
          session_id: String.t(),
          agent_path: String.t(),
          branch_id: String.t(),
          definition_name: String.t(),
          definitions: Troupe.Agents.snapshot(),
          config: Troupe.Config.t(),
          provider: {module(), term()} | :auto,
          workspace: String.t(),
          isolation: :shared | :worktree,
          depth: non_neg_integer(),
          parent: {pid(), reference()} | nil,
          initial_input: String.t() | nil,
          budget: Budget.t(),
          source: :user | :watch | :cli,
          existing_worktree: %{path: String.t(), git_branch: String.t() | nil} | nil
        }

  @enforce_keys [
    :session_id,
    :agent_path,
    :branch_id,
    :definition_name,
    :definitions,
    :config,
    :provider,
    :workspace
  ]
  defstruct session_id: "",
            agent_path: "",
            branch_id: "",
            definition_name: "code",
            definitions: %{},
            config: nil,
            provider: nil,
            workspace: ".",
            isolation: :shared,
            depth: 0,
            parent: nil,
            initial_input: nil,
            budget: %Budget{},
            source: :user,
            existing_worktree: nil

  @spec definition(t()) :: Troupe.Agents.Definition.t()
  def definition(%__MODULE__{} = spec), do: Map.fetch!(spec.definitions, spec.definition_name)

  @spec root?(t()) :: boolean()
  def root?(%__MODULE__{parent: nil}), do: true
  def root?(_), do: false
end
