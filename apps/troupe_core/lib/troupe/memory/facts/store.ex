defmodule Troupe.Memory.Facts.Store do
  @moduledoc """
  The one process that writes a repository's facts (Decision 838): `.troupe/memory/facts.jsonl`
  and the view generated from it, `.troupe/memory.md`.

  One per store, keyed by the repository root `Troupe.Session.Memory.locate/1` gives,
  started on first use under `Troupe.Memory.Facts.Stores` and restarted if it dies; it
  reads both files when it starts. The facts are in an ETS table only it writes and anyone
  reads, with what the two files were (size, mtime, the hash of what was read) when it last
  read or wrote them: a reader that finds either different on disk, or written within the
  second it was read, has it read them again before answering, and every write does the
  same first, so a pull, another daemon or a person's edit is never written over unread.
  A second table, written by readers too, keeps each anchor file's hash beside its size
  and mtime, so a status costs a `stat` per anchor and a hash only when a file changed.

  - **Writes are atomic.** The whole file is written beside itself and renamed over it, so
    a crash leaves the old file or the new one. A line that does not read as a fact (one
    torn by another writer, say) is skipped with a warning; the rest of the file stands.
  - **The view** is rewritten whenever the facts change (`Troupe.Memory.view/2`), its
    frontmatter carrying the brief's own stamp (`built_at`, `head`, `survey`) from one
    version of it to the next. With no facts there is no view.
  - **A person's edit is read back first.** A view whose body is not the one generated
    (its recorded hash says) is read item by item against the facts it was generated from:
    an item that is new is a fact of the person's (`by: person`, unanchored), and a fact
    whose item was taken out is forgotten. A `memory.md` that was never generated, a brief
    from before there were facts, is migrated: every item a fact (`by: migrated`,
    unanchored, checked when the brief was built, else when the file was written). One
    that turns up beside facts it was not generated from (an old brief in a checkout that
    pulled another's facts) adds its items that are not facts already and takes nothing
    away. No text is lost either way.
  - **Held to the repository.** A `.troupe`, `.troupe/memory` or either file that is a link
    to outside the root is neither read nor written (Decision 798's edge).
  """

  use GenServer

  alias Troupe.Memory
  alias Troupe.Memory.Facts
  alias Troupe.Session.Memory, as: Brief
  alias Troupe.Workspace

  require Logger

  @registry Troupe.Registry
  @supervisor Troupe.Memory.Facts.Stores

  @typedoc "What a caller reads with: the process and its two tables, and where the files are."
  @type tables :: %{
          pid: pid(),
          facts: :ets.tid(),
          hashes: :ets.tid(),
          root: Path.t(),
          md: Path.t(),
          jsonl: Path.t()
        }

  @doc false
  def child_spec(root) do
    %{id: {__MODULE__, root}, start: {__MODULE__, :start_link, [root]}, restart: :transient}
  end

  @doc false
  def start_link(root), do: GenServer.start_link(__MODULE__, root)

  @doc """
  The tables of the store for a location, started if it is not, after having it read its
  files again when either changed on disk since it last did.
  """
  @spec ensure(%{root: Path.t()}) :: tables()
  def ensure(%{root: root}) do
    tables = running(root, 100)
    if seen_fresh?(tables), do: tables, else: GenServer.call(tables.pid, :refresh, 30_000)
  end

  @doc "Every fact, as the store holds it (no `status`), in the file's order."
  @spec facts(tables()) :: [map()]
  def facts(tables) do
    case :ets.lookup(tables.facts, :facts) do
      [{:facts, facts}] -> facts
      [] -> []
    end
  end

  @doc "The brief's stamp: `built_at` (a `DateTime` or nil), `head`, `survey`."
  @spec meta(tables()) :: map()
  def meta(tables) do
    case :ets.lookup(tables.facts, :meta) do
      [{:meta, meta}] -> meta
      [] -> %{}
    end
  end

  @doc "A write, through the store."
  @spec call(tables(), term()) :: term()
  def call(tables, message), do: GenServer.call(tables.pid, message, 30_000)

  @doc """
  A file's hash now (lowercase hex sha256) and its mtime, from the cache when its size and
  mtime are as they were and it was not written in the second it was hashed. Only a
  regular file of at most `Troupe.Memory.Facts.max_anchor_bytes/0` is read.
  """
  @spec hash(tables(), Path.t()) :: {:ok, String.t(), DateTime.t()} | {:error, term()}
  def hash(tables, file) do
    with {:ok, %{type: :regular, size: size, mtime: mtime}} <- File.stat(file, time: :posix),
         true <- size <= Facts.max_anchor_bytes() || {:error, :too_large} do
      case :ets.lookup(tables.hashes, file) do
        [{^file, ^size, ^mtime, at, hash}] when mtime < at ->
          {:ok, hash, DateTime.from_unix!(mtime)}

        _other ->
          rehash(tables, file, size, mtime)
      end
    else
      {:ok, %{type: type}} -> {:error, type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rehash(tables, file, size, mtime) do
    at = System.os_time(:second)

    case File.read(file) do
      {:ok, bytes} ->
        hash = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
        :ets.insert(tables.hashes, {file, size, mtime, at, hash})
        {:ok, hash, DateTime.from_unix!(mtime)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Finding the process

  defp running(root, tries) do
    key = {:memory_facts, Workspace.compare_key(root)}

    case Registry.lookup(@registry, key) do
      [{pid, tables}] ->
        if Process.alive?(pid), do: tables, else: retry(root, tries)

      [] ->
        start(root, tries)
    end
  end

  # Started here, or by another caller at the same moment (`:ignore`): looked up again.
  defp start(root, tries) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, root}) do
      {:ok, _pid} -> running(root, tries - 1)
      :ignore -> retry(root, tries)
      {:error, _reason} when tries > 0 -> retry(root, tries)
      {:error, reason} -> exit({:memory_store, reason})
    end
  end

  # A process that just died is still registered until the registry hears of it, and its
  # supervisor starts the next one: a busy machine may take a while over both.
  defp retry(_root, 0), do: exit(:memory_store_unavailable)

  defp retry(root, tries) do
    Process.sleep(10)
    running(root, tries - 1)
  end

  ## The process

  @impl GenServer
  def init(root) do
    key = {:memory_facts, Workspace.compare_key(root)}

    tables = %{
      pid: self(),
      facts: :ets.new(:memory_facts, [:set, :protected, read_concurrency: true]),
      hashes:
        :ets.new(:memory_hashes, [:set, :public, read_concurrency: true, write_concurrency: true]),
      root: root,
      md: Path.join([root, ".troupe", "memory.md"]),
      jsonl: Path.join(root, Memory.facts_file())
    }

    case Registry.register(@registry, key, tables) do
      {:ok, _owner} -> {:ok, load(tables)}
      {:error, {:already_registered, _pid}} -> :ignore
    end
  end

  @impl GenServer
  def handle_call(:refresh, _from, tables), do: {:reply, tables, fresh(tables)}

  def handle_call({:put, fact}, _from, tables) do
    tables = fresh(tables)
    facts = facts(tables)
    same = Enum.find(facts, &same?(&1, fact))

    stored =
      if same,
        do: Map.merge(fact, Map.take(same, ["id", "created_at"])),
        else: fact

    rest = if same, do: Enum.reject(facts, &(&1["id"] == same["id"])), else: facts
    reply(tables, rest ++ [stored], meta(tables), {:ok, stored})
  end

  def handle_call({:delete, id}, _from, tables) do
    tables = fresh(tables)
    facts = facts(tables)

    if Enum.any?(facts, &(&1["id"] == id)),
      do: reply(tables, Enum.reject(facts, &(&1["id"] == id)), meta(tables), :ok),
      else: {:reply, {:error, "no fact #{id} is kept in this repository's memory"}, tables}
  end

  def handle_call({:replace, kind, new, head, now}, _from, tables) do
    tables = fresh(tables)
    kept = Enum.reject(facts(tables), &(&1["kind"] == kind))

    facts =
      Enum.reduce(new, kept, fn fact, acc ->
        if Enum.any?(acc, &same?(&1, fact)), do: acc, else: acc ++ [fact]
      end)

    reply(tables, verified(facts, now), stamped(meta(tables), head, now), :ok)
  end

  def handle_call({:stamp, head, now}, _from, tables) do
    tables = fresh(tables)

    case facts(tables) do
      [] -> {:reply, :ok, tables}
      facts -> reply(tables, verified(facts, now), stamped(meta(tables), head, now), :ok)
    end
  end

  def handle_call(:clear, _from, tables) do
    if inside?(tables.md, tables) and inside?(tables.jsonl, tables) do
      _ = File.rm(tables.md)
      _ = File.rm(tables.jsonl)
    end

    :ets.delete(tables.facts, :seen)
    {:reply, :ok, fresh(tables)}
  end

  defp reply(tables, facts, meta, answer) do
    case persist(tables, facts, meta) do
      :ok -> {:reply, answer, tables}
      {:error, reason} -> {:reply, {:error, reason}, fresh(tables)}
    end
  end

  # The same fact written again: its kind and its claim, space and case aside.
  defp same?(a, b), do: a["kind"] == b["kind"] and squish(a["claim"]) == squish(b["claim"])

  defp squish(text),
    do: text |> to_string() |> String.split() |> Enum.join(" ") |> String.downcase()

  # A check reads every unanchored fact again, which is all a check of one can be.
  defp verified(facts, now),
    do:
      Enum.map(
        facts,
        &if(&1["anchors"] in [nil, []], do: Map.put(&1, "verified_at", now), else: &1)
      )

  defp stamped(meta, head, now) do
    {:ok, at, _} = DateTime.from_iso8601(now)
    Map.merge(meta, %{built_at: at, head: head, survey: Memory.survey_version()})
  end

  ## Reading the files

  # Reads them again when either is not as it was last read or written.
  defp fresh(tables), do: if(seen_fresh?(tables), do: tables, else: load(tables))

  defp seen_fresh?(tables) do
    case :ets.lookup(tables.facts, :seen) do
      [{:seen, seen}] -> same_file?(seen.jsonl, tables.jsonl) and same_file?(seen.md, tables.md)
      [] -> false
    end
  end

  defp same_file?(%{sig: :none}, path), do: sig(path) == :none

  defp same_file?(%{sig: {_size, mtime} = sig, at: at}, path),
    do: sig(path) == sig and mtime < at

  defp sig(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{size: size, mtime: mtime}} -> {size, mtime}
      {:error, _} -> :none
    end
  end

  defp load(tables) do
    {facts, jsonl?} = read_jsonl(tables)
    md = read_md(tables)
    meta = meta_of(md)

    {facts, changed?} =
      case md do
        nil ->
          {facts, false}

        %{content: content, brief: brief, mtime: mtime} ->
          reconcile(facts, jsonl?, content, brief, mtime)
      end

    if changed? or view_differs?(facts, meta, md) do
      case persist(tables, facts, meta) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("memory: #{reason}")
      end
    end

    put_ets(tables, facts, meta)
    tables
  end

  # What the view says against the facts: migrated, read back, added to, or as generated.
  defp reconcile(facts, jsonl?, content, brief, mtime) do
    case {jsonl?, Memory.generated(content)} do
      {false, _} ->
        {migrate(brief, mtime), true}

      {true, :generated} ->
        {facts, false}

      {true, :edited} ->
        read_back(facts, brief)

      {true, :unstamped} ->
        add_missing(facts, brief, mtime)
    end
  end

  defp migrate(brief, mtime) do
    at = iso(brief.built_at || mtime)

    brief
    |> Memory.units()
    |> Enum.uniq()
    |> Enum.map(fn {kind, claim} ->
      unit_fact(kind, claim, "migrated", note_day(kind, claim) || at, brief.head)
    end)
  end

  # Items the view has that no fact reads as are the person's; facts whose item is not
  # there any more were taken out.
  defp read_back(facts, brief) do
    now = iso(DateTime.utc_now())
    {kept, added} = match(facts, Memory.units(brief))
    new = Enum.map(added, fn {kind, claim} -> unit_fact(kind, claim, "person", now, nil) end)
    {kept ++ new, length(kept) != length(facts) or new != []}
  end

  defp add_missing(facts, brief, mtime) do
    at = iso(brief.built_at || mtime)
    {_kept, added} = match(facts, Memory.units(brief))

    new =
      Enum.map(added, fn {kind, claim} -> unit_fact(kind, claim, "migrated", at, brief.head) end)

    {facts ++ new, new != []}
  end

  # The facts an item of the view still stands for, and the items no fact reads as.
  defp match(facts, units) do
    {kept, left} =
      Enum.reduce(facts, {[], units}, fn fact, {kept, units} ->
        unit = {kind_in_view(fact["kind"]), Memory.unit(fact)}

        case Enum.find_index(units, &(&1 == unit)) do
          nil -> {kept, units}
          i -> {[fact | kept], List.delete_at(units, i)}
        end
      end)

    {Enum.reverse(kept), Enum.uniq(left)}
  end

  defp kind_in_view(kind), do: if(kind in Memory.kinds(), do: kind, else: "note")

  defp unit_fact(kind, claim, by, at, head) do
    %{
      "id" => "f_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
      "kind" => kind,
      "claim" => claim,
      "scope" => nil,
      "anchors" => [],
      "evidence" => %{"session" => nil, "seq" => nil, "head" => head, "by" => by},
      "created_at" => at,
      "verified_at" => at
    }
  end

  # A note as notes were written before facts, `- 2026-09-01 root: ...`, was checked that day.
  defp note_day("note", claim) do
    with [_, day] <- Regex.run(~r/^(\d{4}-\d{2}-\d{2}) \S+: /, claim),
         {:ok, date} <- Date.from_iso8601(day) do
      date |> DateTime.new!(~T[00:00:00]) |> iso()
    else
      _ -> nil
    end
  end

  defp note_day(_kind, _claim), do: nil

  defp view_differs?(facts, _meta, nil), do: facts != []

  defp view_differs?(facts, meta, %{content: content}),
    do: Memory.view(facts, meta) != lf(content)

  defp read_jsonl(tables) do
    with true <- inside?(tables.jsonl, tables),
         {:ok, content} <- File.read(tables.jsonl) do
      facts =
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, n} -> decode(line, n, tables.jsonl) end)
        |> Enum.uniq_by(& &1["id"])

      {facts, true}
    else
      _ -> {[], false}
    end
  end

  defp decode(line, n, path) do
    if String.trim(line) == "" do
      []
    else
      case Jason.decode(line) do
        {:ok, %{"id" => id, "kind" => kind, "claim" => claim} = fact}
        when is_binary(id) and is_binary(kind) and is_binary(claim) and claim != "" ->
          [fact]

        {:ok, _other} ->
          Facts.log_unreadable(path, n, "not a fact")
          []

        {:error, _} ->
          Facts.log_unreadable(path, n, "not JSON (a torn line?)")
          []
      end
    end
  end

  # A view whose frontmatter does not read is read as all body, so what a person wrote in
  # it is still read back rather than written over.
  defp read_md(tables) do
    with true <- inside?(tables.md, tables),
         {:ok, %{mtime: mtime}} <- File.stat(tables.md, time: :posix),
         {:ok, content} <- File.read(tables.md) do
      brief =
        case Memory.parse(content) do
          {:ok, brief} -> brief
          {:error, _reason} -> elem(Memory.parse("\n" <> content), 1)
        end

      %{content: content, brief: brief, mtime: DateTime.from_unix!(mtime)}
    else
      {:error, :enoent} ->
        nil

      {:error, reason} ->
        Logger.warning("memory: ignoring unreadable #{tables.md}: #{inspect(reason)}")
        nil

      false ->
        nil
    end
  end

  defp meta_of(nil), do: %{}
  defp meta_of(%{brief: b}), do: %{built_at: b.built_at, head: b.head, survey: b.survey}

  ## Writing

  defp persist(tables, facts, meta) do
    with :ok <- writable(tables),
         :ok <- write(tables.jsonl, Enum.map_join(facts, "", &(encode(&1) <> "\n"))),
         :ok <- write_view(tables, facts, meta) do
      put_ets(tables, facts, meta)
      :ok
    end
  end

  defp write_view(tables, facts, meta) do
    case Memory.view(facts, meta) do
      nil ->
        case File.rm(tables.md) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            {:error, "cannot remove #{tables.md}: #{:file.format_error(reason)}"}
        end

      text ->
        write(tables.md, text)
    end
  end

  defp writable(tables) do
    if inside?(tables.md, tables) and inside?(tables.jsonl, tables),
      do: :ok,
      else:
        {:error,
         "not written: #{Path.join(tables.root, ".troupe")} is a link to outside its repository"}
  end

  defp write(path, text) do
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, text),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  # The contract's order, so a line reads the same way every time.
  defp encode(fact) do
    known = ~w(id kind claim scope anchors evidence created_at verified_at)
    extra = fact |> Map.drop(known ++ ["status"]) |> Enum.sort()

    known
    |> Enum.map(&{&1, Map.get(fact, &1)})
    |> Kernel.++(extra)
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  # One row for the facts, in the file's order, and one each for the stamp and what the
  # files were, all in one insert: a reader never finds them half written.
  defp put_ets(tables, facts, meta) do
    at = System.os_time(:second)
    seen = %{jsonl: %{sig: sig(tables.jsonl), at: at}, md: %{sig: sig(tables.md), at: at}}
    :ets.insert(tables.facts, [{:facts, facts}, {:meta, meta}, {:seen, seen}])
  end

  defp inside?(path, tables), do: Brief.inside?(path, tables.root)

  defp lf(text), do: String.replace(text, "\r\n", "\n")

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
