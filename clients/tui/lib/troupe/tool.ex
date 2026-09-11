defmodule Troupe.Tool do
  @moduledoc """
  Behaviour every tool implements. `run/2` returns `{:ok, content}` or
  `{:error, reason}`; both become a `tool_result` for the model.
  """

  alias Troupe.Tool.Context

  @type permission :: :auto | :ask | :deny
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: map()
  @callback default_permission() :: permission()
  @callback run(args :: map(), ctx :: Context.t()) :: result()
  @callback preview(args :: map(), ctx :: Context.t()) :: String.t()

  @optional_callbacks preview: 2

  @doc "Returns the provider-neutral tool spec."
  @spec spec(module()) :: map()
  def spec(mod), do: %{name: mod.name(), description: mod.description(), input_schema: mod.schema()}

  @doc "Human preview shown in approval prompts."
  @spec preview(module(), map(), Context.t()) :: String.t()
  def preview(mod, args, ctx) do
    if function_exported?(mod, :preview, 2),
      do: mod.preview(args, ctx),
      else: Jason.encode!(args, pretty: true)
  end
end
