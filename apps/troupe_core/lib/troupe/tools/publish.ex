defmodule Troupe.Tools.Publish do
  @moduledoc """
  The only way anything leaves the session's own workspace.

  Every other file tool writes within one mount. `publish` is the one that crosses,
  from `session:/` to a shared root, and `import` is its opposite. That is why it is
  a tool of its own rather than a flag on `write_file`: copying a file onto a volume the
  whole team can see is a different act from editing one in a scratch directory, it
  should look different in a log, and it should be asked about by default.

  Every copy is a durable event carrying the source, the destination and the SHA-256 of
  what was written, so a person looking at a team volume months later can find the
  session that put a file there and check it is still the same bytes.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Mounts, Session, Tool, Watch}
  alias Troupe.Session.Log

  @impl Troupe.Tool
  def name, do: "publish"

  @impl Troupe.Tool
  def description do
    """
    Copy a file from this session's workspace to a shared volume, such as
    `team:<name>/`. This is the only way to put something where other sessions can see
    it, and every copy is recorded with its hash.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "source" => %{"type" => "string", "description" => "Path in this session's workspace."},
        "destination" => %{
          "type" => "string",
          "description" => "Where to put it, e.g. `team:acme/notes/design.md`."
        }
      },
      "required" => ["source", "destination"]
    }
  end

  # Asked by default, because a copy onto a shared volume is visible to people who are
  # not in this session and cannot see what led to it.
  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, source} <- Tool.fetch_string(args, "source"),
         {:ok, destination} <- Tool.fetch_string(args, "destination"),
         {:ok, from, from_entry} <- resolve(ctx, source, :read),
         {:ok, to, to_entry} <- resolve(ctx, destination, :write),
         :ok <- crossing(from_entry, to_entry, :out),
         {:ok, bytes, hash} <- copy(ctx, from, to) do
      record(ctx, from, to, bytes, hash, "out")

      {:ok,
       "Published #{Mounts.display(ctx.workspace.mounts, from)} to " <>
         "#{Mounts.display(ctx.workspace.mounts, to)} (#{bytes} bytes, #{hash})."}
    end
  end

  @doc false
  @spec resolve(Tool.Ctx.t(), String.t(), :read | :write) ::
          {:ok, Path.t(), Mounts.Entry.t()} | {:error, term()}
  def resolve(ctx, path, mode) do
    case ctx.workspace.mounts do
      nil -> {:error, {:no_such_mount, "team"}}
      mounts -> Mounts.resolve(mounts, path, mode)
    end
  end

  # A publish that did not cross is a copy, and `write_file` already does that. Saying so
  # keeps the durable record meaning one thing.
  @doc false
  @spec crossing(Mounts.Entry.t(), Mounts.Entry.t(), :in | :out) :: :ok | {:error, term()}
  def crossing(%{kind: :session}, %{kind: kind}, :out) when kind != :session, do: :ok
  def crossing(%{kind: kind}, %{kind: :session}, :in) when kind != :session, do: :ok

  def crossing(_from, _to, :out),
    do: {:error, "publish copies from session:/ to a shared volume. Use write_file within a mount."}

  def crossing(_from, _to, :in),
    do: {:error, "import copies from a shared volume into session:/. Use read_file within a mount."}

  @doc false
  @spec copy(Tool.Ctx.t(), Path.t(), Path.t()) :: {:ok, non_neg_integer(), String.t()} | {:error, term()}
  def copy(ctx, from, to) do
    with {:ok, contents} <- File.read(from) do
      File.mkdir_p!(Path.dirname(to))
      # The watcher is told first, or our own write comes back as a change the session
      # made by accident.
      Watch.expect_write(ctx.watcher, to, contents)

      case File.write(to, contents) do
        :ok -> {:ok, byte_size(contents), digest(contents)}
        {:error, reason} -> {:error, {reason, to}}
      end
    end
  end

  defp digest(contents) do
    "sha256:" <> (:sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower))
  end

  @doc false
  @spec record(Tool.Ctx.t(), Path.t(), Path.t(), non_neg_integer(), String.t(), String.t()) :: :ok
  def record(ctx, from, to, bytes, hash, direction) do
    Log.append(ctx.session_id, ctx.agent_path || Session.root_path(), :published, %{
      "source" => Mounts.display(ctx.workspace.mounts, from),
      "destination" => Mounts.display(ctx.workspace.mounts, to),
      "hash" => hash,
      "bytes" => bytes,
      "direction" => direction
    })

    :ok
  end

end
