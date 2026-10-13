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
  `<!-- config-keys:end -->`, and the provider-type table the part between
  `<!-- provider-types:begin -->` and `<!-- provider-types:end -->`, written from
  `Troupe.LLM.ProviderType`; the rest of the page is written by hand.

  It writes `clients/gui/packages/client/test/support/provider-types.ts` too: the provider
  types and the ways to set one up exactly as the daemon's `config.get` and `setup.get`
  carry them (`Troupe.Protocol.ProviderTypes.wire/0` and `kinds/0`), which the GUI's fake
  daemon serves, so the fake cannot offer a list the daemon does not. A module rather than
  a file it reads, because the GUI's tests also run in an image built from `clients/gui`
  alone, where nothing above it is.
  """

  use Mix.Task

  alias Troupe.Config.Schema
  alias Troupe.LLM.ProviderType
  alias Troupe.Protocol.ProviderTypes

  @requirements ["app.config"]

  @begin "<!-- config-keys:begin -->"
  @finish "<!-- config-keys:end -->"
  @types_begin "<!-- provider-types:begin -->"
  @types_finish "<!-- provider-types:end -->"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [check: :boolean])
    root = repository_root()
    schema_path = Path.join([root, "protocol", "schema", "config", "v1.json"])
    page_path = Path.join([root, "docs", "user", "configuration.md"])

    types_path = Path.join(root, "clients/gui/packages/client/test/support/provider-types.ts")

    schema = Jason.encode!(Schema.json_schema(), pretty: true) <> "\n"
    page = page_path |> File.read!() |> with_reference()
    types = provider_types()
    files = [{schema_path, schema}, {page_path, page}, {types_path, types}]

    if opts[:check] do
      stale =
        files
        |> Enum.reject(fn {path, expected} -> File.read(path) == {:ok, expected} end)
        |> Enum.map(&elem(&1, 0))

      if stale == [],
        do: Mix.shell().info("the config schema and its reference are current"),
        else:
          Mix.raise(
            "stale: #{Enum.join(stale, ", ")} -- run `mix troupe.config.schema` and commit the result"
          )
    else
      File.mkdir_p!(Path.dirname(schema_path))
      Enum.each(files, fn {path, content} -> File.write!(path, content) end)

      Mix.shell().info(
        "wrote #{schema_path}, #{types_path} and the key reference in #{page_path}"
      )
    end
  end

  defp provider_types do
    """
    // Written by `mix troupe.config.schema` from `Troupe.Protocol.ProviderTypes`; do not edit.
    // `--check` fails in CI when it is not what the daemon's `config.get` and `setup.get` carry.

    /** The provider types a screen offers: `ProviderTypes.wire/0`. */
    export const PROVIDER_TYPES: Array<Record<string, unknown>> = #{Jason.encode!(ProviderTypes.wire(), pretty: true)};

    /** The ways `setup.get` says a provider may be set up: `ProviderTypes.kinds/0`. */
    export const SETUP_KINDS: Array<Record<string, unknown>> = #{Jason.encode!(ProviderTypes.kinds(), pretty: true)};
    """
  end

  defp with_reference(page) do
    page
    |> between(@begin, @finish, Schema.reference(), "the key reference")
    |> between(@types_begin, @types_finish, ProviderType.reference(), "the provider-type table")
  end

  defp between(page, begin, finish, generated, what) do
    case String.split(page, [begin, finish]) do
      [head, _old, tail] ->
        head <> begin <> "\n" <> generated <> finish <> tail

      _ ->
        Mix.raise("docs/user/configuration.md needs #{begin} and #{finish} around #{what}")
    end
  end

  # Tasks run from the umbrella root or from an app directory, so the root is found
  # rather than assumed.
  defp repository_root, do: Path.expand(Path.join(Mix.Project.build_path(), "../.."))
end
