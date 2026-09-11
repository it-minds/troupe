defmodule Mix.Tasks.Troupe.Schema.Diff do
  @moduledoc """
  Compare the committed JSON Schema against the current definitions, and fail on a
  breaking change.

      mix troupe.schema.diff

  Within major version 1: fields may be added, and event types may be added. Fields may
  not be removed, renamed, retyped, or newly made required. A rename is a removal and
  an addition, and it is the removal that breaks every client that was reading it.

  Exits non-zero listing each breaking change with the document and field it is in. A
  compatible change — a new optional field, a new event type — passes, and reminds you
  to regenerate so the committed copy stays honest.
  """

  use Mix.Task

  alias Troupe.Protocol.Schema

  @shortdoc "Fail if the protocol changed in a way clients cannot survive"

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    committed = read_committed(Schema.Paths.root())
    current = Schema.documents()

    case Schema.incompatibilities(committed, current) do
      [] ->
        report_additions(committed, current)

      breaking ->
        Enum.each(breaking, &Mix.shell().error("  " <> Schema.describe(&1)))

        Mix.raise("""
        #{length(breaking)} breaking schema change(s).

        Within version 1 a field may be added but never removed, renamed, retyped, or
        newly made required. If this is deliberate, it needs a new protocol version,
        not a new field list.
        """)
    end
  end

  @doc "Every committed document, keyed by its path relative to the schema root."
  @spec read_committed(Path.t()) :: %{Path.t() => map()}
  def read_committed(root) do
    [root, "**", "*.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "index.json"))
    |> Map.new(fn path -> {Path.relative_to(path, root), path |> File.read!() |> Jason.decode!()} end)
  end

  defp report_additions(committed, current) do
    added = Map.keys(current) -- Map.keys(committed)
    changed = Enum.filter(committed, fn {path, old} -> Map.get(current, path) != old end)

    cond do
      committed == %{} ->
        Mix.raise("no committed schema in #{Schema.Paths.root()} — run `mix troupe.schema.gen`")

      added == [] and changed == [] ->
        Mix.shell().info("schema unchanged: #{map_size(current)} documents")

      true ->
        Mix.shell().info(
          "schema compatible: #{length(added)} new document(s), " <>
            "#{length(changed)} with added fields"
        )

        Mix.shell().info("run `mix troupe.schema.gen` and commit the result")
    end
  end
end
