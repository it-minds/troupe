defmodule Mix.Tasks.Troupe.Config.Schema do
  @shortdoc "Write the config.yaml JSON Schema and key reference from the key table"

  @moduledoc """
  Write `protocol/schema/config/v1.json` and the key reference in
  `docs/user/configuration.md` from `Troupe.Config.Schema`.

      mix troupe.config.schema
      mix troupe.config.schema --check

  Both are generated and committed: the schema so an editor can check a config file
  without a checkout of this repository, and the reference so a person reads the same
  key table the loader validates against. `--check` fails when either is not what the
  table says, and CI runs it, so neither can drift from the loader.

  The reference is the part of the page between `<!-- config-keys:begin -->` and
  `<!-- config-keys:end -->`; the rest of the page is written by hand.
  """

  use Mix.Task

  alias Troupe.Config.Schema

  @requirements ["app.config"]

  @begin "<!-- config-keys:begin -->"
  @finish "<!-- config-keys:end -->"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [check: :boolean])
    root = repository_root()
    schema_path = Path.join([root, "protocol", "schema", "config", "v1.json"])
    page_path = Path.join([root, "docs", "user", "configuration.md"])

    schema = Jason.encode!(Schema.json_schema(), pretty: true) <> "\n"
    page = page_path |> File.read!() |> with_reference()

    if opts[:check] do
      stale =
        [{schema_path, schema}, {page_path, page}]
        |> Enum.reject(fn {path, expected} -> File.read(path) == {:ok, expected} end)
        |> Enum.map(&elem(&1, 0))

      if stale == [],
        do: Mix.shell().info("the config schema and its reference are current"),
        else: Mix.raise("stale: #{Enum.join(stale, ", ")} -- run `mix troupe.config.schema` and commit the result")
    else
      File.mkdir_p!(Path.dirname(schema_path))
      File.write!(schema_path, schema)
      File.write!(page_path, page)
      Mix.shell().info("wrote #{schema_path} and the key reference in #{page_path}")
    end
  end

  defp with_reference(page) do
    case String.split(page, [@begin, @finish]) do
      [head, _old, tail] ->
        head <> @begin <> "\n" <> Schema.reference() <> @finish <> tail

      _ ->
        Mix.raise("docs/user/configuration.md needs #{@begin} and #{@finish} around the key reference")
    end
  end

  # Tasks run from the umbrella root or from an app directory, so the root is found
  # rather than assumed.
  defp repository_root, do: Path.expand(Path.join(Mix.Project.build_path(), "../.."))
end
