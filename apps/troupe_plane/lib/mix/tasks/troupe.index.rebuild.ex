defmodule Mix.Tasks.Troupe.Index.Rebuild do
  @shortdoc "Rebuild the plane's session index from object storage"

  @moduledoc """
  Reconstruct the session index from object storage alone.

      mix troupe.index.rebuild
      mix troupe.index.rebuild --database-url postgres://troupe:troupe@localhost:5433/troupe_plane

  What `troupe admin index rebuild` runs. `--database-url` points it at a database that
  is not the configured one, which is what a restore drill needs: the restored cluster
  comes up beside the live one and the rebuild runs against it before anything is
  switched over. Every session's manifest is plaintext and
  every segment's epoch, last sequence number and head hash are in its key and its
  object metadata, so this needs no key and reads nothing it is not allowed to read.

  Safe to run against a populated index: rows are overwritten from storage rather than
  duplicated, and a session with a tombstone is left erased.
  """

  use Mix.Task

  alias Troupe.Plane.{Index, Repo}

  @impl Mix.Task
  def run(argv) do
    {switches, _positional, _invalid} = OptionParser.parse(argv, strict: [database_url: :string])

    {:ok, _} = Application.ensure_all_started(:troupe_plane)
    {:ok, _} = Repo.start_link(repo_opts(switches))

    case Index.rebuild() do
      {:ok, report} ->
        Mix.shell().info(
          "found #{report.found}, rebuilt #{report.rebuilt}, " <>
            "skipped #{report.skipped}, failed #{report.failed}"
        )

      {:error, reason} ->
        Mix.raise("could not read object storage: #{inspect(reason)}")
    end
  end

  defp repo_opts(switches) do
    case switches[:database_url] do
      nil -> []
      url -> [url: url]
    end
  end
end
