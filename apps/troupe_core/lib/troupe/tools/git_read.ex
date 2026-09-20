defmodule Troupe.Tools.GitRead do
  @moduledoc """
  Read-only git inspection.

  Git reads were a fifth of the read-only shell traffic in the TUI's session audit
  (`git diff`, `git log`, `git status`, `git show`) and the only one of the big
  read-only groups with no native tool. Every subcommand here is one that cannot change
  the repository: the index and the worktree are only ever touched through `shell`,
  behind its approval. `ref` and `path` may not start with `-`, so a flag cannot be
  smuggled in as an argument.
  """

  @behaviour Troupe.Tool

  alias Troupe.Reaper
  alias Troupe.Tool
  alias Troupe.Tools.Output

  @timeout_ms 30_000
  @default_log 20

  @impl Troupe.Tool
  def name, do: "git_read"

  @impl Troupe.Tool
  def description do
    "Inspect the repository without changing it: `status` (porcelain), `diff` (unstaged, " <>
      "or staged with `staged: true`, or between refs with `ref: \"A..B\"`), `log` (recent " <>
      "commits), `show` (one commit), `branch` (local branches). Use `path` to narrow to a " <>
      "file or directory. Anything that writes — add, commit, checkout, stash — belongs in `shell`."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "op" => %{
          "type" => "string",
          "enum" => ["status", "diff", "log", "show", "branch"],
          "description" => "Which read to perform."
        },
        "path" => %{"type" => "string", "description" => "Limit to this file or directory, relative to the workspace."},
        "ref" => %{"type" => "string", "description" => "Commit or branch for `show`, or a range such as main..HEAD for `diff`."},
        "staged" => %{"type" => "boolean", "description" => "diff: show what is staged rather than what is not."},
        "limit" => %{"type" => "integer", "description" => "log: how many commits (default #{@default_log})."}
      },
      "required" => ["op"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, op} <- Tool.fetch_string(args, "op"),
         {:ok, ref} <- no_flag(Map.get(args, "ref"), "ref"),
         {:ok, path} <- no_flag(Map.get(args, "path"), "path"),
         {:ok, argv} <- argv(op, ref, path, args) do
      git(argv, ctx)
    end
  end

  defp no_flag(nil, _what), do: {:ok, nil}
  defp no_flag("", _what), do: {:ok, nil}

  defp no_flag(value, what) when is_binary(value) do
    if String.starts_with?(value, "-"),
      do: {:error, "#{what} may not start with `-`: #{value}"},
      else: {:ok, value}
  end

  defp no_flag(value, what), do: {:error, "#{what} must be a string, got: #{inspect(value)}"}

  defp argv("status", _ref, path, _args), do: {:ok, ["status", "--porcelain=v1", "--branch"] ++ pathspec(path)}

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
     ["log", "--max-count=#{n}", "--date=short", "--pretty=tformat:%h %ad %an  %s"] ++
       List.wrap(ref) ++ pathspec(path)}
  end

  defp argv("show", ref, path, _args), do: {:ok, ["show", "--stat", "--patch", ref || "HEAD"] ++ pathspec(path)}
  defp argv("branch", _ref, _path, _args), do: {:ok, ["branch", "--list", "--verbose", "--no-color"]}

  defp argv(op, _ref, _path, _args),
    do: {:error, "unknown op: #{op} (expected status, diff, log, show or branch)"}

  defp limit(n) when is_integer(n) and n > 0, do: min(n, 500)
  defp limit(_), do: @default_log

  defp pathspec(nil), do: []
  defp pathspec(path), do: ["--", path]

  defp git(argv, ctx) do
    case Reaper.run(ctx.workspace.root_real, ["git", "--no-pager" | argv], timeout_ms: @timeout_ms) do
      {:ok, "", 0} -> {:ok, "(no output)"}
      {:ok, out, 0} -> {:ok, Output.cap(String.replace(out, "\r\n", "\n"), cap(ctx), ctx)}
      {:ok, out, code} -> {:error, "git exited #{code}: #{String.trim(out)}"}
      {:error, reason} -> {:error, "git failed: #{inspect(reason)}"}
    end
  end

  defp cap(%{config: nil}), do: 60_000
  defp cap(%{config: config}), do: config.tool_output_limit
end
