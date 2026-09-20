defmodule Troupe.Tools.ListFiles do
  @moduledoc "Glob the workspace, skipping ignored paths."

  @behaviour Troupe.Tool

  alias Troupe.{Gitignore, Workspace}

  @limit 1_000

  @impl Troupe.Tool
  def name, do: "list_files"

  @impl Troupe.Tool
  def description do
    """
    List files matching a glob, relative to the workspace root. `**` matches across
    directories. Paths ignored by .gitignore, and .git itself, are skipped.
    Examples: `**/*.ex`, `lib/**/*_test.exs`, `*` for the top level.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Glob pattern. Defaults to `**/*`."},
        "path" => %{"type" => "string", "description" => "Directory to glob within."}
      },
      "required" => []
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    pattern = Map.get(args, "pattern") || "**/*"
    base = Map.get(args, "path") || "."

    with {:ok, root} <- Workspace.resolve_readable(ctx.workspace, base, Workspace.read_roots(ctx)) do
      ignore = Gitignore.load(ctx.workspace.root_real)

      matches =
        root
        |> Path.join(pattern)
        |> Path.wildcard(match_dot: false)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Workspace.relative(ctx.workspace, &1))
        |> Enum.reject(&Gitignore.ignored?(ignore, &1))
        |> Enum.sort()

      {:ok, render(matches)}
    end
  end

  defp render([]), do: "No files matched."

  defp render(matches) do
    shown = Enum.take(matches, @limit)
    body = Enum.join(shown, "\n")

    if length(matches) > @limit do
      body <> "\n\n[#{length(matches) - @limit} more matches; narrow the pattern.]"
    else
      body
    end
  end
end
