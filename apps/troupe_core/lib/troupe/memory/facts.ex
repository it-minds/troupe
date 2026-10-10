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
    refused with a sentence. An anchor read back from the file is held to the same edge
    before it is hashed, so a repository's `facts.jsonl` cannot have Troupe read
    elsewhere.
  """

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
  @recall_limit 20

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
         {:ok, anchors} <- anchors(paths, from, where.top),
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

      with {:ok, stored} <- call(where, {:put, fact}), do: {:ok, read(where, stored)}
    end
  end

  @doc """
  Every fact kept, each with its `status`, in the order the view shows them (by kind, then
  oldest first). Filters: `kind`, `status`.
  """
  @spec list(Path.t() | where(), keyword()) :: [fact()]
  def list(workspace, filter \\ []) do
    where = locate(workspace)

    where
    |> all()
    |> Enum.map(&read(where, &1))
    |> Enum.filter(&keep?(&1, filter))
    |> Enum.sort_by(&order/1)
  end

  @doc """
  The facts that answer a question, each with its `status` and evidence, at most `limit`
  (default #{@recall_limit}): by `query`, words any of which the claim or scope holds
  (case aside); by `kind`; by `path`, a file or directory (from the workspace) a fact rests
  on or whose `scope` covers it. With none of them, every fact. Current and unanchored
  facts come before the ones that may no longer be true, then the ones that match more of
  the words, then the most recently checked.
  """
  @spec recall(Path.t() | where(), keyword()) :: [fact()]
  def recall(workspace, opts \\ []) do
    where = locate(workspace)
    words = words(opts[:query])
    path = opts[:path] && relative_path(opts[:path], from(workspace, where), where.top)

    where
    |> all()
    |> Enum.filter(&wanted?(&1, opts[:kind], path))
    |> Enum.map(&{&1, score(&1, words)})
    |> Enum.reject(fn {_fact, score} -> words != [] and score == 0 end)
    |> Enum.map(fn {fact, score} -> {read(where, fact), score} end)
    |> Enum.sort_by(fn {fact, score} ->
      {rank(fact["status"]), -score, desc(fact["verified_at"])}
    end)
    |> Enum.take(Keyword.get(opts, :limit, @recall_limit))
    |> Enum.map(&elem(&1, 0))
  end

  @doc "A fact's status now: `current`, `moved`, `missing` or `unanchored`."
  @spec status(Path.t() | where(), fact()) :: String.t()
  def status(workspace, fact), do: workspace |> locate() |> check(fact) |> elem(0)

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
    where = locate(workspace)
    {core, others} = where |> all() |> Enum.split_with(&(&1["kind"] in Memory.core_kinds()))

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

  @doc """
  Replaces every fact of `kind` with one per claim, as writing a whole section of the brief
  did before there were facts, and stamps the brief as built.
  """
  @spec replace(Path.t() | where(), String.t(), [String.t()], map() | keyword()) ::
          :ok | {:error, String.t()}
  def replace(workspace, kind, claims, ctx \\ %{}) do
    where = locate(workspace)
    from = from(workspace, where)
    ctx = ctx |> Map.new() |> Map.put_new_lazy(:head, fn -> Brief.head(from) end)

    with {:ok, kind} <- kind(kind),
         {:ok, by} <- by(ctx[:by]) do
      now = now()

      facts =
        for claim <- claims, {:ok, claim} <- [claim(claim)] do
          %{
            "id" => new_id(),
            "kind" => kind,
            "claim" => claim,
            "scope" => nil,
            "anchors" => [],
            "evidence" => evidence(ctx, by, from),
            "created_at" => now,
            "verified_at" => now
          }
        end

      call(where, {:replace, kind, facts, ctx[:head], now})
    end
  end

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
        tables = tables(where)
        states = Enum.map(anchors, &anchor_state(&1, where.top, tables))
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

  defp anchor_state(%{"path" => path, "hash" => hash}, top, tables)
       when is_binary(path) and is_binary(hash) do
    with {:ok, file} <- confined(path, top),
         {:ok, now, mtime} <- Store.hash(tables, file) do
      if now == hash, do: {path, :same, nil}, else: {path, :changed, mtime}
    else
      _gone -> {path, :gone, went(Path.join(top, path), top)}
    end
  end

  defp anchor_state(anchor, _top, _tables), do: {inspect(anchor), :gone, nil}

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

  # Each path resolved from the workspace, held to it, and hashed; stored from the top.
  defp anchors(paths, from, top) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case anchor(path, from, top) do
        {:ok, anchor} -> {:cont, {:ok, acc ++ [anchor]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp anchor(path, from, top) do
    with rel when is_binary(rel) <- relative_path(path, from, top) || {:error, outside(path)},
         :ok <- within(Path.expand(path, from), from, path),
         {:ok, file} <- confined(rel, top),
         {:ok, bytes} <- read_anchor(file, path) do
      {:ok, %{"path" => rel, "hash" => sha256(bytes)}}
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

  defp scope(nil), do: {:ok, nil}
  defp scope(""), do: {:ok, nil}
  defp scope(scope) when is_binary(scope), do: {:ok, String.trim(scope)}
  defp scope(_other), do: {:error, "scope is a glob, as a string"}

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
