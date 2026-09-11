defmodule Mix.Tasks.Troupe.Schema.Gen do
  @moduledoc """
  Write `protocol/schema/v1/` from `Troupe.Protocol.Schema`.

  The generated files are committed. That is the point: a client author needs a
  machine-readable description of the protocol without a checkout of this repository
  and without running Elixir, and a reviewer needs to see a field being added or
  removed in a diff rather than in a release note.

      mix troupe.schema.gen

  Run it after changing an event or command shape, then commit what changes.
  `mix troupe.schema.diff` fails CI if you forget, and fails it differently if what
  changed was not something clients can survive.
  """

  use Mix.Task

  alias Troupe.Protocol.Schema

  @shortdoc "Regenerate the committed JSON Schema for the protocol"

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    root = Schema.Paths.root()

    written =
      Enum.map(Schema.documents(), fn {relative, document} ->
        path = Path.join(root, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Jason.encode!(document, pretty: true) <> "\n")
        relative
      end)

    index = %{
      "version" => "1",
      "documents" => Enum.sort(written)
    }

    File.write!(Path.join(root, "index.json"), Jason.encode!(index, pretty: true) <> "\n")

    # Anything left from a type that no longer exists is *not* deleted here: removing
    # a document is a breaking change, and `mix troupe.schema.diff` should be the one
    # to say so rather than have it quietly disappear.
    Mix.shell().info("wrote #{length(written)} schema documents to #{root}")
  end
end

defmodule Troupe.Protocol.Schema.Paths do
  @moduledoc "Where the committed schema lives, found from wherever Mix was started."

  @doc "The `protocol/schema/v1` directory at the repository root."
  @spec root() :: Path.t()
  def root do
    Path.join([repository_root(), "protocol", "schema", "v1"])
  end

  # Tasks run from the umbrella root or from an app directory, so the root is found
  # rather than assumed.
  defp repository_root do
    Path.expand(Path.join(Mix.Project.build_path(), "../.."))
  end
end
