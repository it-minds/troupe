defmodule Troupe.Worktree do
  @moduledoc """
  A git worktree's main checkout, and which of the checkout's files its HEAD commits
  (Decision 826).

  A worktree is made at a commit, so one made before the repository was onboarded has no
  `.troupe/agents/` or `.troupe/skills/` while every session in the main checkout reads
  them. A session in a worktree reads its own tree first and, for a name its tree lacks,
  the main checkout's file — but only one the checkout's HEAD commits. A file onboarded
  there and not committed yet is somebody's work in progress in another tree; it is not
  read, and it is listed as skipped, saying to commit it. A committed file is read where
  it is in the checkout, so an edit not yet committed to it is read with it.

  A worktree is recognised the way trust recognises one (`Troupe.Config.Trust.root/1`):
  its `.git` file names the checkout's `.git/worktrees/<name>`, and that directory's
  `gitdir` names the worktree back, so a directory cannot borrow another checkout's files
  by writing a `.git` file of its own.
  """

  alias Troupe.Config.Trust
  alias Troupe.{Paths, Reaper, Workspace}

  @doc """
  The main checkout `root` is a git worktree of, or `nil` for a checkout, a directory
  that is not in git, and a `.git` file the checkout does not name back.
  """
  @spec main(Path.t()) :: Path.t() | nil
  def main(root) do
    root = Path.expand(root)

    # A checkout's `.git` is a directory, and most workspaces are one: asked before every
    # model call, the answer for them should cost one stat.
    with true <- File.regular?(Path.join(root, ".git")),
         main = Trust.root(root),
         false <- Workspace.compare_key(main) == Workspace.compare_key(real(root)) do
      main
    else
      _not_a_worktree -> nil
    end
  end

  @doc """
  The paths under `dir`, relative to the checkout, that the checkout's HEAD commits.
  Empty when git cannot say: a checkout with no commit, or no git to ask.
  """
  @spec committed(Path.t(), String.t()) :: MapSet.t(String.t())
  def committed(main, dir) do
    # One path a line, and not `-z`: reaper hands back no output that has a NUL in it. A
    # name git would still quote is not one an agent or a skill may have.
    args = ["-c", "core.quotePath=false", "ls-tree", "-r", "--name-only", "HEAD", "--", dir]

    case git(main, args) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> MapSet.new()
      :error -> MapSet.new()
    end
  end

  @doc "Why a file the main checkout has not committed is not read in its worktree."
  @spec uncommitted(Path.t()) :: String.t()
  def uncommitted(main) do
    "not committed in #{Paths.display(main)}, the checkout this worktree belongs to, " <>
      "and a worktree reads only what the checkout has committed: commit it to use it here"
  end

  defp real(path) do
    case Workspace.real_path(path) do
      {:ok, real} -> real
      {:error, _} -> path
    end
  end

  # Through reaper, as every git the harness runs (Decision 733): a helper that will not
  # start is no committed files rather than a crash in whatever was loading definitions.
  defp git(cwd, args) do
    case Reaper.run(cwd, ["git" | args], timeout_ms: 10_000) do
      {:ok, out, 0} -> {:ok, out}
      _other -> :error
    end
  end
end
