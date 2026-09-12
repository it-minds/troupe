defmodule Troupe.Worker.Bundles do
  @moduledoc """
  The config bundles this pod has fetched, verified and written to disk.

  A bundle reaches a pod as an announcement, never as content: `config.updated` names a
  channel, a version and a hash, and the pod asks the plane for the document with
  `bundle.fetch`. What comes back is hashed over its canonical JSON and compared with
  what was announced before a byte of it is trusted, validated the way the plane
  validated it at publish, and then written under `<state>/bundles/<hash>/` — agents,
  skills and the document itself. The directory is named by hash, so a session pinned
  to version 3 reads the same files however many versions are published after it, and
  two versions with identical content share one directory.

  A pod that cannot fetch keeps serving what it has. The announcement may still carry
  the MCP servers inline for one release, and those are applied when the fetch fails,
  so a plane that is briefly unreachable costs the pod nothing it did not already lack.
  What the pod is running is reported back in every heartbeat as `bundle_hash`, which is
  what turns the plane's adoption view from "always stale" into a fact.

  The index — which version of which channel lives in which directory — is kept in
  `bundles/index.json` beside the directories, so a restarted pod knows what it has
  without asking, and a version it once had but whose directory is gone (a lost volume)
  is fetched again rather than assumed.
  """

  use GenServer

  alias Troupe.Paths
  alias Troupe.Protocol.Bundle
  alias Troupe.Worker.MCP
  alias Troupe.Worker.Plane.Link

  require Logger

  @fetch_timeout_ms 30_000
  # A version the index names and the disk lacks is fetched again shortly after boot,
  # and then at intervals until the plane answers: a pod that lost its volume should
  # not wait for the next publish to get its bundle back.
  @refetch_first_ms 5_000
  @refetch_retry_ms 30_000
  @current_key {__MODULE__, :current_hash}

  defstruct [:root, :fetch, :mcp, index: %{}, current: nil, refetch_timer: nil]

  @type entry :: %{
          hash: String.t(),
          version: term(),
          channel: String.t() | nil,
          dir: Path.t()
        }

  # -- api --------------------------------------------------------------------

  @doc """
  Start the registry.

  Options: `:state_dir` (defaults to the platform state directory), `:fetch` (a
  function of the `bundle.fetch` params answering `{:ok, result} | {:error, reason}`;
  defaults to asking the plane over the link), `:mcp` (the MCP registry to hand server
  configs to; `nil` to hand them to nobody).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  A `config.updated` push: fetch, verify, materialise and make current.

  Returns what was applied, or `{:fallback, ...}` when the fetch failed but the push
  carried its MCP servers inline and those were applied instead.
  """
  @spec announce(GenServer.server(), map()) ::
          {:ok, map()} | {:fallback, map()} | {:error, term()}
  def announce(server \\ __MODULE__, params) do
    GenServer.call(server, {:announce, params}, 120_000)
  end

  @doc """
  The directory for a bundle a session is pinned to, fetching it first if this pod has
  never seen it.

  Takes `%{version, hash, channel}`; the hash may be nil when the plane could not
  resolve the version, in which case whatever the plane hands back for the version is
  verified against the hash *it* claims and recorded under that.
  """
  @spec ensure(GenServer.server(), map()) :: {:ok, Path.t()} | {:error, term()}
  def ensure(server \\ __MODULE__, pin) do
    GenServer.call(server, {:ensure, pin}, 120_000)
  end

  @doc "The directory a materialised version lives in, if this pod has it."
  @spec dir_for(GenServer.server(), term()) :: {:ok, Path.t()} | :error
  def dir_for(server \\ __MODULE__, version) do
    GenServer.call(server, {:dir_for, version})
  end

  @doc """
  The newest bundle this pod has materialised — `%{hash, version, channel, dir}` — or
  `nil`. Safe to call when the registry is not running, which is what a laptop or a
  test without one looks like.
  """
  @spec current(GenServer.server()) :: entry() | nil
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  catch
    :exit, _ -> nil
  end

  @doc """
  The hash a heartbeat claims, or `nil` when there is nothing to claim.

  Read from a persistent term rather than asked of the process: the link reads this
  on every heartbeat, and the registry may at that moment be waiting on the link for a
  fetch. A call in that direction would have the two waiting on each other until a
  timeout let go.
  """
  @spec current_hash() :: String.t() | nil
  def current_hash, do: :persistent_term.get(@current_key, nil)

  @doc "Where bundles live under a state directory."
  @spec root(Path.t() | nil) :: Path.t()
  def root(state_dir \\ nil), do: Path.join(Paths.state_dir(state_dir), "bundles")

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe bundles")
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      root: root(Keyword.get(opts, :state_dir)),
      fetch: Keyword.get(opts, :fetch, &fetch_over_link/1),
      mcp: Keyword.get(opts, :mcp, :registry)
    }

    {:ok, state |> load() |> publish_current(), {:continue, :restore}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # A registry that has gone should not leave its claim behind for a heartbeat to
    # repeat; the next one to start publishes its own.
    if :persistent_term.get(@current_key, nil) == state.current do
      :persistent_term.erase(@current_key)
    end

    :ok
  end

  # What a restarted pod does with what it finds: the current bundle's MCP servers go
  # back to the registry so the pod has its tools before the plane says anything, and
  # a current bundle whose directory is missing is fetched again.
  @impl GenServer
  def handle_continue(:restore, %{current: nil} = state), do: {:noreply, state}

  def handle_continue(:restore, state) do
    case Map.fetch(state.index, state.current) do
      {:ok, entry} ->
        case read_document(entry.dir) do
          {:ok, parsed} ->
            hand_to_mcp(state, parsed)

          {:error, reason} ->
            Logger.warning("troupe worker: bundle #{entry.hash} on disk: #{inspect(reason)}")
        end

        {:noreply, state}

      :error ->
        {:noreply, schedule_refetch(state, @refetch_first_ms)}
    end
  end

  @impl GenServer
  def handle_call({:announce, params}, _from, state) do
    pin = %{
      hash: params["bundle_hash"],
      version: params["version"],
      channel: params["channel"]
    }

    case install(state, pin) do
      {:ok, entry, parsed, state} ->
        state = make_current(state, entry)
        tools = hand_to_mcp(state, parsed)
        {:reply, {:ok, Map.put(entry, :tools, tools)}, state}

      {:error, reason, state} ->
        Logger.error(
          "troupe worker: could not apply bundle #{inspect(pin.hash)}: #{describe(reason)}"
        )

        case params["mcp_servers"] do
          servers when is_list(servers) and servers != [] ->
            tools = put_servers(state, servers)
            {:reply, {:fallback, %{reason: reason, tools: tools}}, state}

          _ ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:ensure, pin}, _from, state) do
    case install(state, normalise(pin)) do
      {:ok, entry, _parsed, state} -> {:reply, {:ok, entry.dir}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:dir_for, version}, _from, state) do
    reply =
      case find_version(state, version) do
        nil -> :error
        entry -> {:ok, entry.dir}
      end

    {:reply, reply, state}
  end

  def handle_call(:current, _from, state) do
    {:reply, state.current && Map.get(state.index, state.current), state}
  end

  @impl GenServer
  def handle_info(:refetch, state) do
    state = %{state | refetch_timer: nil}

    case Map.fetch(state.index, state.current) do
      {:ok, _entry} ->
        {:noreply, state}

      :error ->
        case install(state, %{hash: state.current, version: nil, channel: nil}) do
          {:ok, entry, parsed, state} ->
            hand_to_mcp(state, parsed)
            {:noreply, make_current(state, entry)}

          {:error, reason, state} ->
            Logger.info(
              "troupe worker: bundle #{state.current} not back yet: #{describe(reason)}"
            )

            {:noreply, schedule_refetch(state, @refetch_retry_ms)}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- fetch, verify, materialise ---------------------------------------------

  # Already here is already here: a bundle is immutable and its directory is named by
  # its hash, so nothing on disk under that name can be anything but this bundle.
  defp install(state, %{hash: hash} = pin) when is_binary(hash) do
    case Map.fetch(state.index, hash) do
      {:ok, %{dir: dir} = entry} ->
        if File.dir?(dir) do
          {:ok, entry, nil, remember_version(state, entry, pin)} |> reread(entry)
        else
          fetch_and_install(state, pin)
        end

      :error ->
        fetch_and_install(state, pin)
    end
  end

  # No hash to go on — the plane could not resolve the version when it activated. The
  # version alone may still name something this pod has.
  defp install(state, pin) do
    case find_version(state, pin.version) do
      %{dir: dir} = entry when is_binary(dir) ->
        if File.dir?(dir),
          do: {:ok, entry, nil, state} |> reread(entry),
          else: fetch_and_install(state, pin)

      nil ->
        fetch_and_install(state, pin)
    end
  end

  # An entry that was already on disk has no parsed document in hand; the caller that
  # wants one (to re-hand MCP servers on announce) reads it back from `bundle.json`.
  defp reread({:ok, entry, nil, state}, entry) do
    case read_document(entry.dir) do
      {:ok, parsed} -> {:ok, entry, parsed, state}
      {:error, reason} -> {:error, {:unreadable, reason}, state}
    end
  end

  defp fetch_and_install(state, pin) do
    params =
      %{"hash" => pin.hash, "channel" => pin.channel, "version" => pin.version}
      |> Enum.reject(&match?({_key, nil}, &1))
      |> Map.new()

    with {:ok, result} <- fetch(state, params),
         {:ok, content} <- content_of(result),
         {:ok, hash} <- verify(content, pin.hash, result["hash"]),
         {:ok, parsed} <- validate(content),
         dir = dir_for_hash(state, hash),
         :ok <- materialise(parsed, content, dir) do
      entry = %{
        hash: hash,
        version: result["version"] || pin.version,
        channel: result["channel"] || pin.channel,
        dir: dir
      }

      Logger.info(
        "troupe worker: bundle #{hash} (#{entry.channel} v#{entry.version}) materialised"
      )

      {:ok, entry, parsed, state |> put_entry(entry) |> persist()}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp fetch(state, params) do
    case state.fetch.(params) do
      {:ok, %{} = result} -> {:ok, result}
      {:ok, other} -> {:error, {:fetch_failed, {:unexpected, other}}}
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  rescue
    exception -> {:error, {:fetch_failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:fetch_failed, reason}}
  end

  defp content_of(%{"content" => content}) when is_map(content), do: {:ok, content}
  defp content_of(_result), do: {:error, {:fetch_failed, :no_content}}

  # The announced hash is the one that counts. When there was none — an activation the
  # plane could not resolve — the response's own claim is checked instead, so the
  # document is at least what the plane says it is and never something that merely
  # arrived on the socket.
  defp verify(content, announced, claimed) do
    actual = Bundle.hash(content)
    expected = announced || claimed

    cond do
      is_nil(expected) -> {:ok, actual}
      actual == expected -> {:ok, actual}
      true -> {:error, {:hash_mismatch, expected, actual}}
    end
  end

  # Re-checked here even though the plane checked it at publish: the plane's check is
  # the plane's, and a pod that trusted it would be trusting whatever it fetched.
  defp validate(content) do
    case Bundle.validate(content) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, errors} -> {:error, {:invalid_bundle, errors}}
    end
  end

  defp materialise(parsed, content, dir) do
    case Bundle.materialize(parsed, content, dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:materialise_failed, reason}}
    end
  end

  # The hash spelled as a directory name. `sha256:` is how a hash reads in a log and on
  # the wire, and a colon is not a character every filesystem a worker runs on allows
  # in a name, so it becomes a dash on disk and nowhere else.
  defp dir_for_hash(state, hash), do: Path.join(state.root, String.replace(hash, ":", "-"))

  defp read_document(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "bundle.json")),
         {:ok, content} <- Jason.decode(text) do
      validate(content)
    end
  end

  # -- the index --------------------------------------------------------------

  defp put_entry(state, entry), do: %{state | index: Map.put(state.index, entry.hash, entry)}

  # A pin that names a version for a hash already on disk teaches the index that
  # version, so `dir_for/1` answers for it afterwards.
  defp remember_version(state, entry, pin) do
    if is_nil(entry.version) and not is_nil(pin.version) do
      learned = %{entry | version: pin.version, channel: pin.channel || entry.channel}
      state |> put_entry(learned) |> persist()
    else
      state
    end
  end

  defp make_current(state, entry) do
    if state.current == entry.hash,
      do: state,
      else: %{state | current: entry.hash} |> persist() |> publish_current()
  end

  # Only a bundle that is actually on disk is claimed. An index that names a current
  # hash whose directory is gone is a pod that is *behind*, and the plane should see it
  # that way until the refetch lands.
  defp publish_current(state) do
    case Map.fetch(state.index, state.current) do
      {:ok, _entry} -> :persistent_term.put(@current_key, state.current)
      :error -> :persistent_term.erase(@current_key)
    end

    state
  end

  defp find_version(_state, nil), do: nil

  defp find_version(state, version) do
    wanted = to_string(version)

    state.index
    |> Map.values()
    |> Enum.filter(&(to_string(&1.version) == wanted))
    # The current channel's first, when a pod has seen more than one.
    |> Enum.sort_by(&(&1.hash != state.current))
    |> List.first()
  end

  defp normalise(pin) do
    %{
      hash: Map.get(pin, :hash) || Map.get(pin, "hash"),
      version: Map.get(pin, :version) || Map.get(pin, "version"),
      channel: Map.get(pin, :channel) || Map.get(pin, "channel")
    }
  end

  defp index_path(state), do: Path.join(state.root, "index.json")

  defp load(state) do
    case File.read(index_path(state)) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"bundles" => bundles} = stored} when is_list(bundles) ->
            %{state | index: index_of(state, bundles), current: stored["current"]}

          _ ->
            state
        end

      {:error, _} ->
        state
    end
  end

  # The entries the index file lists, keyed by hash.
  defp index_of(state, bundles) do
    bundles
    |> Enum.filter(&is_binary(&1["hash"]))
    |> Map.new(fn b ->
      {b["hash"],
       %{
         hash: b["hash"],
         version: b["version"],
         channel: b["channel"],
         dir: dir_for_hash(state, b["hash"])
       }}
    end)
    # An entry whose directory is gone is not one this pod has. It is dropped here and,
    # if it was current, fetched again by the restore step.
    |> Map.filter(fn {_hash, entry} -> File.dir?(entry.dir) end)
  end

  defp persist(state) do
    document = %{
      "current" => state.current,
      "bundles" =>
        state.index
        |> Map.values()
        |> Enum.map(&%{"hash" => &1.hash, "version" => &1.version, "channel" => &1.channel})
        |> Enum.sort_by(& &1["hash"])
    }

    File.mkdir_p!(state.root)
    File.write!(index_path(state), Jason.encode!(document, pretty: true) <> "\n")
    state
  end

  defp schedule_refetch(state, after_ms) do
    if state.refetch_timer, do: Process.cancel_timer(state.refetch_timer)
    %{state | refetch_timer: Process.send_after(self(), :refetch, after_ms)}
  end

  # -- MCP --------------------------------------------------------------------

  defp hand_to_mcp(state, parsed), do: put_servers(state, Bundle.mcp_server_configs(parsed))

  defp put_servers(%{mcp: nil}, _configs), do: []

  defp put_servers(%{mcp: :registry} = state, configs) do
    case Process.whereis(MCP) do
      nil -> []
      pid -> put_servers(%{state | mcp: pid}, configs)
    end
  end

  defp put_servers(%{mcp: mcp}, configs) do
    case MCP.put_servers(mcp, configs) do
      {:ok, names} -> names
    end
  catch
    :exit, reason ->
      Logger.warning(
        "troupe worker: MCP registry did not take the bundle's servers: #{inspect(reason)}"
      )

      []
  end

  # -- the link ---------------------------------------------------------------

  defp fetch_over_link(params) do
    case Process.whereis(Link) do
      nil -> {:error, :no_link}
      link -> Link.request(link, "bundle.fetch", params, @fetch_timeout_ms)
    end
  end

  defp describe({:hash_mismatch, expected, actual}),
    do: "the document hashes to #{actual}, not the announced #{expected}; refused"

  defp describe({:invalid_bundle, errors}), do: "it does not validate: #{Enum.join(errors, "; ")}"
  defp describe({:fetch_failed, reason}), do: "the fetch failed: #{inspect(reason)}"
  defp describe(other), do: inspect(other)
end
