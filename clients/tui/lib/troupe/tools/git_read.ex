defmodule Troupe.Tools.GitRead do
  @moduledoc """
  Read-only git inspection.

  Git reads were a fifth of the read-only shell traffic in the session audit
  (`git diff` 42, `git log` 35, `git status` 32, `git show` 32) and the only one
  of the big read-only groups with no native tool at all. Every subcommand here
  is one that cannot change the repository: the index and the worktree are only
  ever touched through `shell`, behind its approval.
  """
  @behaviour Troupe.Tool

  alias Troupe.OS
  alias Troupe.Tool.{Bound, Context}

  @timeout_ms 30_000
  @max_bytes 5_000_000
  @default_log 20

  @impl true
  def name, do: "git_read"

  @impl true
  def description,
    do:
      "Inspect the repository without changing it: `status` (porcelain), `diff` (unstaged, or staged with `staged: true`, or between refs with `ref: \"A..B\"`), `log` (recent commits), `show` (one commit), `branch` (local branches). Use `path` to narrow to a file or directory. Anything that writes — add, commit, checkout, stash — belongs in `shell`."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "op" => %{
          "type" => "string",
          "enum" => ["status", "diff", "log", "show", "branch"],
          "description" => "Which read to perform"
        },
        "path" => %{
          "type" => "string",
          "description" => "Limit to this file or directory, relative to the workspace"
        },
        "ref" => %{
          "type" => "string",
          "description" => "Commit or branch for `show`, or a range such as main..HEAD for `diff`"
        },
        "staged" => %{
          "type" => "boolean",
          "description" => "diff: show what is staged rather than what is not"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "log: how many commits (default #{@default_log})"
        }
      },
      "required" => ["op"]
    }
  end

  @impl true
  def default_permission, do: :auto

  @impl true
  def run(%{"op" => op} = args, ctx) do
    with {:ok, ref} <- ref(args),
         {:ok, path} <- path(args),
         {:ok, argv} <- argv(op, ref, path, args) do
      git(argv, ctx)
    end
  end

  def run(_args, _ctx), do: {:error, "op is required"}

  # A ref or path that starts with `-` would be read as a flag, which is how an
  # argument list turns back into the injection an argument list exists to
  # prevent. Paths additionally go after `--`, so a file named like a flag is
  # still addressable.
  defp ref(args), do: no_flag(Map.get(args, "ref"), "ref")
  defp path(args), do: no_flag(Map.get(args, "path"), "path")

  defp no_flag(nil, _what), do: {:ok, nil}
  defp no_flag("", _what), do: {:ok, nil}

  defp no_flag(value, what) when is_binary(value) do
    if String.starts_with?(value, "-"),
      do: {:error, "#{what} may not start with `-`: #{value}"},
      else: {:ok, value}
  end

  defp no_flag(value, what), do: {:error, "#{what} must be a string, got: #{inspect(value)}"}

  defp argv("status", _ref, path, _args),
    do: {:ok, ["status", "--porcelain=v1", "--branch"] ++ pathspec(path)}

  defp argv("diff", ref, path, args) do
    flags =
      cond do
        is_binary(ref) -> [ref]
        Map.get(args, "staged") == true -> ["--staged"]
        true -> []
      end

    {:ok, ["diff", "--stat", "--patch"] ++ flags ++ pathspec(path)}
  end

  defp argv("log", ref, path, args) do
    n = args |> Map.get("limit") |> limit()

    {:ok,
     ["log", "--max-count=#{n}", "--date=short", "--pretty=format:%h %ad %an  %s"] ++
       List.wrap(ref) ++ pathspec(path)}
  end

  defp argv("show", ref, path, _args),
    do: {:ok, ["show", "--stat", "--patch", ref || "HEAD"] ++ pathspec(path)}

  defp argv("branch", _ref, _path, _args),
    do: {:ok, ["branch", "--list", "--verbose", "--no-color"]}

  defp argv(op, _ref, _path, _args),
    do: {:error, "unknown op: #{op} (expected status, diff, log, show or branch)"}

  defp limit(n) when is_integer(n) and n > 0, do: min(n, 500)
  defp limit(_), do: @default_log

  defp pathspec(nil), do: []
  defp pathspec(path), do: ["--", path]

  defp git(argv, ctx) do
    case OS.Process.run("git", ["--no-pager" | argv],
           cd: ctx.workspace,
           timeout_ms: @timeout_ms,
           max_output: @max_bytes
         ) do
      {:ok, "", 0} -> {:ok, "(no output)"}
      {:ok, out, 0} -> {:ok, bound(out, ctx)}
      {:ok, out, code} -> {:error, "git exited #{code}: #{String.trim(out)}"}
      {:error, :timeout, _} -> {:error, "git timed out after #{@timeout_ms}ms"}
    end
  end

  # A diff is the one op that can be arbitrarily long. It is reproducible, but
  # unlike a file read it has no natural offset to name, so what does not fit is
  # stored and paged with `read_output` like any other oversized result.
  defp bound(out, ctx) do
    limits = Context.limits(ctx)
    text = Bound.sanitize(out)

    Troupe.Session.Outputs.store_and_mark(
      ctx.session_id,
      text,
      Bound.chars(text, limits.max_chars),
      limits.file_lines
    )
  end
end
