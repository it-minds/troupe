defmodule Troupe.Tools.Grep do
  @moduledoc """
  Search file contents, using ripgrep when it is on PATH and a built-in scan when it
  is not.

  The fallback exists because a single self-contained binary lands on machines with
  nothing installed, and search is too central to the agent loop to be optional
  there. Both paths produce the same output shape, so the model cannot tell which ran.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Gitignore, Reaper, Tool, Workspace}
  alias Troupe.Tools.Output

  @max_matches 200

  @impl Troupe.Tool
  def name, do: "grep"

  @impl Troupe.Tool
  def description do
    """
    Search file contents with a regular expression. Returns `path:line: text` for
    each match. Narrow with `glob` (e.g. `**/*.ex`) or `path`. Ignored files and
    .git are skipped. Prefer this over reading whole files to find something.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Regular expression to search for."},
        "path" => %{"type" => "string", "description" => "Directory to search within."},
        "glob" => %{"type" => "string", "description" => "Only search files matching this glob."},
        "case_sensitive" => %{"type" => "boolean", "description" => "Defaults to false."}
      },
      "required" => ["pattern"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, pattern} <- Tool.fetch_string(args, "pattern"),
         {:ok, root} <- Workspace.resolve(ctx.workspace, Map.get(args, "path") || ".") do
      opts = %{
        glob: Map.get(args, "glob"),
        case_sensitive: Map.get(args, "case_sensitive", false)
      }

      matches =
        case ripgrep_path() do
          nil -> builtin_search(root, pattern, opts, ctx)
          rg -> ripgrep_search(rg, root, pattern, opts, ctx)
        end

      case matches do
        {:error, _} = error -> error
        lines -> {:ok, render(lines, ctx)}
      end
    end
  end

  defp ripgrep_path, do: System.find_executable("rg")

  # Through reaper, like every other OS process: a search over a huge tree is exactly
  # as cancellable as a shell command because it is started the same way.
  defp ripgrep_search(rg, root, pattern, opts, ctx) do
    flags =
      ["--line-number", "--no-heading", "--color=never", "--max-count", "#{@max_matches}"] ++
        if(opts.case_sensitive, do: ["--case-sensitive"], else: ["--ignore-case"]) ++
        if(opts.glob, do: ["--glob", opts.glob], else: []) ++
        ["--regexp", pattern, "."]

    case Reaper.run(root, [rg | flags], timeout_ms: 60_000) do
      {:ok, output, status} when status in [0, 1] ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&rebase(&1, root, ctx))

      {:ok, output, :timeout} ->
        {:error, "The search timed out. Narrow it with `glob` or `path`.\n" <> output}

      {:ok, output, _status} ->
        {:error, "ripgrep failed: #{String.trim(output)}"}

      # No reaper for this platform means no subprocess — but the built-in scanner
      # needs none, so search still works.
      {:error, :reaper_missing} ->
        builtin_search(root, pattern, opts, ctx)
    end
  end

  # ripgrep prints paths relative to its cwd; the model should see them relative to
  # the workspace root, which is not necessarily the same directory.
  defp rebase(line, root, ctx) do
    case String.split(line, ":", parts: 2) do
      [path, rest] ->
        absolute = Path.expand(path, root)
        Workspace.relative(ctx.workspace, absolute) <> ":" <> rest

      _ ->
        line
    end
  end

  defp builtin_search(root, pattern, opts, ctx) do
    regex_opts = if opts.case_sensitive, do: "", else: "i"

    case Regex.compile(pattern, regex_opts) do
      {:ok, regex} ->
        ignore = Gitignore.load(ctx.workspace.root_real)
        glob = opts.glob || "**/*"

        root
        |> Path.join(glob)
        |> Path.wildcard(match_dot: false)
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&Gitignore.ignored?(ignore, Workspace.relative(ctx.workspace, &1)))
        |> Enum.sort()
        |> Enum.flat_map(&search_file(&1, regex, ctx))
        |> Enum.take(@max_matches)

      {:error, {reason, at}} ->
        {:error, "Invalid regular expression at position #{at}: #{reason}"}
    end
  end

  defp search_file(path, regex, ctx) do
    case File.read(path) do
      {:ok, contents} -> matching_lines(contents, regex, Workspace.relative(ctx.workspace, path))
      {:error, _} -> []
    end
  end

  defp matching_lines(contents, regex, relative) do
    if binary_file?(contents) do
      []
    else
      contents
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> Enum.flat_map(&match_line(&1, regex, relative))
    end
  end

  defp match_line({line, number}, regex, relative) do
    if Regex.match?(regex, line), do: ["#{relative}:#{number}:#{line}"], else: []
  end

  # A NUL byte in the first chunk is the same heuristic grep itself uses.
  defp binary_file?(contents) do
    head = binary_part(contents, 0, min(byte_size(contents), 8_000))
    :binary.match(head, <<0>>) != :nomatch
  end

  defp render([], _ctx), do: "No matches."
  defp render(lines, ctx), do: lines |> Enum.join("\n") |> Output.cap(cap(ctx), ctx)

  defp cap(%{config: nil}), do: 60_000
  defp cap(%{config: config}), do: config.tool_output_limit
end
