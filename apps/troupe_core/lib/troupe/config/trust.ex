defmodule Troupe.Config.Trust do
  @moduledoc """
  Whether a workspace is trusted: whether its own `.troupe/config.yaml` and
  `config.local.yaml` may set the keys `Troupe.Config.Schema` marks `:trusted` — the
  ones that change approvals, where a request goes and with which key, what runs, and
  what may be read.

  A workspace is trusted when the user file's `trusted_workspaces` names it or a
  directory above it. A git worktree of a trusted checkout is trusted too, since that
  is where a branch session works: the worktree's `.git` file names the checkout's
  `.git/worktrees/<name>`, and that directory's `gitdir` names the worktree back, so a
  directory cannot borrow a checkout's trust by writing a `.git` file of its own.

  A session on a pod never asks: it reads no gated key from a project's file.
  """

  alias Troupe.Workspace

  @doc "Whether `workspace` is one of `entries` or under one."
  @spec trusted?(Path.t(), [String.t()]) :: boolean()
  def trusted?(_workspace, []), do: false

  def trusted?(workspace, entries) do
    roots = entries |> Enum.filter(&absolute?/1) |> Enum.map(&key/1)
    candidates = workspace |> candidates() |> Enum.map(&Workspace.compare_key/1)

    Enum.any?(candidates, fn candidate ->
      Enum.any?(roots, &(candidate == &1 or String.starts_with?(candidate, String.trim_trailing(&1, "/") <> "/")))
    end)
  end

  @doc "Whether a trust entry can mean anything: an absolute path, `~` allowed."
  @spec absolute?(String.t()) :: boolean()
  def absolute?(entry) when is_binary(entry) do
    entry == "~" or String.starts_with?(entry, "~/") or Path.type(entry) == :absolute
  end

  def absolute?(_entry), do: false

  defp key(entry), do: entry |> Path.expand() |> real() |> Workspace.compare_key()

  defp candidates(workspace) do
    real = workspace |> Path.expand() |> real()
    [real | List.wrap(main_checkout(real))]
  end

  defp real(path) do
    case Workspace.real_path(path) do
      {:ok, real} -> real
      {:error, _} -> path
    end
  end

  # `<worktree>/.git` is a file saying `gitdir: <checkout>/.git/worktrees/<name>`, and
  # that directory's `gitdir` file names `<worktree>/.git`. Both must agree.
  defp main_checkout(worktree) do
    dot_git = Path.join(worktree, ".git")

    with true <- File.regular?(dot_git),
         {:ok, "gitdir: " <> gitdir} <- File.read(dot_git),
         gitdir = gitdir |> String.trim() |> Path.expand(worktree),
         "worktrees" <- gitdir |> Path.dirname() |> Path.basename(),
         ".git" <- gitdir |> Path.dirname() |> Path.dirname() |> Path.basename(),
         {:ok, back} <- File.read(Path.join(gitdir, "gitdir")),
         true <- same?(back |> String.trim() |> Path.expand(gitdir), dot_git) do
      gitdir |> Path.dirname() |> Path.dirname() |> Path.dirname() |> real()
    else
      _ -> nil
    end
  end

  defp same?(a, b), do: Workspace.compare_key(real(a)) == Workspace.compare_key(real(b))
end
