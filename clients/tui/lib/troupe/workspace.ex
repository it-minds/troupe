defmodule Troupe.Workspace do
  @moduledoc """
  Path confinement. Every tool path is resolved against the branch's workspace
  root with symlinks (and junctions on Windows) followed; anything that
  escapes the root is rejected.
  """

  @type os :: :unix | :windows

  @doc """
  Resolves `path` relative to `root`. Options: `:os` (defaults to the host),
  `:canonicalize` (function used to resolve links; defaults to the real
  filesystem, tests pass identity).
  """
  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :outside_workspace | :invalid_path}
  def resolve(root, path, opts \\ []) when is_binary(root) and is_binary(path) do
    os = Keyword.get(opts, :os, host_os())
    canon = Keyword.get(opts, :canonicalize, &canonicalize/1)

    with :ok <- validate(path),
         {:ok, abs} <- expand(root, path, os) do
      real_root = canon.(normalize(root, os))
      real = canon.(abs)

      if inside?(real_root, real, os) do
        {:ok, real}
      else
        {:error, :outside_workspace}
      end
    end
  end

  @spec host_os() :: os()
  def host_os do
    case :os.type() do
      {:win32, _} -> :windows
      _ -> :unix
    end
  end

  defp validate(path) do
    if String.contains?(path, <<0>>), do: {:error, :invalid_path}, else: :ok
  end

  defp expand(root, path, :unix) do
    {:ok, Path.expand(path, root)}
  end

  defp expand(root, path, :windows) do
    p = String.replace(path, "\\", "/")
    r = normalize(root, :windows)

    cond do
      # UNC path
      String.starts_with?(p, "//") -> {:ok, collapse(p)}
      # Drive-letter absolute
      p =~ ~r{^[A-Za-z]:/} -> {:ok, collapse(p)}
      # Drive-relative (D:foo) is ambiguous -> reject
      p =~ ~r{^[A-Za-z]:} -> {:error, :invalid_path}
      # Rooted on current drive
      String.starts_with?(p, "/") -> {:ok, collapse(drive_of(r) <> p)}
      true -> {:ok, collapse(r <> "/" <> p)}
    end
  end

  defp drive_of(root) do
    case Regex.run(~r{^([A-Za-z]:)}, root) do
      [_, d] -> d
      _ -> ""
    end
  end

  # Collapse "." and ".." segments without touching the filesystem.
  defp collapse(p) do
    {prefix, rest} =
      cond do
        String.starts_with?(p, "//") -> {"//", String.trim_leading(p, "/")}
        p =~ ~r{^[A-Za-z]:/} -> {binary_part(p, 0, 3), binary_part(p, 3, byte_size(p) - 3)}
        true -> {"/", String.trim_leading(p, "/")}
      end

    segs =
      rest
      |> String.split("/", trim: true)
      |> Enum.reduce([], fn
        ".", acc -> acc
        "..", [] -> []
        "..", [_ | acc] -> acc
        seg, acc -> [seg | acc]
      end)
      |> Enum.reverse()

    prefix <> Enum.join(segs, "/")
  end

  defp normalize(root, :windows), do: root |> String.replace("\\", "/") |> collapse()
  defp normalize(root, :unix), do: Path.expand(root)

  defp inside?(root, path, os) do
    {r, p} =
      case os do
        :windows -> {String.downcase(root), String.downcase(path)}
        :unix -> {root, path}
      end

    r = String.trim_trailing(r, "/")
    p == r or String.starts_with?(p, r <> "/")
  end

  @doc """
  Resolves symlinks component by component. Components that do not exist yet
  are appended unchanged, so a path to a file about to be created still
  canonicalizes its existing ancestors.
  """
  @spec canonicalize(String.t()) :: String.t()
  def canonicalize(path) do
    canonicalize(path, 0)
  end

  defp canonicalize(path, depth) when depth > 40, do: path

  defp canonicalize(path, depth) do
    [root | segs] = Path.split(path)
    walk(root, segs, depth)
  end

  defp walk(current, [], _depth), do: current

  defp walk(current, [seg | rest], depth) do
    candidate = Path.join(current, seg)

    case :file.read_link_all(String.to_charlist(candidate)) do
      {:ok, target} ->
        resolved = canonicalize(Path.expand(to_string(target), current), depth + 1)
        walk(resolved, rest, depth)

      {:error, :enoent} ->
        Path.join([candidate | rest])

      {:error, _} ->
        walk(candidate, rest, depth)
    end
  end
end
