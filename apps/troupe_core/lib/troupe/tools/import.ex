defmodule Troupe.Tools.Import do
  @moduledoc """
  The opposite of `publish`: a copy from a shared volume into the session's workspace.

  Separate from `read_file` for the same reason `publish` is separate from `write_file`.
  Reading a team volume is ordinary; taking a copy of something from it into a session's
  own tree is the moment that file starts having two histories, and the durable record
  is what lets somebody later find out which version was taken and when.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Mounts, Tool}
  alias Troupe.Tools.Publish

  @impl Troupe.Tool
  def name, do: "import"

  @impl Troupe.Tool
  def description do
    """
    Copy a file from a shared volume, such as `team:<name>/`, into this session's
    workspace. Every copy is recorded with its hash.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "source" => %{"type" => "string", "description" => "Path on a shared volume."},
        "destination" => %{"type" => "string", "description" => "Where to put it in this workspace."}
      },
      "required" => ["source", "destination"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, source} <- Tool.fetch_string(args, "source"),
         {:ok, destination} <- Tool.fetch_string(args, "destination"),
         {:ok, from, from_entry} <- Publish.resolve(ctx, source, :read),
         {:ok, to, to_entry} <- Publish.resolve(ctx, destination, :write),
         :ok <- Publish.crossing(from_entry, to_entry, :in),
         {:ok, bytes, hash} <- Publish.copy(ctx, from, to) do
      Publish.record(ctx, from, to, bytes, hash, "in")

      {:ok,
       "Imported #{Mounts.display(ctx.workspace.mounts, from)} to " <>
         "#{Mounts.display(ctx.workspace.mounts, to)} (#{bytes} bytes, #{hash})."}
    end
  end
end
