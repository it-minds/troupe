defmodule Troupe.Workspace do
  @moduledoc """
  The workspace root, and the path confinement every file tool goes through.

  A workspace is created once per session from a user-supplied directory. Its root is
  resolved to a real path — symlinks and, on Windows, junctions followed — and every
  path a tool is asked to touch is resolved the same way and checked against it. A
  path that escapes, by any of `..`, an absolute path, a symlink pointing out, a
  second drive letter, a UNC share, or a case-variant of the root, is rejected before
  the tool runs.

  Resolution keeps trailing components that do not exist yet, so `write_file` can
  create a new file — but every component that *does* exist is resolved, so a symlink
  anywhere along the path is caught.
  """

  @enforce_keys [:root, :root_real, :root_key]
  defstruct [:root, :root_real, :root_key]

  @type t :: %__MODULE__{root: Path.t(), root_real: Path.t(), root_key: String.t()}

  @max_link_hops 40

  @doc """
  Build a workspace from a directory, resolving it to a real path.

  Fails if the directory does not exist: a workspace that cannot be resolved cannot
  be confined to, and silently creating one would put the agent somewhere the user
  did not ask for.
  """
  @spec new(Path.t()) :: {:ok, t()} | {:error, term()}
  def new(root) do
    expanded = Path.expand(root)

    if File.dir?(expanded) do
      with {:ok, real} <- real_path(expanded) do
        {:ok, %__MODULE__{root: expanded, root_real: real, root_key: compare_key(real)}}
      end
    else
      {:error, {:not_a_directory, expanded}}
    end
  end

  @doc "Same as `new/1` but raises, for callers that treat a bad workspace as fatal."
  @spec new!(Path.t()) :: t()
  def new!(root) do
    case new(root) do
      {:ok, ws} -> ws
      {:error, reason} -> raise ArgumentError, "invalid workspace #{root}: #{inspect(reason)}"
    end
  end

  @doc """
  Resolve a tool-supplied path against the workspace, or reject it.

  Returns the resolved absolute path on success. Relative paths are taken from the
  workspace root; absolute ones are allowed only when they resolve back inside it.
  """
  @spec resolve(t(), String.t()) :: {:ok, Path.t()} | {:error, {:outside_workspace, String.t()}}
  def resolve(%__MODULE__{} = ws, path) when is_binary(path) do
    candidate =
      if absolute?(path) do
        Path.expand(path)
      else
        Path.expand(path, ws.root_real)
      end

    case real_path(candidate) do
      {:ok, real} ->
        if inside?(ws, real), do: {:ok, real}, else: {:error, {:outside_workspace, path}}

      {:error, _reason} ->
        {:error, {:outside_workspace, path}}
    end
  end

  @doc "The path as the model should see it: relative to the workspace root."
  @spec relative(t(), Path.t()) :: String.t()
  def relative(%__MODULE__{} = ws, path) do
    case Path.relative_to(path, ws.root_real) do
      ^path -> path
      rel -> rel
    end
  end

  @doc false
  @spec inside?(t(), Path.t()) :: boolean()
  def inside?(%__MODULE__{root_key: root_key}, path) do
    key = compare_key(path)
    key == root_key or String.starts_with?(key, root_key <> "/")
  end

  @doc """
  Resolve every existing component of a path, following symlinks and junctions.

  Trailing components that do not exist are appended literally, so a path to a file
  about to be created still resolves. A symlink loop, or more than #{@max_link_hops}
  hops, is an error rather than a hang.
  """
  @spec real_path(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def real_path(path) do
    {prefix, rest} = split_root(Path.expand(path))
    walk(prefix, rest, [], 0)
  end

  # Walk components left to right. `done` is the reversed list of resolved components.
  defp walk(_prefix, _rest, _done, hops) when hops > @max_link_hops do
    {:error, :symlink_loop}
  end

  defp walk(prefix, [], done, _hops), do: {:ok, join(prefix, Enum.reverse(done))}

  defp walk(prefix, [component | rest], done, hops) do
    case component do
      "." ->
        walk(prefix, rest, done, hops)

      ".." ->
        walk(prefix, rest, Enum.drop(done, 1), hops)

      _ ->
        here = join(prefix, Enum.reverse([component | done]))

        case :file.read_link_all(String.to_charlist(here)) do
          {:ok, target} -> follow_link(List.to_string(target), prefix, rest, done, hops)
          {:error, _} -> walk(prefix, rest, [component | done], hops)
        end
    end
  end

  defp follow_link(target, prefix, rest, done, hops) do
    if absolute?(target) do
      {new_prefix, new_rest} = split_root(Path.expand(target))
      walk(new_prefix, new_rest ++ rest, [], hops + 1)
    else
      # A relative link resolves against the directory holding it.
      walk(prefix, components(target) ++ rest, done, hops + 1)
    end
  end

  # Split an absolute path into its root prefix and its components. The prefix is
  # what makes drive letters and UNC shares distinct roots on Windows: `C:` and `D:`
  # and `\\server\share` must never compare equal to each other or to `/`.
  defp split_root(path) do
    normalized = String.replace(path, "\\", "/")

    cond do
      match?(<<_::utf8, ":/", _::binary>>, normalized) ->
        <<drive::binary-size(2), "/", rest::binary>> = normalized
        {drive, components(rest)}

      String.starts_with?(normalized, "//") ->
        case components(normalized) do
          [server, share | rest] -> {"//" <> server <> "/" <> share, rest}
          other -> {"//", other}
        end

      true ->
        {"", components(normalized)}
    end
  end

  defp components(path) do
    path |> String.replace("\\", "/") |> String.split("/", trim: true)
  end

  defp join(prefix, components), do: prefix <> "/" <> Enum.join(components, "/")

  defp absolute?(path) do
    normalized = String.replace(path, "\\", "/")

    String.starts_with?(normalized, "/") or
      match?(<<_::utf8, ":/", _::binary>>, normalized)
  end

  @doc """
  The form two paths are compared in.

  Windows treats both separators alike and compares case-insensitively, so
  `c:\\repo\\..\\REPO\\file` names the same place as `C:/repo/file` and a case-variant
  cannot be used to slip outside a workspace. Everywhere else case is significant and
  a differently-cased path really is a different path.

  `family` is exposed so the Windows rules can be checked from any host; production
  callers use the default.
  """
  @spec compare_key(Path.t(), :windows | :unix) :: String.t()
  def compare_key(path, family \\ family()) do
    normalized = path |> String.replace("\\", "/") |> String.trim_trailing("/")
    normalized = if normalized == "", do: "/", else: normalized

    case family do
      :windows -> String.downcase(normalized)
      :unix -> normalized
    end
  end

  defp family do
    case :os.type() do
      {:win32, _} -> :windows
      _ -> :unix
    end
  end
end
