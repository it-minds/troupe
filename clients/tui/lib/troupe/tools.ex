defmodule Troupe.Tools do
  @moduledoc "Tool registry, allowlists and permissions."

  alias Troupe.Agents.Definition
  alias Troupe.Tool

  @modules [
    Troupe.Tools.ReadFile,
    Troupe.Tools.WriteFile,
    Troupe.Tools.EditFile,
    Troupe.Tools.ListFiles,
    Troupe.Tools.Grep,
    Troupe.Tools.Shell,
    Troupe.Tools.WebFetch,
    Troupe.Tools.TodoWrite,
    Troupe.Tools.TodoRead,
    Troupe.Tools.Delegate,
    Troupe.Tools.Finish,
    Troupe.Tools.AskUser,
    Troupe.Tools.ReadBranch,
    Troupe.Tools.ReadOutput,
    Troupe.Tools.Remember
  ]

  @inline ~w(todo_write todo_read finish ask_user delegate)
  @read_only ~w(read_file read_output list_files grep web_fetch todo_write todo_read finish ask_user delegate remember)

  @spec all() :: %{String.t() => module()}
  def all, do: Map.new(@modules, &{&1.name(), &1})

  @doc """
  Every tool name in a fixed order. Tool definitions render at position 0 of the
  prompt, so a set that reordered between turns would invalidate the whole
  prompt cache; `Map.keys/1` gives no ordering contract, the module list does.
  """
  @spec names() :: [String.t()]
  def names, do: Enum.map(@modules, & &1.name())

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name), do: Map.fetch(all(), name)

  @spec inline?(String.t()) :: boolean()
  def inline?(name), do: name in @inline

  @spec read_only() :: [String.t()]
  def read_only, do: @read_only

  @doc "Tool names a definition may use."
  @spec allowed(Definition.t()) :: [String.t()]
  def allowed(%Definition{tools: :all}), do: names() -- ["read_branch"]

  def allowed(%Definition{tools: list}) when is_list(list),
    do: Enum.filter(list, &Map.has_key?(all(), &1))

  @spec allowed?(Definition.t(), String.t()) :: boolean()
  def allowed?(def, name), do: name in allowed(def)

  @doc "Effective permission for a tool under a definition."
  @spec permission(Definition.t(), String.t()) :: Tool.permission()
  def permission(%Definition{} = def, name) do
    case Map.get(def.permissions, name) do
      nil ->
        case fetch(name) do
          {:ok, mod} -> mod.default_permission()
          :error -> :deny
        end

      p when p in [:auto, :ask, :deny] ->
        p
    end
  end

  @doc "Provider-neutral tool specs for a definition; `delegate` gets a generated description."
  @spec specs(Definition.t(), %{optional(String.t()) => Definition.t()}) :: [map()]
  def specs(%Definition{} = def, definitions) do
    def
    |> allowed()
    |> Enum.reject(&(permission(def, &1) == :deny))
    |> Enum.map(fn name ->
      {:ok, mod} = fetch(name)
      spec = Tool.spec(mod)

      if name == "delegate",
        do: %{spec | description: Troupe.Tools.Delegate.description(definitions)},
        else: spec
    end)
  end
end
