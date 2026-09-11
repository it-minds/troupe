defmodule Mix.Tasks.Troupe.Index.Rebuild do
  @shortdoc "Rebuild the plane's session index from object storage"

  @moduledoc """
  Reconstruct the session index from object storage alone.

      mix troupe.index.rebuild

  What `troupe admin index rebuild` runs. Every session's manifest is plaintext and
  every segment's epoch, last sequence number and head hash are in its key and its
  object metadata, so this needs no key and reads nothing it is not allowed to read.

  Safe to run against a populated index: rows are overwritten from storage rather than
  duplicated, and a session with a tombstone is left erased.
  """

  use Mix.Task

  alias Troupe.Plane.{Index, Repo}

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:troupe_plane)
    {:ok, _} = Repo.start_link()

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
end
