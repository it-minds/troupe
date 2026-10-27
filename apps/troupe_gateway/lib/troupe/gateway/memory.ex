defmodule Troupe.Gateway.Memory do
  @moduledoc """
  This machine's copy of the organisation's memory documents (#55), kept up to date while
  its person is signed in, and handed to the sessions running here.

  The plane answers `me.memory`, signed by its key, with the organisation's document and
  each of the person's teams' (`Troupe.PlaneMemory` keeps the copy and checks it on every
  read). The daemon asks for it:

    * at every `identity.link` that carries a plane token, which a client makes whenever it
      connects and whenever it renews its token;
    * every five minutes while it holds a token (`poll_ms`), so a save on the plane
      reaches a running session here without anybody signing in again: a signed poll, as
      the daemon dials the plane and nothing dials the daemon;
    * when a client hands it an answer it fetched itself (`troupe config pull`,
      `config.memory`).

  Every ask carries what each session running here read at its last turn (`sessions`, each
  document's scope, name, version and hash and when the turn began), which the plane keeps
  so its console sees which sessions are behind: a field on the poll the daemon makes anyway,
  not a call of its own. `status/1` says where this machine stands, for `troupe memory
  --status`.

  **Local only** (`Troupe.Gateway.LocalOnly`): a session under it is left out of that
  report, and an agent's entry from it is refused; it reads the copy kept here. While every
  client attached is in Local only, the poll asks nothing.

  One writer for all three (`keep/2`): a copy the pin refuses is not kept, and the copy
  before stays. A copy whose documents changed is announced to every client as
  `config.changed` (scope `memory`, the documents that changed as its keys), and given to
  every session running here, whose agents read it from their next turn and say what
  changed (`Troupe.Session.PlaneMemory`). A copy that changed nothing says nothing.

  Signing out of the plane the copy came from drops it (`forget/1`): the organisation's
  words are its members', and a machine whose person signed out is no longer one. The key
  the machine pinned for the plane stays, as the trust it is.

  The person's own document is among them, last, and is the one this daemon also writes,
  as its person: `put_own/1` sends their edit (`me.memory.put`, the whole text over the
  version they edited) or an agent's entry (`append`, which `remember` with `level: "me"`
  sends through `append/2`, installed as `Troupe.UserMemory`'s host), then asks `me.memory`
  again, so the sessions running here read it from their next turn rather than the next
  poll. Signed out, there is nowhere to send either, and it says so.
  """

  use GenServer

  alias Troupe.Gateway.{Connections, LocalOnly, Plane}
  alias Troupe.PlaneKeys
  alias Troupe.PlaneMemory
  alias Troupe.Protocol.Memory, as: Shape
  alias Troupe.Protocol.Memory.Entries

  require Logger

  @poll_ms :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Ask the linked plane for `me.memory` now and keep the answer. `:ok` where there is no
  plane, no token, or a plane from before memory; otherwise what `keep/2` answers.
  """
  @spec refresh() :: :ok | {:ok, map()} | {:error, term()}
  def refresh do
    with url when is_binary(url) <- Plane.url(),
         {:ok, answer} <- Plane.call("me.memory", asked()) do
      keep(url, answer)
    else
      {:error, {:rpc, %{"code" => -32_601}}} -> :ok
      {:error, :unlinked} -> :ok
      {:error, _reason} = error -> error
      _no_plane -> :ok
    end
  end

  # What every ask of `me.memory` carries: what each session running here read at its last
  # turn, by session id, when the turn began, and each document's scope, name, version and
  # hash, never its text, so the console sees who is behind. Nothing else of a session, and
  # nothing of one under Local only, whose client promised that nothing of it leaves here.
  defp asked do
    reads = Enum.reject(Troupe.Session.PlaneMemory.reads(), &LocalOnly.session?(&1["session_id"]))
    %{"sessions" => reads}
  end

  @doc """
  Where this machine's memory stands, for its person's own debugging (`troupe memory
  --status`): the copy kept here (`plane_url`, `fetched_at`, `documents`, each `scope`,
  `name`, `version` and `hash`, and `problem` where the copy is refused), the plane's
  documents in force now where it could be asked (`in_force`, then kept as every answer is)
  and whether the copy was `current`, and each session running here with what its last turn
  read and whether that is `current` against the copy now. `reason` says why the plane was
  not asked. `ask: false` (a client in Local only) asks nothing of the plane. `held` is each
  document as the copy holds it (`scope`, `name`, `version`, `text` and its `entries`), the
  person's own among them, and `in_effect` what the sessions here read of them, per topic.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    {held, problem} =
      case PlaneMemory.read_cache() do
        {:ok, cached} -> {cached, nil}
        :absent -> {nil, nil}
        {:error, reason} -> {nil, reason}
      end

    held_stamps = Enum.map((held && held["documents"]) || [], &Shape.stamp/1)

    # The plane's answer, checked and kept as every answer is, is what is in force now.
    asked =
      with :ok <- asking(Keyword.get(opts, :ask, true)),
           {:ok, url} <- signed_in(),
           {:ok, answer} <- plane_call("me.memory", asked()),
           {:ok, _kept} <- keep(url, answer) do
        {:ok, documents_now()}
      end

    now = documents_now()

    %{
      "plane_url" => (held && held["plane_url"]) || Plane.url(),
      "fetched_at" => held && held["fetched_at"],
      "path" => Troupe.Paths.display(PlaneMemory.cache_path()),
      "documents" => held_stamps,
      # Each document as the copy holds it, which the sessions here read: what a memory
      # screen shows, read-only, where the plane is not asked.
      "held" => held_levels(held),
      # What the sessions here read of it, per topic the closest level's entry and what it
      # replaces, as the prompt takes them (every team of the person's at one rank).
      "in_effect" => held |> held_levels() |> Entries.levels() |> Entries.in_effect() |> Entries.effect_json(),
      "problem" => problem,
      "sessions" =>
        Enum.map(Troupe.Session.PlaneMemory.reads(), &Map.put(&1, "current", same?(&1["documents"], now)))
    }
    |> Map.merge(in_force(asked, held_stamps))
  end

  defp in_force({:ok, stamps}, held), do: %{"in_force" => stamps, "current" => same?(held, stamps), "reason" => nil}
  defp in_force({:error, :signed_out}, _held), do: %{"in_force" => nil, "current" => nil, "reason" => "signed out: the plane was not asked"}
  defp in_force({:error, :local_only}, _held), do: %{"in_force" => nil, "current" => nil, "reason" => "Local only: the plane was not asked"}
  defp in_force({:error, reason}, _held), do: %{"in_force" => nil, "current" => nil, "reason" => sentence(reason)}

  defp asking(true), do: :ok
  defp asking(false), do: {:error, :local_only}

  # Each document with its level, version and text, and nothing else of it, and its entries
  # read off the text here, without who wrote them: the plane is not asked.
  defp held_levels(%{"documents" => documents}) when is_list(documents),
    do: Enum.map(documents, &(&1 |> Map.take(~w(scope name version text)) |> Map.put("entries", Entries.parse(&1["text"] || ""))))

  defp held_levels(_none), do: []

  defp documents_now do
    case PlaneMemory.read_cache() do
      {:ok, cached} -> Enum.map(cached["documents"] || [], &Shape.stamp/1)
      _none -> []
    end
  end

  defp same?(a, b), do: MapSet.new(List.wrap(a), &stamp_key/1) == MapSet.new(List.wrap(b), &stamp_key/1)
  defp stamp_key(stamp), do: {stamp["scope"], stamp["name"], stamp["version"], stamp["hash"]}

  @doc """
  Keep a plane's `me.memory` answer as this machine's copy, as the plane signed it. Answers
  what was kept: `plane_url`, `path`, `documents` (each `scope`, `name`, `version`) and
  `changed`, the documents whose version differs from the copy before.
  """
  @spec keep(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def keep(plane_url, answer) when is_binary(plane_url) and is_map(answer) do
    before = documents(PlaneMemory.read_cache())

    with {:ok, body, signed?} <- PlaneKeys.check(plane_url, answer, "memory"),
         {:ok, kept} <-
           PlaneMemory.save(plane_url, body, PlaneMemory.cache_path(), signature(signed?, answer)) do
      changes = PlaneMemory.changes(before, kept["documents"])
      if changes != [], do: announce(changes)

      {:ok,
       %{
         "plane_url" => kept["plane_url"],
         "path" => Troupe.Paths.display(kept["path"]),
         "documents" => Enum.map(kept["documents"], &Map.take(&1, ["scope", "name", "version"])),
         "changed" => changes
       }}
    end
  end

  def keep(_plane_url, _answer),
    do: {:error, "document must be the plane's me.memory answer, an object"}

  @doc """
  Drop this machine's copy, where it came from `plane_url` (any plane's, for `nil`), and
  take the documents away from the sessions running here at their next turn. Answers
  whether there was one.
  """
  @spec forget(String.t() | nil) :: boolean()
  def forget(plane_url) do
    with {:ok, cached} <- copy(),
         true <-
           is_nil(plane_url) or PlaneKeys.plane(plane_url) == PlaneKeys.plane(cached["plane_url"]),
         :ok <- File.rm(PlaneMemory.cache_path()) do
      changes = PlaneMemory.changes(cached["documents"], [])
      if changes != [], do: announce(changes)
      true
    else
      _none -> false
    end
  end

  # The copy as written, whether or not it still checks: an edited one goes too.
  defp copy do
    with {:ok, text} <- File.read(PlaneMemory.cache_path()),
         {:ok, %{"plane_url" => url} = cached} when is_binary(url) <- Jason.decode(text) do
      {:ok, Map.update(cached, "documents", [], &List.wrap/1)}
    else
      _none -> :absent
    end
  end

  defp documents({:ok, cached}), do: cached["documents"]
  defp documents(_none), do: []

  defp signature(:signed, answer), do: answer["signed"]
  defp signature(:unsigned, _answer), do: nil

  # Every session here is given what the copy now holds, read as a session reads it, and
  # takes it at its next turn; then every client hears which documents changed, so one that
  # heard it and sends a turn finds the session already has them.
  defp announce(changes) do
    {memory, _warnings} = PlaneMemory.in_force(nil)
    _given = Troupe.Session.PlaneMemory.put_all(memory)

    Connections.broadcast("config.changed", %{
      "scope" => "memory",
      "path" => Troupe.Paths.display(PlaneMemory.cache_path()),
      "keys" => Enum.map(changes, &key/1)
    })
  end

  defp key(%{"scope" => "organisation"}), do: "memory:organisation"
  defp key(%{"scope" => "user"}), do: "memory:user"
  defp key(%{"scope" => scope, "name" => name}), do: "memory:#{scope}/#{name}"

  # -- the person's own -------------------------------------------------------------

  @doc """
  The person's own document as the plane has it now, asked of the plane and kept as every
  answer of `me.memory` is: `version` (`0` for none), `text`, `bytes`, `limit`, who saved it
  and when, and `plane_url`; and `documents`, the organisation's and the person's teams' as
  the same answer carried them, each with its text, which their sessions read before it. `{:error, :signed_out}` with no plane token. `blame: true` adds
  `lines`: each line with who wrote it, the version it came in and the session an agent's
  entry came from (`troupe memory --blame`).
  """
  #
  # Every document comes with its `entries`, one per `## Topic` section with who last changed
  # it and when and in how many sessions it was used, and beside them `organisation`, its
  # name, and `roles`, which levels the person may change: what the desktop app's Memory view
  # and the terminal's `/memory` show.
  @spec own(keyword()) :: {:ok, map()} | {:error, :signed_out | term()}
  def own(opts \\ []) do
    ask = Map.put(asked(), "entries", true)
    ask = if opts[:blame], do: Map.put(ask, "blame", true), else: ask

    with {:ok, url} <- signed_in(),
         {:ok, answer} <- plane_call("me.memory", ask) do
      _kept = keep(url, answer)
      own_of(answer, url)
    end
  end

  @doc """
  Save the person's own document on the plane: `%{"text" => ..., "version" => n}` or
  `%{"entries" => [...], "version" => n}` for their edit, `%{"append" => entry, "topic" =>
  topic}` for one entry. Then the copy here is asked for again, so the sessions running here
  read it from their next turn. Answers the plane's: `changed`, the `entry` and `topic` as
  kept for an append, and `user`, the document as it now stands.
  """
  @spec put_own(map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def put_own(params) when is_map(params) do
    with {:ok, url} <- signed_in(),
         {:ok, saved} <-
           plane_call(
             "me.memory.put",
             Map.take(params, ["text", "entries", "version", "append", "topic", "session", "agent"])
           ) do
      _refreshed = refresh()
      {:ok, Map.put(saved, "plane_url", url)}
    end
  end

  @doc """
  The history of the person's own document, as the plane has it: every version, one
  version's text beside another's and the line diff between them (`version` and `against`,
  the plane's `me.memory.history`), with `plane_url`.
  """
  @spec history(map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def history(params) when is_map(params) do
    with {:ok, url} <- signed_in(),
         {:ok, answer} <- plane_call("me.memory.history", Map.take(params, ["version", "against"])) do
      {:ok, Map.put(answer, "plane_url", url)}
    end
  end

  @doc """
  Roll the person's own document back to version `to`, over `version`, the one in force as
  they saw it: the plane saves that version's text as the next one. Then the copy here is
  asked for again, as after a save, so the sessions running here read it from their next turn.
  """
  @spec rollback_own(map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def rollback_own(params) when is_map(params) do
    with {:ok, url} <- signed_in(),
         {:ok, saved} <- plane_call("me.memory.rollback", Map.take(params, ["to", "version"])) do
      _refreshed = refresh()
      {:ok, Map.put(saved, "plane_url", url)}
    end
  end

  @doc """
  Where `remember` with `level: "me"` sends its entry on this machine (`Troupe.UserMemory`):
  `put_own/1` with the entry, naming the session and the agent it came from, which the plane
  keeps beside the version as who wrote the line. The plane's refusal comes back as its
  sentence. A session under Local only sends nothing, and says so.
  """
  @spec append(String.t(), Troupe.Tool.Ctx.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :signed_out | String.t()}
  def append(entry, ctx, topic \\ nil) do
    if LocalOnly.session?(ctx.session_id), do: {:error, local_only()}, else: send_entry(entry, ctx, topic)
  end

  defp local_only do
    "this session is under Local only, so nothing of it goes to the plane, the person's own " <>
      "memory included. Remember it for this repository instead (level repository, the " <>
      "default), or ask them to turn Local only off"
  end

  defp send_entry(entry, ctx, topic) do
    params =
      %{"append" => entry, "session" => ctx.session_id, "agent" => agent(ctx)}
      |> then(&if(topic, do: Map.put(&1, "topic", topic), else: &1))

    case put_own(params) do
      {:ok, saved} ->
        {:ok, %{"entry" => saved["entry"], "topic" => saved["topic"], "version" => get_in(saved, ["user", "version"])}}

      {:error, :signed_out} -> {:error, :signed_out}
      {:error, reason} -> {:error, sentence(reason)}
    end
  end

  defp agent(%{definition: %{name: name}}) when is_binary(name), do: name
  defp agent(%{agent_path: [_ | _] = path}), do: List.last(path)
  defp agent(_ctx), do: nil

  @doc "What a refusal of the plane's says, in words."
  @spec sentence(term()) :: String.t()
  def sentence({:rpc, %{"data" => %{"reason" => reason}}}) when is_binary(reason), do: reason
  def sentence({:rpc, %{"code" => -32_601}}), do: "the plane keeps no memory of a person's own; it is from before it"
  def sentence({:rpc, %{"message" => message}}), do: "the plane refused it (#{message})"
  def sentence(:unauthorized), do: "the plane did not take this machine's sign-in; sign in again"
  def sentence({:update_required, sentence}), do: sentence

  def sentence(%{__exception__: true} = error),
    do: "the plane could not be reached (#{Exception.message(error)})"

  def sentence(reason), do: format(reason)

  defp signed_in do
    case Plane.url() do
      url when is_binary(url) -> if Plane.linked?(), do: {:ok, url}, else: {:error, :signed_out}
      _none -> {:error, :signed_out}
    end
  end

  defp plane_call(method, params) do
    case Plane.call(method, params) do
      {:error, :unlinked} -> {:error, :signed_out}
      other -> other
    end
  end

  # The person's own, and beside it the levels above it that their sessions read first (the
  # organisation's and each of their teams'), as the plane answered them to this person: what
  # the desktop app's Memory view sets the person's own entries against.
  #
  # Each with its entries; a plane from before them answers none, and they are read here
  # off the text, the same sections without who wrote them.
  #
  # A team of theirs with no document is there too, empty, so a client lists every team.
  defp own_of(%{"user" => %{} = own} = answer, url) do
    above =
      for %{"scope" => scope} = document <- List.wrap(answer["documents"]), scope != "user",
          do: document |> Map.take(["scope", "name", "version", "hash", "updated_at", "text", "entries"]) |> with_entries()

    named = for %{"scope" => "team", "name" => name} <- above, do: name

    empty =
      for name <- List.wrap(answer["teams"]), is_binary(name), name not in named,
          do: %{"scope" => "team", "name" => name, "version" => 0, "text" => "", "entries" => []}

    above = Enum.sort_by(above ++ empty, &{Enum.find_index(Shape.scopes(), fn s -> s == &1["scope"] end), &1["name"] || ""})

    {:ok,
     own
     |> with_entries()
     |> Map.put("plane_url", url)
     |> Map.put("documents", above)
     |> Map.put("organisation", answer["organisation"])
     |> Map.put("roles", roles(answer["roles"]))}
  end

  defp own_of(_answer, _url),
    do: {:error, {:rpc, %{"code" => -32_601, "message" => "method_not_found"}}}

  # Which levels the person may change, as the plane says (`roles`): the organisation's for a
  # platform admin, a team's for its admins. A plane from before it says nothing, so nobody's.
  defp roles(%{} = roles),
    do: %{
      "platform_admin" => roles["platform_admin"] == true,
      "team_admin" => Enum.filter(List.wrap(roles["team_admin"]), &is_binary/1)
    }

  defp roles(_none), do: %{"platform_admin" => false, "team_admin" => []}

  defp with_entries(%{"entries" => entries} = document) when is_list(entries), do: document
  defp with_entries(document), do: Map.put(document, "entries", Entries.parse(document["text"] || ""))

  @doc """
  What a new session of the person's in one of their teams (`team`, their first by name for
  none) reads, on a worker profile they may use through it where `profile` names one: the
  plane's `memory.in_effect`, as them, with `plane_url`.
  """
  @spec in_effect(map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def in_effect(params) when is_map(params) do
    with {:ok, url} <- signed_in(),
         {:ok, answer} <- plane_call("memory.in_effect", Map.take(params, ["team", "profile"])) do
      {:ok, Map.put(answer, "plane_url", url)}
    end
  end

  # What a level of the organisation's memory the person administers asks of the plane, as
  # them: the plane's own answer, or its own refusal where they may not.
  @admin_arguments %{
    "admin.memory.get" => ~w(scope name version against),
    "admin.memory.preview" => ~w(scope name text entries),
    "admin.memory.put" => ~w(scope name text entries version)
  }

  @doc "The organisation's levels' methods the daemon sends on, as its person (`admin/2`)."
  @spec admin_methods() :: [String.t()]
  def admin_methods, do: Map.keys(@admin_arguments)

  @doc """
  One of `admin_methods/0`, sent to the plane as this daemon's person with the arguments it
  takes and nothing else: what a team admin edits their team's memory with, and a platform
  admin the organisation's, from their own app. The plane decides who may: a refusal comes
  back as it gave it. A save asks for the copy here again, so the sessions running here read
  it from their next turn.
  """
  @spec admin(String.t(), map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def admin(method, params) when is_map_key(@admin_arguments, method) do
    with {:ok, url} <- signed_in(),
         {:ok, answer} <- plane_call(method, Map.take(params, @admin_arguments[method])) do
      _refreshed = if method == "admin.memory.put", do: refresh()
      {:ok, Map.put(answer, "plane_url", url)}
    end
  end

  # -- the poll ---------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # This daemon is where an agent's entry for its person's own memory goes.
    :ok = Troupe.UserMemory.install(&__MODULE__.append/3)

    every =
      Keyword.get(opts, :poll_ms, Application.get_env(:troupe_gateway, :memory_poll_ms, @poll_ms))

    {:ok, schedule(%{every: every})}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    # While every client attached is in Local only, the plane is not asked; the next poll
    # after one that is not asks again.
    if Plane.linked?() and not LocalOnly.paused?() do
      case refresh() do
        {:error, reason} ->
          Logger.info(
            "troupe-daemon: the organisation's memory was not refreshed: #{format(reason)}"
          )

        _kept ->
          :ok
      end
    end

    {:noreply, schedule(state)}
  end

  defp schedule(%{every: every} = state) when is_integer(every) and every > 0 do
    Process.send_after(self(), :poll, every)
    state
  end

  defp schedule(state), do: state

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
