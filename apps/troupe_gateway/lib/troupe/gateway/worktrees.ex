defmodule Troupe.Gateway.Worktrees do
  @moduledoc """
  Git worktrees, so two sessions in one repository do not fight over the files.

  A second session in a workspace that already has a live one defaults to its own
  worktree on `troupe/<slug>`. Without that, two agents edit the same checkout and
  each sees the other's half-finished work as if it were the user's — which is worse
  than either of them failing.

  Removal refuses a dirty tree unless forced: uncommitted work in a worktree is
  usually the only copy.
  """

  alias Troupe.Reaper

  @type resolved :: %{path: Path.t(), worktree: Path.t() | nil, branch: String.t() | nil}

  @doc """
  Decide where a new session should work.

  `mode` is `"auto"` (branch only when the workspace is busy), `"never"`, or
  `"always"`.
  """
  @spec resolve(Path.t(), String.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve(workspace, mode) do
    workspace = Path.expand(workspace)

    cond do
      mode == "never" -> {:ok, plain(workspace)}
      not git_repository?(workspace) -> {:ok, plain(workspace)}
      mode == "always" -> create(workspace)
      busy?(workspace) -> create(workspace)
      true -> {:ok, plain(workspace)}
    end
  end

  defp plain(workspace), do: %{path: workspace, worktree: nil, branch: nil}

  defp busy?(workspace) do
    %{}
    |> Troupe.list_live_sessions()
    |> Enum.any?(&(&1.workspace == workspace and &1.state == :active))
  end

  @doc "Create a worktree for a workspace on a fresh `troupe/<slug>` branch."
  @spec create(Path.t()) :: {:ok, resolved()} | {:error, term()}
  def create(workspace) do
    slug = slug()
    branch = "troupe/" <> slug
    path = Path.join(Path.dirname(workspace), Path.basename(workspace) <> "-" <> slug)

    case git(workspace, ["worktree", "add", "-b", branch, path]) do
      {:ok, _output, 0} -> {:ok, %{path: path, worktree: path, branch: branch}}
      {:ok, output, _status} -> {:error, {:worktree_failed, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Every worktree of a workspace, with the session using it and whether it is dirty."
  @spec list(Path.t() | nil) :: [map()]
  def list(nil) do
    %{}
    |> Troupe.list_live_sessions()
    |> Enum.map(& &1.workspace)
    |> Enum.uniq()
    |> Enum.flat_map(&list/1)
  end

  def list(workspace) do
    workspace = Path.expand(workspace)

    case git(workspace, ["worktree", "list", "--porcelain"]) do
      {:ok, output, 0} -> output |> parse_porcelain() |> Enum.map(&annotate/1)
      _ -> []
    end
  end

  @doc "Remove a worktree. Refuses a dirty one unless `force`."
  @spec remove(Path.t(), boolean()) :: :ok | {:error, :dirty | term()}
  def remove(path, force?) do
    path = Path.expand(path)

    cond do
      not File.dir?(path) ->
        {:error, :not_found}

      not force? and dirty?(path) ->
        {:error, :dirty}

      true ->
        args = ["worktree", "remove"] ++ if(force?, do: ["--force"], else: []) ++ [path]

        case git(path, args) do
          {:ok, _output, 0} -> :ok
          {:ok, output, _} -> {:error, String.trim(output)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Whether a checkout has uncommitted changes or untracked files."
  @spec dirty?(Path.t()) :: boolean()
  def dirty?(path) do
    case git(path, ["status", "--porcelain"]) do
      {:ok, output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp annotate(%{"worktree" => path} = entry) do
    session =
      %{}
      |> Troupe.list_live_sessions()
      |> Enum.find(&(&1.workspace == path))

    %{
      "path" => path,
      "branch" => entry |> Map.get("branch", "") |> String.replace_prefix("refs/heads/", ""),
      "session_id" => session && session.id,
      "dirty" => dirty?(path)
    }
  end

  defp parse_porcelain(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      block
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, " ", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, true}
        end
      end)
    end)
    |> Enum.filter(&Map.has_key?(&1, "worktree"))
  end

  defp git_repository?(path) do
    match?({:ok, _, 0}, git(path, ["rev-parse", "--git-dir"]))
  end

  # Through reaper like every other OS process, so a hung git cannot outlive the
  # command that started it.
  defp git(cwd, args) do
    if File.dir?(cwd) do
      Reaper.run(cwd, ["git" | args], timeout_ms: 30_000)
    else
      {:error, :not_found}
    end
  end

  defp slug do
    4 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end
end
