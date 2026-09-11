defmodule Troupe.Workspace.Survey do
  @moduledoc """
  A cheap, language-agnostic orientation snapshot of a workspace: what kind of
  project it is and which files it holds.

  Built once per agent (see `Troupe.Agent.Server`) and rendered into the system
  prompt, so the first question starts with the layout already known instead of
  a round of discovery calls. Derived from disk on demand: never an event,
  never persisted, and never authoritative — `list_files` is.
  """

  alias Troupe.OS

  @type marker :: %{path: String.t(), label: String.t(), detail: String.t() | nil}

  @type t :: %__MODULE__{
          root: String.t(),
          vcs: :git | :none,
          branch: String.t() | nil,
          languages: [{String.t(), pos_integer()}],
          markers: [marker()],
          files: [String.t()],
          dirs: [{String.t(), pos_integer()}],
          total: non_neg_integer(),
          listing: :files | :dirs,
          capped: boolean()
        }

  defstruct root: ".",
            vcs: :none,
            branch: nil,
            languages: [],
            markers: [],
            files: [],
            dirs: [],
            total: 0,
            listing: :files,
            capped: false

  # Hard ceiling on how many paths we walk, so a huge tree cannot stall a turn.
  @max_walk 20_000
  # Characters the file/layout section may occupy; beyond it we summarize.
  @max_chars 4_000
  @max_languages 8
  @max_markers 8
  @max_dirs 40

  @pruned ~w(
    .git .hg .svn node_modules _build deps .elixir_ls target dist build out
    .venv venv __pycache__ .next .nuxt .svelte-kit vendor .gradle .idea .vscode
    .terraform burrito_out cover coverage .mypy_cache .pytest_cache .cache
    .tox .bundle Pods DerivedData bin obj
  )

  @languages %{
    ".ex" => "Elixir",
    ".exs" => "Elixir",
    ".erl" => "Erlang",
    ".hrl" => "Erlang",
    ".ts" => "TypeScript",
    ".tsx" => "TypeScript",
    ".js" => "JavaScript",
    ".jsx" => "JavaScript",
    ".mjs" => "JavaScript",
    ".cjs" => "JavaScript",
    ".vue" => "Vue",
    ".svelte" => "Svelte",
    ".py" => "Python",
    ".rb" => "Ruby",
    ".go" => "Go",
    ".rs" => "Rust",
    ".zig" => "Zig",
    ".c" => "C",
    ".h" => "C",
    ".cc" => "C++",
    ".cpp" => "C++",
    ".hpp" => "C++",
    ".java" => "Java",
    ".kt" => "Kotlin",
    ".swift" => "Swift",
    ".cs" => "C#",
    ".php" => "PHP",
    ".scala" => "Scala",
    ".hs" => "Haskell",
    ".lua" => "Lua",
    ".sh" => "Shell",
    ".bash" => "Shell",
    ".fish" => "Shell",
    ".ps1" => "PowerShell",
    ".sql" => "SQL",
    ".css" => "CSS",
    ".scss" => "CSS",
    ".html" => "HTML",
    ".heex" => "HEEx",
    ".md" => "Markdown",
    ".json" => "JSON",
    ".yaml" => "YAML",
    ".yml" => "YAML",
    ".toml" => "TOML"
  }

  # Project markers, matched on basename anywhere up to depth 2.
  @markers %{
    "mix.exs" => "Elixir/Mix",
    "rebar.config" => "Erlang/rebar3",
    "package.json" => "Node",
    "deno.json" => "Deno",
    "tsconfig.json" => "TypeScript",
    "go.mod" => "Go",
    "Cargo.toml" => "Rust",
    "build.zig" => "Zig",
    "pyproject.toml" => "Python",
    "setup.py" => "Python",
    "requirements.txt" => "Python",
    "Gemfile" => "Ruby",
    "composer.json" => "PHP",
    "pom.xml" => "Java/Maven",
    "build.gradle" => "Java/Gradle",
    "build.gradle.kts" => "Kotlin/Gradle",
    "CMakeLists.txt" => "C/C++ CMake",
    "Makefile" => "Make",
    "Dockerfile" => "Docker",
    "docker-compose.yml" => "Docker Compose",
    "flake.nix" => "Nix",
    "Package.swift" => "Swift"
  }

  @doc """
  Surveys `root`. Options: `:max_chars` (listing budget), `:git` (set false to
  skip git and walk the filesystem instead).
  """
  @spec build(String.t(), keyword()) :: t()
  def build(root, opts \\ []) when is_binary(root) do
    {vcs, files} =
      if Keyword.get(opts, :git, true) and File.exists?(Path.join(root, ".git")) do
        case git_files(root) do
          {:ok, list} -> {:git, list}
          :error -> {:none, walk(root)}
        end
      else
        {:none, walk(root)}
      end

    files = Enum.sort(files)
    total = length(files)

    survey = %__MODULE__{
      root: root,
      vcs: vcs,
      branch: if(vcs == :git, do: git_branch(root)),
      languages: languages(files),
      markers: markers(root, files),
      files: files,
      dirs: dirs(files),
      total: total,
      capped: total >= @max_walk
    }

    %__MODULE__{survey | listing: listing(survey, Keyword.get(opts, :max_chars, @max_chars))}
  end

  @doc "Renders the survey as a system-prompt section. Empty string when there is nothing to say."
  @spec render(t()) :: String.t()
  def render(%__MODULE__{total: 0}), do: ""

  def render(%__MODULE__{} = s) do
    [
      "\n\n# Workspace",
      "Project: #{project_line(s)}",
      if(s.languages == [], do: nil, else: "Languages: #{languages_line(s)}"),
      "\n" <> listing_section(s)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  ## Collection

  defp git_files(root) do
    args = ["ls-files", "--cached", "--others", "--exclude-standard"]

    case OS.Process.run("git", args, cd: root, timeout_ms: 10_000, max_output: 2_000_000) do
      {:ok, out, 0} ->
        # `--others` reports an opaque directory (nested repo or worktree) as one
        # entry with a trailing slash; those are not files.
        files =
          out
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.ends_with?(&1, "/"))
          |> Enum.take(@max_walk)

        {:ok, files}

      _ ->
        :error
    end
  end

  defp git_branch(root) do
    case OS.Process.run("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: root,
           timeout_ms: 10_000,
           max_output: 200
         ) do
      {:ok, out, 0} -> out |> String.trim() |> presence()
      _ -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(s), do: s

  # Depth-first walk with pruning and a hard cap, used when the workspace is not a git repo.
  defp walk(root) do
    {_count, files} = walk(root, "", {0, []})
    files
  end

  defp walk(root, rel, acc) do
    case File.ls(Path.join(root, rel)) do
      {:ok, entries} -> Enum.reduce(Enum.sort(entries), acc, &visit(root, rel, &1, &2))
      {:error, _} -> acc
    end
  end

  defp visit(_root, _rel, _name, {count, _files} = acc) when count >= @max_walk, do: acc

  defp visit(root, rel, name, {count, files} = acc) do
    child = if rel == "", do: name, else: rel <> "/" <> name

    cond do
      name in @pruned -> acc
      File.dir?(Path.join(root, child)) -> walk(root, child, acc)
      true -> {count + 1, [child | files]}
    end
  end

  ## Derivation

  defp languages(files) do
    files
    |> Enum.reduce(%{}, fn path, acc ->
      case Map.fetch(@languages, path |> Path.extname() |> String.downcase()) do
        {:ok, lang} -> Map.update(acc, lang, 1, &(&1 + 1))
        :error -> acc
      end
    end)
    |> Enum.sort_by(fn {lang, count} -> {-count, lang} end)
    |> Enum.take(@max_languages)
  end

  defp markers(root, files) do
    files
    |> Enum.filter(fn path ->
      Map.has_key?(@markers, Path.basename(path)) and depth(path) <= 2
    end)
    |> Enum.sort_by(&{depth(&1), &1})
    |> Enum.take(@max_markers)
    |> Enum.map(fn path ->
      %{path: path, label: Map.fetch!(@markers, Path.basename(path)), detail: detail(root, path)}
    end)
  end

  defp depth(path), do: path |> Path.split() |> length()

  # Cheap name extraction for the ecosystems where it is a one-line regex.
  defp detail(root, path) do
    pattern =
      case Path.basename(path) do
        "mix.exs" -> ~r/app:\s*:([a-zA-Z0-9_]+)/
        "package.json" -> ~r/"name"\s*:\s*"([^"]+)"/
        "go.mod" -> ~r/^module\s+(\S+)/m
        "Cargo.toml" -> ~r/^\s*name\s*=\s*"([^"]+)"/m
        _ -> nil
      end

    with %Regex{} = re <- pattern,
         {:ok, content} <- File.read(Path.join(root, path)),
         [_, name] <- Regex.run(re, content) do
      name
    else
      _ -> nil
    end
  end

  defp dirs(files) do
    files
    |> Enum.reduce(%{}, fn path, acc ->
      Map.update(acc, Path.dirname(path), 1, &(&1 + 1))
    end)
    |> Enum.sort_by(fn {dir, count} -> {-count, dir} end)
    |> Enum.take(@max_dirs)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp listing(%__MODULE__{files: files}, max_chars) do
    size = Enum.reduce(files, 0, fn f, acc -> acc + byte_size(f) + 1 end)
    if size <= max_chars, do: :files, else: :dirs
  end

  ## Rendering

  defp project_line(%__MODULE__{} = s) do
    vcs = if s.vcs == :git, do: "git#{branch_suffix(s.branch)}", else: "no vcs"

    case s.markers do
      [] -> "#{s.root} (#{vcs})"
      markers -> "#{s.root} (#{vcs}) — #{Enum.map_join(markers, ", ", &marker_text/1)}"
    end
  end

  defp branch_suffix(nil), do: ""
  defp branch_suffix(branch), do: " on #{branch}"

  defp marker_text(%{path: path, label: label, detail: nil}), do: "#{path} (#{label})"
  defp marker_text(%{path: path, label: label, detail: name}), do: "#{path} (#{label}: #{name})"

  defp languages_line(%__MODULE__{languages: languages}) do
    Enum.map_join(languages, ", ", fn {lang, count} -> "#{lang} #{count}" end)
  end

  defp listing_section(%__MODULE__{listing: :files} = s) do
    "## Files (#{count_text(s)})\n" <> Enum.join(s.files, "\n")
  end

  defp listing_section(%__MODULE__{listing: :dirs} = s) do
    body = Enum.map_join(s.dirs, "\n", fn {dir, count} -> "#{dir}/ — #{count}" end)

    """
    ## Layout (#{count_text(s)}; too many to list, largest directories by file count)
    #{body}

    Use `list_files` or `grep` to see individual files.\
    """
  end

  defp count_text(%__MODULE__{total: total, capped: true}), do: "#{total}+ files"
  defp count_text(%__MODULE__{total: total}), do: "#{total} files"
end
