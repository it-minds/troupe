defmodule Troupe.Onboard do
  @moduledoc """
  Onboarding (issue #516, Decision 823): other tools' files brought into Troupe's own,
  once, through one writer that reaches two places and records where each file came from.

  - **Two roots, Troupe's kinds of file.** A proposal (`Troupe.Onboard.Source`) writes
    under the workspace's `.troupe/` (`:repo`) or the person's config directory (`:user`),
    and only what Troupe reads there: `agents/<name>.md`, `commands/<name>.md`,
    `skills/<name>/...`, `workflows/<name>.json`, `mcp.json`, and the person's own
    `AGENTS.md`. The file is judged where it really is, links followed (Decision 798's
    edge, #512's rule for what Troupe writes): one that resolves outside its root, through
    a linked `.troupe` or `agents`, is refused, as is a path with `..`, an absolute one,
    and one naming any other file (`config.yaml`, which has a writer of its own, the
    credentials, the brief). A repository's file is onboarded into the repository and the
    person's own, under `~/`, into their config directory, never one into the other.
  - **Provenance.** Every file written says where it came from: `imported_from`,
    `imported_hash` (the lowercase hex sha256 of the source's bytes) and `imported_at`, and
    `imported_also` for the other files it was made from (`also_from`: an agent's
    permissions in a settings file, say), in a Markdown file's frontmatter; for any other
    file, and for `AGENTS.md`, which is read into a prompt as it is, in `onboarded.json`
    at the root, keyed by the file's path.
  - **Nothing silent.** `plan/2` asks the registered sources and passes over what was
    onboarded from the same source with the same hash (the person's later edits stand) and
    what the person declined for that hash; everything else is a proposal with its diff
    against what is there. `accept/3` writes one, atomically, and refuses when the file
    changed since it was shown; `decline/2` remembers a no in the state directory, so the
    next run does not ask again until the source changes. A declined proposal leaves
    nothing in either root.
  - **Drift.** `drift/2` reads the provenance back and names each file whose source, or
    one of the files it was also made from, has changed or gone since: what `troupe
    instructions check` reports.
  - **Skipped.** A source that exports `skipped/2` says which of the other tool's files it
    found and proposed nothing for, and why; `plan/2` passes them on for the person.

  No process: each write is a function over a path, serialised by a VM-wide transaction on
  it, as the brief's are (Decision 649).
  """

  alias Troupe.Config.Migrate
  alias Troupe.Onboard.{Pod, Source}
  alias Troupe.{Paths, Workspace}
  alias Troupe.Protocol.AgentDefinition

  # The sources `troupe onboard` asks, in this order. A source registers itself here, one
  # line.
  @sources [Troupe.Onboard.AgentsAndCommands]

  # Where a file other than frontmatter Markdown records its provenance, at each root.
  @manifest "onboarded.json"

  # The person's answers, in the state directory: never in a root.
  @declined "onboard.json"

  @keys ~w(imported_from imported_hash imported_at)

  @type target :: :repo | :user

  @typedoc "A proposal checked against its root, as `troupe onboard` shows it."
  @type item :: %{
          proposal: Source.proposal(),
          file: Path.t(),
          real: Path.t(),
          shown: String.t(),
          status: :new | :changed,
          current: binary() | nil,
          content: binary(),
          diff: String.t(),
          at: String.t(),
          was: String.t() | nil
        }

  @typedoc "A proposal that cannot be written, and why, in a sentence."
  @type refusal :: %{
          target: term(),
          path: term(),
          source: term(),
          reason: String.t()
        }

  @type plan :: %{
          workspace: Path.t(),
          sources: [module()],
          proposals: [item()],
          refused: [refusal()],
          skipped: [%{source: String.t(), reason: String.t()}],
          unchanged: non_neg_integer(),
          declined: non_neg_integer()
        }

  @doc """
  The registered sources: `@sources`, or the `:onboard_sources` application setting,
  which a test (or a script driving a build) sets and no config file reaches.
  """
  @spec sources() :: [module()]
  def sources, do: Application.get_env(:troupe_core, :onboard_sources, @sources)

  @doc """
  What onboarding would write in `workspace`: each registered source's proposals, checked
  against their roots. A proposal whose file was onboarded from the same source with the
  same hash is `unchanged` and one the person declined for that hash is `declined`, both
  only counted; `all: true` offers the declined again. `skipped` is what the sources found
  and proposed nothing for, each with its reason. Where `Troupe.Onboard.Pod` refuses (a
  pod, Decision 826; `session_id:` names the session asking) the plan is that one refusal
  and no source is asked. Options, each for a test: `sources`,
  `config_dir`, `home`, `state_dir` and `now` (the `imported_at` written).
  """
  @spec plan(Path.t(), keyword()) :: plan()
  def plan(workspace, opts \\ []) do
    case Pod.refusal(Keyword.get(opts, :session_id)) do
      nil -> plan_here(workspace, opts)
      reason -> refused_here(workspace, reason)
    end
  end

  # On a pod onboarding doesn't run at all (Decision 826): one refusal, no source asked.
  defp refused_here(workspace, reason) do
    %{
      workspace: Path.expand(workspace),
      sources: [],
      proposals: [],
      refused: [%{target: nil, path: nil, source: nil, reason: reason}],
      skipped: [],
      unchanged: 0,
      declined: 0
    }
  end

  defp plan_here(workspace, opts) do
    workspace = Path.expand(workspace)
    opts = defaults(opts)
    sources = Keyword.get(opts, :sources) || sources()
    declined = if opts[:all], do: %{}, else: declined(opts)

    results =
      for source <- sources,
          result <- propose(source, workspace, opts) ++ skipped(source, workspace, opts) do
        with {:ok, proposal} <- result, do: classify(proposal, workspace, declined, opts)
      end

    %{
      workspace: workspace,
      sources: sources,
      proposals: for({:proposal, item} <- results, do: item),
      refused: for({:refused, refusal} <- results, do: refusal),
      skipped: for({:skipped, skipped} <- results, do: skipped),
      unchanged: Enum.count(results, &match?({:unchanged, _}, &1)),
      declined: Enum.count(results, &match?({:declined, _}, &1))
    }
  end

  @doc """
  Writes a proposal `plan/2` showed, exactly as it was shown: the same `imported_at`, and
  not over a file that changed since.
  """
  @spec accept(item(), Path.t(), keyword()) ::
          {:ok, %{file: Path.t(), shown: String.t(), action: :created | :replaced}}
          | {:error, String.t()}
  def accept(item, workspace, opts \\ []) do
    write(item.proposal, workspace, Keyword.merge(opts, now: item.at, expect: item.current))
  end

  @doc """
  Remembers that the person said no to a proposal `plan/2` showed, in the state directory,
  so the next plan does not offer it again until its source changes. Nothing is written
  where the proposal would have gone.
  """
  @spec decline(item(), keyword()) :: :ok | {:error, String.t()}
  def decline(item, opts \\ []) do
    file = declined_file(opts)

    :global.trans({{__MODULE__, file}, self()}, fn ->
      map = read_json(file)

      declined =
        map |> Map.get("declined", %{}) |> Map.put(key(item.real), fingerprint(item.proposal))

      write_json(file, Map.put(map, "declined", declined))
    end)
  end

  @doc """
  Writes one proposal, with its provenance: checked again against its root, written to a
  temporary file beside it and renamed over it, so a crash leaves the old file or the new,
  never half of one. `expect:` is what the file held when it was shown, `nil` for nothing:
  a file that changed since is not overwritten. `now:` is the `imported_at`. Answers the
  file and whether it was `:created` or `:replaced`, or a sentence saying why not.
  """
  @spec write(Source.proposal(), Path.t(), keyword()) ::
          {:ok, %{file: Path.t(), shown: String.t(), action: :created | :replaced}}
          | {:error, String.t()}
  def write(proposal, workspace, opts \\ []) do
    workspace = Path.expand(workspace)
    opts = defaults(opts)

    with {:ok, place} <- check(proposal, workspace, opts) do
      :global.trans({{__MODULE__, key(place.real)}, self()}, fn ->
        write_at(place, proposal, opts)
      end)
    end
  end

  defp write_at(place, proposal, opts) do
    current = read(place.real)

    with :ok <- as_shown(current, place, opts),
         :ok <- replace(place.real, render(proposal, place, opts[:now])),
         :ok <- manifest(proposal, place, opts[:now]) do
      action = if current, do: :replaced, else: :created
      {:ok, %{file: place.file, shown: place.shown, action: action}}
    end
  end

  @doc """
  Whether a proposal may be written, and where: `{:ok, place}`, or `{:error, sentence}`
  saying why not. The sentences are the tool's refusals too.
  """
  @spec check(Source.proposal(), Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def check(proposal, workspace, opts \\ []) do
    opts = defaults(opts)

    with :ok <- shape(proposal),
         :ok <- check_path(proposal.target, proposal.path),
         {:ok, place} <- place(proposal.target, proposal.path, workspace, opts),
         :ok <- same_hashes(proposal, workspace, opts) do
      {:ok, place}
    end
  end

  @doc """
  The lowercase hex sha256 of a source file's bytes, the file found as a proposal names
  it: relative to the workspace, and really inside it, for `:repo`; starting `~/`, and
  really inside the home directory, for `:user`.
  """
  @spec hash_source(target(), String.t(), Path.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def hash_source(target, source, workspace, opts \\ []) do
    opts = defaults(opts)

    with {:ok, file} <- source_file(target, source, Path.expand(workspace), opts) do
      case File.read(file) do
        {:ok, bytes} -> {:ok, sha256(bytes)}
        {:error, :enoent} -> {:error, "`#{source}` is not there"}
        {:error, reason} -> {:error, "cannot read `#{source}`: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc """
  The files onboarding wrote, under the workspace's `.troupe/` and the person's config
  directory, with their recorded provenance (`files`), and a `drift` finding for each source
  or other file it was made from that has changed or gone since (`findings`, on the line
  of `imported_hash` or `imported_also`), in `troupe instructions check`'s shape. A
  record naming a source where none may be (a repository's file pointing outside the
  workspace) is passed over, as is a `.troupe` that links out.
  """
  @spec drift(Path.t(), keyword()) :: %{files: [map()], findings: [map()]}
  def drift(workspace, opts \\ []) do
    workspace = Path.expand(workspace)
    opts = defaults(opts)
    records = Enum.flat_map([:repo, :user], &records(&1, workspace, opts))

    findings =
      for record <- records, {line, message} <- drifted(record, workspace, opts) do
        %{path: record.file, line: line, kind: :drift, message: message}
      end

    %{files: records, findings: findings}
  end

  @doc "A line diff of what a file holds and what onboarding would write; all `+` for a new one."
  @spec diff(binary() | nil, binary()) :: String.t()
  def diff(nil, new),
    do: new |> String.trim_trailing() |> String.split("\n") |> Enum.map_join("\n", &("+ " <> &1))

  def diff(old, new), do: Migrate.diff(String.replace(old, "\r\n", "\n"), new)

  ## Planning

  defp propose(source, workspace, opts) do
    case source.proposals(workspace, home: opts[:home]) do
      list when is_list(list) ->
        Enum.map(list, fn
          proposal when is_map(proposal) -> {:ok, proposal}
          other -> {:refused, refusal(%{}, "#{inspect(source)} proposed #{inspect(other)}")}
        end)

      other ->
        [{:refused, refusal(%{}, "#{inspect(source)} answered #{inspect(other)}, not proposals")}]
    end
  rescue
    error -> [{:refused, refusal(%{}, "#{inspect(source)} failed: #{Exception.message(error)}")}]
  end

  # What a source found and proposed nothing for, when it says (an optional callback).
  defp skipped(source, workspace, opts) do
    if Code.ensure_loaded?(source) and function_exported?(source, :skipped, 2),
      do: Enum.map(source.skipped(workspace, home: opts[:home]), &skipped_entry(source, &1)),
      else: []
  rescue
    error -> [{:refused, refusal(%{}, "#{inspect(source)} failed: #{Exception.message(error)}")}]
  end

  defp skipped_entry(_source, %{source: from, reason: reason})
       when is_binary(from) and is_binary(reason),
       do: {:skipped, %{source: from, reason: reason}}

  defp skipped_entry(source, other),
    do: {:refused, refusal(%{}, "#{inspect(source)} skipped #{inspect(other)}")}

  defp classify(proposal, workspace, declined, opts) do
    case check(proposal, workspace, opts) do
      {:error, reason} ->
        {:refused, refusal(proposal, reason)}

      {:ok, place} ->
        current = read(place.real)
        was = recorded(current, place)

        cond do
          was != nil and fingerprint(was) == fingerprint(proposal) ->
            {:unchanged, place}

          Map.get(declined, key(place.real)) == fingerprint(proposal) ->
            {:declined, place}

          true ->
            {:proposal, item(proposal, place, current, was, opts[:now])}
        end
    end
  end

  # What a file was made from, as one list: its source and hash, then each other file's,
  # in order. The same for a proposal and for a record read back from a file, so two
  # compare equal exactly when nothing it was made from has changed.
  defp fingerprint(%{"imported_from" => from, "imported_hash" => hash} = record) do
    also = for %{"from" => f, "hash" => h} <- List.wrap(record["imported_also"]), do: {f, h}
    flatten(from, hash, also)
  end

  defp fingerprint(%{source: from, source_hash: hash} = proposal),
    do: flatten(from, hash, Enum.map(also(proposal), &{&1.source, &1.source_hash}))

  defp fingerprint(_record), do: nil

  defp flatten(from, hash, also),
    do: [from, hash | also |> Enum.sort() |> Enum.flat_map(&Tuple.to_list/1)]

  defp also(proposal), do: Map.get(proposal, :also_from, [])

  defp item(proposal, place, current, was, at) do
    content = render(proposal, place, at)

    %{
      proposal: proposal |> Map.put_new(:notes, []) |> Map.put_new(:also_from, []),
      file: place.file,
      real: place.real,
      shown: place.shown,
      status: if(current, do: :changed, else: :new),
      current: current,
      content: content,
      diff: diff(current, content),
      at: at,
      was: was && was["imported_from"]
    }
  end

  defp refusal(proposal, reason) do
    %{
      target: proposal[:target],
      path: proposal[:path],
      source: proposal[:source],
      reason: reason
    }
  end

  ## Checking

  defp shape(%{target: target} = p) when target in [:repo, :user] do
    cond do
      not Enum.all?([:path, :content, :source, :source_hash], &is_binary(p[&1])) ->
        shape(nil)

      not list_of?(Map.get(p, :notes, []), &is_binary/1) ->
        {:error, "its notes are not a list of sentences"}

      not sha256?(p.source_hash) ->
        {:error, "its source_hash is not a lowercase hex sha256"}

      not list_of?(Map.get(p, :also_from, []), &also?/1) ->
        {:error, "its also_from is not a list of sources, each with its source_hash"}

      true ->
        :ok
    end
  end

  defp shape(_proposal),
    do:
      {:error,
       "it is not a proposal: it needs a target (:repo or :user), a path, content, " <>
         "a source and a source_hash"}

  defp list_of?(list, fun), do: is_list(list) and Enum.all?(list, fun)

  defp also?(%{source: source, source_hash: hash}) when is_binary(source) and is_binary(hash),
    do: sha256?(hash)

  defp also?(_entry), do: false

  defp sha256?(hash), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

  @doc """
  Whether a path, relative to its root, names a file onboarding writes: one of the kinds
  Troupe reads there, with no `..`, no absolute start and no backslash. Where it really is
  is `check/3`'s question.
  """
  @spec check_path(target(), String.t()) :: :ok | {:error, String.t()}
  def check_path(target, path) do
    segments = String.split(path, "/")

    cond do
      problem = path_problem(path, segments) ->
        {:error, problem}

      ours?(target, segments) ->
        :ok

      true ->
        {:error,
         "`#{path}` is not a file onboarding writes: it writes agents/<name>.md, " <>
           "commands/<name>.md, skills/<name>/..., workflows/<name>.json and mcp.json" <>
           if(target == :user, do: ", and your own AGENTS.md", else: "")}
    end
  end

  defp path_problem(path, segments) do
    cond do
      path == "" ->
        "the path is empty"

      Workspace.absolute?(path) or String.starts_with?(path, "~") ->
        "`#{path}` is not relative: a path is relative to .troupe/ or to your config directory"

      String.contains?(path, "\\") ->
        "`#{path}` has a backslash: write it with /"

      Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        "`#{path}` has an empty, `.` or `..` part"

      # What git reads from a `.git` can run a command (Decision 833).
      Workspace.git_dir?(path) ->
        "`#{path}` is in a .git directory, which onboarding never writes"

      path =~ ~r/[\x00-\x1f:*?"<>|]/ ->
        "`#{path}` has a character a file name cannot have everywhere"

      true ->
        nil
    end
  end

  defp ours?(_target, ["agents", file]), do: named?(file, ".md")
  defp ours?(_target, ["commands", file]), do: named?(file, ".md")
  defp ours?(_target, ["workflows", file]), do: named?(file, ".json")
  # A skill's own files, one directory deep at most: as deep as `drift/2` looks.
  defp ours?(_target, ["skills", name, _file]), do: AgentDefinition.valid_name?(name)
  defp ours?(_target, ["skills", name, _dir, _file]), do: AgentDefinition.valid_name?(name)
  defp ours?(_target, ["mcp.json"]), do: true
  defp ours?(:user, ["AGENTS.md"]), do: true
  defp ours?(_target, _segments), do: false

  defp named?(file, ext),
    do: String.ends_with?(file, ext) and AgentDefinition.valid_name?(Path.basename(file, ext))

  # The file, where it really is, inside the root's real path: a `.troupe` (or an `agents`
  # in it) that is a link to elsewhere is not followed out.
  defp place(target, path, workspace, opts) do
    root = root(target, workspace, opts)
    file = Path.join(root, path)

    with {:ok, base} <- base(target, workspace, opts),
         {:ok, real} <- real(file),
         :ok <- under(real, base, path, target),
         :ok <- not_a_directory(real, path) do
      {:ok,
       %{
         target: target,
         path: path,
         root: root,
         base: base,
         file: file,
         real: real,
         shown: shown(target, path, opts)
       }}
    end
  end

  defp root(:repo, workspace, _opts), do: Paths.project_dir(workspace)
  defp root(:user, _workspace, opts), do: opts[:config_dir]

  # The root as it must really be: the workspace's own `.troupe`, not where a link would
  # take it; the config directory wherever the person keeps it.
  defp base(:repo, workspace, _opts) do
    with {:ok, real} <- real(workspace), do: {:ok, real <> "/.troupe"}
  end

  defp base(:user, _workspace, opts), do: real(opts[:config_dir])

  defp under(real, base, path, target) do
    if inside?(real, base),
      do: :ok,
      else:
        {:error,
         "`#{path}` resolves to #{Paths.display(real)}, outside #{root_name(target)}: " <>
           "onboarding writes only there"}
  end

  defp not_a_directory(real, path) do
    if File.dir?(real), do: {:error, "`#{path}` is a directory"}, else: :ok
  end

  defp root_name(:repo), do: "the workspace's .troupe/"
  defp root_name(:user), do: "your config directory"

  defp shown(:repo, path, _opts), do: ".troupe/" <> path
  defp shown(:user, path, opts), do: Paths.display(Path.join(opts[:config_dir], path))

  # The source, and each file it was also made from, is where it may be and holds what the
  # proposal says it does.
  defp same_hashes(proposal, workspace, opts) do
    [%{source: proposal.source, source_hash: proposal.source_hash} | also(proposal)]
    |> Enum.reduce_while(:ok, fn %{source: source, source_hash: expected}, :ok ->
      case hash_source(proposal.target, source, workspace, opts) do
        {:ok, ^expected} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt, {:error, "its hash of `#{source}` is not that file's sha256 as it is now"}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # A repository's file becomes a repository's, and the person's own, under `~/`, their
  # own: never one into the other, so a clone cannot write the person's config directory.
  defp source_file(:repo, source, workspace, _opts) do
    cond do
      String.starts_with?(source, "~") ->
        {:error,
         "`#{source}` is in your home directory: a file written into the repository's " <>
           ".troupe/ comes from the repository"}

      Workspace.absolute?(source) ->
        {:error, "`#{source}` is not relative to the workspace"}

      true ->
        confined(Path.join(workspace, source), workspace, source, "the workspace")
    end
  end

  defp source_file(:user, "~/" <> rest = source, _workspace, opts),
    do: confined(Path.join(opts[:home], rest), opts[:home], source, "your home directory")

  defp source_file(:user, source, _workspace, _opts),
    do:
      {:error,
       "`#{source}` does not start with ~/: a file written into your config directory " <>
         "comes from your home directory"}

  defp confined(file, edge, source, where) do
    with {:ok, real} <- real(file),
         {:ok, edge} <- real(edge) do
      if inside?(real, edge), do: {:ok, real}, else: {:error, "`#{source}` is outside #{where}"}
    end
  end

  ## Writing

  # The proposal's content as written: with its provenance in the frontmatter, for a
  # Markdown file read as frontmatter and body; as it is, for the rest.
  defp render(proposal, place, at) do
    if frontmatter?(place.path),
      do: with_provenance(proposal.content, provenance(proposal, at)),
      else: proposal.content
  end

  # `imported_also` only when the file was made from more than its source, each other file
  # by its path and hash, in path order.
  defp provenance(proposal, at) do
    also =
      proposal
      |> also()
      |> Enum.sort_by(& &1.source)
      |> Enum.map(&%{"from" => &1.source, "hash" => &1.source_hash})

    %{
      "imported_from" => proposal.source,
      "imported_hash" => proposal.source_hash,
      "imported_at" => at
    }
    |> then(&if also == [], do: &1, else: Map.put(&1, "imported_also", also))
  end

  # Each key on a line of its own, its value as JSON, which YAML reads as it is: a quoted
  # string, or `imported_also`'s list of `{"from", "hash"}`.
  defp with_provenance(content, provenance) do
    lines =
      for key <- @keys ++ ["imported_also"], Map.has_key?(provenance, key), into: "" do
        "#{key}: #{Jason.encode!(provenance[key])}\n"
      end

    case frontmatter(content) do
      {:ok, yaml, body} -> "---\n" <> strip(yaml) <> lines <> "---\n" <> body
      :none -> "---\n" <> lines <> "---\n" <> content
    end
  end

  defp strip(yaml),
    do: Regex.replace(~r/^imported_(?:from|hash|at|also):[^\n]*(?:\n|\z)/m, yaml, "")

  defp frontmatter(text) do
    case Regex.run(~r/\A---\r?\n(.*?)^---[ \t]*(?:\r?\n|\z)/ms, text) do
      [whole, yaml] ->
        {:ok, yaml, binary_part(text, byte_size(whole), byte_size(text) - byte_size(whole))}

      nil ->
        :none
    end
  end

  # `AGENTS.md` is read into a prompt whole, frontmatter and all, so it records in the
  # manifest; every other Markdown file Troupe reads takes its keys from a frontmatter.
  defp frontmatter?(path), do: String.ends_with?(path, ".md") and path != "AGENTS.md"

  defp as_shown(current, place, opts) do
    if Keyword.has_key?(opts, :expect) and opts[:expect] != current,
      do:
        {:error,
         "#{place.shown} changed since it was shown; run troupe onboard again to see it as it is"},
      else: :ok
  end

  defp replace(file, content) do
    tmp = file <> ".onboard-#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, "cannot write #{Paths.display(file)}: #{:file.format_error(reason)}"}
    end
  end

  # The provenance of a file that keeps none of its own, beside it at the root: written
  # after the file, so a failure between the two leaves a file with no record (proposed
  # again, never taken for unchanged) rather than a record of a file not written.
  defp manifest(proposal, place, at) do
    with false <- frontmatter?(place.path),
         {:ok, real} <- real(Path.join(place.base, @manifest)),
         :ok <- under(real, place.base, @manifest, place.target) do
      entry = provenance(proposal, at)

      :global.trans({{__MODULE__, key(real)}, self()}, fn ->
        put_manifest(real, place.path, entry)
      end)
    else
      true -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_manifest(manifest, path, entry) do
    files = manifest |> read_json() |> Map.get("files", %{}) |> Map.put(path, entry)
    object = Jason.OrderedObject.new(Enum.sort(files))
    replace(manifest, Jason.encode!(%{"version" => 1, "files" => object}, pretty: true) <> "\n")
  end

  ## Reading back

  defp recorded(nil, _place), do: nil

  defp recorded(current, place) do
    if frontmatter?(place.path),
      do: frontmatter_provenance(current),
      else: place.base |> Path.join(@manifest) |> read_json() |> get_in(["files", place.path])
  end

  defp frontmatter_provenance(text) do
    with {:ok, yaml, _body} <- frontmatter(text),
         {:ok, %{"imported_hash" => hash} = map} when is_binary(hash) <-
           YamlElixir.read_from_string(yaml) do
      map
      |> Map.take(@keys)
      |> Map.new(fn {k, v} -> {k, to_string(v)} end)
      |> Map.put("imported_also", also_read(map["imported_also"]))
    else
      _ -> nil
    end
  end

  # The other files a record names, as `{"from", "hash"}` maps; anything else in the key
  # is not a record of one.
  defp also_read(list) when is_list(list) do
    for %{"from" => from, "hash" => hash} <- list,
        is_binary(from) and is_binary(hash),
        do: %{"from" => from, "hash" => hash}
  end

  defp also_read(_none), do: []

  defp records(target, workspace, opts) do
    root = root(target, workspace, opts)

    with {:ok, base} <- base(target, workspace, opts),
         {:ok, real} <- real(root),
         true <- key(real) == key(base) and File.dir?(base) do
      (Enum.flat_map(~w(agents commands skills), &markdown_entry(base, "", &1, 0)) ++
         manifest_records(base))
      |> Enum.map(&Map.merge(&1, %{target: target, shown: shown(target, &1.path, opts)}))
      |> Enum.sort_by(& &1.path)
    else
      _ -> []
    end
  end

  # Frontmatter Markdown in the directories onboarding writes it to, three levels down at
  # most (`skills/<name>/<dir>/<file>`), links not followed.
  defp markdown_records(dir, rel, depth) when depth < 4 do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.sort() |> Enum.flat_map(&markdown_entry(dir, rel, &1, depth))
      {:error, _reason} -> []
    end
  end

  defp markdown_records(_dir, _rel, _depth), do: []

  defp markdown_entry(dir, rel, name, depth) do
    file = Path.join(dir, name)
    rel = if rel == "", do: name, else: rel <> "/" <> name

    case File.lstat(file) do
      {:ok, %File.Stat{type: :directory}} ->
        markdown_records(file, rel, depth + 1)

      {:ok, %File.Stat{type: :regular}} ->
        if frontmatter?(rel), do: markdown_record(file, rel), else: []

      _other ->
        []
    end
  end

  defp markdown_record(file, rel) do
    with {:ok, text} <- File.read(file),
         %{"imported_from" => from, "imported_hash" => hash} = record <-
           frontmatter_provenance(text) do
      [
        %{
          path: rel,
          file: file,
          from: from,
          hash: hash,
          also: record["imported_also"],
          line: line_of(text, "imported_hash:"),
          also_line: line_of(text, "imported_also:")
        }
      ]
    else
      _ -> []
    end
  end

  defp manifest_records(base) do
    for {rel, %{"imported_from" => from, "imported_hash" => hash} = record} <-
          base |> Path.join(@manifest) |> read_json() |> Map.get("files", %{}),
        is_binary(from) and is_binary(hash),
        file = Path.join(base, rel),
        File.regular?(file),
        do: %{
          path: rel,
          file: file,
          from: from,
          hash: hash,
          also: also_read(record["imported_also"]),
          line: 1,
          also_line: 1
        }
  end

  defp line_of(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.find_index(&String.starts_with?(&1, prefix))
    |> case do
      nil -> 1
      index -> index + 1
    end
  end

  # `{line, message}` for the source and for each other file the record names, when it has
  # changed or gone; one that is not where it may be is not read.
  defp drifted(record, workspace, opts) do
    main = {record.from, record.hash, record.line, "imported from"}

    others =
      for %{"from" => f, "hash" => h} <- record.also,
          do: {f, h, record.also_line, "imported with"}

    for {from, hash, line, how} <- [main | others],
        message <- changed(record.target, from, hash, workspace, opts),
        do: {line, "#{how} `#{from}`, which #{message}"}
  end

  defp changed(target, from, hash, workspace, opts) do
    case source_file(target, from, workspace, opts) do
      {:ok, file} -> file |> File.read() |> compared(hash)
      {:error, _outside} -> []
    end
  end

  defp compared({:ok, bytes}, hash) do
    if sha256(bytes) == hash,
      do: [],
      else: ["has changed since; `troupe onboard` shows what changed"]
  end

  defp compared({:error, :enoent}, _hash), do: ["is not there any more"]
  defp compared({:error, _reason}, _hash), do: []

  ## Files

  defp declined(opts), do: opts |> declined_file() |> read_json() |> Map.get("declined", %{})

  defp declined_file(opts), do: Path.join(Paths.state_dir(opts[:state_dir]), @declined)

  defp read(file) do
    case File.read(file) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  defp read_json(file) do
    with {:ok, text} <- File.read(file),
         {:ok, map} when is_map(map) <- Jason.decode(text) do
      map
    else
      _ -> %{}
    end
  end

  defp write_json(file, map), do: replace(file, Jason.encode!(map, pretty: true) <> "\n")

  defp real(path) do
    case Workspace.real_path(path) do
      {:ok, real} -> {:ok, real}
      {:error, reason} -> {:error, "cannot resolve #{Paths.display(path)}: #{inspect(reason)}"}
    end
  end

  defp inside?(path, base) do
    path = key(path)
    base = key(base)
    String.starts_with?(path, base <> "/") and path != base
  end

  defp key(path), do: Workspace.compare_key(path)

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp defaults(opts) do
    opts
    |> Keyword.put_new_lazy(:config_dir, &Paths.config_dir/0)
    |> Keyword.put_new_lazy(:home, &System.user_home!/0)
    |> Keyword.put_new_lazy(:now, fn ->
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end)
  end
end
