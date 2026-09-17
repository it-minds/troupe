defmodule Troupe.Tools.ReadOutput do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.Session.Outputs

  @default_limit 200

  @impl true
  def name, do: "read_output"

  @impl true
  def description,
    do:
      "Page through the full output of an earlier tool call that was truncated. `id` is the identifier printed in the truncation marker (`out_...`); `offset` is the 1-based first line and `limit` the number of lines (default #{@default_limit}). Use this instead of running an expensive or non-idempotent command again."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "Output id such as out_7f3a"},
        "offset" => %{"type" => "integer", "description" => "First line to return (1-based)"},
        "limit" => %{"type" => "integer", "description" => "Maximum number of lines"}
      },
      "required" => ["id"]
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(%{"id" => id} = args, ctx) when is_binary(id) do
    offset = max(args["offset"] || 1, 1)
    limit = max(args["limit"] || @default_limit, 1)

    Outputs.read(ctx.session_id, id, offset, limit)
  end

  def run(_, _), do: {:error, "id is required"}
end
