defmodule Troupe.Worker.Disk do
  @moduledoc """
  How full the PVC is, and what to do about it.

  A worker caches sessions it has run recently — their workspaces and their event logs —
  because activating one that is already on disk costs nothing. That cache is the only
  thing on a worker's volume that can grow without bound, so it is also the only thing
  that has to be given up when the volume fills.

  Two watermarks. Above the **high** one the worker puts its quietest sessions to sleep,
  which is not a loss: dormancy is upload-then-erase, so the bytes reclaimed are bytes
  that are already in object storage. Above the **critical** one it stops accepting
  placements at all, because a pod that runs out of disk mid-turn loses the turn.
  """

  @high 0.80
  @critical 0.90

  @type usage :: %{
          total_bytes: non_neg_integer(),
          used_bytes: non_neg_integer(),
          available_bytes: non_neg_integer(),
          fraction: float()
        }

  @doc """
  What the filesystem holding `path` looks like.

  `df` rather than an Erlang API, because the number that matters is the filesystem's
  and not the sum of the files this code knows about: a PVC shared with anything else,
  or holding a deleted-but-open file, would make the sum a lie.
  """
  @spec usage(Path.t()) :: usage()
  def usage(path) do
    case df(path) do
      {:ok, total, used, available} ->
        %{
          total_bytes: total,
          used_bytes: used,
          available_bytes: available,
          fraction: if(total > 0, do: used / total, else: 0.0)
        }

      :error ->
        %{total_bytes: 0, used_bytes: 0, available_bytes: 0, fraction: 0.0}
    end
  end

  @doc "Where this volume stands: `:ok`, `:high`, or `:critical`."
  @spec pressure(Path.t() | usage(), keyword()) :: :ok | :high | :critical
  def pressure(path_or_usage, opts \\ [])

  def pressure(path, opts) when is_binary(path), do: pressure(usage(path), opts)

  def pressure(%{fraction: fraction}, opts) do
    cond do
      fraction >= Keyword.get(opts, :critical, @critical) -> :critical
      fraction >= Keyword.get(opts, :high, @high) -> :high
      true -> :ok
    end
  end

  @doc "The default watermarks, so a caller can report the same numbers it acts on."
  @spec watermarks() :: %{high: float(), critical: float()}
  def watermarks, do: %{high: @high, critical: @critical}

  defp df(path) do
    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} -> parse(output)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # The POSIX format is fixed: Filesystem, 1024-blocks, Used, Available, Capacity,
  # Mounted on — and a long device name wraps onto its own line, which is why the
  # numbers are taken from the end rather than by column index.
  defp parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.join(" ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.flat_map(&parse_integer/1)
    |> case do
      [total, used, available | _] -> {:ok, total * 1024, used * 1024, available * 1024}
      _ -> :error
    end
  end

  defp parse_integer(token) do
    case Integer.parse(token) do
      {value, ""} -> [value]
      _ -> []
    end
  end
end
