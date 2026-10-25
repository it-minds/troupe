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

  alias Troupe.Gateway.{Connections, Plane}
  alias Troupe.PlaneKeys
  alias Troupe.PlaneMemory

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
         {:ok, answer} <- Plane.call("me.memory", %{}) do
      keep(url, answer)
    else
      {:error, {:rpc, %{"code" => -32_601}}} -> :ok
      {:error, :unlinked} -> :ok
      {:error, _reason} = error -> error
      _no_plane -> :ok
    end
  end

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
  and when, and `plane_url`. `{:error, :signed_out}` with no plane token.
  """
  @spec own() :: {:ok, map()} | {:error, :signed_out | term()}
  def own do
    with {:ok, url} <- signed_in(),
         {:ok, answer} <- plane_call("me.memory", %{}) do
      _kept = keep(url, answer)
      own_of(answer, url)
    end
  end

  @doc """
  Save the person's own document on the plane: `%{"text" => ..., "version" => n}` for their
  edit, `%{"append" => entry}` for one entry. Then the copy here is asked for again, so the
  sessions running here read it from their next turn. Answers the plane's: `changed`, the
  `entry` as kept for an append, and `user`, the document as it now stands.
  """
  @spec put_own(map()) :: {:ok, map()} | {:error, :signed_out | term()}
  def put_own(params) when is_map(params) do
    with {:ok, url} <- signed_in(),
         {:ok, saved} <- plane_call("me.memory.put", Map.take(params, ["text", "version", "append"])) do
      _refreshed = refresh()
      {:ok, Map.put(saved, "plane_url", url)}
    end
  end

  @doc """
  Where `remember` with `level: "me"` sends its entry on this machine (`Troupe.UserMemory`):
  `put_own/1` with the entry. The plane's refusal comes back as its sentence.
  """
  @spec append(String.t(), Troupe.Tool.Ctx.t()) :: {:ok, map()} | {:error, :signed_out | String.t()}
  def append(entry, _ctx) do
    case put_own(%{"append" => entry}) do
      {:ok, saved} -> {:ok, %{"entry" => saved["entry"], "version" => get_in(saved, ["user", "version"])}}
      {:error, :signed_out} -> {:error, :signed_out}
      {:error, reason} -> {:error, sentence(reason)}
    end
  end

  @doc "What a refusal of the plane's says, in words."
  @spec sentence(term()) :: String.t()
  def sentence({:rpc, %{"data" => %{"reason" => reason}}}) when is_binary(reason), do: reason
  def sentence({:rpc, %{"code" => -32_601}}), do: "the plane keeps no memory of a person's own; it is from before it"
  def sentence({:rpc, %{"message" => message}}), do: "the plane refused it (#{message})"
  def sentence(:unauthorized), do: "the plane did not take this machine's sign-in; sign in again"
  def sentence({:update_required, sentence}), do: sentence
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

  defp own_of(%{"user" => %{} = own}, url), do: {:ok, Map.put(own, "plane_url", url)}

  defp own_of(_answer, _url),
    do: {:error, {:rpc, %{"code" => -32_601, "message" => "method_not_found"}}}

  # -- the poll ---------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # This daemon is where an agent's entry for its person's own memory goes.
    :ok = Troupe.UserMemory.install(&__MODULE__.append/2)

    every =
      Keyword.get(opts, :poll_ms, Application.get_env(:troupe_gateway, :memory_poll_ms, @poll_ms))

    {:ok, schedule(%{every: every})}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    if Plane.linked?() do
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
