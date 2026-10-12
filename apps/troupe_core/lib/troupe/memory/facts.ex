defmodule Troupe.Memory.Facts do
  @moduledoc """
  A repository's memory as facts (#248, Decision 838): `.troupe/memory/facts.jsonl`, one
  fact per line, in the checkout whose `.troupe/memory.md` holds the brief (Decision 831's
  rule, `Troupe.Session.Memory.locate/1`).

  A fact is a record, string keys as the protocol carries it: `id`, `kind` (`command`,
  `convention`, `overview`, `layout`, `note` or `negative`), `claim`, `scope` (a glob, or
  null), `anchors` (`path`, from the repository's top, and `hash`, the lowercase hex
  sha256 of the file's bytes when the fact was written, computed here and never taken
  from a model), `evidence` (`session`, `seq`, `head`, `exit_status` when a command
  proved it, and `by`: `librarian`, `agent:<name>`, `person` or `migrated`),
  `created_at` and `verified_at`.

  - **Status is computed when read, never stored** (`status/2`): `current` while every
    anchor's file hashes as it did, `moved` once one changed, `missing` once one is gone,
    `unanchored` with none. Nothing here deletes a fact for it: a moved fact is evidence
    that something changed, not that the fact is wrong, and the librarian re-checks it.
    A file's hash is kept beside its size and mtime and asked for again only when either
    changed (or in the second it was hashed), so a prompt stats a fact's anchors and
    hashes only the files that changed; the repository is never walked.
  - **One process per store** (`Troupe.Memory.Facts.Store`), started on first use under
    `Troupe.Memory.Facts.Stores`, is the file's only writer and holds the facts in ETS,
    which the callers here read without asking it. A file someone else wrote since (a
    pull, another daemon, a person) is read again before anything is answered or written.
  - **An anchor is a file in the workspace**: a path outside it, through `..` or a link,
    one into `.git`, the memory's own files, a directory and a file over 10 MiB are each
    refused with a sentence, and in a git repository so is a file git does not track (an
    ignored `.env`), whose hash should not reach a `facts.jsonl` that may be committed
    (Decision 839). On Windows a path typed in another case than the committed name is
    that file, and is stored by the committed name. An anchor read back from the file is
    held to the workspace, `.git`, the memory's own files and, in a repository, what git
    tracks before it is hashed, so a repository's `facts.jsonl` cannot have Troupe read
    elsewhere or hash a file it would not have written (Decision 854): such an anchor is
    `missing`. What git tracks is asked once for every anchor a read has not asked about
    since the index last changed, and kept beside the hashes by the index's size and
    mtime, so a prompt makes no git call while the index stands still.
  - **A scope is a glob** of paths from the repository's top, one word: not a sentence,
    not absolute, not through `..`, its braces closed.
  """

  alias Troupe.Git
  alias Troupe.Memory
  alias Troupe.Memory.Facts.Store
  alias Troupe.Session.Memory, as: Brief
  alias Troupe.Workspace

  require Logger

  @type fact :: Memory.fact()
  @type where :: %{root: Path.t(), top: Path.t()}

  @kind_order ~w(overview layout command convention negative note)
  @max_anchors 8
  @max_anchor_bytes 10 * 1024 * 1024
  @max_claim 4_000
  @max_scope 200
  @recall_limit 20
  # How many paths one `git ls-files` is asked about, so a command line stays short.
  @tracked_batch 200

  @doc """
  Writes a fact and answers it as written, with its `status`. `attrs`: `kind`, `claim`,
  `anchors` (paths the agent read, from the workspace or absolute in it) and `scope`
  (optional), atom or string keys. `ctx`: `session`, `seq`, `by` (default `person`) and
  `exit_status` (optional). The hashes, `head`, the id and the times are worked out here.
  A fact of the same kind and claim as one kept is that one written again: its id and
  `created_at` stay, everything else is this call's.
  """
  @spec put(Path.t() | where(), map(), map() | keyword()) :: {:ok, fact()} | {:error, String.t()}
  def put(workspace, attrs, ctx \\ %{}) do
    attrs = stringify(attrs)
    ctx = Map.new(ctx)
    where = locate(workspace)
    from = from(workspace, where)

    with {:ok, kind} <- kind(attrs["kind"]),
         {:ok, claim} <- claim(attrs["claim"]),
         {:ok, scope} <- scope(attrs["scope"]),
         {:ok, paths} <- anchor_paths(attrs["anchors"]),
         {:ok, anchors} <- anchors(paths, from, where),
         {:ok, by} <- by(ctx[:by]) do
      now = now()

      fact = %{
        "id" => new_id(),
        "kind" => kind,
        "claim" => claim,
        "scope" => scope,
        "anchors" => anchors,
        "evidence" => evidence(ctx, by, from),
        "created_at" => now,
        "verified_at" => now
      }

      with {:ok, stored} <- call(where, {:put, fact}),
           do: {:ok, read(with_tracked(where, [stored]), stored)}
    end
  end

  @doc """
  Every fact kept, each with its `status`, in the order the view shows them (by kind, then
  oldest first). Filters: `kind`, `status`.
  """
  @spec list(Path.t() | where(), keyword()) :: [fact()]
  def list(workspace, filter \\ []) do
    where = loaded(workspace)
    facts = all(where)
    where = with_tracked(where, facts)

    facts
    |> Enum.map(&read(where, &1))
    |> Enum.filter(&keep?(&1, filter))
    |> Enum.sort_by(&order/1)
  end

  @doc """
  The facts that answer a question, each with its `status` and evidence, at most `limit`
  (default #{@recall_limit}): by `query`, words any of which the claim or scope holds
  (case aside); by `kind`; by `path`, a file or directory (from the workspace) a fact rests
  on or whose `scope` covers it; by `status`, as `status/2` has it (Decision 839: the
  librarian asks for the `moved` and `missing` ones). With none of them, every fact.
  Current and unanchored facts come before the ones that may no longer be true, then the
  ones that match more of the words, then the most recently checked.
  """
  @spec recall(Path.t() | where(), keyword()) :: [fact()]
  def recall(workspace, opts \\ []) do
    where = loaded(workspace)
    words = words(opts[:query])
    path = opts[:path] && relative_path(opts[:path], from(workspace, where), where.top)

    scored =
      where
      |> all()
      |> Enum.filter(&wanted?(&1, opts[:kind], path))
      |> Enum.map(&{&1, score(&1, words)})
      |> Enum.reject(fn {_fact, score} -> words != [] and score == 0 end)

    where = with_tracked(where, Enum.map(scored, &elem(&1, 0)))

    scored
    |> Enum.map(fn {fact, score} -> {read(where, fact), score} end)
    |> Enum.filter(fn {fact, _score} ->
      opts[:status] in [nil, ""] or fact["status"] == opts[:status]
    end)
    |> Enum.sort_by(fn {fact, score} ->
      {rank(fact["status"]), -score, desc(fact["verified_at"])}
    end)
    |> Enum.take(Keyword.get(opts, :limit, @recall_limit))
    |> Enum.map(&elem(&1, 0))
  end

  @doc "A fact's status now: `current`, `moved`, `missing` or `unanchored`."
  @spec status(Path.t() | where(), fact()) :: String.t()
  def status(workspace, fact),
    do: workspace |> loaded() |> with_tracked([fact]) |> check(fact) |> elem(0)

  @doc "Forgets one fact."
  @spec delete(Path.t() | where(), String.t()) :: :ok | {:error, String.t()}
  def delete(workspace, id), do: workspace |> locate() |> call({:delete, id})

  @doc """
  What a prompt carries (`Troupe.Memory.prompt/2`): the `command` and `convention` facts
  with their status, oldest first, each that is `moved` or `missing` saying which of its
  anchors `changed` and which are `gone` and when the newest of those went (`changed_at`,
  the file's mtime, or for a gone one its nearest directory's); and how many facts of
  every other kind there are, which `recall` answers.
  """
  @spec core(Path.t() | where()) :: Memory.core()
  def core(workspace) do
    where = loaded(workspace)
    {core, others} = where |> all() |> Enum.split_with(&(&1["kind"] in Memory.core_kinds()))
    where = with_tracked(where, core)

    %{
      facts:
        core
        |> Enum.sort_by(&order/1)
        |> Enum.map(&detail(where, &1)),
      others: Enum.frequencies_by(others, & &1["kind"])
    }
  end

  @doc "How many facts are kept."
  @spec count(Path.t() | where()) :: non_neg_integer()
  def count(workspace), do: workspace |> locate() |> all() |> length()

  @doc "The brief's own stamp, as the view's frontmatter records it: `built_at`, `head`, `survey`."
  @spec meta(Path.t() | where()) :: map()
  def meta(workspace), do: workspace |> locate() |> tables() |> Store.meta()

  @doc """
  Stamps the brief as checked now (Decision 696): `built_at`, `head` and the survey's
  version, and every unanchored fact's `verified_at`, since reading them is all a check of
  those can be. A moved or missing fact is left as it is: re-anchoring it is the
  librarian's to do. Nothing when there are no facts.
  """
  @spec stamp(Path.t() | where(), String.t() | nil) :: :ok | {:error, String.t()}
  def stamp(workspace, head), do: workspace |> locate() |> call({:stamp, head, now()})

  @doc "Forgets every fact, and the view with them."
  @spec clear(Path.t() | where()) :: :ok | {:error, String.t()}
  def clear(workspace), do: workspace |> locate() |> call(:clear)

  ## Where

  # A workspace's store and the top its anchors are read from; a location already worked
  # out is taken as it is, which saves a `git` call where the caller has made one.
  defp locate(%{root: _, top: _} = where), do: where
  defp locate(workspace), do: Brief.locate(workspace)

  defp from(%{top: top}, _where), do: top
  defp from(workspace, _where), do: Path.expand(workspace)

  # A location with its store's tables, asked for once for every fact a call reads.
  defp loaded(workspace) do
    where = locate(workspace)
    Map.put(where, :tables, Store.ensure(where))
  end

  defp tables(%{tables: tables}), do: tables
  defp tables(where), do: Store.ensure(where)

  defp all(where), do: where |> tables() |> Store.facts()

  defp call(where, message), do: where |> tables() |> Store.call(message)

  ## Status

  defp read(where, fact), do: Map.put(fact, "status", where |> check(fact) |> elem(0))

  defp detail(where, fact) do
    {status, changed, gone, at} = check(where, fact)

    fact
    |> Map.merge(%{"status" => status, "changed" => changed, "gone" => gone})
    |> Map.put("changed_at", at && DateTime.to_iso8601(at))
  end

  # The status, the anchors that changed and that are gone, and when the newest of those
  # went, as near as the files say.
  defp check(where, fact) do
    case List.wrap(fact["anchors"]) do
      [] ->
        {"unanchored", [], [], nil}

      anchors ->
        states = Enum.map(anchors, &anchor_state(&1, where))
        changed = for {path, :changed, _at} <- states, do: path
        gone = for {path, :gone, _at} <- states, do: path

        at =
          states
          |> Enum.map(&elem(&1, 2))
          |> Enum.reject(&is_nil/1)
          |> Enum.max(DateTime, fn -> nil end)

        status =
          cond do
            gone != [] -> "missing"
            changed != [] -> "moved"
            true -> "current"
          end

        {status, changed, gone, if(status == "current", do: nil, else: at)}
    end
  end

  # An anchor git does not track is not hashed: it is `missing` as of the file's own mtime,
  # so a brief built since does not count it again.
  defp anchor_state(%{"path" => path, "hash" => hash}, where)
       when is_binary(path) and is_binary(hash) do
    with {:ok, file} <- confined(path, where.top),
         {:tracked, true} <- {:tracked, tracked?(where, path)},
         {:ok, now, mtime} <- Store.hash(tables(where), file) do
      if now == hash, do: {path, :same, nil}, else: {path, :changed, mtime}
    else
      {:tracked, false} -> {path, :gone, mtime(Path.join(where.top, path))}
      _gone -> {path, :gone, went(Path.join(where.top, path), where.top)}
    end
  end

  defp anchor_state(anchor, _where), do: {inspect(anchor), :gone, nil}

  defp mtime(file) do
    case File.stat(file, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      {:error, _} -> nil
    end
  end

  # When a file went, as near as the files say: the mtime of the nearest directory still
  # there, which changed when the file (or the directory it was in) was removed.
  defp went(path, top) do
    dir = Path.dirname(path)

    case File.stat(dir, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      {:error, _} -> if dir == top or dir == path, do: nil, else: went(dir, top)
    end
  end

  ## Anchors

  defp anchor_paths(nil), do: {:ok, []}

  defp anchor_paths(paths) when is_list(paths) and length(paths) > @max_anchors,
    do: {:error, "at most #{@max_anchors} anchors: name the files the claim rests on"}

  defp anchor_paths(paths) when is_list(paths) do
    if Enum.all?(paths, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, paths |> Enum.map(&String.trim/1) |> Enum.uniq()},
      else: {:error, "anchors are paths of files, as strings"}
  end

  defp anchor_paths(_other), do: {:error, "anchors are a list of file paths"}

  # Each path resolved from the workspace, held to it, and hashed; stored from the top, by
  # the name git commits it under.
  defp anchors(paths, from, where) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case anchor(path, from, where) do
        {:ok, anchor} -> {:cont, {:ok, acc ++ [anchor]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, anchors} -> {:ok, Enum.uniq_by(anchors, & &1["path"])}
      error -> error
    end
  end

  defp anchor(path, from, where) do
    top = where.top

    with rel when is_binary(rel) <- relative_path(path, from, top) || {:error, outside(path)},
         :ok <- within(Path.expand(path, from), from, path),
         {:ok, file} <- confined(rel, top),
         {:ok, bytes} <- read_anchor(file, path),
         {:ok, name} <- tracked(where, rel) do
      {:ok, %{"path" => name, "hash" => sha256(bytes)}}
    end
  end

  # Only a file git tracks is an anchor (Decision 839): the hash of an ignored or untracked
  # file, a `.env`, would go into a `facts.jsonl` that may be committed, and a hash is an
  # oracle for what a file holds. Outside a repository nothing is committed, so nothing is
  # held back; inside one where git cannot answer, the anchor is refused rather than guessed.
  # The answer is the committed name, which on Windows may differ in case from the one typed.
  defp tracked(where, rel) do
    case where |> tracked_names([rel]) |> lookup(rel) do
      name when is_binary(name) ->
        {:ok, name}

      false ->
        {:error,
         "#{rel} is not a file git tracks (it is ignored or was never added): anchor a " <>
           "file the repository commits"}

      :unknown ->
        {:error, "git could not say whether it tracks #{rel}, so it is no anchor"}
    end
  end

  ## What git tracks

  # The facts' anchors that git tracks in the checkout or worktree they are read from, in
  # `where.tracked`, so a status hashes none it does not (Decision 854).
  defp with_tracked(where, facts) do
    paths =
      for fact <- facts,
          %{"path" => path} when is_binary(path) <- List.wrap(fact["anchors"]),
          uniq: true,
          do: path

    Map.put(where, :tracked, if(paths == [], do: %{}, else: tracked_names(where, paths)))
  end

  defp tracked?(%{tracked: tracked} = where, path) do
    case lookup(tracked, path) do
      nil -> where |> tracked_names([path]) |> lookup(path) |> is_binary()
      name -> is_binary(name)
    end
  end

  defp tracked?(where, path), do: where |> tracked_names([path]) |> lookup(path) |> is_binary()

  defp lookup(:all, path), do: path
  defp lookup(names, path), do: Map.get(names, path)

  # `:all` outside a repository, where nothing is held back; otherwise each path to the name
  # git commits it under, `false` for one it does not track, or `:unknown` when git could
  # not say. A path asked about since the index last changed is answered from the cache
  # beside the hashes; the rest are asked of git together, in one listing per batch.
  defp tracked_names(where, paths) do
    top = where.top

    if Brief.repository?(where) do
      tables = tables(where)
      top_key = Workspace.compare_key(top)
      at = System.os_time(:second)
      sig = index_sig(top)
      {known, ask} = Enum.split_with(paths, &(cached(tables, top_key, sig, &1) != nil))

      asked = ask_git(top, ask)
      if sig != :none, do: remember(tables, top_key, sig, at, asked)

      known
      |> Map.new(&{&1, cached(tables, top_key, sig, &1)})
      |> Map.merge(asked)
    else
      :all
    end
  end

  # The answer kept for a path against the index as it is now, or `nil`: never one taken in
  # the second the index was last written, which a later write in that second would not show.
  defp cached(_tables, _top_key, :none, _path), do: nil

  defp cached(tables, top_key, {_size, mtime} = sig, path) do
    case :ets.lookup(tables.hashes, {:tracked, top_key, path}) do
      [{_key, ^sig, at, name}] when mtime < at -> name
      _other -> nil
    end
  end

  defp remember(tables, top_key, sig, at, asked) do
    for {path, name} <- asked, name != :unknown do
      :ets.insert(tables.hashes, {{:tracked, top_key, path}, sig, at, name})
    end
  end

  defp ask_git(_top, []), do: %{}

  defp ask_git(top, paths) do
    paths
    |> Enum.chunk_every(@tracked_batch)
    |> Enum.map(&ask_batch(top, &1))
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  # Without case where the platform compares paths without it, so a name typed in another
  # case than the committed one is that file, answered by its committed name.
  defp ask_batch(top, paths) do
    magic = if Workspace.compare_key("A") == "a", do: ":(literal,icase)", else: ":(literal)"
    specs = Enum.map(paths, &(magic <> &1))

    case Git.run(top, ["ls-files", "--cached", "-z", "--" | specs], timeout_ms: 10_000) do
      {:ok, out, 0} ->
        listed = String.split(out, <<0>>, trim: true)
        Map.new(paths, &{&1, committed(&1, listed)})

      _other ->
        Map.new(paths, &{&1, :unknown})
    end
  end

  defp committed(path, listed) do
    if path in listed,
      do: path,
      else: Enum.find(listed, false, &(Workspace.compare_key(&1) == Workspace.compare_key(path)))
  end

  # The size and mtime of the index git lists tracked files from: the checkout's
  # `.git/index`, or the one a worktree's `.git` file names; `:none` when it cannot be found.
  defp index_sig(top) do
    dot_git = Path.join(top, ".git")

    index =
      case File.read(dot_git) do
        {:ok, "gitdir: " <> dir} -> Path.join(Path.expand(String.trim(dir), top), "index")
        {:ok, _other} -> nil
        {:error, _directory} -> Path.join(dot_git, "index")
      end

    with index when is_binary(index) <- index,
         {:ok, %{type: :regular, size: size, mtime: mtime}} <- File.stat(index, time: :posix) do
      {size, mtime}
    else
      _ -> :none
    end
  end

  # A path from the workspace (or absolute in it) as the repository's top has it, or nil;
  # compared as the platform compares paths, so a drive letter's case is no matter.
  defp relative_path(path, from, top) do
    expanded = path |> Path.expand(from) |> String.replace("\\", "/") |> String.trim_trailing("/")
    root = Workspace.compare_key(Path.expand(top))

    if String.starts_with?(Workspace.compare_key(expanded), root <> "/"),
      do: String.slice(expanded, (String.length(root) + 1)..-1//1),
      else: nil
  end

  defp within(expanded, from, path) do
    if under?(expanded, from), do: :ok, else: {:error, outside(path)}
  end

  # A stored path, held to the top: relative, not through `..`, not into `.git` or the
  # memory's own files, and, links followed, still under the top.
  defp confined(rel, top) do
    parts = String.split(rel, "/")

    cond do
      Path.type(rel) != :relative or ".." in parts or "" in parts ->
        {:error, outside(rel)}

      ".git" in parts ->
        {:error, "#{rel} is inside .git: anchor a file of the repository's own"}

      rel == ".troupe/memory.md" or List.starts_with?(parts, [".troupe", "memory"]) ->
        {:error, "#{rel} is the memory itself: anchor the file the claim is about"}

      true ->
        file = Path.join(top, rel)

        with {:ok, real} <- Workspace.real_path(file),
             {:ok, real_top} <- Workspace.real_path(top),
             true <- under?(real, real_top) do
          {:ok, real}
        else
          {:error, _} -> {:error, "#{rel} is not there"}
          false -> {:error, "#{rel} is a link to outside the workspace"}
        end
    end
  end

  defp read_anchor(file, path) do
    case File.stat(file) do
      {:ok, %{type: :regular, size: size}} when size > @max_anchor_bytes ->
        {:error, "#{path} is over 10 MiB: anchor a smaller file the claim rests on"}

      {:ok, %{type: :regular}} ->
        case File.read(file) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, reason} -> {:error, "#{path} cannot be read: #{:file.format_error(reason)}"}
        end

      {:ok, %{type: type}} ->
        {:error, "#{path} is a #{type}, not a file: anchor a file the claim rests on"}

      {:error, _reason} ->
        {:error, "#{path} is not there"}
    end
  end

  defp outside(path), do: "#{path} is outside the workspace: anchor a file of this repository"

  defp under?(path, root) do
    key = Workspace.compare_key(path)
    root = Workspace.compare_key(root)
    key == root or String.starts_with?(key, root <> "/")
  end

  ## Fields

  defp kind(kind) when is_binary(kind) do
    if kind in Memory.kinds(),
      do: {:ok, kind},
      else: {:error, "unknown kind #{kind}; one of #{Enum.join(Memory.kinds(), ", ")}"}
  end

  defp kind(_other),
    do: {:error, "a fact needs a kind: one of #{Enum.join(Memory.kinds(), ", ")}"}

  defp claim(claim) when is_binary(claim) do
    claim = claim |> String.replace("\r\n", "\n") |> String.trim()

    cond do
      claim == "" -> {:error, "nothing to remember: the claim is empty"}
      String.length(claim) > @max_claim -> {:error, "a claim is at most #{@max_claim} characters"}
      true -> {:ok, claim}
    end
  end

  defp claim(_other), do: {:error, "nothing to remember: the claim is empty"}

  # A glob of paths from the repository's top, as `recall` matches it
  # (`Troupe.Instructions.glob_match?/2`): one word of at most 200 characters, not absolute,
  # not through `..`, with `/` between directories and its braces closed.
  defp scope(nil), do: {:ok, nil}

  defp scope(scope) when is_binary(scope) do
    scope = String.trim(scope)

    cond do
      scope == "" -> {:ok, nil}
      why = not_a_glob(scope) -> {:error, why}
      true -> {:ok, scope}
    end
  end

  defp scope(_other), do: {:error, "scope is a glob, as a string"}

  defp not_a_glob(scope) do
    cond do
      String.length(scope) > @max_scope ->
        "a scope is a glob of at most #{@max_scope} characters"

      scope =~ ~r/[\s\x00-\x1f]/u ->
        "scope #{inspect(scope)} is not a glob: one pattern of paths, as `lib/**` or `*.ex`"

      Workspace.absolute?(scope) or String.starts_with?(scope, "~") ->
        "scope #{scope} is not relative: a glob from the repository's top, as `lib/**`"

      String.contains?(scope, "\\") ->
        "scope #{scope} has a backslash: write a glob with /"

      ".." in String.split(scope, "/") ->
        "scope #{scope} goes up through ..: a glob from the repository's top"

      not Troupe.Instructions.glob?(scope) ->
        "scope #{scope} is not a glob: a { is not closed"

      true ->
        nil
    end
  end

  defp by(nil), do: {:ok, "person"}
  defp by(by) when by in ["librarian", "person", "migrated"], do: {:ok, by}
  defp by("agent:" <> name = by) when name != "", do: {:ok, by}
  defp by(other), do: {:error, "unknown author #{inspect(other)}"}

  defp evidence(ctx, by, from) do
    %{
      "session" => ctx[:session],
      "seq" => ctx[:seq],
      "head" => Map.get_lazy(ctx, :head, fn -> Brief.head(from) end),
      "by" => by
    }
    |> then(
      &if(is_integer(ctx[:exit_status]),
        do: Map.put(&1, "exit_status", ctx[:exit_status]),
        else: &1
      )
    )
  end

  ## Recall

  defp words(nil), do: []

  defp words(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_.\/-]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) > 1))
    |> Enum.uniq()
  end

  defp score(_fact, []), do: 0

  defp score(fact, words) do
    text = String.downcase("#{fact["claim"]} #{fact["scope"]}")
    Enum.count(words, &String.contains?(text, &1))
  end

  defp wanted?(fact, kind, path),
    do: (kind in [nil, ""] or fact["kind"] == kind) and (path == nil or about?(fact, path))

  # A fact rests on the path, on a file under it, or its scope covers it.
  defp about?(fact, path) do
    anchored =
      Enum.any?(List.wrap(fact["anchors"]), fn
        %{"path" => p} when is_binary(p) -> p == path or String.starts_with?(p, path <> "/")
        _other -> false
      end)

    anchored or
      (is_binary(fact["scope"]) and Troupe.Instructions.glob_match?(fact["scope"], path))
  end

  defp rank(status) when status in ["current", "unanchored"], do: 0
  defp rank(_status), do: 1

  # Newest first, as a sort key ascending.
  defp desc(nil), do: 0

  defp desc(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> -DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp keep?(fact, filter) do
    Enum.all?(filter, fn
      {:kind, kind} -> fact["kind"] == kind
      {:status, status} -> fact["status"] == status
      _other -> true
    end)
  end

  # The view's order: by kind, then oldest first, ties as the file keeps them (a stable sort).
  defp order(fact) do
    {Enum.find_index(@kind_order, &(&1 == fact["kind"])) || length(@kind_order),
     to_string(fact["created_at"])}
  end

  ## Helpers

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(list) when is_list(list), do: list |> Map.new() |> stringify()

  defp new_id, do: "f_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc false
  def max_anchor_bytes, do: @max_anchor_bytes

  @doc false
  def log_unreadable(path, line_no, reason),
    do: Logger.warning("memory: skipping line #{line_no} of #{path}: #{reason}")
end
