defmodule Troupe.Tools.Grep do
  @moduledoc """
  Search file contents, using ripgrep when it is on PATH and a built-in scan when it
  is not.

  The fallback exists because a single self-contained binary lands on machines with
  nothing installed, and search is too central to the agent loop to be optional
  there. Both paths produce the same output shape, so the model cannot tell which ran.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Config, Executable, Gitignore, Paths, Reaper, Tool, Workspace}
  alias Troupe.Tools.Output

  @max_matches 200

  @impl Troupe.Tool
  def name, do: "grep"

  @impl Troupe.Tool
  def description do
    """
    Search file contents with a regular expression. Answers how many lines matched in
    how many files, then `path:line: text` for each match. Narrow with `path`, a directory or one file, or with `glob`, a
    pattern of file names: check what the files are really called before narrowing
    by their extension. Ignored files and .git are skipped. Prefer this over reading
    whole files to find something.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Regular expression to search for."},
        "path" => %{
          "type" => "string",
          "description" => "A directory to search within, or one file to search."
        },
        "glob" => %{"type" => "string", "description" => "Only search files matching this glob."},
        "case_sensitive" => %{"type" => "boolean", "description" => "Defaults to false."}
      },
      "required" => ["pattern"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx), do: search(args, ctx, ripgrep_path())

  @doc false
  # `rg` is ripgrep's path, or `nil` for the built-in scan: a test takes each.
  def search(args, ctx, rg) do
    with {:ok, pattern} <- Tool.fetch_string(args, "pattern"),
         {:ok, root} <-
           Workspace.resolve_readable(
             ctx.workspace,
             Map.get(args, "path") || ".",
             Workspace.read_roots(ctx)
           ) do
      opts = %{
        glob: Map.get(args, "glob"),
        case_sensitive: Map.get(args, "case_sensitive", false)
      }

      matches =
        case rg do
          nil -> builtin_search(root, pattern, opts, ctx)
          rg -> ripgrep_search(rg, root, pattern, opts, ctx)
        end

      case matches do
        {:error, _} = error -> error
        found -> {:ok, render(found, ctx, opts)}
      end
    end
  end

  # On the PATH alone: a repository's `rg.bat` in the daemon's current directory is not
  # ripgrep (Decision 846).
  defp ripgrep_path, do: Executable.find("rg")

  # Through reaper, like every other OS process: a search over a huge tree is exactly
  # as cancellable as a shell command because it is started the same way.
  #
  # `path` may name one file (Decision 776): ripgrep then runs beside it and searches it
  # alone, and `--with-filename` keeps the `path:line:` shape a single file would drop.
  defp ripgrep_search(rg, root, pattern, opts, ctx) do
    {dir, target} =
      if File.regular?(root), do: {Path.dirname(root), Path.basename(root)}, else: {root, "."}

    flags =
      ["--line-number", "--with-filename", "--no-heading", "--color=never"] ++
        ["--max-count", "#{@max_matches}"] ++
        if(opts.case_sensitive, do: ["--case-sensitive"], else: ["--ignore-case"]) ++
        if(opts.glob, do: ["--glob", opts.glob], else: []) ++
        ["--regexp", pattern, target]

    case Reaper.run(dir, [rg | flags], timeout_ms: 60_000) do
      {:ok, output, status} when status in [0, 1] ->
        lines =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&rebase(&1, dir, ctx))

        found(lines, lines, capped?(lines))

      {:ok, output, :timeout} ->
        {:error, "The search timed out. Narrow it with `glob` or `path`.\n" <> output}

      {:ok, output, _status} ->
        {:error, "ripgrep failed: #{String.trim(output)}"}

      # No reaper for this platform, or one that will not start, means no subprocess —
      # but the built-in scanner needs none, so search still works.
      {:error, _reason} ->
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
        all = root |> files(opts, ctx) |> Enum.flat_map(&search_file(&1, regex, ctx))
        found(all, Enum.take(all, @max_matches), false)

      {:error, {reason, at}} ->
        {:error, "Invalid regular expression at position #{at}: #{reason}"}
    end
  end

  # A file named as the `path` is searched as asked, as ripgrep searches a file it is
  # given (Decision 776); a directory's files are those the glob and `.gitignore` leave.
  defp files(root, opts, ctx) do
    if File.regular?(root) do
      [root]
    else
      ignore = Gitignore.load(ctx.workspace.root_real)

      root
      |> Paths.glob_escape()
      |> Path.join(opts.glob || "**/*")
      |> Path.wildcard(match_dot: false)
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&Gitignore.ignored?(ignore, Workspace.relative(ctx.workspace, &1)))
      |> Enum.sort()
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

  # What a search found (Decision 777): the lines to show, how many lines matched in how
  # many files, and whether a file stopped at the cap, so that there may be more.
  defp found(all, shown, more?) do
    files = Enum.map(all, &file_of/1)
    %{lines: shown, total: length(all), files: files |> Enum.uniq() |> length(), more: more?}
  end

  # ripgrep stops each file at `--max-count`: a file that reached it may hold more.
  defp capped?(lines) do
    lines |> Enum.frequencies_by(&file_of/1) |> Enum.any?(fn {_file, n} -> n >= @max_matches end)
  end

  # `path:line:text`, the path possibly an absolute one with a drive.
  defp file_of(line) do
    case Regex.run(~r/\A((?:[A-Za-z]:)?[^:]*):\d+:/, line) do
      [_, path] -> path
      nil -> line
    end
  end

  # A glob that matched no file looks the same as a pattern that matched no line, so the
  # answer names the glob (Decision 776).
  defp render(%{lines: []}, _ctx, %{glob: glob}) when is_binary(glob),
    do: "No matches in files matching #{glob}."

  defp render(%{lines: []}, _ctx, _opts), do: "No matches."

  # The count first, where a cut result keeps it: a model asked how many lines match
  # counts them from the list by eye otherwise, and a long list it counts wrong.
  defp render(found, ctx, _opts) do
    (count(found) <> "\n" <> Enum.join(found.lines, "\n")) |> Output.cap(cap(ctx), ctx)
  end

  defp count(%{lines: lines, total: total, files: files, more: more?}) do
    matched = "#{plural(total, "matching line")} in #{plural(files, "file")}"

    cond do
      more? -> matched <> ", and more in a file that reached #{@max_matches}:"
      length(lines) < total -> matched <> "; the first #{length(lines)} follow:"
      true -> matched <> ":"
    end
  end

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"

  defp cap(%{config: nil}), do: %Config{}.tool_output_limit
  defp cap(%{config: config}), do: config.tool_output_limit
end
